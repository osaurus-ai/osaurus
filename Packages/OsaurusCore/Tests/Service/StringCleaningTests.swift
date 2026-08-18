import Foundation
import Testing

@testable import OsaurusCore

struct StringCleaningTests {
    @Test
    func stripGeminiDisplayMetadata_removesGeminiSignatureMarkers() {
        let input = "\u{200B}ts:CiQabcDEF123+/=_\u{200B}Dependencies installed."
        let cleaned = StringCleaning.stripGeminiDisplayMetadata(input)

        #expect(cleaned == "Dependencies installed.")
    }

    @Test
    func stripGeminiDisplayMetadata_removesVisibleLeakedSignatureTokens() {
        let input = "ts:CiQbvj72+49RKk4lfHalZIoEXp8c2HsTTVB9c3ugC9IWty4E1FQKdAG+Pvb7T6Kk0wzT0GD Dependencies installed."
        let cleaned = StringCleaning.stripGeminiDisplayMetadata(input)

        #expect(cleaned == "Dependencies installed.")
    }
    // MARK: - Leaked Harmony channel labels

    /// The bug: Gemma-4 emits `<|channel>thought\n…<channel|>`; when the closing
    /// tag spelling isn't recognised the delimiters go but the label survives
    /// into the user-visible answer. Token ids [100, 45518, 107, 101].
    @Test
    func stripLeakedChannelLabel_removesLabelAsEntireMessage() {
        #expect(StringCleaning.stripLeakedChannelLabel("thought") == "")
        #expect(StringCleaning.stripLeakedChannelLabel("  thought \n") == "")
    }

    @Test
    func stripLeakedChannelLabel_removesLabelLineAheadOfTheAnswer() {
        #expect(StringCleaning.stripLeakedChannelLabel("thought\nThe capital is Paris.") == "The capital is Paris.")
    }

    /// The regression guard that matters for every OTHER model: a reply that
    /// legitimately opens with a heading word must survive untouched. An
    /// earlier draft matched case-insensitively and ate this.
    @Test
    func stripLeakedChannelLabel_leavesCapitalisedHeadingsAlone() {
        let heading = "Analysis\nThe data shows a 12% increase."
        #expect(StringCleaning.stripLeakedChannelLabel(heading) == heading)
        #expect(StringCleaning.stripLeakedChannelLabel("Final") == "Final")
        #expect(StringCleaning.stripLeakedChannelLabel("Thought") == "Thought")
    }

    @Test
    func stripLeakedChannelLabel_leavesOrdinaryProseAlone() {
        let prose = "I thought the answer was 42, but the final tally says otherwise."
        #expect(StringCleaning.stripLeakedChannelLabel(prose) == prose)
        let multiword = "thought experiment"
        #expect(StringCleaning.stripLeakedChannelLabel(multiword) == multiword)
        #expect(StringCleaning.stripLeakedChannelLabel("") == "")
    }

    @Test
    func isHarmonyChannelLabel_isExactAndCaseSensitive() {
        #expect(StringCleaning.isHarmonyChannelLabel("thought"))
        #expect(StringCleaning.isHarmonyChannelLabel("analysis"))
        #expect(!StringCleaning.isHarmonyChannelLabel("Thought"))
        #expect(!StringCleaning.isHarmonyChannelLabel("Paris"))
        #expect(!StringCleaning.isHarmonyChannelLabel("thoughts"))
    }

}
