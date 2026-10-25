import CryptoKit
import Foundation
import MLXLMCommon

/// Only whitelisted native diagnostics become telemetry. The originating
/// error still belongs to the caller; never copy its text into a report.
struct HandledGPUFailureReport: Sendable, Equatable {
    let modelReference: String
    let stage: String
    let promptTokens: Int?
    let generatedTokens: Int?

    init?(failure: GenerationFailure, modelName: String, promptTokens: Int, generatedTokens: Int) {
        guard failure.cause.contains("[METAL] Command buffer execution failed:"),
            failure.cause.contains("kIOGPUCommandBufferCallbackErrorImpactingInteractivity")
        else { return nil }
        // Canonical catalog ids use publisher--repository. Paths and arbitrary
        // local names remain correlatable without publishing their contents.
        let catalogPattern = #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,95}--[A-Za-z0-9][A-Za-z0-9_.-]{0,159}\z"#
        if modelName.range(of: catalogPattern, options: .regularExpression) != nil {
            modelReference = modelName
        } else {
            let digest = SHA256.hash(data: Data(modelName.utf8))
                .prefix(12).map { String(format: "%02x", $0) }.joined()
            modelReference = "local-sha256:\(digest)"
        }
        stage = failure.stage.rawValue
        self.promptTokens = promptTokens >= 0 ? promptTokens : nil
        self.generatedTokens = generatedTokens >= 0 ? generatedTokens : nil
    }

    var context: [String: Any] {
        var context: [String: Any] = [
            "kind": "impacting_interactivity", "stage": stage,
            "model_reference": modelReference,
            "snapshot_stage": "terminal_info_before_producer_drain",
        ]
        if let promptTokens { context["prompt_tokens"] = promptTokens }
        if let generatedTokens { context["generated_tokens"] = generatedTokens }
        return context
    }

    static func savedProfileContext(_ saved: VMLXMemorySafetySettings) -> [String: Any] {
        var context: [String: Any] = [
            "mode": saved.mode.rawValue, "slider": saved.slider,
            "keep_model_in_memory": saved.keepModelInMemory,
            "fail_closed_when_estimate_unknown": saved.failClosedWhenEstimateUnknown,
        ]
        if let value = saved.customPhysicalMemoryFraction { context["custom_physical_memory_fraction"] = value }
        if let value = saved.customAllocatorCacheBytes { context["custom_allocator_max_bytes"] = value }
        if let value = saved.customDefaultMaxKVSize { context["custom_default_max_kv_tokens"] = value }
        if let value = saved.customMaxConcurrentSequences { context["custom_max_concurrent_sequences"] = value }
        return context
    }
}
