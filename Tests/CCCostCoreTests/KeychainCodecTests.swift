import Foundation
import Testing
@testable import CCCostCore

@Suite struct KeychainCodecTests {

    // Synthetic credential JSON only — never real token material.

    @Test func plainMinifiedJSONPassthrough() {
        let minified = #"{"claudeAiOauth":{"accessToken":"synthetic-token-123"}}"#
        #expect(KeychainCodec.decodeSecurityValue(minified) == minified)
        // Trailing newline from `security` stdout is trimmed
        #expect(KeychainCodec.decodeSecurityValue(minified + "\n") == minified)
    }

    @Test func plainPrettyJSONPassthrough() {
        // Pretty JSON arriving as literal text (e.g. file path) parses as JSON
        // directly and is returned verbatim, NOT mistaken for hex.
        let pretty = """
        {
          "claudeAiOauth" : {
            "accessToken" : "synthetic-token-123"
          }
        }
        """
        #expect(KeychainCodec.decodeSecurityValue(pretty) == pretty)
    }

    @Test func hexEncodedPrettyJSONRoundTrip() throws {
        // `security -w` hex-encodes values containing newlines (Claude Code
        // stores pretty-printed JSON). Encode → decode → extract.
        let pretty = """
        {
          "claudeAiOauth" : {
            "accessToken" : "synthetic-token-123",
            "expiresAt" : 1780000000000
          }
        }
        """
        let hex = pretty.utf8.map { String(format: "%02X", $0) }.joined()
        let decoded = try #require(KeychainCodec.decodeSecurityValue(hex + "\n"))
        #expect(decoded == pretty)

        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any])
        let oauth = try #require(obj["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "synthetic-token-123")
    }

    @Test func lowercaseHexAnd0xPrefixAccepted() {
        let json = "{\"k\":\n1}"  // newline forces the hex path in real life
        let lower = json.utf8.map { String(format: "%02x", $0) }.joined()
        #expect(KeychainCodec.decodeSecurityValue(lower) == json)
        #expect(KeychainCodec.decodeSecurityValue("0x" + lower) == json)
        #expect(KeychainCodec.decodeSecurityValue("0X" + lower) == json)
    }

    @Test func oddLengthHexLikeStringPassesThrough() {
        // Odd digit count can't be byte hex → returned as-is (trimmed)
        #expect(KeychainCodec.decodeSecurityValue("ABC") == "ABC")
        #expect(KeychainCodec.decodeSecurityValue("0xABC\n") == "0xABC")
    }

    @Test func nonHexStringPassesThrough() {
        #expect(KeychainCodec.decodeSecurityValue("not-hex-at-all") == "not-hex-at-all")
        #expect(KeychainCodec.decodeSecurityValue("zz11\n") == "zz11")
    }

    @Test func emptyOrWhitespaceReturnsNil() {
        #expect(KeychainCodec.decodeSecurityValue("") == nil)
        #expect(KeychainCodec.decodeSecurityValue("   \n  ") == nil)
    }

    @Test func hexDecodingToInvalidUTF8ReturnsNil() {
        // Valid hex, but bytes DE AD BE EF are not UTF-8 — per the
        // implementation this returns nil (equivalent to the old Data path
        // which would have failed JSON parsing downstream anyway).
        #expect(KeychainCodec.decodeSecurityValue("deadbeef") == nil)
    }
}
