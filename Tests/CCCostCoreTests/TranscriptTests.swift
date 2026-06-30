import Foundation
import Testing
@testable import CCCostCore

@Suite struct TranscriptTests {

    // MARK: - scan: last-wins across a buffer

    @Test func scanPicksNewestTitleAndInstruction() {
        let text = """
        {"type":"ai-title","aiTitle":"Old title"}
        {"type":"user","message":{"content":"first prompt"}}
        {"type":"ai-title","aiTitle":"New title"}
        {"type":"last-prompt","lastPrompt":"latest instruction"}
        """
        let s = TranscriptParse.scan(text: text)
        #expect(s.title == "New title")
        #expect(s.instruction == "latest instruction")
    }

    @Test func scanFrontTruncatedFirstLineLosesToLastWins() {
        // A buffer whose first line is a mid-JSON fragment (window front cut):
        // it fails to parse and the later complete line wins.
        let text = """
        e-title","aiTitle":"garbled fragment"}
        {"type":"ai-title","aiTitle":"Real title"}
        """
        #expect(TranscriptParse.scan(text: text).title == "Real title")
    }

    @Test func scanEmptyBufferIsEmpty() {
        #expect(TranscriptParse.scan(text: "") == TranscriptSummary.empty)
        #expect(TranscriptParse.scan(Data()) == TranscriptSummary.empty)
    }

    @Test func scanDataOverloadDecodesUTF8() {
        let line = "{\"type\":\"ai-title\",\"aiTitle\":\"中文标题\"}"
        let s = TranscriptParse.scan(Data(line.utf8))
        #expect(s.title == "中文标题")
    }

    // MARK: - ai-title / last-prompt parsing

    @Test func parseAITitleRejectsEmptyOrWrongType() {
        #expect(TranscriptParse.parseAITitle("{\"type\":\"ai-title\",\"aiTitle\":\"\"}") == nil)
        #expect(TranscriptParse.parseAITitle("{\"type\":\"user\",\"aiTitle\":\"x\"}") == nil)
        #expect(TranscriptParse.parseAITitle("not json") == nil)
    }

    @Test func parseLastPromptRejectsBlank() {
        #expect(TranscriptParse.parseLastPrompt("{\"type\":\"last-prompt\",\"lastPrompt\":\"   \"}") == nil)
        #expect(TranscriptParse.parseLastPrompt("{\"type\":\"last-prompt\",\"lastPrompt\":\"hi\"}") == "hi")
    }

    // MARK: - user-instruction de-noising

    @Test func userInstructionPlainStringContent() {
        #expect(TranscriptParse.parseUserInstruction(
            "{\"type\":\"user\",\"message\":{\"content\":\"do the thing\"}}") == "do the thing")
    }

    @Test func userInstructionJoinsTextBlocks() {
        let line = "{\"type\":\"user\",\"message\":{\"content\":[" +
            "{\"type\":\"text\",\"text\":\"line A\"}," +
            "{\"type\":\"tool_result\",\"content\":\"ignored\"}," +
            "{\"type\":\"text\",\"text\":\"line B\"}]}}"
        #expect(TranscriptParse.parseUserInstruction(line) == "line A\nline B")
    }

    @Test func userInstructionToolResultOnlyIsNil() {
        let line = "{\"type\":\"user\",\"message\":{\"content\":[" +
            "{\"type\":\"tool_result\",\"content\":\"r\"}]}}"
        #expect(TranscriptParse.parseUserInstruction(line) == nil)
    }

    @Test func userInstructionIsMetaRejected() {
        #expect(TranscriptParse.parseUserInstruction(
            "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"content\":\"/context output\"}}") == nil)
    }

    @Test func userInstructionJunkPrefixRejected() {
        for p in ["<task-notification x", "<local-command-name>", "<system-reminder>",
                  "[Request interrupted by user]", "Caveat: blah"] {
            let line = "{\"type\":\"user\",\"message\":{\"content\":\"\(p)\"}}"
            #expect(TranscriptParse.parseUserInstruction(line) == nil, "should reject: \(p)")
        }
        // A normal prompt that merely CONTAINS a bracket is kept (prefix-only gate).
        #expect(TranscriptParse.parseUserInstruction(
            "{\"type\":\"user\",\"message\":{\"content\":\"fix the [bug] please\"}}") == "fix the [bug] please")
    }

    @Test func isJunkIsPrefixOnly() {
        #expect(TranscriptParse.isJunk("<task-notification foo"))
        #expect(TranscriptParse.isJunk("Caveat: x"))
        #expect(!TranscriptParse.isJunk("this is a Caveat: in the middle"))
        #expect(!TranscriptParse.isJunk("normal prompt"))
    }

    // MARK: - cleaned: whitespace / @-path / cap

    @Test func cleanedCollapsesWhitespace() {
        #expect(TranscriptParse.cleaned("  hello\n\tworld   foo ") == "hello world foo")
        #expect(TranscriptParse.cleaned("   ") == nil)
        #expect(TranscriptParse.cleaned(nil) == nil)
    }

    @Test func cleanedShortensLongSingleAtPathToBasename() {
        let longPath = "@/Users/me/.claude/uploads/" + String(repeating: "a", count: 80) + "/report.pdf"
        #expect(longPath.count > 60)
        #expect(TranscriptParse.cleaned(longPath) == "@report.pdf")
    }

    @Test func cleanedKeepsShortAtPathAndMultiTokenAtText() {
        // Under the 60-char threshold → kept as-is.
        #expect(TranscriptParse.cleaned("@/a/b/c.txt") == "@/a/b/c.txt")
        // Has a space → not a single-attachment prompt → not shortened.
        let s = "@/Users/me/.claude/uploads/" + String(repeating: "a", count: 80) + "/r.pdf and more"
        #expect(TranscriptParse.cleaned(s) == s)
    }

    @Test func cleanedCapsAt300() {
        let long = String(repeating: "x", count: 500)
        #expect(TranscriptParse.cleaned(long)?.count == 300)
    }
}
