//
//  StreamDegenerationDetectorTests.swift
//  osaurusTests
//
//  Threshold tests for the live-stream degeneration detector: the two known
//  failure modes (`!!!!!…` character runs and `idea idea idea…` phrase
//  loops) must trip it, normal prose — including legitimate repetition just
//  under the thresholds — must not, and the incremental adaptation must hold
//  its guarantees (trigger across arbitrary delta splits, bounded tail).
//
//  The batch-mode boundary cases mirror the CLI gauntlet's
//  DegenerationDetectorTests — thresholds are shared and must stay in sync.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("StreamDegenerationDetector thresholds and incremental behaviour")
struct StreamDegenerationDetectorTests {

    /// Feed `text` to a fresh detector, either whole or split into fixed
    /// `chunkSize`-character deltas, returning the first evidence (if any).
    private func observe(_ text: String, chunkSize: Int? = nil) -> String? {
        var detector = StreamDegenerationDetector()
        guard let chunkSize else { return detector.observe(text) }
        var index = text.startIndex
        while index < text.endIndex {
            let end =
                text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex)
                ?? text.endIndex
            if let evidence = detector.observe(String(text[index..<end])) {
                return evidence
            }
            index = end
        }
        return nil
    }

    // MARK: - Character runs (ported boundary cases)

    @Test func characterRunAtThresholdIsDetected() {
        let text = "The explanation ends here " + String(repeating: "!", count: 64)
        let evidence = observe(text)
        #expect(evidence != nil)
        #expect(evidence?.contains("\"!\"") == true, "evidence should name the character")
        #expect(evidence?.contains("64") == true, "evidence should carry the run length")
    }

    @Test func characterRunBelowThresholdIsClean() {
        let text = "Wow " + String(repeating: "!", count: 63) + " that is bright."
        #expect(observe(text) == nil)
    }

    @Test func characterRunAtEndOfTextIsDetected() {
        // The run must be caught even when the text ends mid-run.
        let text = "aaaa" + String(repeating: "e", count: 100)
        #expect(observe(text) != nil)
    }

    // MARK: - N-gram loops (ported boundary cases)

    @Test func singleWordLoopIsDetectedViaTrigram() {
        // 24 consecutive "idea" = the 3-gram "idea idea idea" occurring
        // 8 times back-to-back.
        let text = "The core concept is "
            + Array(repeating: "idea", count: 24).joined(separator: " ")
        let evidence = observe(text)
        #expect(evidence != nil)
        #expect(evidence?.contains("idea idea idea") == true)
    }

    @Test func phraseLoopAtThresholdIsDetected() {
        let text = Array(repeating: "the sky is blue because", count: 8).joined(separator: " ")
        let evidence = observe(text)
        #expect(evidence != nil)
        #expect(evidence?.contains("the sky is blue because") == true)
    }

    @Test func phraseRepeatedSevenTimesIsClean() {
        // One repeat under the threshold must not trip the detector.
        let text = Array(repeating: "alpha beta gamma", count: 7).joined(separator: " ")
        #expect(observe(text) == nil)
    }

    @Test func loopEmbeddedInProseIsDetected() {
        let text =
            "Rayleigh scattering explains the color. "
            + Array(repeating: "shorter wavelengths scatter more", count: 9)
                .joined(separator: " ")
            + " and that is why the sky is blue."
        #expect(observe(text) != nil)
    }

    @Test func sevenWordPhraseLoopIsDetectedAsSevenGram() {
        // Repeating units longer than 3 words are caught by their own
        // n-gram size (here n=7), not just trigrams.
        let text = Array(repeating: "blue sky today and calm sea tonight", count: 8)
            .joined(separator: " ")
        #expect(observe(text) != nil)
    }

    @Test func nonConsecutiveRepetitionIsClean() {
        // The same fragment appearing often but always separated by a
        // varying token is emphasis, not a loop: no 3–12-gram ever repeats
        // immediately back-to-back.
        let text = (0..<12).map { "blue sky number \($0) is lovely" }.joined(separator: " ")
        #expect(observe(text) == nil)
    }

    @Test func normalProseIsClean() {
        let text = """
            The sky appears blue because sunlight entering the atmosphere is \
            scattered by air molecules. Shorter wavelengths, such as blue and \
            violet, scatter far more strongly than longer red wavelengths — \
            this is Rayleigh scattering. Our eyes are more sensitive to blue \
            than violet, and some violet is absorbed high in the atmosphere, \
            so the dome overhead looks blue. A fair critique: this account \
            ignores Mie scattering from aerosols, which whitens the horizon, \
            and it does not explain why sunsets are red.
            """
        #expect(observe(text) == nil)
    }

    @Test func emptyAndTinyInputsAreClean() {
        #expect(observe("") == nil)
        #expect(observe("ok") == nil)
        #expect(observe("one two three four") == nil)
    }

    // MARK: - Incremental behaviour

    @Test func phraseLoopSplitAcrossManySmallDeltasIsDetected() {
        // The same trigger text as the batch case, fed 3 characters at a
        // time (splitting words and separators arbitrarily), must still
        // trip — this is the live-stream shape.
        let text = "The core concept is "
            + Array(repeating: "idea", count: 24).joined(separator: " ")
        let evidence = observe(text, chunkSize: 3)
        #expect(evidence != nil)
        #expect(evidence?.contains("idea idea idea") == true)
    }

    @Test func characterRunSplitAcrossDeltasIsDetected() {
        // `!!!!!` split into 5-char deltas crosses the 64 threshold on a
        // delta boundary; the cross-delta run counter must carry.
        let text = "answer " + String(repeating: "!", count: 70)
        let evidence = observe(text, chunkSize: 5)
        #expect(evidence != nil)
        #expect(evidence?.contains("\"!\"") == true)
    }

    @Test func cleanTextBelowThresholdNeverTriggersWhenStreamed() {
        let text = "Wow " + String(repeating: "!", count: 63) + " that is bright."
        #expect(observe(text, chunkSize: 4) == nil)
    }

    @Test func longCleanStreamNeverTriggersAndTailStaysBounded() {
        // ~64 KB of unique-word text streamed in 1 KB deltas: no trigger,
        // and the internal tail buffer must respect its documented bound at
        // every step (the whole point of the incremental adaptation is that
        // memory does not grow with stream length).
        var detector = StreamDegenerationDetector()
        var word = 0
        for _ in 0..<64 {
            var delta = ""
            while delta.count < 1024 {
                delta += "word\(word) "
                word += 1
            }
            #expect(detector.observe(delta) == nil)
            #expect(
                detector.tailCharacterCountForTesting
                    <= StreamDegenerationDetector.maxTailCharacters
            )
        }
    }

    @Test func detectorLatchesAfterFirstTrigger() {
        // The mapper aborts on first trigger; the latch guarantees no
        // duplicate evidence even if more deltas arrive.
        var detector = StreamDegenerationDetector()
        let loop = Array(repeating: "idea", count: 24).joined(separator: " ")
        #expect(detector.observe(loop) != nil)
        #expect(detector.observe(loop) == nil)
        #expect(detector.observe(String(repeating: "!", count: 100)) == nil)
    }

    @Test func loopArrivingAfterLongCleanPrefixIsStillDetected() {
        // The tail trim must not disable detection later in the stream: a
        // loop that starts after several buffer-lengths of clean text still
        // fits entirely inside the tail window and must trigger.
        var detector = StreamDegenerationDetector()
        for i in 0..<4096 {
            #expect(detector.observe("unique\(i) ") == nil)
        }
        var evidence: String?
        for _ in 0..<24 where evidence == nil {
            evidence = detector.observe("idea ")
        }
        #expect(evidence?.contains("idea idea idea") == true)
    }
}
