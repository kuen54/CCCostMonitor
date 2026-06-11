import Foundation
import Testing
@testable import CCCostCore

@Suite struct ModelClassTests {

    @Test func caseIterableOrderMatchesLegacyUIOrder() {
        // This order IS the display/iteration order the legacy `order` arrays
        // hardcoded (Fable above Opus, then Sonnet/Haiku, non-Claude last).
        #expect(ModelClass.allCases == [.fable, .opus, .sonnet, .haiku, .other])
        #expect(ModelClass.allCases.map(\.rawValue) ==
                ["fable", "opus", "sonnet", "haiku", "other"])
    }

    @Test func displayNamesMatchLegacyNamesDictionaries() {
        #expect(ModelClass.fable.displayName  == "Fable")
        #expect(ModelClass.opus.displayName   == "Opus")
        #expect(ModelClass.sonnet.displayName == "Sonnet")
        #expect(ModelClass.haiku.displayName  == "Haiku")
        #expect(ModelClass.other.displayName  == "Other")
    }

    @Test func parseKnownRawValues() {
        for cls in ModelClass.allCases {
            #expect(ModelClass.parse(cls.rawValue) == cls)
        }
    }

    @Test func parseUnknownStringsReturnNil() {
        #expect(ModelClass.parse("gpt-4o") == nil)
        #expect(ModelClass.parse("kimi-k2") == nil)
        #expect(ModelClass.parse("") == nil)
        // Case-sensitive, like the legacy raw key comparison
        #expect(ModelClass.parse("Opus") == nil)
        #expect(ModelClass.parse("OTHER") == nil)
    }
}
