//
//  TranscriptionTextNormalizerTests.swift
//  osaurus
//

import Testing

@testable import OsaurusCore

struct TranscriptionTextNormalizerTests {
    @Test
    func visibleTextDropsInvisibleOnlyTranscripts() {
        let hidden = "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{FFFE}\n\t "

        #expect(TranscriptionTextNormalizer.visibleText(hidden).isEmpty)
        #expect(!TranscriptionTextNormalizer.hasVisibleText(hidden))
    }

    @Test
    func visibleTextPreservesVisibleWords() {
        let text = "\u{200B}  hello\u{2060} world  \n"

        #expect(TranscriptionTextNormalizer.visibleText(text) == "hello world")
        #expect(TranscriptionTextNormalizer.hasVisibleText(text))
    }

    @Test
    func visibleTextPreservesJoinersWhenTextIsVisible() {
        let text = "a\u{200D}b c\u{200C}d"

        #expect(TranscriptionTextNormalizer.visibleText(text) == "a\u{200D}b c\u{200C}d")
        #expect(TranscriptionTextNormalizer.hasVisibleText(text))
    }

    @Test
    func visibleTextPreservesDirectionMarksWhenTextIsVisible() {
        let text = "\u{200F}right-to-left\u{200E}"

        #expect(TranscriptionTextNormalizer.visibleText(text) == "\u{200F}right-to-left\u{200E}")
        #expect(TranscriptionTextNormalizer.hasVisibleText(text))
    }

    @Test
    func visibleTextDropsDirectionMarksWithoutVisibleText() {
        let text = "\u{200F}\u{200E}\u{202A}\u{202C}"

        #expect(TranscriptionTextNormalizer.visibleText(text).isEmpty)
        #expect(!TranscriptionTextNormalizer.hasVisibleText(text))
    }

    @Test
    func combinedSkipsHiddenSegments() {
        let combined = TranscriptionTextNormalizer.combined([
            "\u{200B}",
            " first ",
            "\u{FFFE}",
            "second",
        ])

        #expect(combined == "first second")
    }

    @Test
    func mergedDoesNotAddHiddenTranscript() {
        let merged = TranscriptionTextNormalizer.merged(
            existing: " existing ",
            transcript: "\u{200B}\u{2060}"
        )

        #expect(merged == "existing")
    }

    @Test
    func mergedJoinsVisibleExistingTextAndTranscript() {
        let merged = TranscriptionTextNormalizer.merged(
            existing: " existing ",
            transcript: "\u{200B} transcript "
        )

        #expect(merged == "existing transcript")
    }
}
