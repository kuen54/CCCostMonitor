import SwiftUI
import AppKit

// Session tab (live Claude Code sessions).
// Extracted from the former single-file Views.swift (v3.0.2 split; no behavior change).

// MARK: - Session tab (live Claude Code sessions)

/// Read-only list of live interactive Claude Code sessions, grouped by working
/// directory. Structurally modeled on TimeTabView. Phase 1: rows are
/// NON-interactive (no click-to-jump) — but each row carries a `contentShape`
/// so a Phase 3 tap handler attaches without restructuring.
struct SessionTabView: View {
    @ObservedObject var sessionStore: SessionStore
    @Environment(\.localizer) private var loc

    var body: some View {
        VStack(spacing: 8) {
            let groups = sessionStore.groups
            if groups.isEmpty {
                emptyState
            } else {
                if sessionStore.showOldClaudeHint { hintBanner }
                if let jumpHint = sessionStore.jumpHint { jumpHintBanner(jumpHint) }
                ForEach(groups) { group in
                    SessionGroupSection(group: group, sessionStore: sessionStore)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        // Drive the jump-hint banner's `.transition(.opacity)` — the hint is set
        // from a background completion (no withAnimation at the source), so animate
        // its insertion/removal here instead.
        .animation(.easeInOut(duration: 0.2), value: sessionStore.jumpHint)
        // Phase 6: viewing the Session tab no longer wipes the green cue — that
        // cleared it before the user could tell which session finished. Each
        // finished-unseen row keeps its own green dot until the user clicks it
        // (engagement) or the reducer auto-evicts it.
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 20)).foregroundColor(.secondary)
            Text(loc("sessionEmpty"))
                .font(.system(size: 11)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }

    /// Shown when running `claude` processes exist but no session registry does
    /// (old Claude Code) — synthesized rows below show only a "Running" status.
    private var hintBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text(loc("sessionOldCCHint"))
                .font(.system(size: 10.5)).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    /// Transient, non-modal hint after a click-to-jump that could only raise the
    /// app (ambiguous pane) / needs Automation permission / failed. Auto-clears.
    private func jumpHintBanner(_ key: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text(loc(key))
                .font(.system(size: 10.5)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
        .transition(.opacity)
    }
}

/// One cwd's card: folder header (basename / git top-level, full path on hover)
/// + its session rows.
struct SessionGroupSection: View {
    let group: SessionGroup
    @ObservedObject var sessionStore: SessionStore
    @Environment(\.localizer) private var loc

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(group.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(group.sessions.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Spacer(minLength: 0)
            }
            .help(group.cwd)

            VStack(spacing: 2) {
                ForEach(group.sessions) { session in
                    SessionRow(session: session, sessionStore: sessionStore)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

/// One session: leading colored STATUS dot + the session TITLE (the transcript
/// ai-title) as the primary line + the latest user INSTRUCTION as the subtitle
/// (one line, …-truncated), relative time, hover jump affordance.
/// Phase 3: the whole row is clickable — a tap focuses/raises that session's
/// terminal window (and pane/tab where possible) via sessionStore.jump.
struct SessionRow: View {
    let session: SessionInfo
    @ObservedObject var sessionStore: SessionStore
    @Environment(\.localizer) private var loc
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Status survives as the leading dot (busy=orange, waiting=amber,
            // idle/shell=grey); the label moves to accessibility, not the title.
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(statusLabel)
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitleText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let updated = session.updatedAt {
                Text(timeAgo(Date(timeIntervalSince1970: updated / 1000), loc))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            // Jump affordance: a subtle "open this terminal" glyph that fades in
            // on hover. Always present in the layout (fixed width) so the row
            // doesn't reflow when it appears.
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .opacity(hovering ? 0.9 : 0.0)
                .frame(width: 13)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        // Single hit-testable shape (set up in Phase 1) so the tap is additive.
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0.0))
        )
        .onHover { inside in
            // Only act on a REAL transition. SwiftUI can re-deliver the same
            // value on a re-render; without this guard a repeated `true` would
            // double-push the cursor stack (and a repeated `false` underflow-pop).
            guard inside != hovering else { return }
            hovering = inside
            // Pointer cursor over a clickable row. push/pop must stay balanced.
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // Tapping a row activates the terminal app, which makes the menu-bar
        // popover resign key and tear down WHILE the pointer is still over the
        // row — so onHover's `false` never arrives. Pop the cursor we pushed on
        // teardown so it can't leak a stuck pointing-hand into the next popover.
        .onDisappear {
            if hovering { NSCursor.pop(); hovering = false }
        }
        .onTapGesture { sessionStore.jump(session) }
    }

    /// Primary line: the session title (newest transcript ai-title). Falls back
    /// to the cwd basename (repo), then a localized "Untitled session".
    private var titleText: String {
        if let t = sessionStore.titles[session.sessionId], !t.isEmpty { return t }
        let base = SessionLogic.basename(session.cwd)
        return base.isEmpty ? loc("sessionUntitled") : base
    }

    /// Subtitle: the latest clean user instruction. SwiftUI tail-truncates it to
    /// one line ("…"); falls back to a localized "(no recent prompt)".
    private var subtitleText: String {
        if let i = sessionStore.instructions[session.sessionId], !i.isEmpty { return i }
        return loc("sessionNoPrompt")
    }

    /// True when THIS session just finished a turn the user hasn't engaged with —
    /// the per-session twin of the notch's aggregate green cue.
    private var isDoneUnseen: Bool { sessionStore.doneUnseen.contains(session.sessionId) }

    /// Leading dot kind by PRIORITY (busy > waiting > done-unseen > grey). One
    /// pure decision in SessionLogic.dotKind so the color and the accessibility
    /// label can't drift apart.
    private var dotKind: SessionLogic.SessionDotKind {
        SessionLogic.dotKind(status: session.status, doneUnseen: isDoneUnseen)
    }

    /// Dot color: a 1:1 map of dotKind. done-unseen GREEN is identical to the
    /// notch aggregate done dot; a done-unseen session is by definition
    /// idle/shell/unknown, so green replaces grey for exactly those rows.
    private var statusColor: Color {
        switch dotKind {
        case .busy:       return .orange
        case .waiting:    return Color.ccStatusWaiting
        case .doneUnseen: return .green
        case .grey:       return .gray
        }
    }

    private var statusLabel: String {
        // Lockstep with the dot: a green (done-unseen) dot must never read
        // "Running"/"Idle". Finer-grained text (wait reason) layers on top.
        if dotKind == .doneUnseen { return loc("sessionFinishedUnread") }
        switch session.status {
        case .busy:
            return loc("sessionWorking")
        case .waiting:
            switch session.waitReason {
            case .needsConfirmation:    return loc("sessionNeedsConfirm")
            case .needsInput, .none:    return loc("sessionWaitingInput")
            }
        case .idle, .shell:
            return loc("sessionIdle")
        case .unknown:
            return loc("sessionRunning")
        }
    }
}

