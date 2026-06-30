import Foundation

// MARK: - Transcript reader (app layer, Foundation-only)
//
// Claude Code writes lines of type `ai-title` into each session transcript:
//   {"type":"ai-title","aiTitle":"Add notch display mode","sessionId":"<sid>"}
// The LATEST aiTitle is the title Claude pushes to the terminal; Otty surfaces
// it as the pane `process` field. Joining a live session's latest aiTitle to the
// Otty pane whose title equals it (with a cwd cross-check) resolves the EXACT
// pane in the click-to-jump path (see SessionLogic.matchOttyPane).
//
// Phase 5 GENERALIZES this into `summary(...)`, which in ONE tail pass extracts
// BOTH the session title (newest `ai-title`) AND the newest user instruction
// (newest clean `last-prompt`/`user` line), so the Session tab can show a
// meaningful title + subtitle. `latestAITitle` remains as a thin wrapper for the
// Otty exact-jump path (it just reads `.title`).
//
// Strictly read-only file I/O — no spawn, no write, no settings/consent/hook. It
// is deliberately NOT in CCCostCore (which is pure, no file I/O); it stays
// app-side. Transcripts can be multi-MB, so the read is bounded: only the tail
// is examined, capped, and tolerant of a truncated line and malformed JSON
// (degrades to nil → callers fall back to cwd matching / placeholder text).
enum AITitleReader {

    /// One tail pass over a transcript: the session title + the latest user
    /// instruction. Either may be nil (no transcript / none found / all junk).
    struct TranscriptSummary: Equatable {
        let title: String?
        let instruction: String?
        static let empty = TranscriptSummary(title: nil, instruction: nil)
    }

    /// Title + latest instruction for a session, resolved via the glob then one
    /// bounded tail read. Empty when there is no transcript. `needInstruction`
    /// false = title-only fast path (the tail loop stops as soon as the title is
    /// found instead of widening to the 4 MB cap hunting an instruction the caller
    /// will not read) — used by the Otty exact-jump path.
    static func summary(sessionId: String,
                        projectsDir: URL = FileManager.default
                          .homeDirectoryForCurrentUser
                          .appendingPathComponent(".claude/projects"),
                        needInstruction: Bool = true) -> TranscriptSummary {
        guard let path = transcriptPath(sessionId: sessionId, projectsDir: projectsDir) else {
            return .empty
        }
        return summary(inFileAt: path, needInstruction: needInstruction)
    }

    /// Latest `aiTitle` for a session, or nil if no transcript / no title found.
    /// Thin wrapper over `summary` — keeps the Otty exact-jump call site (9/11)
    /// working unchanged. Title-only (`needInstruction: false`) so a click never
    /// widens the tail read past the title hunting an unused instruction.
    static func latestAITitle(sessionId: String,
                              projectsDir: URL = FileManager.default
                                .homeDirectoryForCurrentUser
                                .appendingPathComponent(".claude/projects")) -> String? {
        return summary(sessionId: sessionId, projectsDir: projectsDir, needInstruction: false).title
    }

