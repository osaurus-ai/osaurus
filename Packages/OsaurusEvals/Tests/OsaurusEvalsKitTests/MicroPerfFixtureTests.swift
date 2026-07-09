//
//  MicroPerfFixtureTests.swift
//  OsaurusEvalsKitTests
//
//  Token-free coverage for the micro-perf lane: fixtures must decode with
//  sane rep/token counts (median/stdev need >= 2 reps), and the runner
//  must reject malformed expectations BEFORE burning generations. The
//  measurement itself needs a live model and is exercised by the
//  optimization loop, not here.
//

import Foundation
import Testing

@testable import OsaurusEvalsKit

@MainActor
struct MicroPerfFixtureTests {
    private static var suiteURL: URL {
        packageRootURL().appendingPathComponent("Suites/MicroPerf", isDirectory: true)
    }

    private static func packageRootURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // …/Tests/OsaurusEvalsKitTests/MicroPerfFixtureTests.swift → package root
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    @Test
    func fixturesDecodeWithValidShape() throws {
        let suite = try EvalSuite.load(from: Self.suiteURL)
        #expect(suite.cases.count >= 3)
        for testCase in suite.cases {
            #expect(testCase.domain == "micro_perf")
            let exp = try #require(
                testCase.expect.microPerf,
                "case \(testCase.id) is missing expect.microPerf"
            )
            #expect(exp.reps >= 2, "case \(testCase.id): reps must be >= 2 for median/stdev")
            #expect(exp.maxTokens >= 1)
            if let repeatCount = exp.promptRepeat {
                #expect(repeatCount >= 1)
            }
            #expect(!testCase.query.isEmpty)
        }
    }

    @Test
    func runnerRejectsMalformedExpectationsBeforeGenerating() async {
        let missing = EvalCase(
            id: "micro_perf.missing",
            domain: "micro_perf",
            query: "count",
            fixtures: .init(),
            expect: .init()
        )
        let missingReport = await EvalRunner.runMicroPerfCase(missing, modelId: "test")
        #expect(missingReport.outcome == .errored)
        #expect(missingReport.notes.contains { $0.contains("missing `expect.microPerf`") })

        let singleRep = EvalCase(
            id: "micro_perf.single-rep",
            domain: "micro_perf",
            query: "count",
            fixtures: .init(),
            expect: .init(microPerf: .init(reps: 1, maxTokens: 32))
        )
        let singleRepReport = await EvalRunner.runMicroPerfCase(singleRep, modelId: "test")
        #expect(singleRepReport.outcome == .errored)
        #expect(singleRepReport.notes.contains { $0.contains("reps must be >= 2") })

        let zeroTokens = EvalCase(
            id: "micro_perf.zero-tokens",
            domain: "micro_perf",
            query: "count",
            fixtures: .init(),
            expect: .init(microPerf: .init(reps: 3, maxTokens: 0))
        )
        let zeroTokensReport = await EvalRunner.runMicroPerfCase(zeroTokens, modelId: "test")
        #expect(zeroTokensReport.outcome == .errored)
        #expect(zeroTokensReport.notes.contains { $0.contains("maxTokens must be >= 1") })
    }

    @Test
    func statsComputeMedianAndStdev() {
        let odd = MicroPerfStats(nonEmpty: [3, 1, 2])
        #expect(odd?.median == 2)

        let even = MicroPerfStats(nonEmpty: [4, 1, 3, 2])
        #expect(even?.median == 2.5)

        let flat = MicroPerfStats(nonEmpty: [5, 5, 5])
        #expect(flat?.stdev == 0)

        #expect(MicroPerfStats(nonEmpty: []) == nil)

        // Sample stdev of {2, 4}: mean 3, variance ((1+1)/1) = 2.
        let pair = MicroPerfStats(nonEmpty: [2, 4])
        #expect(abs((pair?.stdev ?? 0) - 2.0.squareRoot()) < 1e-9)
    }

    @Test
    func thermalStateLabelsAreStable() {
        #expect(RunEnvironment.thermalStateLabel(.nominal) == "nominal")
        #expect(RunEnvironment.thermalStateLabel(.fair) == "fair")
        #expect(RunEnvironment.thermalStateLabel(.serious) == "serious")
        #expect(RunEnvironment.thermalStateLabel(.critical) == "critical")
    }

    @Test
    func environmentCapturesThermalAndPower() {
        let env = RunEnvironment.current(caseIDs: ["a"], runModel: "test")
        // Thermal state is always readable in-process; power source may be
        // nil in constrained sandboxes, so only its VALUES are pinned.
        #expect(env.thermalState != nil)
        if let source = env.powerSource {
            #expect(["AC", "battery", "UPS"].contains(source))
        }
    }
}
