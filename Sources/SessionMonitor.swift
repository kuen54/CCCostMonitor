import Foundation
import CoreServices
import Darwin

// MARK: - Live session monitor (app layer)
//
// Maintains the list of LIVE interactive Claude Code sessions by combining the
// pure registry decode (Core_Sessions.swift) with process facts this layer can
// observe but the core cannot: liveness via kill(2), a PID-reuse guard via the
// process name (ps), and an optional start-time sanity check. Watches
// ~/.claude/sessions with a low-latency FSEventStream (status changes reflect
// sub-second) plus a backstop poll Timer (catches process death that doesn't
// rewrite a file). All I/O runs on a private serial queue; results publish on
// the main thread, and only when the snapshot actually changed.
//
// NOT part of CCCostCore — never add this file to Package.swift.

/// Phase-3 runtime targeting facts for ONE live session — everything needed to
/// raise its terminal window/pane, observed by the app layer but deliberately
/// kept OUT of the Codable SessionInfo (these are ephemeral process facts, not
/// registry data). Published as a parallel `[sessionId: SessionTarget]` map.
struct SessionTarget: Equatable {
    /// Controlling tty, bare ("ttys000"); nil when the session has none.
    let tty: String?
    /// The owning GUI terminal (Otty / Apple Terminal / iTerm2 / …).
    let terminal: TerminalKind
    /// Human display name of the terminal app (for hints / `open -a`).
    let appName: String?
    /// Bundle id of the terminal app (for `open -b` and otty-cli discovery).
    let bundleId: String?
    /// Running pid of the terminal GUI app (for NSRunningApplication.activate).
    let appPid: Int?
    /// A tmux/screen server sits between the shell and the GUI app.
    let multiplexed: Bool
    /// The session's cwd, copied here for the Otty fuzzy (cwd) join.
    let cwd: String
}

/// Everything the monitor publishes in one Equatable payload so the consumer can
/// guard a single comparison.
struct SessionScan: Equatable {
    var sessions: [SessionInfo]
    /// cwd → display label (git top-level basename when resolvable, else cwd
    /// basename). The view overlays this onto SessionLogic.grouped labels.
    var labels: [String: String]
    /// True only in the fallback case: no registry, but running `claude`
    /// processes were found → "update Claude Code to see live status".
    var oldClaudeHint: Bool
    /// Phase 2: any session finished a turn (busy/waiting → idle/shell) that the
    /// user hasn't looked at yet. Derived by the monitor across scans via the
    /// pure SessionLogic.stepDoneUnseen reducer; drives the notch's green dot.
    /// Equals `!doneUnseenIds.isEmpty`.
    var anyDoneUnseen: Bool = false
    /// Phase 6: the exact sessionIds that finished a turn unseen (= keys of the
    /// monitor's doneUnseen tracker). Lets the Session LIST give each finished-
    /// unseen row its own green dot, not just the notch's aggregate cue.
    var doneUnseenIds: Set<String> = []
    /// Phase 3: sessionId → terminal targeting facts for click-to-jump.
    var targets: [String: SessionTarget] = [:]
    /// Phase 5: sessionId → session title (newest `ai-title` in the transcript).
    /// Absent when the session has no transcript / no title yet (view falls back).
    var titles: [String: String] = [:]
    /// Phase 5: sessionId → the latest clean user instruction (one line). Absent
    /// when none found (view falls back to a placeholder).
    var instructions: [String: String] = [:]

    static let empty = SessionScan(sessions: [], labels: [:], oldClaudeHint: false)
}

final class SessionMonitor {
    private let onChange: (SessionScan) -> Void
    private let sessionsDir: String
    private let projectsDir: URL

    // Private serial queue: ALL file/ps/lsof/git work runs here, never on main.
    private let queue = DispatchQueue(label: "com.claude.cc-cost-monitor.sessions", qos: .utility)

    private var fsStream: FSEventStreamRef?
    private var pollTimer: DispatchSourceTimer?
    private var started = false

