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
}
