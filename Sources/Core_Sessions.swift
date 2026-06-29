import Foundation

// MARK: - Live Claude Code sessions — pure core
//
// Foundation-only on purpose (part of the CCCostCore test target): this file
// only decodes/filters/groups the session registry that Claude Code writes to
// ~/.claude/sessions/<pid>.json. All the impure facts — process liveness
// (kill/ps), file watching (FSEvents), the fallback proc scan — live in the
// app-side SessionMonitor and must NOT enter this file.
//
// The on-disk schema is INTERNAL to Claude Code and changes between versions,
// so every decode here is defensive: unknown enum strings degrade to .unknown,
// every non-identity field is optional + decoded with decodeIfPresent, and a
// single malformed file yields nil (the caller skips just that file) rather
// than throwing through the whole scan.

/// Status enum mirrored from the installed Claude Code binary. `unknown` is the
/// forward-compatible bucket for any string a future version introduces (and the
/// status the app synthesizes for old Claude Code that predates the registry).
enum SessionStatus: String, Codable, Equatable {
    case busy
    case shell
    case idle
    case waiting
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .unknown
    }
}

/// Coarse UI bucket for `waitingFor` so the view doesn't hardcode Claude Code's
/// internal wait-reason strings. permission prompt => the user must approve;
/// everything else (input/dialog/worker/sandbox) => the session wants input.
enum SessionWaitReason: Equatable {
    case needsConfirmation
    case needsInput
}

/// One decoded entry from ~/.claude/sessions/<pid>.json. Identity = (pid,
/// sessionId); everything else is optional so partial/older/newer schemas
/// decode without throwing.
struct SessionInfo: Codable, Equatable, Identifiable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let status: SessionStatus
    let waitingFor: String?
    let startedAt: Double?      // epoch milliseconds
    let updatedAt: Double?      // epoch milliseconds
    let statusUpdatedAt: Double?// epoch milliseconds (NOT a heartbeat)
    let version: String?
    let kind: String?
    let entrypoint: String?

    var id: String { sessionId }

    /// First segment of the UUID — a friendly short handle for the UI.
    var shortId: String { String(sessionId.prefix(8)) }

    /// Coarse wait reason, only meaningful while status == .waiting.
    var waitReason: SessionWaitReason? {
        guard status == .waiting else { return nil }
        switch waitingFor {
        case "permission prompt":
            return .needsConfirmation
        case "input needed", "dialog open", "worker request", "sandbox request":
            return .needsInput
        default:
            // Unknown future wait reason → treat as "wants input" (amber, the
            // attention-needed presentation) rather than dropping it.
            return .needsInput
        }
    }

    enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, status, waitingFor
        case startedAt, updatedAt, statusUpdatedAt
        case version, kind, entrypoint
    }

    init(pid: Int, sessionId: String, cwd: String, status: SessionStatus,
         waitingFor: String? = nil, startedAt: Double? = nil, updatedAt: Double? = nil,
         statusUpdatedAt: Double? = nil, version: String? = nil,
         kind: String? = nil, entrypoint: String? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.waitingFor = waitingFor
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.version = version
        self.kind = kind
        self.entrypoint = entrypoint
    }

    /// Defensive decode: tolerates missing/extra keys and wrong-typed optionals.
    /// Throws ONLY when the identity fields (pid, sessionId) are absent — those
    /// make the entry meaningless, so `parse(jsonData:)` turns the throw into a
    /// skipped (nil) file rather than aborting the whole scan.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        guard let pid = (try? c.decodeIfPresent(Int.self, forKey: .pid)) ?? nil else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath, debugDescription: "session file missing pid"))
        }
        guard let sessionId = (try? c.decodeIfPresent(String.self, forKey: .sessionId)) ?? nil,
              !sessionId.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath, debugDescription: "session file missing sessionId"))
        }
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = ((try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? nil) ?? ""
        self.status = ((try? c.decodeIfPresent(SessionStatus.self, forKey: .status)) ?? nil) ?? .unknown
        self.waitingFor = (try? c.decodeIfPresent(String.self, forKey: .waitingFor)) ?? nil
        self.startedAt = (try? c.decodeIfPresent(Double.self, forKey: .startedAt)) ?? nil
        self.updatedAt = (try? c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? nil
        self.statusUpdatedAt = (try? c.decodeIfPresent(Double.self, forKey: .statusUpdatedAt)) ?? nil
        self.version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
        self.kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        self.entrypoint = (try? c.decodeIfPresent(String.self, forKey: .entrypoint)) ?? nil
    }
}