    // Backstop-poll gating (queue only). The poll exists ONLY to catch silent
    // process death (a SIGKILL leaves a stale registry file FSEvents never
    // reports); with zero live sessions there is nothing to catch, so it is
    // suspended — see reconcilePoll(). `fsHealthy` is true only when the FS
    // watcher is proven to be watching a dir that already existed; otherwise the
    // poll must stay on (a stream created on a missing dir won't attach when it
    // is later mkdir'd, and the old-Claude ps fallback has no sessions dir at
    // all). `pollInterval` is the currently scheduled cadence, nil = suspended.
    private var fsHealthy = false
    private var pollInterval: TimeInterval?
    private var lastLiveCount = 0
    // Suspension is only safe when FSEvents on the sessions dir is the COMPLETE
    // detector. Two more guards beyond fsHealthy:
    //   sawRegistry — we've seen ≥1 *.json this run, proving this is modern
    //     Claude Code (registry-backed). Until then we might be in the old-Claude
    //     ps fallback (scanClaudeProcessesAsSessions), whose processes never
    //     touch the watched dir, so FSEvents would never wake us for them.
    //   lastReadOK — the latest sessions-dir read actually succeeded. A failed
    //     read (dir vanished / transient FS error) reports zero sessions but is
    //     NOT trustworthy zero; suspending on it would strand a live session.
    // Both are set in computeScan() before reconcilePoll() runs.
    private var sawRegistry = false
    private var lastReadOK = false

    // queue-confined state
    private var lastScan: SessionScan?
    private var labelCache: [String: String] = [:]   // cwd → resolved label

    // queue-confined transcript-summary cache (Phase 5): sessionId → the last
    // read title/instruction plus the (path,size,mtime) it was read from. A
    // stable session is just a `stat` (no re-read); only a session whose
    // transcript file changed is re-read. Dead sessions are pruned each scan.
    private struct TranscriptCacheEntry {
        let path: String
        let size: Int
        let mtime: TimeInterval
        let title: String?
        let instruction: String?
    }
    private var transcriptCache: [String: TranscriptCacheEntry] = [:]

    // queue-confined negative cache for the transcript GLOB (Phase B): sessionId
    // → when its glob last came up empty. A just-launched session (transcript not
    // written yet) or a synthetic `proc-` session re-globs at most once per
    // `transcriptGlobRetry` instead of walking all of ~/.claude/projects every
    // 2 s tick. Short TTL on purpose — we watch sessions/, not projects/, so a
    // re-glob is the only way a freshly written transcript title is discovered.
    private var transcriptGlobMiss: [String: Double] = [:]
    private static let transcriptGlobRetry: TimeInterval = 20

    // queue-confined done-unseen tracker state (Phase 2): the previous scan's
    // per-session statuses + the sessionIds that finished a turn unseen (→ when).
    private var prevStatuses: [String: SessionStatus] = [:]
    private var doneUnseen: [String: Double] = [:]

    // Poll cadence. Faster while the UI is on screen, slower (but still alive,
    // to catch process death) when hidden.
    private var activeInterval: TimeInterval = 2.0
    private var idleInterval: TimeInterval = 6.0
    private var isActive = false

