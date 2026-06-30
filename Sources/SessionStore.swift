import Foundation
import Combine

// MARK: - Live-session store (app layer)
//
// The live Claude Code session state, split out of UsageStore into its own
// ObservableObject. The session monitor republishes every ~2 s while sessions are
// active; keeping that state HERE means only the views that actually read sessions
// (the Session tab + the notch) recompute on each scan — PopoverView observes
// UsageStore and no longer re-renders the whole popover (Cost/Tokens/Time/Plan
// included) every 2 s just because a session ticked.
//
// Owns the SessionMonitor (FSEvents + poll over ~/.claude/sessions) and the
// SessionJumper (click-to-jump). UsageStore holds exactly one of these and
// forwards the lifecycle calls; the menu-bar title pipeline observes this store's
// `$sessions` so the Session-tab count/▸busy marker stays fresh.
final class SessionStore: ObservableObject {

    /// Live interactive Claude Code sessions (read-only; maintained by the monitor).
    @Published var sessions: [SessionInfo] = []
    /// cwd → display label (git top-level basename when resolvable).
    @Published var labels: [String: String] = [:]
    /// sessionId → terminal targeting facts for click-to-jump.
    @Published var targets: [String: SessionTarget] = [:]
    /// sessionId → session title (newest transcript `ai-title`).
    @Published var titles: [String: String] = [:]
    /// sessionId → latest clean user instruction (one line).
    @Published var instructions: [String: String] = [:]
    /// Transient, non-modal hint (a localization KEY) after a jump that could only
    /// raise the app / failed. Auto-clears.
    @Published var jumpHint: String? = nil
    /// No registry but `claude` is running (old Claude Code) → "update" hint.
    @Published var showOldClaudeHint: Bool = false
    /// A session finished a turn the user hasn't looked at — the notch aggregate
    /// green cue. Kept equal to `!doneUnseen.isEmpty`.
    @Published var anyDoneUnseen: Bool = false
    /// The exact sessionIds that finished a turn unseen — each Session row's green
    /// dot (cleared per-session on engagement).
    @Published var doneUnseen: Set<String> = []

    var liveCount: Int { sessions.count }
    var anyBusy: Bool { sessions.contains { $0.status == .busy } }
    var anyWaiting: Bool { sessions.contains { $0.status == .waiting } }

    /// Sessions grouped by cwd, with monitor-resolved labels overlaid.
    var groups: [SessionGroup] {
        SessionLogic.grouped(sessions).map { g in
            guard let refined = labels[g.cwd], refined != g.label else { return g }
            return SessionGroup(cwd: g.cwd, label: refined, sessions: g.sessions)
        }
    }

    // Live session monitor (FSEvents + poll). Publishes onto the main thread; each
    // field is guarded so an unchanged scan causes no objectWillChange.
    private lazy var monitor = SessionMonitor { [weak self] scan in
        guard let self = self else { return }
        if self.sessions != scan.sessions { self.sessions = scan.sessions }
        if self.labels != scan.labels { self.labels = scan.labels }
        if self.targets != scan.targets { self.targets = scan.targets }
        if self.titles != scan.titles { self.titles = scan.titles }
        if self.instructions != scan.instructions { self.instructions = scan.instructions }
        if self.showOldClaudeHint != scan.oldClaudeHint { self.showOldClaudeHint = scan.oldClaudeHint }
        if self.anyDoneUnseen != scan.anyDoneUnseen { self.anyDoneUnseen = scan.anyDoneUnseen }
        if self.doneUnseen != scan.doneUnseenIds { self.doneUnseen = scan.doneUnseenIds }
    }
    // Click-to-jump (all spawning confined to its own serial queue).
    private let jumper = SessionJumper()
    // Main-thread only: cancels a pending hint auto-clear when a newer jump lands.
    private var jumpHintClear: DispatchWorkItem?

    // MARK: Lifecycle (forwarded from UsageStore / the controllers)

    func startMonitoring() { monitor.start() }
    func setActive(_ active: Bool) { monitor.setActive(active) }
    func stopMonitoring() { monitor.stop() }

    /// The user engaged with ONE session (clicked its row) — clear just that
    /// session's finished-unseen green dot.
    func markSeen(_ sessionId: String) { monitor.markSeen(sessionId: sessionId) }

    /// Click-to-jump: focus/raise the terminal window (and pane/tab where possible)
    /// that owns `session`. Fire-and-forget; the jumper does all spawning off-main.
    func jump(_ session: SessionInfo) {
        // Engaging clears this session's green dot regardless of how the jump lands.
        markSeen(session.sessionId)
        let target = targets[session.sessionId]
            ?? SessionTarget(tty: nil, terminal: .unknown, appName: nil,
                             bundleId: nil, appPid: nil, multiplexed: false, cwd: session.cwd)
        jumper.jump(session: session, target: target) { [weak self] outcome in
            self?.handleJumpOutcome(outcome)
        }
    }

    /// Map a jump outcome to a transient, non-modal hint (a localization key the
    /// Session tab renders). Main thread only (the jumper hops the completion).
    private func handleJumpOutcome(_ outcome: JumpOutcome) {
        switch outcome {
        case .focusedPane:
            setJumpHint(nil)
        case .appOnly(let reason):
            setJumpHint(reason == .permissionDenied
                ? "sessionJumpNeedsPermission" : "sessionJumpAppOnly")
        case .failed:
            setJumpHint("sessionJumpFailed")
        }
    }

    private func setJumpHint(_ key: String?) {
        jumpHintClear?.cancel()
        jumpHint = key
        guard key != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.jumpHint = nil }
        jumpHintClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }
}
