import Foundation

// MARK: - Transcript parsing — pure core
//
// The pure half of AITitleReader: given a tail buffer (or one JSONL line),
// extract the session title (newest `ai-title`) and the newest CLEAN user
// instruction (newest `last-prompt` / non-junk `user` line). Foundation-only
// (part of CCCostCore) so the de-noising rules are unit-testable; ALL file I/O —
// the bounded tail read and the `~/.claude/projects` glob — stays app-side in
// AITitleReader. Every parse is defensive: malformed JSON / unexpected shapes
// degrade to nil, never throw.

/// One tail pass's result: the session title + the latest user instruction.
/// Either may be nil (no transcript / none found / all junk). Equatable for the
/// monitor's publish-guard and for tests.
struct TranscriptSummary: Equatable {
    let title: String?
    let instruction: String?
    static let empty = TranscriptSummary(title: nil, instruction: nil)
}

enum TranscriptParse {

    /// One in-order pass over a tail buffer's lines, LAST qualifying line winning
    /// per field (so the freshest title/instruction near EOF is chosen; a
    /// front-truncated older line fails to parse and yields to last-wins, so no
    /// special front handling is needed). Cheap substring gates keep JSON parsing
    /// to the handful of marker lines. Lossy UTF-8 decode: a multibyte char cut
    /// at the front becomes U+FFFD, which only lands in the (skippable, older)
    /// front-truncated first line.
    static func scan(_ buffer: Data) -> TranscriptSummary {
        scan(text: String(decoding: buffer, as: UTF8.self))
    }

    /// String overload — `scan(_:Data)` decodes then calls this; tests pass text
    /// directly so they don't have to round-trip through Data.
    static func scan(text: String) -> TranscriptSummary {
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
    static func parseAITitle(_ line: String) -> String? {
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
    static func parseLastPrompt(_ line: String) -> String? {
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
    static func parseUserInstruction(_ line: String) -> String? {
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
    static let junkPrefixes = [
        "<task-notification", "<local-command", "<command-name", "<command-message",
        "<system-reminder", "[Request interrupted", "Caveat:"]

    static func isJunk(_ trimmed: String) -> Bool {
        for p in junkPrefixes where trimmed.hasPrefix(p) { return true }
        return false
    }

    /// Collapse all whitespace/newlines to single spaces, trim, cap to bound
    /// memory (the final visual "…" is SwiftUI's job). A long attachment-only
    /// `@"…/uploads/<id>/<file>"` prompt is shortened to its last path component
    /// so it stays readable. nil/empty in → nil out.
    static func cleaned(_ raw: String?) -> String? {
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
