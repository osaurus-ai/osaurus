//
//  JudgeCalibrationFixtureTests.swift
//  OsaurusEvalsKitTests
//
//  Token-free coverage for the judge-calibration lane: the fixtures must
//  decode, be internally consistent (conditions ↔ expectedVerdicts
//  aligned), and keep the ground-truth mix balanced enough to catch a
//  biased judge. Grading itself needs a live judge LLM, so it is
//  deliberately NOT exercised here — this pins the fixture contract the
//  runner validates before spending a judge call.
//

import Foundation
import Testing

@testable import OsaurusEvalsKit

@MainActor
struct JudgeCalibrationFixtureTests {

    private func loadSuite() throws -> EvalSuite {
        let suiteDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites/JudgeCalibration", isDirectory: true)
        return try EvalSuite.load(from: suiteDir)
    }

    @Test func suiteDecodesWithAlignedGroundTruth() throws {
        let suite = try loadSuite()
        #expect(suite.decodeFailures.isEmpty, "decode failures: \(suite.decodeFailures)")
        // Floor, not exact: new cases must not break this smoke.
        #expect(suite.cases.count >= 10, "JudgeCalibration suite shrank; got \(suite.cases.count)")

        for testCase in suite.cases {
            #expect(testCase.domain == "judge_calibration", "\(testCase.id) has wrong domain")
            let exp = try #require(
                testCase.expect.judgeCalibration,
                "\(testCase.id) missing expect.judgeCalibration"
            )
            #expect(!exp.finalText.isEmpty, "\(testCase.id) has empty finalText")
            #expect(!exp.conditions.isEmpty, "\(testCase.id) has no conditions")
            #expect(
                exp.conditions.count == exp.expectedVerdicts.count,
                "\(testCase.id): \(exp.conditions.count) conditions vs \(exp.expectedVerdicts.count) expected verdicts"
            )
        }
    }

    /// The suite as a whole must contain both expected-pass and
    /// expected-fail verdicts (a suite of all-true ground truth cannot
    /// catch a rubber-stamping judge; all-false cannot catch an
    /// over-strict one).
    @Test func groundTruthMixesPassAndFail() throws {
        let suite = try loadSuite()
        let verdicts = suite.cases.compactMap(\.expect.judgeCalibration).flatMap(\.expectedVerdicts)
        #expect(verdicts.contains(true), "no expected-pass verdicts in the suite")
        #expect(verdicts.contains(false), "no expected-fail verdicts in the suite")
    }

    /// Mis-authored fixtures (count mismatch) must error before any judge
    /// call is spent — the runner's own precondition, exercised without a
    /// model because the guard fires before judge resolution.
    @Test func misalignedFixtureErrorsBeforeJudging() async {
        let testCase = EvalCase(
            id: "judge_calibration.misaligned",
            domain: "judge_calibration",
            query: "q",
            fixtures: .init(),
            expect: .init(
                judgeCalibration: .init(
                    finalText: "some reply",
                    conditions: ["a", "b"],
                    expectedVerdicts: [true]
                )
            )
        )
        let report = await EvalRunner.runJudgeCalibrationCase(testCase, modelId: "fixture")
        #expect(report.outcome == .errored)
        #expect(report.notes.contains { $0.contains("equal-length") })
    }
}
