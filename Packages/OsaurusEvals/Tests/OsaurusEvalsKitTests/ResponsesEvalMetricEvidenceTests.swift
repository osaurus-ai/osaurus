import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

@Suite("Responses eval measurement and failure evidence", .serialized)
@MainActor
struct ResponsesEvalMetricEvidenceTests {
    private func turn(_ number: Int, rate: Double?) -> CacheProofTurnMetrics {
        CacheProofTurnMetrics(turnNumber: number, sessionNumber: 1,
            ttftMs: 100, prefillTokensPerSecond: 800, promptTokenCount: 100,
            cacheRestoredTokens: 64, remainingPrefillTokens: 36, cacheRestoreDetail: "disk",
            stopReason: number == 2 ? "length" : "stop", unclosedReasoning: number == 2,
            visibleCharacterCount: 7, reasoningCharacterCount: 10,
            prefillProgressEvents: [.init(stage: "cacheRestore", completedUnitCount: 64, totalUnitCount: 100, detail: "disk")],
            decodeTokensPerSecond: rate, modelResponseID: "resp_\(number)",
            terminalStatus: number == 2 ? "incomplete" : "completed", completionTokenCount: 17,
            scriptedToolDiagnostic: false, originalFunctionCallIDs: ["call_\(number)"],
            cachedInputTokenCount: 64, producerDrainStatus: "native_producer_drained")
    }
    private func cache(error: String? = nil, skip: String? = nil, rate: Double? = nil) -> CacheProofTranscript {
        CacheProofTranscript(visibleTurns: ["first", "partial"], error: error, skipReason: skip,
            kvPrefixHitsDelta: 1, diskL2HitsDelta: 1, decodeTokensPerSecond: rate,
            turnMetrics: [turn(1, rate: 41), turn(2, rate: rate)])
    }

    @Test func actualFinalTurnCannotBorrowAnEarlierReportedRate() {
        let missing = CacheProofDecodeGate.evaluate(turns: [turn(1, rate: 50), turn(2, rate: nil)],
            minimumFinal: 40, minimumRatio: 0.8)
        #expect(missing.count == 1 && missing.allSatisfy { !$0.passed })
        #expect(missing[0].note.contains("actual final turn"))
        let slow = CacheProofDecodeGate.evaluate(turns: [turn(1, rate: 50), turn(2, rate: 11)],
            minimumFinal: 40, minimumRatio: 0.8)
        #expect(slow.count == 2 && slow.allSatisfy { !$0.passed })
        let good = CacheProofDecodeGate.evaluate(turns: [turn(1, rate: 50), turn(2, rate: 42)],
            minimumFinal: 40, minimumRatio: 0.8)
        #expect(good.count == 2 && good.allSatisfy { $0.passed })
    }

    @Test func ratioNeedsAnEarlierBaselineButAbsoluteGateCanUseOneMeasuredTurn() {
        let onlyFinal = [turn(1, rate: nil), turn(2, rate: 42)]
        let ratio = CacheProofDecodeGate.evaluate(turns: onlyFinal, minimumFinal: 40, minimumRatio: 0.8)
        #expect(ratio.count == 2 && !ratio[0].passed && ratio[1].passed)
        let absolute = CacheProofDecodeGate.evaluate(turns: [turn(1, rate: 42)], minimumFinal: 40, minimumRatio: nil)
        #expect(absolute.count == 1 && absolute[0].passed)
        for invalid in [Double.nan, Double.infinity, 0, -1] {
            #expect(CacheProofDecodeGate.evaluate(turns: [turn(1, rate: invalid)], minimumFinal: 40, minimumRatio: nil).allSatisfy { !$0.passed })
        }
    }

    @Test func unknownOutputCannotPassATotalCostCeilingAsZero() {
        #expect(EvalTokenCost.total(estimatedPrompt: 90, reportedCompletion: nil) == nil)
        #expect(EvalTokenCost.ceiling(100, estimatedPrompt: 90, reportedCompletion: nil) == .unreported)
        #expect(EvalTokenCost.ceiling(100, estimatedPrompt: nil, reportedCompletion: 17) == .unreported)
        #expect(EvalTokenCost.ceiling(100, estimatedPrompt: 90, reportedCompletion: 17) == .exceeded(107))
        // Explicitly reported zero is a real measurement and stays distinct.
        #expect(EvalTokenCost.ceiling(100, estimatedPrompt: 90, reportedCompletion: 0) == .within(90))
        #expect(EvalTokenCost.total(estimatedPrompt: Int.max, reportedCompletion: 1) == nil)
    }

