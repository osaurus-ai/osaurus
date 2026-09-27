import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

/// A DFlash 2 turn must read as one: the log line and the Live Activity row
/// are how a user (or an eval) tells a drafted turn from a plain one.
@Suite("DFlash 2 readout")
struct DFlash2ReadoutTests {
    private var stats: DFlash2GenerationStats {
        var s = DFlash2GenerationStats()
        s.blockSize = 5
        s.verifyCalls = 100
        s.draftedTokens = 400
        s.acceptedTokens = 152
        s.emittedTokens = 252
        s.draftSeconds = 0.18
        s.verifySeconds = 0.95
        return s
    }

    @Test func liveActivityNamesWidthYieldAndAcceptance() {
        #expect(
            LiveActivitySection.describeDFlash2(stats)
                == "DFlash 2 · block 5 · 2.5 tok/verify · 38% of drafts accepted")
        var fallback = stats
        fallback.autoregressiveFallbackTokens = 3
        #expect(LiveActivitySection.describeDFlash2(fallback).hasSuffix("AR fallback 3 tok"))
        var paused = stats
        paused.autoregressiveFallbackTokens = 130
        paused.throughputPauses = 2
        paused.throughputPausedTokens = 128
        #expect(
            LiveActivitySection.describeDFlash2(paused).hasSuffix(
                "plain for 128 tok (drafting slower, 2 pauses) · AR fallback 2 tok"))
    }

    @Test func logLineIsGreppable() {
        let line = GenerationEventMapper.describeDFlash2(stats)
        #expect(line.hasPrefix("block=5 verifyCalls=100 emitted=252 drafted=400 accepted=152 "))
        #expect(line.contains("tokPerVerify=2.52"))
        #expect(line.contains("draftMs=1.80 verifyMs=9.50"))
        #expect(line.contains("pauses=0 pausedTokens=0"))
    }

    @Test func aPlainTurnClearsTheModelsLastDFlashRun() async {
        let model = "readout-\(UUID().uuidString)"
        await MLXBatchAdapter.recordLastDFlash2Stats(modelName: model, stats: stats)
        #expect(await MLXBatchAdapter.lastDFlash2StatsSnapshot()[model] == stats)
        await MLXBatchAdapter.recordLastDFlash2Stats(modelName: model, stats: nil)
        #expect(await MLXBatchAdapter.lastDFlash2StatsSnapshot()[model] == nil)
    }
}