    init(sessionsDir: String? = nil, projectsDir: URL? = nil,
         onChange: @escaping (SessionScan) -> Void) {
        self.onChange = onChange
        self.sessionsDir = sessionsDir
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")
        self.projectsDir = projectsDir
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString)
                .appendingPathComponent(".claude/projects"), isDirectory: true)
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.started else { return }
            self.started = true
            self.startFSWatcher()
            // The first rescan sets lastLiveCount and reconcilePoll() starts the
            // backstop poll iff it's actually needed (sessions present, or no
            // healthy FSEvents to rely on).
            self.rescan()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self, self.started else { return }
            self.started = false
            self.cancelPoll()
            self.fsHealthy = false
            if let s = self.fsStream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                self.fsStream = nil
            }
        }
    }

    /// Switch the backstop poll cadence with UI visibility. Fast when the user is
    /// looking (popover/notch open), slow otherwise. FSEvents covers status
    /// changes regardless; the poll only exists to notice silent process death.
    func setActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self = self, self.started, self.isActive != active else { return }
            self.isActive = active
            // rescan()'s tail reconciles the poll cadence to the new isActive
            // (and leaves it suspended if there's still nothing to poll).
            self.rescan()
        }
    }

    // MARK: - FSEvents (low latency)

    private func startFSWatcher() {
        fsHealthy = false
        // Only a stream over a dir that ALREADY exists reliably reports child
        // creation; one created on a missing dir won't attach when the dir is
        // later mkdir'd (picked up only on a restart), so it can't justify
        // suspending the poll. Stat it up front and gate fsHealthy on it.
        var isDir: ObjCBool = false
        let dirExists = FileManager.default
            .fileExists(atPath: sessionsDir, isDirectory: &isDir) && isDir.boolValue
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let monitor = Unmanaged<SessionMonitor>.fromOpaque(info).takeUnretainedValue()
            // Already on the monitor's serial queue (set below) — rescan directly.
            monitor.rescan()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [sessionsDir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,  // sub-second latency so status flips reflect fast
            // WatchRoot: deliver an event if the sessions dir itself is deleted/
            // recreated (new inode). Without it, a runtime `rm -rf` + recreate of
            // ~/.claude/sessions would strand us while the poll is suspended (the
            // stream watches the old inode, which sees nothing); the root-change
            // event wakes a rescan that resumes the poll and re-detects sessions.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        ) else { return }
        // Deliver callbacks on our serial queue so rescan never touches main.
        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) {
            fsStream = stream
            // Trust suspension only when we're watching a real, pre-existing dir.
            fsHealthy = dirExists
        } else {
            // The sessions dir may not exist yet on a fresh machine; the poll
            // timer keeps us correct and a later mkdir is picked up on restart.
            NSLog("CCCostMonitor: session FSEventStreamStart failed; poll-only")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsStream = nil
        }
    }

    // MARK: - Backstop poll

    private func startPollTimer(interval: TimeInterval) {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.rescan() }
        pollTimer = timer
        pollInterval = interval
        timer.resume()
    }

    private func cancelPoll() {
        pollTimer?.cancel()
        pollTimer = nil
        pollInterval = nil
    }

    /// Bring the backstop poll into line with the current state (queue only).
    /// The poll's sole job is to notice silent process death (a SIGKILL leaves a
    /// stale registry file that FSEvents never reports). With zero live sessions
    /// there is nothing to catch, so — IF FSEvents is healthy enough to wake us
    /// when the next session file appears — suspend the poll entirely: no timer,
    /// no periodic CPU wakeups while no Claude Code session is running. When a
    /// new file lands, the FSEvents callback runs rescan(), lastLiveCount goes
    /// positive, and this restarts the poll. While !fsHealthy (stream failed, or
    /// watching a not-yet-existent dir, or the old-Claude ps fallback) the poll
    /// always runs — it's the only safety net there. Only (re)builds the timer
    /// when the desired cadence actually changes, so steady ticks aren't reset.
    private func reconcilePoll() {
        guard started else { cancelPoll(); return }
        // Suspend ONLY when FSEvents is the complete, trustworthy detector and
        // there's genuinely nothing live. Any doubt → keep polling (safe default).
        let canSuspend = fsHealthy && sawRegistry && lastReadOK && lastLiveCount == 0
        guard !canSuspend else { cancelPoll(); return }
        let desired = isActive ? activeInterval : idleInterval
        if pollInterval != desired { startPollTimer(interval: desired) }
    }

    // MARK: - Scan (queue only)

    private func rescan(now: Double = Date().timeIntervalSince1970) {
        var scan = computeScan(now: now)
        // Fold this scan into the done-unseen tracker (pure reducer, our clock).
        let stepped = SessionLogic.stepDoneUnseen(
            prev: prevStatuses, current: scan.sessions,
            doneUnseen: doneUnseen, seenAll: false, now: now)
        prevStatuses = stepped.prev
        doneUnseen = stepped.doneUnseen
        scan.doneUnseenIds = Set(doneUnseen.keys)
        scan.anyDoneUnseen = !doneUnseen.isEmpty
        if scan != lastScan {
            lastScan = scan
            DispatchQueue.main.async { [weak self] in self?.onChange(scan) }
        }
        // Drive the backstop poll off the freshly observed live count: it stays
        // on while sessions exist (to catch silent death) and suspends to zero
        // wakeups when none do. Always reconcile — an unchanged scan keeps the
        // same count, so this is a no-op then.
        lastLiveCount = scan.sessions.count
        reconcilePoll()
    }

    /// Phase 6: the user ENGAGED with ONE session (clicked its list row to jump):
    /// forget just that session's "finished, unseen" cue, leaving every other
    /// session's green dot intact. Queue-confined; republishes guarded on the main
    /// thread only when that id was actually pending. prevStatuses is intentionally
    /// NOT touched: the cleared id is already at its done status there (it only
    /// entered doneUnseen via a busy/waiting → idle TRANSITION, which advanced prev
    /// to that idle/shell status), so the next stepDoneUnseen sees prev == current
    /// for it (no transition) and will NOT re-add the green we just cleared.
    func markSeen(sessionId: String) {
        queue.async { [weak self] in
            guard let self = self,
                  self.doneUnseen.removeValue(forKey: sessionId) != nil else { return }
            guard var scan = self.lastScan else { return }
            scan.doneUnseenIds = Set(self.doneUnseen.keys)
            scan.anyDoneUnseen = !self.doneUnseen.isEmpty
            self.lastScan = scan
            DispatchQueue.main.async { [weak self] in self?.onChange(scan) }
        }
    }

    private func computeScan(now: Double) -> SessionScan {
        let (parsed, hadRegistryFiles, readOK) = parseRegistry()
        // Feed the poll-suspension guards (read before reconcilePoll, which runs
        // at the tail of rescan after this returns). sawRegistry latches sticky:
        // once this machine has shown a registry file, it's modern Claude Code.
        lastReadOK = readOK
        if hadRegistryFiles { sawRegistry = true }

        let sessions: [SessionInfo]
        var oldHint = false
        if !parsed.isEmpty {
            // Modern Claude Code: trust the registry, keep only the live ones.
            sessions = filterAlive(parsed)
        } else if hadRegistryFiles {
            // Registry files exist but none are listable (e.g. only sdk-cli / `-p`
            // sessions). This IS modern Claude Code — do NOT show the upgrade hint;
            // there simply are no interactive sessions to display.
            sessions = []
        } else {
            // Fallback ladder: registry truly absent (no *.json at all). If `claude`
            // is actually running, surface synthesized entries + a one-time upgrade
            // hint (old Claude Code that doesn't write a session registry).
            let synth = scanClaudeProcessesAsSessions()
            sessions = synth
            oldHint = !synth.isEmpty
        }

        // Collapse any duplicate-sessionId entries (the same logical session
        // present under two pid files — `claude --resume` adopts it under a new
        // pid while the old file lingers, or it's open in two windows) to ONE
        // freshest entry BEFORE ordering, so the list can't render a session
        // twice with disagreeing dots and targets/summaries below aren't doubled.
        let unique = SessionLogic.dedupBySessionId(sessions)
        // Stable order so the Equatable publish-guard never thrashes.
        let ordered = unique.sorted { a, b in
            a.cwd != b.cwd ? a.cwd < b.cwd : a.sessionId < b.sessionId
        }
        let labels = resolveLabels(for: ordered)
        let targets = gatherTargets(for: ordered)
        let (titles, instructions) = gatherSummaries(for: ordered, now: now)
        return SessionScan(sessions: ordered, labels: labels,
                           oldClaudeHint: oldHint, targets: targets,
                           titles: titles, instructions: instructions)
    }

    // MARK: - Transcript summaries (Phase 5)

    /// For each live session, resolve its transcript title + latest instruction,
    /// served from a (path,size,mtime) cache so a stable session costs only a
    /// `stat` and only a changed transcript is re-read. The expensive glob runs
    /// at most once per session (cached path is re-`stat`ed thereafter; re-glob
    /// only if it vanished). All on the monitor's serial queue (off-main).
    private func gatherSummaries(for sessions: [SessionInfo], now: Double)
        -> (titles: [String: String], instructions: [String: String]) {
        let fm = FileManager.default
        var titles: [String: String] = [:]
        var instructions: [String: String] = [:]
        var live = Set<String>()
        for s in sessions {
            live.insert(s.sessionId)
            // Synthesized fallback sessions (old Claude Code with no registry)
            // never have a transcript on disk — never glob for them.
            if s.sessionId.hasPrefix("proc-") { continue }
            // Reuse the cached path while it still exists; else (re-)glob, but
            // skip the walk if a recent glob already came up empty (negative
            // cache, short TTL — see transcriptGlobMiss).
            var path = transcriptCache[s.sessionId]?.path
            if path == nil || !fm.fileExists(atPath: path!) {
                if let lastMiss = transcriptGlobMiss[s.sessionId],
                   now - lastMiss < SessionMonitor.transcriptGlobRetry { continue }
                path = AITitleReader.transcriptPath(sessionId: s.sessionId,
                                                    projectsDir: projectsDir)
                if path == nil { transcriptGlobMiss[s.sessionId] = now; continue }
                transcriptGlobMiss.removeValue(forKey: s.sessionId)  // resolved → clear miss
            }
            guard let p = path else { continue }
            let attrs = try? fm.attributesOfItem(atPath: p)
            let size = (attrs?[.size] as? Int) ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?
                .timeIntervalSinceReferenceDate ?? -1
            let entry: TranscriptCacheEntry
            if let hit = transcriptCache[s.sessionId],
               hit.path == p, hit.size == size, hit.mtime == mtime {
                entry = hit                                  // unchanged → no re-read
            } else {
                let sum = AITitleReader.summary(inFileAt: p)
                entry = TranscriptCacheEntry(path: p, size: size, mtime: mtime,
                                             title: sum.title, instruction: sum.instruction)
                transcriptCache[s.sessionId] = entry
            }
            if let t = entry.title { titles[s.sessionId] = t }
            if let i = entry.instruction { instructions[s.sessionId] = i }
        }
        // Drop cache entries for sessions that are no longer live. Filter
        // unconditionally: a live session with no transcript path is never
        // inserted, so `cache.count == live.count` can hold while the cache still
        // holds a dead entry — a count guard would leak it. The cache is tiny.
        if !transcriptCache.isEmpty {
            transcriptCache = transcriptCache.filter { live.contains($0.key) }
        }
        if !transcriptGlobMiss.isEmpty {
            transcriptGlobMiss = transcriptGlobMiss.filter { live.contains($0.key) }
        }
        return (titles, instructions)
    }

    // MARK: - Jump targeting (Phase 3)

    // queue-confined targeting cache (Phase G): sessionId → (pid, resolved
    // target). Keyed by sessionId for eviction, but pid-checked on hit: `claude
    // --resume` reuses a sessionId under a NEW pid, so a stale entry from the old
    // pid must miss and re-resolve — otherwise a jump would target the dead
    // process's tty/window. (HEAD recomputed every scan, so this can't regress.)
    private var targetCache: [String: (pid: Int, target: SessionTarget)] = [:]

    /// Per-session targeting map for click-to-jump. Targeting facts (tty / owning
    /// GUI terminal / app pid / multiplexed) are INVARIANT for a session's process
    /// lifetime, so they're cached by sessionId and the expensive full-process-
    /// table `ps -Ao` runs ONLY when there's at least one uncached live session —
    /// steady state spawns no targeting ps at all. A degraded resolve (the session
    /// pid wasn't in the snapshot — a racy/partial table) is returned for this
    /// scan but NOT cached, so it's retried next scan. Dead sessions are evicted.
    /// The pure table-parse + ppid-walk live in SessionLogic (testable); only the
    /// `ps` spawn and the Bundle Info.plist read (app name/id) stay here.
    private func gatherTargets(for sessions: [SessionInfo]) -> [String: SessionTarget] {
        guard !sessions.isEmpty else { targetCache.removeAll(); return [:] }
        let live = Set(sessions.map { $0.sessionId })
        var result: [String: SessionTarget] = [:]
        var uncached: [SessionInfo] = []
        for s in sessions {
            if let hit = targetCache[s.sessionId], hit.pid == s.pid {
                result[s.sessionId] = hit.target               // same session AND same pid
            } else {
                uncached.append(s)                             // new / resumed (pid changed) → re-resolve
            }
        }
        if !uncached.isEmpty,
           let out = runProcess("/bin/ps", ["-Ao", "pid=,ppid=,tty=,comm="]) {
            let table = SessionLogic.parseProcTable(out)
            for s in uncached {
                let pt = SessionLogic.resolveTarget(table: table, pid: s.pid)
                let info = pt.appBundlePath.map { terminalAppInfo(bundlePath: $0) }
                let target = SessionTarget(
                    tty: pt.tty, terminal: pt.terminal,
                    appName: info?.name, bundleId: info?.bundleId,
                    appPid: pt.appPid, multiplexed: pt.multiplexed, cwd: s.cwd)
                result[s.sessionId] = target
                if pt.pidPresent { targetCache[s.sessionId] = (s.pid, target) }  // never cache a racy miss
            }
        }
        if !targetCache.isEmpty { targetCache = targetCache.filter { live.contains($0.key) } }
        return result
    }

    // bundlePath → (bundleId, display name), memoized (cheap Info.plist read).
    private var terminalInfoCache: [String: (bundleId: String?, name: String?)] = [:]
    private func terminalAppInfo(bundlePath: String) -> (bundleId: String?, name: String?) {
        if let hit = terminalInfoCache[bundlePath] { return hit }
        let bundle = Bundle(path: bundlePath)
        let bundleId = bundle?.bundleIdentifier
        let name = (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? {
                let base = (bundlePath as NSString).lastPathComponent
                return base.hasSuffix(".app") ? String(base.dropLast(4)) : base
            }()
        let info = (bundleId, name)
        terminalInfoCache[bundlePath] = info
        return info
    }

    /// Decode every *.json under the sessions dir, keep listable (cli + status)
    /// entries. A malformed file is skipped, not fatal. Also reports whether ANY
    /// *.json file existed at all, so the caller can tell "modern CC with no
    /// listable sessions" apart from "no registry → maybe old CC".
    private func parseRegistry() -> (sessions: [SessionInfo], hadFiles: Bool, readOK: Bool) {
        let fm = FileManager.default
        // Distinguish "dir read failed" (readOK=false → untrustworthy zero, never
        // suspend the poll on it) from "dir genuinely empty" (readOK=true).
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            return ([], false, false)
        }
        let jsonNames = names.filter { $0.hasSuffix(".json") }
        var out: [SessionInfo] = []
        for name in jsonNames {
            let path = (sessionsDir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let info = SessionLogic.parse(jsonData: data),
                  SessionLogic.listable(info) else { continue }
            out.append(info)
        }
        return (out, !jsonNames.isEmpty, true)
    }

    // MARK: - Liveness

    private struct ProcFact { let comm: String; let startEpoch: TimeInterval? }

    /// Keep only sessions whose pid is (a) alive, (b) actually a `claude` process
    /// (PID-reuse guard via comm), and (c) not an obvious pid-reuse by start time.
    ///
    /// Start-time check is ASYMMETRIC by design. `startedAt` is the session-init
    /// instant, which legitimately LAGS process spawn (`lstart`) by node boot +
    /// claude init — measured 2–88s positive on real live sessions. So a process
    /// whose lstart is at/before the recorded startedAt is the same session; a
    /// symmetric window would false-drop live sessions. The only genuine pid-reuse
    /// signature is a live process that spawned CLEARLY AFTER the recorded session
    /// start, so we reject solely on `lstart - startedAt` exceeding a wide margin.
    /// The comm guard already makes reuse astronomically unlikely; this is a weak
    /// secondary. Skipped gracefully when either timestamp is unparseable.
    private static let pidReuseMargin: TimeInterval = 120
    private func filterAlive(_ sessions: [SessionInfo]) -> [SessionInfo] {
        let pids = sessions.map { $0.pid }
        let facts = psFacts(for: pids)  // ONE batched ps call
        return sessions.filter { s in
            guard processExists(s.pid) else { return false }
            // kill(2) is the load-bearing liveness check. The ps facts only REFINE
            // it (PID-reuse guards). When ps gave us a row for this pid, apply the
            // comm-name + start-time guards; when it didn't (ps failed / timed out
            // / returned nothing), trust kill alone rather than dropping the
            // session — otherwise one flaky ps spawn blanks the whole list.
            guard let fact = facts[s.pid] else { return true }
            if !fact.comm.contains("claude") { return false }   // pid reused by a non-claude proc
            if let start = fact.startEpoch, let recorded = s.startedAt {
                // Only reject when the live process started well AFTER the recorded
                // session — the pid-reuse signature. A lagging startedAt (negative
                // here) is the normal, healthy case and must be kept.
                if start - recorded / 1000.0 > SessionMonitor.pidReuseMargin { return false }
            }
            return true
        }
    }

    /// kill(pid, 0): 0 = exists & signalable; EPERM = exists but not ours (still
    /// alive). Anything else (ESRCH) = gone.
    private func processExists(_ pid: Int) -> Bool {
        let r = kill(pid_t(pid), 0)
        return r == 0 || (r == -1 && errno == EPERM)
    }

    /// ONE `ps -o pid=,lstart=,comm= -p <pids>` for all candidate pids.
    private func psFacts(for pids: [Int]) -> [Int: ProcFact] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = runProcess("/bin/ps", ["-o", "pid=,lstart=,comm=", "-p", list]) else { return [:] }
        var result: [Int: ProcFact] = [:]
        for line in out.split(separator: "\n") {
            if let (pid, fact) = parsePsLine(String(line)) { result[pid] = fact }
        }
        return result
    }

    /// Parse "  5185 Wed Jun 24 21:38:58 2026 /path/to/claude" → (pid, comm,
    /// lstart-as-local-epoch). The column split is the pure, testable
    /// SessionLogic.parsePsLine; the lstart→epoch conversion (local TZ) stays here.
    private func parsePsLine(_ line: String) -> (Int, ProcFact)? {
        guard let p = SessionLogic.parsePsLine(line) else { return nil }
        let epoch = SessionMonitor.lstartFormatter.date(from: p.lstart)?.timeIntervalSince1970
        return (p.pid, ProcFact(comm: p.comm, startEpoch: epoch))
    }

    /// `ps -o lstart=` local-time format, e.g. "Wed Jun 24 21:38:58 2026".
    private static let lstartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"  // default (local) timezone
        return f
    }()

    // MARK: - Fallback proc scan (old Claude Code without a registry)

    /// Find running `.../bin/claude` processes and synthesize SessionInfo entries
    /// (status .unknown, cwd via lsof). Never crashes on lsof permission errors.
    private func scanClaudeProcessesAsSessions() -> [SessionInfo] {
        guard let out = runProcess("/bin/ps", ["-axo", "pid=,lstart=,comm="]) else { return [] }
        var sessions: [SessionInfo] = []
        for line in out.split(separator: "\n") {
            guard let (pid, fact) = parsePsLine(String(line)),
                  fact.comm.contains("/claude") || fact.comm.hasSuffix("claude") else { continue }
            let cwd = lsofCwd(pid) ?? ""
            let startedMs = fact.startEpoch.map { $0 * 1000.0 }
            sessions.append(SessionInfo(
                pid: pid,
                sessionId: "proc-\(pid)",         // synthetic stable id
                cwd: cwd,
                status: .unknown,
                startedAt: startedMs,
                kind: "interactive",
                entrypoint: "cli"))
        }
        return sessions
    }

    /// `lsof -a -p <pid> -d cwd -Fn` → the working directory (n-line). Returns nil
    /// on any failure (permission, no output) — never throws.
    private func lsofCwd(_ pid: Int) -> String? {
        guard let out = runProcess("/usr/sbin/lsof",
                                   ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]) else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    // MARK: - Display labels (git top-level)

    /// Resolve a display label per distinct cwd, memoized. Prefers the git
    /// top-level dir basename (so a session in a subdir shows the repo name),
    /// falling back to the cwd basename. Cheap: git runs at most once per cwd.
    private func resolveLabels(for sessions: [SessionInfo]) -> [String: String] {
        var labels: [String: String] = [:]
        for cwd in Set(sessions.map { $0.cwd }) where !cwd.isEmpty {
            if let cached = labelCache[cwd] {
                labels[cwd] = cached
                continue
            }
            let label: String
            if let top = runProcess("/usr/bin/git", ["-C", cwd, "rev-parse", "--show-toplevel"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty {
                label = SessionLogic.basename(top)
            } else {
                label = SessionLogic.basename(cwd)
            }
            labelCache[cwd] = label
            labels[cwd] = label
        }
        return labels
    }

    // MARK: - Process helper

    /// Run a short-lived command on the serial queue, return raw stdout (callers
    /// `split`/`trim` as needed) or nil on launch failure / non-UTF8. Delegates to
    /// the shared ProcessRunner (watchdog-killed, stderr → /dev/null).
    private func runProcess(_ launchPath: String, _ args: [String],
                            timeout: TimeInterval = 5.0) -> String? {
        ProcessRunner.run(launchPath, args, timeout: timeout)?.output
    }
}
