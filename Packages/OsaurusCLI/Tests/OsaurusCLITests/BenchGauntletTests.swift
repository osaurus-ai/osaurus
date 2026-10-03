//
//  BenchGauntletTests.swift
//  osaurus
//
//  Tests for the gauntlet's pure verdict functions: the stop-sequence
//  probe's positive-evidence rule and the empty-transcript guards for
//  mtp-equivalence and the degeneration canary. These verdicts feed the
//  capability ledger, so a vacuous pass corrupts serving policy evidence.
//

import XCTest

@testable import OsaurusCLICore

final class BenchGauntletTests: XCTestCase {
    // MARK: - Stop-sequence verdict

    func testStopSequenceCountedToBoundaryThenStoppedPasses() {
        let outcome = BenchCommand.stopSequenceVerdict(
            content: "ALPHA", finishReason: "stop")
        XCTAssertEqual(outcome.verdict, "pass")
    }

    func testStopSequenceWordedAnswerIsUntestedNotPass() {
        // Natural EOS also yields finish_reason "stop": without the digit
        // "6" there is no evidence the stop sequence did anything.
        let outcome = BenchCommand.stopSequenceVerdict(
            content: "I cannot follow that format.", finishReason: "stop")
        XCTAssertEqual(outcome.verdict, "untested")
        XCTAssertTrue(outcome.evidence.contains("exact pre-boundary"))
    }

    func testStopSequenceEmptyContentIsUntested() {
        let outcome = BenchCommand.stopSequenceVerdict(content: "", finishReason: "stop")
        XCTAssertEqual(outcome.verdict, "untested")
    }

    func testStopSequenceContentContainingEightFails() {
        let outcome = BenchCommand.stopSequenceVerdict(
            content: "ALPHAOMEGA", finishReason: "stop")
        XCTAssertEqual(outcome.verdict, "fail")
        XCTAssertTrue(outcome.evidence.contains("continued past"))
    }

    func testStopSequenceLeakedStopTokenFails() {
        // Counted to the boundary but the stop sequence itself surfaced in
        // content: the sequence must be excluded from output.
        let outcome = BenchCommand.stopSequenceVerdict(
            content: "ALPHA<<GAUNTLET_STOP>>", finishReason: "stop")
        XCTAssertEqual(outcome.verdict, "fail")
        XCTAssertTrue(outcome.evidence.contains("leaked into content"))
    }

    func testStopSequenceNonStopFinishReasonFails() {
        let outcome = BenchCommand.stopSequenceVerdict(
            content: "ALPHA", finishReason: "length")
        XCTAssertEqual(outcome.verdict, "fail")
        XCTAssertTrue(outcome.evidence.contains("finish_reason=length"))
    }

    // MARK: - Template leakage positive evidence

    func testTemplateLeakEmptyTranscriptIsUntested() {
        XCTAssertEqual(
            BenchCommand.templateLeakVerdict(content: "", reasoning: "").verdict,
            "untested")
    }

    func testTemplateLeakRecognizesSupportedFamilyMarkers() {
        for marker in ["<end_of_turn>", "<|eot_id|>", "<|end|>", "<|endoftext|>"] {
            let outcome = BenchCommand.templateLeakVerdict(
                content: "answer \(marker)", reasoning: "")
            XCTAssertEqual(outcome.verdict, "fail", "marker \(marker) was not detected")
        }
    }

    func testTemplateLeakCleanNonEmptyTranscriptPasses() {
        XCTAssertEqual(
            BenchCommand.templateLeakVerdict(content: "hello", reasoning: "").verdict,
            "pass")
    }

    // MARK: - Ledger merge safety

    func testLedgerWritePreservesExistingFailureAndUnknownFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("model-ledger.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "org/model": [
                "productionServing": "fail",
                "blockReason": "measured regression",
                "digest": "sha256:old",
                "futureField": ["kept": true],
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: url)

