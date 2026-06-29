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
}
