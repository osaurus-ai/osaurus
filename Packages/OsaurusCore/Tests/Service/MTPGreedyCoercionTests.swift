import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

/// The greedy-while-MTP contract, at its single enforcement site:
/// - a request that actually runs native MTP decodes greedy (0/1/0/0);
/// - every non-MTP request — no drafter or DFlash 2 — keeps the
///   request/runtime/bundle-resolved sampler untouched, including Qwen 3.8
///   Flash Next's generation_config.json values (1.0 / 0.95 / 20).
@Suite struct MTPGreedyCoercionTests {

    private func bundleShapedParams() -> GenerateParameters {
        var params = GenerateParameters()
        params.temperature = 1.0
        params.topP = 0.95
        params.topK = 20
        params.minP = 0
        return params
    }

    @Test("an MTP-active request reports effective greedy 0/1/0/0")
    func mtpActiveCoercesToGreedy() {
        var params = bundleShapedParams()
        let coerced = MLXBatchAdapter.applyMTPGreedyIfNeeded(
            &params, draftStrategy: .nativeMTP(depth: 2, verifierMode: nil))
        #expect(coerced)
        #expect(params.temperature == 0)
        #expect(params.topP == 1)
        #expect(params.topK == 0)
        #expect(params.minP == 0)
    }

    @Test("no drafter preserves the bundle generation_config sampler")
    func noDrafterPreservesSampling() {
        var params = bundleShapedParams()
        let coerced = MLXBatchAdapter.applyMTPGreedyIfNeeded(
            &params, draftStrategy: nil)
        #expect(!coerced)
        #expect(params.temperature == 1.0)
        #expect(params.topP == 0.95)
        #expect(params.topK == 20)
    }

    @Test("an already-greedy MTP request reports no coercion")
    func alreadyGreedyIsNotACoercion() {
        var params = GenerateParameters()
        params.temperature = 0
        params.topP = 1
        params.topK = 0
        params.minP = 0
        let coerced = MLXBatchAdapter.applyMTPGreedyIfNeeded(
            &params, draftStrategy: .nativeMTP(depth: 1, verifierMode: nil))
        #expect(!coerced)
        #expect(params.temperature == 0)
    }
}
