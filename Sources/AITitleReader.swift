import Foundation

// MARK: - AI-title reader (app layer, Foundation-only)
//
// Claude Code writes lines of type `ai-title` into each session transcript:
//   {"type":"ai-title","aiTitle":"Add notch display mode","sessionId":"<sid>"}
// The LATEST aiTitle is the title Claude pushes to the terminal; Otty surfaces
// it as the pane `process` field. Joining a live session's latest aiTitle to the
// Otty pane whose title equals it (with a cwd cross-check) resolves the EXACT
// pane in the click-to-jump path (see SessionLogic.matchOttyPane).
//
// This is read at CLICK TIME (lazily, off the monitor's scan loop) so there is
// zero added cost per scan. Strictly read-only file I/O — no spawn, no write,
// no settings/consent/hook. It is deliberately NOT in CCCostCore (which is pure,
// no file I/O); it stays app-side. Transcripts can be multi-MB, so the read is
// bounded: only the tail is examined, capped, and tolerant of a truncated line
// and malformed JSON (degrades to nil → caller falls back to cwd matching).
enum AITitleReader {

    /// Latest `aiTitle` for a session, or nil if no transcript / no title found.
    static func latestAITitle(sessionId: String,
                              projectsDir: URL = FileManager.default
                                .homeDirectoryForCurrentUser
                                .appendingPathComponent(".claude/projects")) -> String? {
        guard let path = transcriptPath(sessionId: sessionId, projectsDir: projectsDir) else {
            return nil
        }
        return latestAITitle(inFileAt: path)
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

    /// Read the file's TAIL in chunks from EOF backward, returning the `aiTitle`
    /// of the LAST `ai-title` line. Bounds total work so a huge transcript can't
    /// stall the jump queue: at most `cap` bytes are read. A line truncated at
    /// the window's front simply fails to parse and is resolved by reading one
    /// more chunk back (the newest title sits at the end of the file, so it is
    /// captured in the first chunk in the common case). Returns nil on any I/O
    /// failure or if no parseable `ai-title` is found within the cap.
    static func latestAITitle(inFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let chunk = 256 * 1024            // 256 KB read-back per step
        let cap: UInt64 = 4 * 1024 * 1024 // never read more than 4 MB of tail

        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        var pos = end
        var buffer = Data()
        while pos > 0 && UInt64(buffer.count) < cap {
            let step = Int(min(UInt64(chunk), pos))
            pos -= UInt64(step)
            do { try handle.seek(toOffset: pos) } catch { break }
            let data = handle.readData(ofLength: step)
            buffer = data + buffer
            if let title = lastAITitle(in: buffer) { return title }
        }
        return nil
    }

    /// The aiTitle of the newest parseable ai-title line in `buffer`, or nil if
    /// none is parseable yet (caller should widen the window). We scan marker
    /// lines newest→oldest and return the first that parses:
    ///   - A complete-but-unparseable newest marker (a false-positive `"ai-title"`
    ///     substring, a corrupt record, or a line END-truncated by a concurrent
    ///     write at EOF) is skipped in favour of the prior complete title — which
    ///     is exactly what Otty still shows until the new title finishes writing
    ///     and Claude pushes it. So this never returns a *stale* title: the prior
    ///     complete title IS the current pane title while the newer one is mid-write.
    ///   - The only case we widen for is the FRONT line (index 0) failing: it may
    ///     be a real newer title truncated at the window front, which one more
    ///     read-back recovers. We never fall back past a front-truncated newest.
    private static func lastAITitle(in buffer: Data) -> String? {
        // Lossy decode: a multibyte char cut at the front becomes U+FFFD, which
        // only ever lands in the (skippable) front-truncated first line.
        let text = String(decoding: buffer, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        var i = lines.count - 1
        while i >= 0 {
            if lines[i].contains("\"ai-title\"") {
                if let title = parseAITitle(lines[i]) { return title }
                // Marker failed to parse. If it's the front line it may be a
                // real newer title truncated at the window front → widen to
                // recover it. Otherwise it's a complete false-positive/corrupt
                // marker → keep scanning older lines for a usable title.
                if i == 0 { return nil }
            }
            i -= 1
        }
        return nil                                  // no usable marker → widen
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
}
