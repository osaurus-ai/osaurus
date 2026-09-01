import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

/// Pins the tool-loop and sustained-decode cache-proof case contracts so a
/// schema drift (renamed key, dropped gate) fails here instead of silently
/// turning a scored lane into a vacuous one.
@Suite
struct ToolLoopCacheProofCaseTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func loadCase(_ id: String) throws -> EvalCase {
        let suite = try EvalSuite.load(
            from: packageRoot.appendingPathComponent("Suites/CacheProof")
        )
        return try #require(suite.cases.first { $0.id == id })
    }

    @Test func perCallRestoreCaseScoresEveryToolContinuation() throws {
        let testCase = try Self.loadCase("cache_proof.tool-loop-per-call-restore")
        let exp = try #require(testCase.expect.cacheProof)

        let followUps = try #require(exp.toolResultFollowUps)
        #expect(followUps.count == 3)
        // Warm in-session continuations reuse boundaries through the
        // disk-L2 lane (no typed restore events), so the per-call reuse
        // contract is disk-hit movement plus bounded per-continuation TTFT.
        #expect(exp.minDiskL2HitsDelta == 3)
        #expect(exp.maxTtftMs != nil)
        // Tool-loop cases must not also author user follow-ups.
        #expect(exp.followUpTurns == nil)
    }

    @Test func writeVolumeCaseCapsStoresAndFootprint() throws {
        let testCase = try Self.loadCase("cache_proof.tool-loop-write-volume")
        let exp = try #require(testCase.expect.cacheProof)

        #expect(exp.toolResultFollowUps?.count == 3)
        let ceiling = try #require(exp.maxDiskL2StoresDelta)
        // 4 requests; the canonical set is ~1 reusable boundary per request
        // plus initial session/stable boundaries. The ceiling exists to catch
        // rung-ladder regressions (2+ full records per tool call), so it must
        // stay well under 2-per-request-plus-warmups territory going wild,
        // while leaving room for counter semantics (stores counts calls, not
        // unique files).
        #expect(ceiling <= 12)
        #expect(exp.minDiskL2StoresDelta != nil)
        #expect(exp.maxFootprintGrowthMb != nil)
    }

    @Test func sustainedDecodeCaseGatesTheCollapseClass() throws {
        let testCase = try Self.loadCase("cache_proof.sustained-decode-deep-context")
        let exp = try #require(testCase.expect.cacheProof)

        #expect(exp.followUpTurns?.count == 5)
        let ratio = try #require(exp.minFinalDecodeTpsRatio)
        // 0.6 passes normal deep-context degradation but fails the measured
        // allocator-cap collapse (50 -> ~10 tok/s, ratio ~0.2).
        #expect(ratio >= 0.5 && ratio < 1.0)
        // Long decode spans so per-turn rates are real measurements.
        #expect((exp.maxTokens ?? 0) >= 256)
        #expect(exp.toolResultFollowUps == nil)
    }
}
