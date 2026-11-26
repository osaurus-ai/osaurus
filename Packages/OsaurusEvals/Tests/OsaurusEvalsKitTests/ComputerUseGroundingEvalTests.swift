//
//  ComputerUseGroundingEvalTests.swift
//  OsaurusEvalsKitTests
//
//  Model-free coverage for the `computer_use_grounding` lane: the suite
//  decodes, and every `scriptedFrame` case passes, so the synthetic screens
//  and per-frame scoring hold for the budget a model resolves to.
//

import Foundation
import Testing

@testable import OsaurusEvalsKit

struct ComputerUseGroundingEvalTests {

    @Test func suiteDecodesAndScriptedCasesPass() async throws {
        let suiteDir =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites")
            .appendingPathComponent("ComputerUseGrounding")

        let suite = try EvalSuite.load(from: suiteDir)
        #expect(suite.decodeFailures.isEmpty, "ComputerUseGrounding JSON failed to decode: \(suite.decodeFailures)")

        var scriptedRan = 0
        for testCase in suite.cases where testCase.expect.computerUseGrounding?.scriptedFrame != nil {
            let report = await EvalRunner.runComputerUseGroundingCase(testCase, modelId: "scripted")
            #expect(report.outcome == .passed, "\(testCase.id): \(report.notes)")
            scriptedRan += 1
        }
        #expect(scriptedRan == 3)
    }

    @Test func aWrongFrameIsAttributed() async {
        let testCase = EvalCase(
            id: "grounding.wrong-frame",
            domain: "computer_use_grounding",
            query: "Click the named button on each synthetic screen.",
            fixtures: EvalCase.Fixtures(),
            expect: EvalCase.Expectations(
                computerUseGrounding: EvalCase.ComputerUseGroundingExpectations(
                    expectFrame: "pixels", scriptedFrame: "normalized1000"
                )
            )
        )
        let report = await EvalRunner.runComputerUseGroundingCase(testCase, modelId: "scripted")
        #expect(report.outcome == .failed)
        #expect(report.notes.contains { $0.hasPrefix("attribution:") && $0.contains("case expects pixels") })
    }
}
