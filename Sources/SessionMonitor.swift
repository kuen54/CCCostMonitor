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

    private func rescan() {
        let scan = computeScan()
        if scan != lastScan {
            lastScan = scan
            DispatchQueue.main.async { [weak self] in self?.onChange(scan) }
        }
    }

    private func computeScan() -> SessionScan {
        let parsed = parseRegistry()

        let sessions: [SessionInfo]
        var oldHint = false
        if !parsed.isEmpty {
            // Modern Claude Code: trust the registry, keep only the live ones.
            sessions = filterAlive(parsed)
        } else {
            // Fallback ladder: registry missing/empty. If `claude` is actually
            // running, surface synthesized entries + a one-time upgrade hint.
            let synth = scanClaudeProcessesAsSessions()
            sessions = synth
            oldHint = !synth.isEmpty
        }

        // Stable order so the Equatable publish-guard never thrashes.
        let ordered = sessions.sorted { a, b in
            a.cwd != b.cwd ? a.cwd < b.cwd : a.sessionId < b.sessionId
        }
        let labels = resolveLabels(for: ordered)
        return SessionScan(sessions: ordered, labels: labels, oldClaudeHint: oldHint)
    }

    /// Decode every *.json under the sessions dir, keep listable (cli + status)
    /// entries. A malformed file is skipped, not fatal.
    private func parseRegistry() -> [SessionInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }
        var out: [SessionInfo] = []
        for name in names where name.hasSuffix(".json") {
            let path = (sessionsDir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let info = SessionLogic.parse(jsonData: data),
                  SessionLogic.listable(info) else { continue }
            out.append(info)
        }
        return out
    }

    // MARK: - Liveness

    private struct ProcFact { let comm: String; let startEpoch: TimeInterval? }

    /// Keep only sessions whose pid is (a) alive, (b) actually a `claude` process
    /// (PID-reuse guard), and (c) whose live start time matches the recorded
    /// startedAt within 5s when both are parseable (skipped gracefully otherwise).
    private func filterAlive(_ sessions: [SessionInfo]) -> [SessionInfo] {
        let pids = sessions.map { $0.pid }
        let facts = psFacts(for: pids)  // ONE batched ps call
        return sessions.filter { s in
            guard processExists(s.pid) else { return false }
            guard let fact = facts[s.pid], fact.comm.contains("claude") else { return false }
            if let start = fact.startEpoch, let recorded = s.startedAt {
                if abs(start - recorded / 1000.0) >= 5 { return false }  // PID reuse
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
        task.standardError = Pipe()   // swallow stderr (lsof warnings etc.)
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
