//
//  StreamRepetitionDetectorTests.swift
//  OsaurusCoreTests — Streaming
//
//  Pin `StreamRepetitionDetector`. The bar is intentionally asymmetric: a
//  missed loop costs wall-clock time, a false positive truncates a real
//  answer mid-sentence. The "must not trip" cases matter more than the
//  "must trip" ones.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct StreamRepetitionDetectorTests {

    private func feedAll(_ chunks: [String]) -> StreamRepetitionDetector {
        var detector = StreamRepetitionDetector()
        for chunk in chunks { detector.feed(chunk) }
        return detector
    }

    // MARK: - Must trip

    /// The observed failure: one turn, ~200 repetitions, no tool call.
    @Test func verbatimRepeatedLineTrips() {
        let detector = feedAll(
            Array(repeating: "Let me continue with the remaining documentation:\n", count: 6)
        )
        #expect(detector.hasDetectedLoop)
        #expect(detector.repeatedPhrase == "let me continue with the remaining documentation")
    }

    /// The real transcript varied the tail ("…the final batch", "…the
    /// remaining functions"), so exact-match alone would have missed it. The
    /// shared opening phrase is what identifies the family.
    @Test func varyingTailWithSharedOpeningTrips() {
        let detector = feedAll([
            "Let me continue with the remaining documentation:\n",
            "Let me continue with the final batch:\n",
            "Let me continue with the remaining docs:\n",
            "Let me continue with the remaining functions:\n",
            "Let me continue with the final documentation:\n",
            "Let me continue with the remaining pages:\n",
            "Let me continue with the final functions:\n",
            "Let me continue with the remaining categories:\n",
        ])
        #expect(detector.hasDetectedLoop)
    }

    /// Models loop without newlines too, separating repeats with a markdown
    /// rule — exactly the shape in the export.
    @Test func markdownRuleSeparatedRepeatsTrip() {
        var detector = StreamRepetitionDetector()
        for _ in 0 ..< 6 {
            detector.feed("Let me continue with the remaining documentation:---")
        }
        #expect(detector.hasDetectedLoop)
    }

    /// Chunk boundaries are arbitrary — a loop split mid-word must still trip.
    @Test func detectionSurvivesArbitraryChunkBoundaries() {
        let text = String(
            repeating: "Let me continue with the remaining documentation:\n",
            count: 6
        )
        var detector = StreamRepetitionDetector()
        for character in text { detector.feed(String(character)) }
        #expect(detector.hasDetectedLoop)
    }

    /// Once degenerate, stay degenerate — the consumer polls a latched flag.
    @Test func detectionLatches() {
        var detector = feedAll(
            Array(repeating: "Let me continue with the remaining documentation:\n", count: 6)
        )
        detector.feed("A perfectly ordinary sentence that follows the loop.\n")
        #expect(detector.hasDetectedLoop)
    }

    // MARK: - Must NOT trip

    @Test func ordinaryProseDoesNotTrip() {
        let detector = feedAll([
            "I loaded ten wiki pages into the collection.\n",
            "Each one carries YAML frontmatter with a title and tags.\n",
            "The largest is Toolkit-Variables at 29KB.\n",
            "Search for `Execute-MSI` to find the function reference.\n",
            "Let me know if you want the nested pages too.\n",
        ])
        #expect(!detector.hasDetectedLoop)
    }

    /// Repeated short lines are ordinary content — closing braces, table
    /// rules, bullet markers — and must never trip the detector.
    @Test func repeatedShortLinesDoNotTrip() {
        let detector = feedAll(Array(repeating: "}\n", count: 20))
        #expect(!detector.hasDetectedLoop)
    }

    /// Code legitimately repeats identical substantial lines.
    @Test func repeatedLinesInsideACodeFenceDoNotTrip() {
        var chunks = ["```swift\n"]
        chunks += Array(repeating: "    logger.debug(\"processing next item\")\n", count: 12)
        chunks.append("```\n")
        #expect(!feedAll(chunks).hasDetectedLoop)
    }

    /// A checklist reuses its opening words on every line by construction —
    /// the exact shape the model was ASKED to produce in the failing session.
    /// The opening-phrase family must be suppressed for list items entirely,
    /// or a long "- [ ] Write …" todo would be cut off as degenerate.
    @Test func checklistItemsDoNotTrip() {
        let detector = feedAll([
            "- [ ] Write the Home overview document\n",
            "- [ ] Write the installation methods document\n",
            "- [ ] Write the core functions document\n",
            "- [ ] Write the toolkit components document\n",
            "- [ ] Write the common use cases document\n",
            "- [ ] Write the exit codes document\n",
            "- [ ] Write the deployment variables document\n",
            "- [ ] Write the zero-config install document\n",
            "- [ ] Write the custom dialogs document\n",
            "- [ ] Write the logging document\n",
        ])
        #expect(!detector.hasDetectedLoop)
    }

    /// Numbered steps get the same exemption.
    @Test func numberedStepsDoNotTrip() {
        var chunks: [String] = []
        for index in 1 ... 10 {
            chunks.append("\(index). Scrape the next documentation page in the list.\n")
        }
        #expect(!feedAll(chunks).hasDetectedLoop)
    }

    /// The exemption is scoped to the opening-phrase signal. A list that
    /// repeats one item VERBATIM is still degeneration.
    @Test func verbatimRepeatedListItemStillTrips() {
        let detector = feedAll(
            Array(repeating: "- [ ] Write the Home overview document\n", count: 6)
        )
        #expect(detector.hasDetectedLoop)
    }

    /// Four repeats is aggressive prose, not degeneration. The threshold has
    /// to leave room above normal writing.
    @Test func fewRepeatsStayBelowTheThreshold() {
        let detector = feedAll(
            Array(repeating: "Let me continue with the remaining documentation:\n", count: 4)
        )
        #expect(!detector.hasDetectedLoop)
    }

    /// Repeats spread far apart are a writing tic, not a decoding collapse —
    /// the window is what makes the signal specific.
    @Test func repeatsOutsideTheWindowDoNotTrip() {
        // Filler openings are all distinct, so only the recurring target line
        // could trip the detector — and the window evicts it each time.
        let fillerOpenings = [
            "Alpha records show", "Bravo entries list", "Charlie totals cover",
            "Delta figures include", "Echo values report", "Foxtrot counts track",
            "Golf numbers describe", "Hotel margins summarise",
        ]
        var chunks: [String] = []
        for index in 0 ..< 6 {
            chunks.append("Let me continue with the remaining documentation:\n")
            for filler in 0 ..< StreamRepetitionDetector.windowSize {
                let opening = fillerOpenings[filler % fillerOpenings.count]
                chunks.append("\(opening) the \(index)-\(filler) quarterly breakdown.\n")
            }
        }
        #expect(!feedAll(chunks).hasDetectedLoop)
    }

    // MARK: - Normalization

    @Test func normalizationFoldsCaseWhitespaceAndTrailingPunctuation() {
        #expect(StreamRepetitionDetector.normalize("  Let   me  Continue:  ") == "let me continue")
        #expect(StreamRepetitionDetector.normalize("Let me continue...") == "let me continue")
        #expect(StreamRepetitionDetector.normalize("**Let me continue**") == "let me continue")
    }

    @Test func openingPhraseUsesTheFirstThreeWords() {
        #expect(
            StreamRepetitionDetector.openingPhrase(of: "let me continue with the remaining docs")
                == "let me continue"
        )
        #expect(StreamRepetitionDetector.openingPhrase(of: "let me") == "let me")
    }
}