/// One cwd's worth of sessions, for the grouped session list. `label` is the
/// basename of the cwd (the app layer may refine it with the git top-level dir
/// name); `cwd` is the full path (id, group key, and the secondary/tooltip line).
struct SessionGroup: Identifiable, Equatable {
    let cwd: String
    let label: String
    let sessions: [SessionInfo]

    var id: String { cwd }
    var anyBusy: Bool { sessions.contains { $0.status == .busy } }
    var anyWaiting: Bool { sessions.contains { $0.status == .waiting } }
    /// Most-recent updatedAt across the group (0 when none reported one).
    var mostRecentUpdate: Double { sessions.compactMap { $0.updatedAt }.max() ?? 0 }
}

// MARK: - Jump targeting types (Phase 3)

/// The GUI terminal that owns a session's tty, as far up the ppid chain as the
/// app layer could resolve. Drives SessionJumper's per-terminal dispatch.
enum TerminalKind: String, Equatable {
    case otty
    case appleTerminal
    case iterm2
    case ghostty
    case wezterm
    case kitty
    case alacritty
    case unknown
}

/// One Otty pane as reported by `otty-cli pane list --json`. Otty exposes only
/// these for matching — notably NO pid/tty — so the session→pane join is fuzzy.
struct OttyPane: Equatable {
    let id: String
    let cwd: String
    let title: String   // the JSON `process` field (the agent/title line)
}

/// Outcome of matching a session to the live Otty panes.
enum OttyMatch: Equatable {
    case exact(paneId: String)   // exactly one pane fits → focus it
    case ambiguous               // several candidates, can't disambiguate
    case none                    // no pane matches this cwd
}

/// Pure session logic — decoding, filtering, grouping. No process or file I/O.
enum SessionLogic {

    /// Decode one registry file's bytes. Returns nil for a malformed/partial file
    /// (missing identity) so the caller skips just that file.
    static func parse(jsonData: Data) -> SessionInfo? {
        try? JSONDecoder().decode(SessionInfo.self, from: jsonData)
    }

    /// Whether a registry-parsed session belongs in the live session list.
    /// Excludes `claude -p` / SDK mode (entrypoint == "sdk-cli", which also omits
    /// `status`): a listable entry is an interactive CLI session with a real
    /// status. NOTE: app-synthesized fallback sessions (old Claude Code, status
    /// .unknown) bypass this filter — it gates the registry only.
    static func listable(_ s: SessionInfo) -> Bool {
        s.entrypoint == "cli" && s.status != .unknown
    }

