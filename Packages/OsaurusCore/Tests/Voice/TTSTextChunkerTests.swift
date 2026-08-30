// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("TTS text chunking")
struct TTSTextChunkerTests {
    // A short demo phrase already fits in one decoder run, so it must not be
    // split — that path sounds perfect today and shouldn't change.
    @Test("short text stays a single chunk")
    func shortTextSingleChunk() {
        let chunks = TTSTextChunker.split("Hello there, how are you?")
        #expect(chunks == ["Hello there, how are you?"])
    }

    @Test("empty and whitespace-only text yields no chunks")
    func emptyYieldsNothing() {
        #expect(TTSTextChunker.split("").isEmpty)
        #expect(TTSTextChunker.split("   \n\t ").isEmpty)
    }

    // The whole point of the change: a long paste is broken into several
    // chunks so the decoder state resets before it can drift.
    @Test("long text is broken into multiple chunks under the budget")
    func longTextSplits() {
        let sentence = "This is a fairly ordinary sentence used to build up length. "
        let text = String(repeating: sentence, count: 12)
        let chunks = TTSTextChunker.split(text)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.count <= TTSTextChunker.maxChars)
        }
    }

    // Splitting must not drop or reorder words — the spoken result has to
    // match the input.
    @Test("chunks preserve the original words in order")
    func preservesContent() {
        let text = "First sentence here. Second sentence follows! Third one too? And a tail."
        let chunks = TTSTextChunker.split(text)
        let rejoinedWords = chunks.joined(separator: " ").split(separator: " ")
        let originalWords = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        #expect(rejoinedWords == originalWords)
    }

    // A single sentence longer than the budget can't be split on sentence
    // boundaries; it passes through as its own chunk (FluidAudio splits it
    // further internally) rather than being dropped.
    @Test("an oversized single sentence becomes its own chunk")
    func oversizedSentence() {
        let long = String(repeating: "word ", count: 120).trimmingCharacters(in: .whitespaces)
        let chunks = TTSTextChunker.split(long)
        #expect(chunks == [long])
    }

    // Hard-wrapped prose (newlines mid-sentence) must reflow, not split at
    // every line break — otherwise the voice resets mid-sentence.
    @Test("soft newlines inside a paragraph do not create chunk boundaries")
    func wrappedProseReflows() {
        let wrapped = """
            There is a particular kind of quiet that settles over a city
            just before dawn, when the streetlights still glow but the sky
            has begun to soften.
            """
        let chunks = TTSTextChunker.split(wrapped)
        // One reflowed sentence, well under the budget → a single chunk that
        // starts at the real sentence start, not mid-line.
        #expect(chunks.count == 1)
        #expect(chunks.first?.hasPrefix("There is a particular kind of quiet") == true)
        #expect(chunks.first?.contains("\n") == false)
    }

    // A blank line is a real paragraph break and should start a new chunk even
    // when the two paragraphs would fit within the budget together.
    @Test("blank lines split paragraphs into separate chunks")
    func blankLinesSplitParagraphs() {
        let text = "First short paragraph.\n\nSecond short paragraph."
        let chunks = TTSTextChunker.split(text)
        #expect(chunks == ["First short paragraph.", "Second short paragraph."])
    }
}
