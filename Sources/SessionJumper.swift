import Foundation
import AppKit

// MARK: - Session jumper (app layer)
//
// Click-to-jump: focus/raise the terminal window (and pane/tab where possible)
// that owns a live Claude Code session. App-only — NEVER part of CCCostCore.
//
// SAFETY: every external spawn (otty-cli / osascript / open) runs OFF the main
// thread on this object's serial queue, each wrapped in the same Process + Pipe
// + watchdog-kill pattern SessionMonitor uses (stderr → /dev/null so an undrained
// pipe can't wedge the queue). The ONLY actions taken are read-only enumeration
// and "focus/raise an existing window/pane" + app activation. Nothing here
// closes a pane, kills a process, sends user keystrokes, or writes any file.

/// The result of a jump attempt, surfaced to the UI as an honest hint.
enum JumpOutcome: Equatable {
    case focusedPane               // landed on the exact pane/tab
    case focusedWindow             // raised the right window (less granular)
    case appOnly(JumpReason)       // could only bring the app forward
    case failed(JumpReason)        // couldn't even do that
}

enum JumpReason: String, Equatable {
    case ambiguous           // several panes/tabs fit — couldn't disambiguate
    case permissionDenied    // Automation (TCC) prompt denied / not granted
    case unsupported         // terminal isn't scriptable / no CLI
    case noTarget            // missing targeting facts (no tty / app pid)
    case launchFailed        // even app activation failed
}

final class SessionJumper {
    // All spawning is confined here; never touches main.
    private let queue = DispatchQueue(label: "com.claude.cc-cost-monitor.jump", qos: .userInitiated)

    /// Fire-and-forget: resolve + perform the jump on the background queue, then
    /// deliver the outcome on the MAIN thread (UI hint). Never blocks the caller.
    func jump(session: SessionInfo, target: SessionTarget,
              completion: ((JumpOutcome) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let outcome = self.perform(session: session, target: target)
            if let completion = completion {
                DispatchQueue.main.async { completion(outcome) }
            }
        }
    }

    // MARK: - Dispatch by terminal

    private func perform(session: SessionInfo, target: SessionTarget) -> JumpOutcome {
        switch target.terminal {
        case .otty:          return jumpOtty(session: session, target: target)
        case .appleTerminal: return jumpAppleScript(target: target, kind: .appleTerminal)
        case .iterm2:        return jumpAppleScript(target: target, kind: .iterm2)
        case .ghostty:       return jumpGhostty(target: target)
        case .wezterm:       return jumpWezterm(target: target)
        case .kitty:         return jumpKitty(target: target)
        case .alacritty:     return activateApp(target, reason: .unsupported)
        case .unknown:       return activateApp(target, reason: target.multiplexed ? .ambiguous : .unsupported)
        }
    }

    // MARK: Otty (zero TCC)

    private func jumpOtty(session: SessionInfo, target: SessionTarget) -> JumpOutcome {
        guard let cli = ottyCliPath(target) else {
            return activateApp(target, reason: .unsupported)
        }
        guard let (_, listOut) = run(cli, ["pane", "list", "--json"]),
              let panes = parseOttyPanes(listOut) else {
            return activateApp(target, reason: .ambiguous)
        }
        // Otty exposes no pid/tty per pane — fuzzy join on cwd (title tiebreak
        // when a session title is available; today none is, so cwd-only).
        switch SessionLogic.matchOttyPane(cwd: session.cwd, title: nil, panes: panes) {
        case .exact(let paneId):
            _ = run(cli, ["pane", "focus", paneId, "--json"])
            // pane focus selects the tab inside Otty but doesn't raise the GUI;
            // activate the app so it comes to the front. Both are non-TCC.
            _ = activateAppPid(target)
            return .focusedPane
        case .ambiguous, .none:
            return activateApp(target, reason: .ambiguous)
        }
    }