    /// Glob `~/.claude/projects/**/<sessionId>.jsonl` and return the first
    /// TOP-LEVEL match (skips anything under a `subagents/` dir — those are
    /// nested agent transcripts, not the session the user clicked). The
    /// encoded-cwd directory name is fragile, so we match on the sessionId
    /// filename rather than reconstructing the path.
    static func transcriptPath(sessionId: String, projectsDir: URL) -> String? {
        let fm = FileManager.default
        let target = "\(sessionId).jsonl"
        guard let en = fm.enumerator(at: projectsDir,
                                     includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles]) else { return nil }
        // Bound the click-time walk so a pathological tree (huge project count,
        // network home) can't stall the jump queue unboundedly. Also prune the
        // descent into `subagents/` dirs rather than filtering their files after
        // the fact — those nested agent transcripts are never the clicked session.
        var scanned = 0
        let maxEntries = 500_000
        for case let url as URL in en {
            scanned += 1
            if scanned > maxEntries { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if url.lastPathComponent == "subagents" { en.skipDescendants() }
                continue
            }
            guard url.lastPathComponent == target else { continue }
            if url.path.contains("/subagents/") { continue }   // defense in depth
            return url.path
        }
        return nil
    }

    /// Latest `aiTitle` for a file (no glob). Thin wrapper over `summary`,
    /// title-only so it stops at the first chunk that yields a title.
    static func latestAITitle(inFileAt path: String) -> String? {
        return summary(inFileAt: path, needInstruction: false).title
    }

    /// Read the file's TAIL in 256 KB chunks from EOF backward, extracting in ONE
    /// pass BOTH the newest `ai-title` and the newest USER INSTRUCTION (newest
    /// clean `last-prompt`/`user` line). Bounds total work so a huge transcript
    /// can't stall: at most `cap` bytes are read. `ai-title` and instruction
    /// lines both appear frequently near the end, so the first chunk satisfies
    /// the common case; we widen only while one is still missing. Both the
    /// newest title and the newest instruction sit at the END of the file, where
    /// lines are complete, so a line truncated at the window FRONT (an older
    /// candidate) simply fails to parse and loses to last-wins — no special
    /// front handling is needed. Returns `.empty` on any I/O failure.
    static func summary(inFileAt path: String, needInstruction: Bool = true) -> TranscriptSummary {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .empty }
        defer { try? handle.close() }

        let chunk = 256 * 1024            // 256 KB read-back per step
        let cap: UInt64 = 4 * 1024 * 1024 // never read more than 4 MB of tail

        guard let end = try? handle.seekToEnd(), end > 0 else { return .empty }
        var pos = end
        var buffer = Data()
        var result = TranscriptSummary.empty
        while pos > 0 && UInt64(buffer.count) < cap {
            let step = Int(min(UInt64(chunk), pos))
            pos -= UInt64(step)
            do { try handle.seek(toOffset: pos) } catch { break }
            let data = handle.readData(ofLength: step)
            buffer = data + buffer
            result = scan(buffer)
            // Everything needed found: reading further back only yields OLDER
            // candidates, which lose to last-wins — stop. (Common case: one
            // 256 KB chunk.) Title-only callers stop the moment a title appears.
            if result.title != nil && (!needInstruction || result.instruction != nil) { break }
        }
        return result
    }

    /// One in-order pass over `buffer`'s lines, letting the LAST qualifying
    /// line win for each field (so the freshest title / instruction near EOF is
    /// chosen; a mid-write END-truncated newest line fails to parse and yields
    /// to the prior complete one — exactly what the terminal still shows). Cheap
    /// substring gates keep JSON parsing to the handful of marker lines.
    private static func scan(_ buffer: Data) -> TranscriptSummary {
        // Lossy decode: a multibyte char cut at the front becomes U+FFFD, which
        // only ever lands in the (skippable, older) front-truncated first line.
        let text = String(decoding: buffer, as: UTF8.self)
        var title: String? = nil
        var instruction: String? = nil
        for sub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(sub)
            if line.contains("\"ai-title\"") {
                if let t = parseAITitle(line) { title = t }
            }
            if line.contains("\"last-prompt\"") {
                if let lp = parseLastPrompt(line) { instruction = lp }
            } else if line.contains("\"type\":\"user\"") {
                if let txt = parseUserInstruction(line) { instruction = txt }
            }
        }
        return TranscriptSummary(title: cleaned(title), instruction: cleaned(instruction))
    }

    /// Parse one JSONL line, returning its `aiTitle` only when it is genuinely an
    /// `ai-title` record with a non-empty title. Never throws on malformed JSON.
    private static func parseAITitle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "ai-title",
              let title = obj["aiTitle"] as? String,
              !title.isEmpty else { return nil }
        return title
    }

    /// `{"type":"last-prompt","lastPrompt":"<typed prompt>",...}` → the prompt.
    /// `lastPrompt` is the user's clean submitted instruction (no tool-results /
    /// notifications). nil if not a last-prompt record or the prompt is blank.
    private static func parseLastPrompt(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "last-prompt",
              let lp = obj["lastPrompt"] as? String,
              !lp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return lp
    }

    /// `{"type":"user","message":{"content":<String|[blocks]>},...}` → the typed
    /// text, or nil when the line is not a genuine user instruction. `content`
    /// is a plain String for typed prompts, or an array whose `{type:"text"}`
    /// blocks we join (tool_result / image blocks yield no text → nil). Junk is
    /// rejected: `isMeta` lines (slash-command output like `/context`), and text
    /// that (trimmed) begins with an injected-noise marker.
    private static func parseUserInstruction(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "user" else { return nil }
        if (obj["isMeta"] as? Bool) == true { return nil }        // slash-command meta
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        let text: String
        if let s = msg["content"] as? String {
            text = s
        } else if let arr = msg["content"] as? [[String: Any]] {
            text = arr.compactMap { block -> String? in
                guard (block["type"] as? String) == "text",
                      let t = block["text"] as? String else { return nil }
                return t
            }.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isJunk(trimmed) { return nil }
        return text
    }

    /// Injected-noise prefixes that are not user instructions (tool notifications,
    /// local-command wrappers, slash-command markers, interrupt/caveat banners).
    private static let junkPrefixes = [
        "<task-notification", "<local-command", "<command-name", "<command-message",
        "<system-reminder", "[Request interrupted", "Caveat:"]

    private static func isJunk(_ trimmed: String) -> Bool {
        for p in junkPrefixes where trimmed.hasPrefix(p) { return true }
        return false
    }

    /// Collapse all whitespace/newlines to single spaces, trim, cap to bound
    /// memory (the final visual "…" is SwiftUI's job). A long attachment-only
    /// `@"…/uploads/<id>/<file>"` prompt is shortened to its last path component
    /// so it stays readable. nil/empty in → nil out.
    private static func cleaned(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        var s = raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if s.isEmpty { return nil }
        // Single @-path attachment prompt → keep just the filename.
        if s.hasPrefix("@") && !s.dropFirst().contains(" "), s.count > 60 {
            let path = s.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let base = (path as NSString).lastPathComponent
            if !base.isEmpty { s = "@" + base }
        }
        if s.count > 300 { s = String(s.prefix(300)) }
        return s
    }
}