    @Test func actualAgentAndClaimsTelemetryPreserveUnknownTotals() throws {
        let agent = AgentLoopTranscript(toolCalls: [], finalText: "fixture", iterations: 1,
            exit: "finalResponse", systemPrompt: "", toolSchemaNames: [], error: nil,
            completionTokens: nil, promptTokensTotal: 90, modelSteps: 1)
        let agentTelemetry = try #require(EvalRunner.telemetry(from: agent))
        #expect(agentTelemetry.promptTokensTotal == 90)
        #expect(agentTelemetry.completionTokens == nil && agentTelemetry.totalModelTokens == nil)
        let claims = CapabilityClaimsTranscript(toolCalls: [], finalText: "fixture", iterations: 1,
            hitIterationCap: false, systemPrompt: "", loadedToolNames: [], error: nil,
            completionTokens: nil, promptTokensTotal: 90, modelSteps: 1)
        let claimsTelemetry = try #require(EvalRunner.claimsTelemetry(from: claims))
        #expect(claimsTelemetry.promptTokensTotal == 90)
        #expect(claimsTelemetry.completionTokens == nil && claimsTelemetry.totalModelTokens == nil)
    }

    @Test func earlyErrorReportKeepsRawCacheRowsInReportAndConfiguredSidecar() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("responses-cache-evidence-" + UUID().uuidString)
        let previous = EvalTranscriptStore.directory
        EvalTranscriptStore.configure(directory: directory)
        defer {
            EvalTranscriptStore.configure(directory: previous)
            try? FileManager.default.removeItem(at: directory)
        }
        // Historical data can contain both; the generation error takes priority.
        let raw = cache(error: "incomplete length", skip: "no MLX engine", rate: 41.123456789)
        let report = try #require(EvalRunner.cacheProofEarlyReport(raw, id: "cache.partial", label: "fixture",
            query: "fixture query", modelId: "fixture-model", latencyMs: 123))
        #expect(report.outcome == .errored)
        #expect(report.cacheProof?.error == "incomplete length")
        #expect(report.cacheProof?.turnMetrics?.last?.modelResponseID == "resp_2")
        #expect(report.cacheProof?.turnMetrics?.last?.terminalStatus == "incomplete")
        #expect(report.cacheProof?.turnMetrics?.last?.producerDrainStatus == "native_producer_drained")
        #expect(report.cacheProof?.turnMetrics?.last?.cachedInputTokenCount == 64)
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(EvalCaseReport.self, from: encoded)
        #expect(decoded.cacheProof?.turnMetrics?.last?.completionTokenCount == 17)
        let sidecar = try JSONDecoder().decode(EvalCaseTranscript.self,
            from: Data(contentsOf: directory.appendingPathComponent("cache.partial.json")))
        #expect(sidecar.cacheProof?.turnMetrics?.last?.decodeTokensPerSecond == 41.123456789)
        #expect(sidecar.cacheProof?.visibleTurns == ["first", "partial"])
        #expect(sidecar.error == "incomplete length")
    }

    @Test func rawEvidenceSurvivesDisabledSidecarsRepeatsAndLegacyDecode() throws {
        let previous = EvalTranscriptStore.directory
        EvalTranscriptStore.configure(directory: nil)
        defer { EvalTranscriptStore.configure(directory: previous) }
        let failure = try #require(EvalRunner.cacheProofEarlyReport(cache(error: "cancelled"), id: "cache.fixture",
            label: "fixture", query: "fixture", modelId: "fixture-model", latencyMs: 1))
        #expect(failure.cacheProof?.error == "cancelled")
        let passing = EvalCaseReport(id: "cache.fixture", label: "fixture", domain: "cache_proof",
            outcome: .passed, notes: [], modelId: "fixture-model", latencyMs: 1, cacheProof: cache(rate: 42))
        let merged = EvalCaseReport.mergedTrials([failure, passing, passing])
        #expect(merged.outcome == .passed && merged.trialSummaries?.count == 3)
        #expect(merged.trialSummaries?.first?.cacheProof?.error == "cancelled")
        let legacy = EvalCaseReport(id: "legacy", label: "legacy", domain: "fixture", outcome: .passed,
            notes: [], modelId: "fixture", latencyMs: nil)
        let decoded = try JSONDecoder().decode(EvalCaseReport.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.cacheProof == nil)
    }
}
