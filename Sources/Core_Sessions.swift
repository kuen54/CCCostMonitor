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
    /// Excludes:
    ///   - `claude -p` / SDK mode (`entrypoint == "sdk-cli"`, which also omits
    ///     `status`): a listable entry is an interactive CLI session with a real
    ///     status.
    ///   - background forks (`kind == "bg"`): a session launched with
    ///     `--fork-session --resume <other>.jsonl` and run under Claude Code's
    ///     bg-pty-host daemon (a background-agent job). It forks another session's
    ///     transcript, so it inherits that session's title and appears as a visual
    ///     DUPLICATE of the interactive session it branched from — and it has no
    ///     real terminal window (its parent is the daemon, not a terminal app), so
    ///     it isn't a jumpable session either. Only the KNOWN "bg" kind is
    ///     excluded; a nil/absent kind (older Claude Code that predates the field)
    ///     still lists, so this can never hide a real interactive session.
    /// NOTE: app-synthesized fallback sessions (old Claude Code, status .unknown)
    /// bypass this filter — it gates the registry only.
    static func listable(_ s: SessionInfo) -> Bool {
        s.entrypoint == "cli" && s.status != .unknown && s.kind != "bg"
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

    // MARK: - Duplicate-session collapse

    /// Collapse entries that share a `sessionId` down to ONE. The registry is keyed
    /// by pid (`~/.claude/sessions/<pid>.json`), so a single logical session can be
    /// present under two files at once — most often `claude --resume <id>` adopts
    /// the session under a NEW pid while the previous pid's file still lingers (a
    /// SIGKILL leaves it un-reaped and liveness hasn't reaped it yet), or the same
    /// session is open in two windows. Left un-collapsed, both flow through as
    /// SessionInfo with the SAME `id` (sessionId): the Session list's `ForEach` is
    /// keyed on that id, so SwiftUI renders TWO rows for one session, each with its
    /// own status dot derived from its own file → the dots visibly disagree. (It
    /// also lets a stale `busy` file keep the notch/menu-bar `anyBusy` cue on.)
    ///
    /// Keep the entry that best reflects the session's CURRENT state: the most
    /// recently touched registry file (`freshness`), tie-broken by the higher pid
    /// (the newer/resumed process) so the pick is a TOTAL order and can't thrash
    /// the @Published publish-guard between two equally-fresh files. Survivors keep
    /// first-appearance order (the caller re-sorts anyway). Collapsing is always
    /// safe: a sessionId is a UUID identifying ONE logical session, so two files
    /// sharing it are never two different sessions.
    static func dedupBySessionId(_ sessions: [SessionInfo]) -> [SessionInfo] {
        var winner: [String: SessionInfo] = [:]
        var order: [String] = []
        for s in sessions {
            if let cur = winner[s.sessionId] {
                if isFresher(s, than: cur) { winner[s.sessionId] = s }
            } else {
                winner[s.sessionId] = s
                order.append(s.sessionId)
            }
        }
        return order.compactMap { winner[$0] }
    }

    /// True when `a` is a more current registry write than `b` for the same
    /// session — the pick key in `dedupBySessionId`. Recency first (freshest file
    /// wins), then higher pid as a deterministic total-order tiebreak.
    static func isFresher(_ a: SessionInfo, than b: SessionInfo) -> Bool {
        let af = freshness(a), bf = freshness(b)
        if af != bf { return af > bf }
        return a.pid > b.pid
    }

    /// Latest "touched" epoch (ms) for a session across its optional timestamps
    /// (`max`, not first-non-nil, so a file that only bumped `statusUpdatedAt`
    /// still counts as fresh); 0 when none are present.
    static func freshness(_ s: SessionInfo) -> Double {
        max(s.updatedAt ?? 0, s.statusUpdatedAt ?? 0, s.startedAt ?? 0)
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

    /// Strip a leading Claude/spinner status glyph from an Otty pane title so it
    /// can be compared to a plain session title. Claude Code prefixes the pushed
    /// title with `✳ ` (U+2733) when the session is idle/ready, or a Braille
    /// spinner frame (`⠐ `/`⠂ `, U+2800–U+28FF) while it's busy. This drops a
    /// leading run of any non-alphanumeric "decoration" (those glyphs, other
    /// symbols, whitespace) up to the first letter/digit, then trims the tail.
    /// CJK ideographs are Unicode letters, so a Chinese title's first character
    /// is kept. Applied to BOTH sides before comparison so it's symmetric.
    static func normalizeOttyTitle(_ s: String) -> String {
        var out = s
        while let f = out.unicodeScalars.first,
              !(CharacterSet.alphanumerics.contains(f)) {
            out.removeFirst()
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Match a live session to one Otty pane. Otty exposes only {cwd, title} per
    /// pane (no pid/tty), so this is a FUZZY join. Priority:
    ///   1. TITLE+CWD exact — when `title` is non-empty, if exactly one pane in
    ///      the session's cwd has `normalize(process) == normalize(title)` → that
    ///      pane. The cwd cross-check (only panes sharing the session's cwd are
    ///      considered) prevents a coincidental cross-directory title collision
    ///      from mis-targeting.
    ///   2. CWD-unique — a cwd owned by exactly one pane → that pane (this is the
    ///      whole behavior when `title` is nil/empty, i.e. unchanged from before).
    ///   3. else `.ambiguous` (several panes, can't disambiguate → app-activate).
    /// `.none` only when no pane shares the cwd at all. Pure + deterministic.
    static func matchOttyPane(cwd: String, title: String?, panes: [OttyPane]) -> OttyMatch {
        let byCwd = panes.filter { $0.cwd == cwd }
        if byCwd.isEmpty { return .none }
        // 1. title + cwd exact (cwd-restricted, so the cross-check is implicit).
        if let t = title.map(normalizeOttyTitle), !t.isEmpty {
            let hits = byCwd.filter { normalizeOttyTitle($0.title) == t }
            if hits.count == 1 { return .exact(paneId: hits[0].id) }
        }
        // 2. cwd-unique.
        if byCwd.count == 1 { return .exact(paneId: byCwd[0].id) }
        // 3. can't disambiguate.
        return .ambiguous
    }

    /// Parse `otty-cli pane list --json` → [OttyPane]. Panes live under a
    /// top-level `data` array; an entry missing id/cwd is skipped; the `process`
    /// field is the title. nil when the JSON isn't the expected shape. Pure, so
    /// the fuzzy-join match logic is testable without spawning otty-cli.
    static func parseOttyPanes(_ json: String) -> [OttyPane]? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else { return nil }
        return arr.compactMap { p in
            guard let id = p["id"] as? String, let cwd = p["cwd"] as? String else { return nil }
            return OttyPane(id: id, cwd: cwd, title: (p["process"] as? String) ?? "")
        }
    }

    // MARK: - Process table parsing + ppid-chain targeting (pure)
    //
    // The string/collection half of SessionMonitor's jump targeting and liveness:
    // splitting `ps` output and walking a ppid chain to the owning GUI terminal.
    // Foundation-only so the column math (a comm path may contain spaces; lstart
    // is exactly 5 tokens) and the ancestry walk are unit-testable. Spawning `ps`
    // and converting lstart→epoch (locale/TZ-dependent) stay in the app layer.

    /// One row of `ps -Ao pid=,ppid=,tty=,comm=`: parent pid, controlling tty,
    /// executable path. Keyed by pid in `parseProcTable`.
    struct ProcRow: Equatable {
        let ppid: Int
        let tty: String
        let comm: String
    }

    /// Parse `ps -Ao pid=,ppid=,tty=,comm=` output into pid → row. `comm` is the
    /// remainder of the line so an executable path containing spaces survives;
    /// rows with < 4 columns or a non-integer pid/ppid are skipped. Pure.
    static func parseProcTable(_ out: String) -> [Int: ProcRow] {
        var table: [Int: ProcRow] = [:]
        for line in out.split(separator: "\n") {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard toks.count >= 4, let pid = Int(toks[0]), let ppid = Int(toks[1]) else { continue }
            let comm = toks[3...].joined(separator: " ")
            table[pid] = ProcRow(ppid: ppid, tty: toks[2], comm: comm)
        }
        return table
    }

    /// Split one `ps -o pid=,lstart=,comm=` (or `-axo`) line into (pid, lstart,
    /// comm). lstart is exactly the 5 whitespace tokens of "EEE MMM d HH:mm:ss
    /// yyyy" (a single-digit day still yields 5 tokens — empty subsequences are
    /// omitted); comm is the remainder (may contain spaces). nil for a line with
    /// fewer than 7 tokens or a non-integer pid. Pure + timezone-independent —
    /// the lstart→epoch conversion stays in the app layer (it needs a DateFormatter
    /// in the local zone, which would make a date assertion machine-dependent).
    static func parsePsLine(_ line: String) -> (pid: Int, lstart: String, comm: String)? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 7, let pid = Int(tokens[0]) else { return nil }
        let lstart = tokens[1...5].joined(separator: " ")
        let comm = tokens[6...].joined(separator: " ")
        return (pid, lstart, comm)
    }

    /// Targeting facts resolved purely from a proc table by walking a session's
    /// ppid chain (claude → -zsh → login → GUI app). `pidPresent` is false when
    /// the session's own pid wasn't in the snapshot (a racy/partial table) — the
    /// app layer uses it to avoid caching a degraded result. `appBundlePath` is
    /// the first `.app` ancestor (the app layer turns it into a display name /
    /// bundle id). Bounded to 12 hops so a cycle can't spin.
    struct ProcTarget: Equatable {
        let tty: String?
        let terminal: TerminalKind
        let appBundlePath: String?
        let appPid: Int?
        let multiplexed: Bool
        let pidPresent: Bool
    }

    static func resolveTarget(table: [Int: ProcRow], pid: Int) -> ProcTarget {
        let own = table[pid]
        var multiplexed = false
        var terminal: TerminalKind = .unknown
        var appPid: Int? = nil
        var appBundle: String? = nil
        var cursor = own?.ppid ?? 0
        var hops = 0
        while let row = table[cursor], hops < 12 {
            hops += 1
            if isMultiplexer(comm: row.comm) { multiplexed = true }
            if let bundle = appBundlePath(fromExecPath: row.comm) {
                appBundle = bundle
                appPid = cursor
                terminal = classifyTerminal(commPath: row.comm)
                break
            }
            if row.ppid <= 1 { break }
            cursor = row.ppid
        }
        return ProcTarget(tty: own?.tty, terminal: terminal, appBundlePath: appBundle,
                          appPid: appPid, multiplexed: multiplexed, pidPresent: own != nil)
    }

    // MARK: - Status dot (pure decision)

    /// The Session-row / notch status dot, by PRIORITY. Pure so the view's color
    /// map and its accessibility-label switch derive from ONE decision and can't
    /// drift apart, and the priority (busy > waiting > done-unseen > grey) is
    /// unit-testable. A finished-unseen session is by definition idle/shell/unknown
    /// (the done-unseen reducer does NOT evict on idle→unknown), so `.doneUnseen`
    /// replaces `.grey` for exactly those rows.
    enum SessionDotKind: Equatable {
        case busy        // working (orange)
        case waiting     // wants the user (amber)
        case doneUnseen  // finished a turn the user hasn't engaged (green)
        case grey        // idle / shell / unknown, nothing pending
    }

    static func dotKind(status: SessionStatus, doneUnseen: Bool) -> SessionDotKind {
        switch status {
        case .busy:    return .busy
        case .waiting: return .waiting
        case .idle, .shell, .unknown:
            return doneUnseen ? .doneUnseen : .grey
        }
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
    ///   (c) `seenAll` (the user looked) clears everything.
    /// There is NO time-based expiry: a present session that finished and is
    /// still idle/shell stays an unseen cue indefinitely, until the user clicks
    /// into it (the app-layer per-session `markSeen(sessionId:)`) or it is evicted
    /// by (a)/(b)/(c). `finishedAt = now` is still stamped on each finish so the
    /// value is available for a future "finished Xm ago" presentation.
    /// Returns the next (prevStatuses, doneUnseen). Deterministic for a given
    /// `now`, so the caller must pass its own clock (no Date() in core).
    static func stepDoneUnseen(prev: [String: SessionStatus],
                               current: [SessionInfo],
                               doneUnseen: [String: Double],
                               seenAll: Bool,
                               now: Double) -> (prev: [String: SessionStatus],
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
        for (id, _) in next {
            if let st = curStatus[id], st == .busy || st == .waiting {
                next.removeValue(forKey: id)            // (a) active again
            } else if !currentIds.contains(id) {
                next.removeValue(forKey: id)            // (b) session gone
            }
        }
        return (curStatus, next)
    }
}
