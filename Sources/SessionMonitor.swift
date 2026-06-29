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
    var anyDoneUnseen: Bool = false
    /// Phase 3: sessionId → terminal targeting facts for click-to-jump.
    var targets: [String: SessionTarget] = [:]

    static let empty = SessionScan(sessions: [], labels: [:], oldClaudeHint: false)
}

final class SessionMonitor {
    private let onChange: (SessionScan) -> Void
    private let sessionsDir: String

    // Private serial queue: ALL file/ps/lsof/git work runs here, never on main.
    private let queue = DispatchQueue(label: "com.claude.cc-cost-monitor.sessions", qos: .utility)

    private var fsStream: FSEventStreamRef?
    private var pollTimer: DispatchSourceTimer?
    private var started = false

    // queue-confined state
    private var lastScan: SessionScan?
    private var labelCache: [String: String] = [:]   // cwd → resolved label

    // queue-confined done-unseen tracker state (Phase 2): the previous scan's
    // per-session statuses + the sessionIds that finished a turn unseen (→ when).
    private var prevStatuses: [String: SessionStatus] = [:]
    private var doneUnseen: [String: Double] = [:]

    // Poll cadence. Faster while the UI is on screen, slower (but still alive,
    // to catch process death) when hidden.
    private var activeInterval: TimeInterval = 2.0
    private var idleInterval: TimeInterval = 6.0
    private var isActive = false