        let record = BenchCommand.GauntletLedgerRecord(
            productionServing: nil,
            source: "gauntlet",
            chip: "M4",
            measuredAt: "2026-07-10T00:00:00Z",
            probes: ["load": "pass"],
            evidence: ["load": "ok"]
        )
        try BenchCommand.writeLedgerRecord(at: url, modelKey: "org/model", record: record)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let result = try XCTUnwrap(root["org/model"] as? [String: Any])
        XCTAssertEqual(result["productionServing"] as? String, "fail")
        XCTAssertEqual(result["blockReason"] as? String, "measured regression")
        XCTAssertEqual(result["digest"] as? String, "sha256:old")
        XCTAssertNotNil(result["futureField"])
        XCTAssertEqual(result["source"] as? String, "gauntlet")
    }

    func testLedgerWritePreservesExistingPass() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("model-ledger.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "org/model": ["productionServing": "pass", "digest": "sha256:weights"]
        ]).write(to: url)

        let record = BenchCommand.GauntletLedgerRecord(
            productionServing: nil,
            source: "gauntlet",
            chip: nil,
            measuredAt: "2026-07-10T00:00:00Z",
            probes: ["load": "fail"],
            evidence: ["load": "failed"]
        )
        try BenchCommand.writeLedgerRecord(at: url, modelKey: "org/model", record: record)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let result = try XCTUnwrap(root["org/model"] as? [String: Any])
        XCTAssertEqual(result["productionServing"] as? String, "pass")
        XCTAssertEqual(result["digest"] as? String, "sha256:weights")
    }

    // MARK: - mtp-equivalence empty-transcript guard

    func testMTPGuardBothRunsSufficientProceeds() {
        XCTAssertNil(
            BenchCommand.mtpEquivalenceTranscriptGuard(
                mtpCompletionTokens: 16, arCompletionTokens: 200))
    }

    func testMTPGuardEmptyTranscriptsAreUntested() {
        let outcome = BenchCommand.mtpEquivalenceTranscriptGuard(
            mtpCompletionTokens: 0, arCompletionTokens: 0)
        XCTAssertEqual(outcome?.verdict, "untested")
        XCTAssertTrue(outcome?.evidence.contains("empty transcript") == true)
    }

    func testMTPGuardRequiresBothRunsAboveThreshold() {
        XCTAssertEqual(
            BenchCommand.mtpEquivalenceTranscriptGuard(
                mtpCompletionTokens: 200, arCompletionTokens: 15)?.verdict,
            "untested")
        XCTAssertEqual(
            BenchCommand.mtpEquivalenceTranscriptGuard(
                mtpCompletionTokens: 15, arCompletionTokens: 200)?.verdict,
            "untested")
    }

    func testMTPGuardMissingUsageCountsAsEmpty() {
        XCTAssertEqual(
            BenchCommand.mtpEquivalenceTranscriptGuard(
                mtpCompletionTokens: nil, arCompletionTokens: 200)?.verdict,
            "untested")
    }

    // MARK: - Degeneration canary transcript guard

    func testCanaryEmptyTranscriptIsUntestedNotPass() {
        let outcome = BenchCommand.degenerationCanaryVerdict(transcript: "")
        XCTAssertEqual(outcome.verdict, "untested")
        XCTAssertTrue(outcome.evidence.contains("too short"))
    }

    func testCanaryShortCleanTranscriptIsUntested() {
        let short = String(repeating: "varied words here ", count: 5)  // < 256 chars
        XCTAssertLessThan(short.count, BenchCommand.gauntletMinCanaryTranscriptChars)
        XCTAssertEqual(BenchCommand.degenerationCanaryVerdict(transcript: short).verdict, "untested")
    }

    func testCanaryLongCleanTranscriptPasses() {
        // Sentence-length variety so the repetition detector stays quiet.
        var long = ""
        var index = 0
        while long.count < 600 {
            long += "Sentence number \(index) discusses a different topic entirely. "
            index += 1
        }
        let outcome = BenchCommand.degenerationCanaryVerdict(transcript: long)
        XCTAssertEqual(outcome.verdict, "pass", "evidence was: \(outcome.evidence)")
    }

    func testCanaryDetectorHitFailsEvenOnShortTranscript() throws {
        let looping = String(repeating: "the same phrase over and over ", count: 40)
        guard DegenerationDetector.detect(in: looping) != nil else {
            // Detector thresholds are its own tests' concern; this test only
            // asserts the verdict wiring when the detector does fire.
            throw XCTSkip("detector did not fire on the synthetic loop")
        }
        XCTAssertEqual(BenchCommand.degenerationCanaryVerdict(transcript: looping).verdict, "fail")
    }

    // MARK: - Option exclusivity

    func testTunePrefillAndGauntletAreMutuallyExclusive() {
        XCTAssertNil(BenchCommand.parseOptions(["--tune-prefill", "--gauntlet"]))
        XCTAssertNotNil(BenchCommand.parseOptions(["--gauntlet"]))
        XCTAssertNotNil(BenchCommand.parseOptions(["--tune-prefill"]))
    }
}
