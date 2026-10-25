import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct HandledGPUFailureReportTests {
    private let signature = "[METAL] Command buffer execution failed: Impacting Interactivity (0000000e:kIOGPUCommandBufferCallbackErrorImpactingInteractivity)"

    @Test func nativeSignatureProducesAnIdentifierOnlyReport() throws {
        let cause = "MLX Error: \(signature) at /Users/private-user/secret.cpp:73"
        let report = try #require(HandledGPUFailureReport(
            failure: GenerationFailure(stage: .decoding, cause: cause),
            modelName: "OsaurusAI--Allosaurus-v0.2-125B-A6B-JANGHT1.8", promptTokens: 4096, generatedTokens: 231))
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: report.context), as: UTF8.self)
        #expect(report.stage == "decoding")
        #expect(report.promptTokens == 4096)
        #expect(report.generatedTokens == 231)
        #expect(encoded.contains("Allosaurus-v0.2"))
        #expect(!encoded.contains("private-user"))
        #expect(!encoded.contains("secret.cpp"))
        #expect(!encoded.contains(signature))
        #expect(report.context["snapshot_stage"] as? String == "terminal_info_before_producer_drain")
    }

    @Test(arguments: ["", "Out of memory", "kIOGPUCommandBufferCallbackErrorTimeout",
        "kIOGPUCommandBufferCallbackErrorInnocentVictim", "Impacting Interactivity in user text",
        "kIOGPUCommandBufferCallbackErrorImpactingInteractivity"])
    func unrelatedErrorsAreNotReclassifiedAsInteractivity(cause: String) {
        #expect(HandledGPUFailureReport(failure: GenerationFailure(stage: .preparation, cause: cause),
            modelName: "public--model", promptTokens: 0, generatedTokens: 0) == nil)
    }

    @Test(arguments: ["/Users/private-user/models/secret-model", "private local model", "C:\\Users\\private-user\\model", "public--model\n"])
    func arbitraryLocalNamesAndPathsAreHashed(modelName: String) throws {
        let failure = GenerationFailure(stage: .preparation, cause: signature)
        let first = try #require(HandledGPUFailureReport(failure: failure, modelName: modelName,
            promptTokens: 8, generatedTokens: 0))
        let second = try #require(HandledGPUFailureReport(failure: failure, modelName: modelName,
            promptTokens: 8, generatedTokens: 0))
        #expect(first.modelReference.hasPrefix("local-sha256:"))
        #expect(first.modelReference == second.modelReference)
        #expect(!first.modelReference.contains("private"))
        #expect(!first.modelReference.contains("secret"))
    }

    @Test func unavailableCountsAreNotInventedAsZero() throws {
        let report = try #require(HandledGPUFailureReport(
            failure: GenerationFailure(stage: .preparation, cause: signature),
            modelName: "public--model", promptTokens: -1, generatedTokens: -1))
        #expect(report.context["prompt_tokens"] == nil)
        #expect(report.context["generated_tokens"] == nil)
    }

    @Test func defaultSavedProfileDoesNotInventCustomCaps() {
        let context = HandledGPUFailureReport.savedProfileContext(VMLXMemorySafetySettings())
        #expect(context["mode"] as? String == "safe_auto")
        #expect(context["slider"] as? Int == 2)
        #expect(context["custom_physical_memory_fraction"] == nil)
        #expect(context["custom_allocator_max_bytes"] == nil)
        #expect(context["custom_default_max_kv_tokens"] == nil)
        #expect(context["custom_max_concurrent_sequences"] == nil)
    }

    @Test func everyExplicitRAMOverrideIsRetainedWithoutResolvingNewLimits() {
        var saved = VMLXMemorySafetySettings()
        saved.mode = .strict
        saved.keepModelInMemory = false
        saved.failClosedWhenEstimateUnknown = true
        saved.customPhysicalMemoryFraction = 0.2625
        saved.customAllocatorCacheBytes = 67_108_864
        saved.customDefaultMaxKVSize = 8192
        saved.customMaxConcurrentSequences = 2
        let context = HandledGPUFailureReport.savedProfileContext(saved)
        #expect(context["mode"] as? String == "strict")
        #expect(context["slider"] as? Int == 3)
        #expect(context["keep_model_in_memory"] as? Bool == false)
        #expect(context["fail_closed_when_estimate_unknown"] as? Bool == true)
        #expect(context["custom_physical_memory_fraction"] as? Double == 0.2625)
        #expect(context["custom_allocator_max_bytes"] as? UInt64 == 67_108_864)
        #expect(context["custom_default_max_kv_tokens"] as? Int == 8192)
        #expect(context["custom_max_concurrent_sequences"] as? Int == 2)
        #expect(context["memory_limit_bytes"] == nil)
    }

    @Test func eventKeepsSavedPolicySeparateFromObservedOccupancyAndLimits() throws {
        let report = try #require(HandledGPUFailureReport(
            failure: GenerationFailure(stage: .decoding, cause: signature),
            modelName: "public--model", promptTokens: 128, generatedTokens: 10))
        let memory: [String: Any] = [
            "saved_profile": ["mode": "safe_auto", "slider": 2],
            "observed_at_terminal_info": [
                "gpu_architecture": "applegpu_g17s",
                "allocator_cache_limit_bytes": 8_589_934_592,
                "mlx_cached_bytes": 134_217_728,
                "phys_footprint_bytes": 38_000_000_000,
                "rss_bytes": 37_000_000_000,
            ],
        ]
        let event = CrashReportingService.makeHandledGPUFailureEvent(report: report, memory: memory)
        #expect(event.fingerprint == ["handled-metal-gpu-failure", "impacting-interactivity"])
        #expect(event.tags?["gpu.stage"] == "decoding")
        let snapshot = try #require(event.context?["gpu_memory_snapshot"] as? [String: Any])
        let observed = try #require(snapshot["observed_at_terminal_info"] as? [String: Any])
        #expect(observed["gpu_architecture"] as? String == "applegpu_g17s")
        #expect(observed["allocator_cache_limit_bytes"] as? Int == 8_589_934_592)
        #expect(observed["mlx_cached_bytes"] as? Int == 134_217_728)
        #expect(observed["phys_footprint_bytes"] as? Int == 38_000_000_000)
        #expect(observed["rss_bytes"] as? Int == 37_000_000_000)
        #expect(JSONSerialization.isValidJSONObject(snapshot))
    }
}