    init(sessionsDir: String? = nil, onChange: @escaping (SessionScan) -> Void) {
        self.onChange = onChange
        self.sessionsDir = sessionsDir
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.started else { return }
            self.started = true
            self.startFSWatcher()
            self.startPollTimer(interval: self.idleInterval)
            self.rescan()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self, self.started else { return }
            self.started = false
            self.pollTimer?.cancel()
            self.pollTimer = nil
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
            self.startPollTimer(interval: active ? self.activeInterval : self.idleInterval)
            self.rescan()
        }
    }

    // MARK: - FSEvents (low latency)

    private func startFSWatcher() {
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
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return }
        // Deliver callbacks on our serial queue so rescan never touches main.
        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) {
            fsStream = stream
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
        timer.resume()
    }

    // MARK: - Scan (queue only)

    private func rescan(now: Double = Date().timeIntervalSince1970) {
        var scan = computeScan()
        // Fold this scan into the done-unseen tracker (pure reducer, our clock).
        let stepped = SessionLogic.stepDoneUnseen(
            prev: prevStatuses, current: scan.sessions,
            doneUnseen: doneUnseen, seenAll: false, now: now)
        prevStatuses = stepped.prev
        doneUnseen = stepped.doneUnseen
        scan.anyDoneUnseen = !doneUnseen.isEmpty
        if scan != lastScan {
            lastScan = scan
            DispatchQueue.main.async { [weak self] in self?.onChange(scan) }
        }
    }

    /// The user is now looking at session state (notch opened / Session tab
    /// shown): forget every pending "finished, unseen" cue. Queue-confined like
    /// the rest of the monitor's state; republishes the cleared flag on the main
    /// thread (only when it was actually set, so no needless publish). prevStatuses
    /// is intentionally NOT reset — transition tracking continues uninterrupted.
    func markSeen() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.doneUnseen.removeAll()
            guard var scan = self.lastScan, scan.anyDoneUnseen else { return }
            scan.anyDoneUnseen = false
            self.lastScan = scan
            DispatchQueue.main.async { [weak self] in self?.onChange(scan) }
        }
    }

    private func computeScan() -> SessionScan {
        let (parsed, hadRegistryFiles) = parseRegistry()

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

        // Stable order so the Equatable publish-guard never thrashes.
        let ordered = sessions.sorted { a, b in
            a.cwd != b.cwd ? a.cwd < b.cwd : a.sessionId < b.sessionId
        }
        let labels = resolveLabels(for: ordered)
        let targets = gatherTargets(for: ordered)
        return SessionScan(sessions: ordered, labels: labels,
                           oldClaudeHint: oldHint, targets: targets)
    }

    // MARK: - Jump targeting (Phase 3)

    private struct ProcRow { let ppid: Int; let tty: String; let comm: String }

    /// Build the per-session targeting map from ONE `ps -Ao pid,ppid,tty,comm`
    /// snapshot (no N spawns): the session's tty comes straight from its row,
    /// the owning GUI terminal from walking the ppid chain up to the first
    /// process whose comm is a `.app` bundle, and `multiplexed` from spotting a
    /// tmux/screen ancestor on the way up. App display name + bundle id are read
    /// once per app bundle path (cached). Empty on any ps failure — the UI then
    /// just app-activates with no exact target.
    private func gatherTargets(for sessions: [SessionInfo]) -> [String: SessionTarget] {
        guard !sessions.isEmpty,
              let out = runProcess("/bin/ps", ["-Ao", "pid=,ppid=,tty=,comm="]) else { return [:] }
        var table: [Int: ProcRow] = [:]
        for line in out.split(separator: "\n") {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard toks.count >= 4, let pid = Int(toks[0]), let ppid = Int(toks[1]) else { continue }
            let comm = toks[3...].joined(separator: " ")
            table[pid] = ProcRow(ppid: ppid, tty: toks[2], comm: comm)
        }

        var result: [String: SessionTarget] = [:]
        for s in sessions {
            let tty = table[s.pid].map { $0.tty }
            // Walk the ppid chain: claude → -zsh → login → GUI app (ppid 1).
            var multiplexed = false
            var terminal: TerminalKind = .unknown
            var appPid: Int? = nil
            var appBundle: String? = nil
            var cursor = table[s.pid]?.ppid ?? 0
            var hops = 0
            while let row = table[cursor], hops < 12 {
                hops += 1
                if SessionLogic.isMultiplexer(comm: row.comm) { multiplexed = true }
                if let bundle = SessionLogic.appBundlePath(fromExecPath: row.comm) {
                    appBundle = bundle
                    appPid = cursor
                    terminal = SessionLogic.classifyTerminal(commPath: row.comm)
                    break
                }
                if row.ppid <= 1 { break }
                cursor = row.ppid
            }
            let info = appBundle.map { terminalAppInfo(bundlePath: $0) }
            result[s.sessionId] = SessionTarget(
                tty: tty, terminal: terminal,
                appName: info?.name, bundleId: info?.bundleId,
                appPid: appPid, multiplexed: multiplexed, cwd: s.cwd)
        }
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
    private func parseRegistry() -> (sessions: [SessionInfo], hadFiles: Bool) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return ([], false) }
        let jsonNames = names.filter { $0.hasSuffix(".json") }
        var out: [SessionInfo] = []
        for name in jsonNames {
            let path = (sessionsDir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let info = SessionLogic.parse(jsonData: data),
                  SessionLogic.listable(info) else { continue }
            out.append(info)
        }
        return (out, !jsonNames.isEmpty)
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
            guard let fact = facts[s.pid], fact.comm.contains("claude") else { return false }
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

    /// Parse "  5185 Wed Jun 24 21:38:58 2026 /path/to/claude" →
    /// (pid, comm, lstart-as-local-epoch). lstart is always 5 whitespace tokens
    /// (Dow Mon DD HH:MM:SS YYYY); comm is the rest (may contain spaces).
    private func parsePsLine(_ line: String) -> (Int, ProcFact)? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 7, let pid = Int(tokens[0]) else { return nil }
        let lstart = tokens[1...5].joined(separator: " ")
        let comm = tokens[6...].joined(separator: " ")
        let epoch = SessionMonitor.lstartFormatter.date(from: lstart)?.timeIntervalSince1970
        return (pid, ProcFact(comm: comm, startEpoch: epoch))
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

    /// Run a short-lived command, return trimmed stdout, or nil on launch failure
    /// / timeout / non-UTF8. Synchronous on the serial queue; a watchdog kills a
    /// hung child so the queue can't wedge.
    private func runProcess(_ launchPath: String, _ args: [String],
                            timeout: TimeInterval = 5.0) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let outPipe = Pipe()
        task.standardOutput = outPipe
        // Discard stderr to /dev/null (NOT a Pipe): an undrained Pipe whose child
        // writes >64KB would block, stalling the serial queue until the watchdog.
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)
    }
}