    /// Basename of a path ("/Users/x/proj" → "proj"). Empty/"/" fall back to the
    /// input so a group always has a non-empty label.
    static func basename(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    /// Group sessions by full cwd, each group labelled with the cwd basename.
    /// Deterministic ordering (so the @Published publish-guard doesn't thrash):
    /// groups with a busy session first, then by most-recent updatedAt (desc),
    /// then by cwd; within a group, busy first, then updatedAt (desc), then
    /// sessionId. Stable because every comparison has a total-order tiebreak.
    static func grouped(_ sessions: [SessionInfo]) -> [SessionGroup] {
        var byCwd: [String: [SessionInfo]] = [:]
        var order: [String] = []
        for s in sessions {
            if byCwd[s.cwd] == nil { order.append(s.cwd) }
            byCwd[s.cwd, default: []].append(s)
        }
        var groups: [SessionGroup] = order.map { cwd in
            let sorted = (byCwd[cwd] ?? []).sorted(by: sessionOrder)
            return SessionGroup(cwd: cwd, label: basename(cwd), sessions: sorted)
        }
        groups.sort(by: groupOrder)
        return groups
    }

    static func sessionOrder(_ a: SessionInfo, _ b: SessionInfo) -> Bool {
        let ab = a.status == .busy, bb = b.status == .busy
        if ab != bb { return ab }
        let au = a.updatedAt ?? 0, bu = b.updatedAt ?? 0
        if au != bu { return au > bu }
        return a.sessionId < b.sessionId
    }

    static func groupOrder(_ a: SessionGroup, _ b: SessionGroup) -> Bool {
        if a.anyBusy != b.anyBusy { return a.anyBusy }
        if a.mostRecentUpdate != b.mostRecentUpdate { return a.mostRecentUpdate > b.mostRecentUpdate }
        return a.cwd < b.cwd
    }

    // MARK: - Jump targeting (Phase 3) — pure helpers
    //
    // Everything here is Foundation-only string/collection logic so it's unit
    // testable in CCCostCore. The impure parts — running `ps`, otty-cli,
    // osascript, NSRunningApplication — live in the app layer (SessionMonitor /
    // SessionJumper). These helpers just classify and match.

    /// First `.app` bundle path embedded in an executable path, e.g.
    /// "/Applications/Otty.app/Contents/MacOS/Otty" → "/Applications/Otty.app".
    /// nil when the path has no ".app" segment. Matches the ".app/" boundary (or a
    /// trailing ".app") so it can't mis-slice "/Users/foo.apptest/bin/term".
    static func appBundlePath(fromExecPath path: String) -> String? {
        if let r = path.range(of: ".app/") {
            return String(path[path.startIndex..<path.index(r.lowerBound, offsetBy: 4)])
        }
        return path.hasSuffix(".app") ? path : nil
    }

    /// True when an executable path / comm string belongs to a terminal
    /// multiplexer (tmux or screen) sitting between the shell and the GUI app.
    static func isMultiplexer(comm: String) -> Bool {
        let base = (comm as NSString).lastPathComponent.lowercased()
        return base == "tmux" || base.hasPrefix("tmux:")
            || base == "screen" || base == "screen-256color"
    }

    /// Classify the owning GUI terminal from its executable path (ps `comm`).
    /// Matched on the `.app` bundle name so it's robust to the helper binary's
    /// own name (e.g. Otty's exec is `Otty`, WezTerm's is `wezterm-gui`).
    static func classifyTerminal(commPath: String) -> TerminalKind {
        let p = commPath.lowercased()
        if p.contains("/otty.app/")      || p.hasSuffix("/otty") { return .otty }
        if p.contains("/ghostty.app/")   || p.contains("ghostty") { return .ghostty }
        if p.contains("/iterm.app/")     || p.contains("/iterm2") { return .iterm2 }
        if p.contains("/wezterm.app/")   || p.contains("wezterm") { return .wezterm }
        if p.contains("/kitty.app/")     || p.hasSuffix("/kitty") { return .kitty }
        if p.contains("/alacritty.app/") || p.contains("alacritty") { return .alacritty }
        // Apple Terminal last: its bundle is the only one that legitimately owns
        // the generic "terminal.app" path.
        if p.contains("/terminal.app/") { return .appleTerminal }
        return .unknown
    }

    /// Normalize a tty to the "/dev/ttysNNN" form AppleScript's `tty of tab`
    /// reports. ps prints it bare ("ttys000"); "??" / empty → nil (no tty).
    static func devTTY(_ tty: String?) -> String? {
        guard let t = tty, !t.isEmpty, t != "??" else { return nil }
        return t.hasPrefix("/dev/") ? t : "/dev/\(t)"
    }

    /// Strip a leading Claude/spinner status glyph (✳ ⠐ … and friends) + spaces
    /// from an Otty pane title so it can be compared to a plain session title.
    static func normalizeOttyTitle(_ s: String) -> String {
        var out = s
        // Drop a leading run of non-alphanumeric "decoration" (emoji, braille
        // spinner frames, bullets, whitespace) — keep the first letter/digit on.
        while let f = out.unicodeScalars.first,
              !(CharacterSet.alphanumerics.contains(f)) {
            out.removeFirst()
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Match a live session to one Otty pane. Otty exposes only {cwd, title}
    /// per pane (no pid/tty), so this is a FUZZY join: unique cwd → exact; a cwd
    /// shared by several panes falls back to a title tiebreak when a session
    /// title is available, else reports `.ambiguous`.
    static func matchOttyPane(cwd: String, title: String?, panes: [OttyPane]) -> OttyMatch {
        let byCwd = panes.filter { $0.cwd == cwd }
        if byCwd.isEmpty { return .none }
        if byCwd.count == 1 { return .exact(paneId: byCwd[0].id) }
        if let t = title.map(normalizeOttyTitle), !t.isEmpty {
            let hits = byCwd.filter { normalizeOttyTitle($0.title) == t }
            if hits.count == 1 { return .exact(paneId: hits[0].id) }
        }
        return .ambiguous
    }

    // MARK: AppleScript builders (pure strings)

    /// Apple Terminal: select the tab whose `tty` matches, raise its window,
    /// activate. Returns "ok" / "notfound" on stdout so the caller can tell a
    /// missing tab from a TCC denial (which fails the osascript run entirely).
    static func appleTerminalFocusScript(devTTY: String) -> String {
        let tty = devTTY.replacingOccurrences(of: "\"", with: "")
        return """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "notfound"
        """
    }

    /// iTerm2: select the session whose `tty` matches (+ its tab/window), activate.
    static func itermFocusScript(devTTY: String) -> String {
        let tty = devTTY.replacingOccurrences(of: "\"", with: "")
        return """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select s
                            select t
                            select w
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "notfound"
        """
    }

    // MARK: - Done-unseen reducer (Phase 2)
    //
    // Tracks sessions that JUST finished a turn (an active → done transition) and
    // that the user hasn't "looked at" yet — the data behind the notch's green
    // "a turn finished" cue. Pure + deterministic with `now` injected, so the
    // app-side SessionMonitor stays a thin queue-confined wrapper and all the
    // transition logic is unit-testable.

    /// Session ids whose status went from ACTIVE (.busy/.waiting) to DONE
    /// (.idle/.shell) between `previous` and `current` — i.e. a turn just ended.
    /// A session ABSENT from `previous` (first observation) is never a finish:
    /// seeing a brand-new idle session is not "it just finished for you".
    static func justFinished(previous: [String: SessionStatus],
                             current: [SessionInfo]) -> [String] {
        current.compactMap { s in
            guard let prev = previous[s.sessionId] else { return nil }
            let wasActive = (prev == .busy || prev == .waiting)
            let nowDone = (s.status == .idle || s.status == .shell)
            return (wasActive && nowDone) ? s.sessionId : nil
        }
    }

    /// One pure step of the done-unseen tracker. Folds `justFinished` into
    /// `doneUnseen` (sessionId → finishedAt epoch) and then evicts any entry that
    /// is no longer "an unseen finish":
    ///   (a) the session is .busy/.waiting again,
    ///   (b) the session vanished from `current`,
    ///   (c) its finishedAt is older than `ttl` (default 3600s),
    ///   (d) `seenAll` (the user looked) clears everything.
    /// Returns the next (prevStatuses, doneUnseen). Deterministic for a given
    /// `now`, so the caller must pass its own clock (no Date() in core).
    static func stepDoneUnseen(prev: [String: SessionStatus],
                               current: [SessionInfo],
                               doneUnseen: [String: Double],
                               seenAll: Bool,
                               now: Double,
                               ttl: Double = 3600) -> (prev: [String: SessionStatus],
                                                       doneUnseen: [String: Double]) {
        let curStatus = Dictionary(current.map { ($0.sessionId, $0.status) },
                                   uniquingKeysWith: { _, b in b })
        // The user looked: forget every pending cue, but still advance prev so a
        // later genuine transition is detected against an up-to-date baseline.
        guard !seenAll else { return (curStatus, [:]) }

        var next = doneUnseen
        for id in justFinished(previous: prev, current: current) {
            next[id] = now
        }
        let currentIds = Set(curStatus.keys)
        for (id, finishedAt) in next {
            if let st = curStatus[id], st == .busy || st == .waiting {
                next.removeValue(forKey: id)            // (a) active again
            } else if !currentIds.contains(id) {
                next.removeValue(forKey: id)            // (b) session gone
            } else if now - finishedAt > ttl {
                next.removeValue(forKey: id)            // (c) stale
            }
        }
        return (curStatus, next)
    }
}