    /// Prefer the otty-cli inside the resolved app bundle, else the standard
    /// install path. Returns nil only if neither exists.
    private func ottyCliPath(_ target: SessionTarget) -> String? {
        var candidates: [String] = []
        if let id = target.bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            candidates.append(url.appendingPathComponent("Contents/MacOS/otty-cli").path)
        }
        candidates.append("/Applications/Otty.app/Contents/MacOS/otty-cli")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Parse `otty-cli pane list --json` → [OttyPane]. Tolerates schema drift:
    /// any entry missing id/cwd is skipped; the `process` field is the title.
    private func parseOttyPanes(_ json: String) -> [OttyPane]? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else { return nil }
        return arr.compactMap { p in
            guard let id = p["id"] as? String, let cwd = p["cwd"] as? String else { return nil }
            return OttyPane(id: id, cwd: cwd, title: (p["process"] as? String) ?? "")
        }
    }

    // MARK: Apple Terminal / iTerm2 (AppleScript, exact by tty)

    private func jumpAppleScript(target: SessionTarget, kind: TerminalKind) -> JumpOutcome {
        guard let dev = SessionLogic.devTTY(target.tty) else {
            return activateApp(target, reason: .noTarget)
        }
        let script = kind == .iterm2
            ? SessionLogic.itermFocusScript(devTTY: dev)
            : SessionLogic.appleTerminalFocusScript(devTTY: dev)
        guard let (status, out) = run("/usr/bin/osascript", ["-e", script]) else {
            // osascript itself failed to launch.
            return activateApp(target, reason: .unsupported)
        }
        if status == 0 {
            if out.contains("ok") { return .focusedPane }     // tab matched + activated
            return activateApp(target, reason: .ambiguous)     // ran, tty not found
        }
        // Non-zero exit ⇒ almost always a denied Automation (TCC) prompt, or the
        // app isn't scriptable. Degrade honestly to a plain app raise.
        return activateApp(target, reason: .permissionDenied)
    }

    // MARK: Ghostty (limited scripting → honest app raise)

    private func jumpGhostty(target: SessionTarget) -> JumpOutcome {
        // Ghostty's AppleScript surface can't reliably select a tab by tty, so
        // we raise the app and report that we couldn't pinpoint the tab.
        return activateApp(target, reason: .ambiguous)
    }

    // MARK: WezTerm / kitty (best-effort via their CLIs)

    private func jumpWezterm(target: SessionTarget) -> JumpOutcome {
        guard let dev = SessionLogic.devTTY(target.tty), let cli = which("wezterm") else {
            return activateApp(target, reason: target.tty == nil ? .noTarget : .unsupported)
        }
        // Find the pane whose tty matches, activate it. Read-only list + activate.
        guard let (_, listJSON) = run(cli, ["cli", "list", "--format", "json"]),
              let data = listJSON.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return activateApp(target, reason: .ambiguous)
        }
        let bare = dev.replacingOccurrences(of: "/dev/", with: "")
        let match = rows.first { row in
            guard let t = row["tty_name"] as? String else { return false }
            return t == dev || t == bare || t.hasSuffix(bare)
        }
        if let paneId = match?["pane_id"] {
            _ = run(cli, ["cli", "activate-pane", "--pane-id", "\(paneId)"])
            _ = activateAppPid(target)
            return .focusedPane
        }
        return activateApp(target, reason: .ambiguous)
    }

    private func jumpKitty(target: SessionTarget) -> JumpOutcome {
        // kitty's remote-control can't match a window by tty, so there's no
        // reliable exact target — raise the app and report it honestly. (A
        // best-effort `kitten @ focus-window` would need a shared socket the
        // session isn't guaranteed to expose.)
        return activateApp(target, reason: .ambiguous)
    }

    // MARK: - Universal fallback: raise the owning app

    /// Bring the terminal GUI to the front (NSRunningApplication by pid, then
    /// `open -b`/`open -a`). Reports `.appOnly(reason)` on success so the UI can
    /// explain we couldn't pinpoint the tab; `.failed` only if even this fails.
    private func activateApp(_ target: SessionTarget, reason: JumpReason) -> JumpOutcome {
        if activateAppPid(target) { return .appOnly(reason) }
        if let id = target.bundleId, let (s, _) = run("/usr/bin/open", ["-b", id]), s == 0 {
            return .appOnly(reason)
        }
        if let name = target.appName, let (s, _) = run("/usr/bin/open", ["-a", name]), s == 0 {
            return .appOnly(reason)
        }
        return .failed(.launchFailed)
    }

    /// Activate by running-app pid. NSRunningApplication.activate is hopped to
    /// main (AppKit) and its result read back synchronously.
    private func activateAppPid(_ target: SessionTarget) -> Bool {
        guard let pid = target.appPid else { return false }
        var ok = false
        DispatchQueue.main.sync {
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                ok = app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        return ok
    }

    // MARK: - Process helpers (off-main, watchdog-killed, stderr → /dev/null)

    /// `which`-style PATH lookup for a CLI. Returns the resolved path or nil.
    private func which(_ name: String) -> String? {
        guard let (status, out) = run("/usr/bin/which", [name]), status == 0 else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Run a short-lived command; return (exitStatus, trimmed stdout), or nil on
    /// launch failure / timeout. Same shape as SessionMonitor.runProcess: a
    /// watchdog DispatchWorkItem kills a hung child so the queue can't wedge, and
    /// stderr goes to /dev/null (an undrained stderr pipe could block on >64KB).
    @discardableResult
    private func run(_ launchPath: String, _ args: [String],
                     timeout: TimeInterval = 5.0) -> (Int32, String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (task.terminationStatus, out)
    }
}
