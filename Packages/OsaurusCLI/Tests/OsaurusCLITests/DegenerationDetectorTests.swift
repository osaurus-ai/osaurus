//
//  DegenerationDetectorTests.swift
//  osaurus
//
//  Threshold tests for the gauntlet's degeneration canary detector: the two
//  known failure modes (`!!!!!…` character runs and `idea idea idea…` phrase
//  loops) must trip it, and normal prose — including legitimate repetition
//  just under the thresholds — must not.
//

import XCTest

@testable import OsaurusCLICore

final class DegenerationDetectorTests: XCTestCase {

    // MARK: - Character runs

    func testCharacterRunAtThresholdIsDetected() {
        let text = "The explanation ends here " + String(repeating: "!", count: 64)
        let evidence = DegenerationDetector.detect(in: text)
        XCTAssertNotNil(evidence)
        XCTAssertTrue(evidence?.contains("\"!\"") == true, "evidence should name the character")
        XCTAssertTrue(evidence?.contains("64") == true, "evidence should carry the run length")
    }

    func testCharacterRunBelowThresholdIsClean() {
        let text = "Wow " + String(repeating: "!", count: 63) + " that is bright."
        XCTAssertNil(DegenerationDetector.detect(in: text))
    }

    func testCharacterRunAtEndOfTextIsDetected() {
        // The run must be caught even when the text ends mid-run.
        let text = "aaaa" + String(repeating: "e", count: 100)
        XCTAssertNotNil(DegenerationDetector.detect(in: text))
    }

    // MARK: - N-gram loops

    func testTwoTokenLoopIsDetected() {
        let text = String(repeating: "I think ", count: 20)
        XCTAssertNotNil(DegenerationDetector.detect(in: text))
    }

    func testSingleWordLoopIsDetectedViaRepeatedPair() {
        // Consecutive identical words form a repeated 2-token unit.
        let text = "The core concept is "
            + Array(repeating: "idea", count: 24).joined(separator: " ")
        let evidence = DegenerationDetector.detect(in: text)
        XCTAssertNotNil(evidence)
        XCTAssertTrue(evidence?.contains("idea idea") == true)
    }

    func testPhraseLoopAtThresholdIsDetected() {
        let text = Array(repeating: "the sky is blue because", count: 8).joined(separator: " ")
        let evidence = DegenerationDetector.detect(in: text)
        XCTAssertNotNil(evidence)
        XCTAssertTrue(evidence?.contains("the sky is blue because") == true)
    }

    func testPhraseRepeatedSevenTimesIsClean() {
        // One repeat under the threshold must not trip the detector.
        let text = Array(repeating: "alpha beta gamma", count: 7).joined(separator: " ")
        XCTAssertNil(DegenerationDetector.detect(in: text))
    }

    func testLoopEmbeddedInProseIsDetected() {
        let text =
            "Rayleigh scattering explains the color. "
            + Array(repeating: "shorter wavelengths scatter more", count: 9)
                .joined(separator: " ")
            + " and that is why the sky is blue."
        XCTAssertNotNil(DegenerationDetector.detect(in: text))
    }

    func testSevenWordPhraseLoopIsDetectedAsSevenGram() {
        // Repeating units longer than 3 words are caught by their own
        // n-gram size (here n=7), not just trigrams.
        let text = Array(repeating: "blue sky today and calm sea tonight", count: 8)
            .joined(separator: " ")
        XCTAssertNotNil(DegenerationDetector.detect(in: text))
    }

    func testNonConsecutiveRepetitionIsClean() {
        // The same fragment appearing often but always separated by a
        // varying token is emphasis, not a loop: no 3–12-gram ever repeats
        // immediately back-to-back.
        let text = (0..<12).map { "blue sky number \($0) is lovely" }.joined(separator: " ")
        XCTAssertNil(DegenerationDetector.detect(in: text))
    }

    func testNormalProseIsClean() {
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
        XCTAssertNil(DegenerationDetector.detect(in: text))
    }

    func testEmptyAndTinyInputsAreClean() {
        XCTAssertNil(DegenerationDetector.detect(in: ""))
        XCTAssertNil(DegenerationDetector.detect(in: "ok"))
        XCTAssertNil(DegenerationDetector.detect(in: "one two three four"))
    }
}
