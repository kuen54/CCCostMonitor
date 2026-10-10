import CryptoKit
import Foundation
import Testing
@testable import CCCostCore

@Suite struct CredentialLocatorTests {

    // Synthetic paths / attributes only — never real keychain dumps.

    private func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func suffixMatchesClaudeCodeNaming() {
        let name = CredentialLocator.suffixedService(configDir: "/Users/test/.claude", sha256Hex: sha256Hex)
        #expect(name == "Claude Code-credentials-" + String(sha256Hex("/Users/test/.claude").prefix(8)))
        #expect(name.count == "Claude Code-credentials-".count + 8)
    }

    @Test func suffixHashesNFCForm() {
        // "é" decomposed (e + U+0301) must hash like the precomposed form, as Claude Code NFC-normalizes.
        let decomposed = "/Users/caf\u{65}\u{301}/.claude"
        let composed = "/Users/caf\u{e9}/.claude"
        #expect(CredentialLocator.suffixedService(configDir: decomposed, sha256Hex: sha256Hex)
                == CredentialLocator.suffixedService(configDir: composed, sha256Hex: sha256Hex))
    }

    @Test func candidatesWithoutEnv() {
        let services = CredentialLocator.candidateServices(envConfigDir: nil, home: "/Users/test", sha256Hex: sha256Hex)
        #expect(services == [
            "Claude Code-credentials",
            CredentialLocator.suffixedService(configDir: "/Users/test/.claude", sha256Hex: sha256Hex),
        ])
        #expect(CredentialLocator.candidateCredentialFiles(envConfigDir: nil, home: "/Users/test")
                == ["/Users/test/.claude/.credentials.json"])
    }

    @Test func candidatesWithEnvDedupAndOrder() {
        // Env pointing at the default dir: its suffixed item leads, no duplicates.
        let same = CredentialLocator.candidateServices(envConfigDir: "/Users/test/.claude", home: "/Users/test",
                                                       sha256Hex: sha256Hex)
        let suffixed = CredentialLocator.suffixedService(configDir: "/Users/test/.claude", sha256Hex: sha256Hex)
        #expect(same == [suffixed, "Claude Code-credentials"])

        // Env pointing elsewhere: env item, default, then ~/.claude's suffixed item.
        let other = CredentialLocator.candidateServices(envConfigDir: "/tmp/cc", home: "/Users/test",
                                                        sha256Hex: sha256Hex)
        #expect(other == [CredentialLocator.suffixedService(configDir: "/tmp/cc", sha256Hex: sha256Hex),
                          "Claude Code-credentials", suffixed])
        #expect(CredentialLocator.candidateCredentialFiles(envConfigDir: "/tmp/cc", home: "/Users/test")
                == ["/tmp/cc/.credentials.json", "/Users/test/.claude/.credentials.json"])
        // Empty env behaves like unset.
        #expect(CredentialLocator.candidateServices(envConfigDir: "", home: "/Users/test", sha256Hex: sha256Hex)
                == CredentialLocator.candidateServices(envConfigDir: nil, home: "/Users/test", sha256Hex: sha256Hex))
    }

    @Test func parseModDateFromSecurityAttributes() {
        let attrs = """
        keychain: "/Users/test/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="test"
            "cdat"<timedate>=0x32303236303630313038333532345A00  "20260601083524Z\\000"
            "mdat"<timedate>=0x32303236313031303036333032395A00  "20261010063029Z\\000"
            "svce"<blob>="Claude Code-credentials"
        """
        #expect(CredentialLocator.parseModDate(attrs) == "20261010063029Z")
        #expect(CredentialLocator.parseModDate(#"    "mdat"<timedate>=<NULL>"#) == nil)
        #expect(CredentialLocator.parseModDate("") == nil)
    }

    @Test func pickNewestPrefersFreshestThenPriority() {
        #expect(CredentialLocator.pickNewest([]) == nil)
        // The stale unsuffixed item left by an earlier login loses to the active one.
        #expect(CredentialLocator.pickNewest([
            ("Claude Code-credentials", "20260924132143Z"),
            ("Claude Code-credentials-13f379c8", "20261010063029Z"),
        ]) == "Claude Code-credentials-13f379c8")
        // Ties and missing dates keep the earlier candidate; a dated item beats an undated one.
        #expect(CredentialLocator.pickNewest([("a", "20261010063029Z"), ("b", "20261010063029Z")]) == "a")
        #expect(CredentialLocator.pickNewest([("a", nil), ("b", nil)]) == "a")
        #expect(CredentialLocator.pickNewest([("a", nil), ("b", "20200101000000Z")]) == "b")
    }
}
