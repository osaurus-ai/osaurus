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
        #expect(report.context["prompt_tokens"] as? Int == 4096)
        #expect(report.context["generated_tokens"] as? Int == 231)
        #expect(report.context["input_units"] as? Int == 4096)
        #expect(report.context["output_units"] as? Int == 231)
        #expect(encoded.contains("Allosaurus-v0.2"))
        #expect(!encoded.contains("private-user"))
        #expect(!encoded.contains("secret.cpp"))
        #expect(!encoded.contains(signature))
        #expect(report.context["snapshot_stage"] as? String == "app_terminal_info_handler")
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
        #expect(report.context["input_units"] == nil)
        #expect(report.context["output_units"] == nil)
        #expect(report.context["restored_units"] == nil)
        for key in [
            "decode_path", "configured_depth", "last_prefill_stage", "last_prefill_operation", "prefill_completed_units",
            "prefill_total_units", "restored_tokens", "restore_detail", "cache_restore_ms",
            "disk_restore_bytes", "disk_restore_ms", "model_volume_kind",
        ] {
            #expect(report.context[key] == nil, "\(key) must be absent when it was not observed")
        }
    }

    /// The request context lands as identifiers and counts under stable
    /// keys, JSON-serializable, and still without the error text.
    @Test func requestContextIsEncodedAsIdentifiersAndCounts() throws {
        let context = HandledGPUFailureContext(
            decodePath: "native_mtp:d3", configuredDepth: 3,
            lastPrefillStage: "cacheRestore", prefillCompletedUnits: 1200, prefillTotalUnits: 4096,
            restoredTokens: 1200, restoreDetail: "disk", cacheRestoreMs: 2481,
            diskRestoreBytes: 734_003_200, diskRestoreMs: 2400,
            modelVolumeKind: "removable", promptTokens: 4096)
        let cause = "MLX Error: \(signature) at /Users/private-user/secret.cpp:73"
        let report = try #require(HandledGPUFailureReport(
            failure: GenerationFailure(stage: .preparation, cause: cause),
            modelName: "/Users/private-user/models/allosaurus", promptTokens: -1, generatedTokens: -1,
            context: context))
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: report.context), as: UTF8.self)
        #expect(JSONSerialization.isValidJSONObject(report.context))
        #expect(report.context["decode_path"] as? String == "native_mtp:d3")
        #expect(report.context["configured_depth"] as? Int == 3)
        #expect(report.context["last_prefill_stage"] as? String == "cacheRestore")
        #expect(report.context["prefill_completed_units"] as? Int == 1200)
        #expect(report.context["prefill_total_units"] as? Int == 4096)
        #expect(report.context["restored_tokens"] as? Int == 1200)
        #expect(report.context["restored_units"] as? Int == 1200)
        #expect(report.context["restore_detail"] as? String == "disk")
        #expect(report.context["cache_restore_ms"] as? Int == 2481)
        #expect(report.context["disk_restore_bytes"] as? Int64 == 734_003_200)
        #expect(report.context["disk_restore_ms"] as? Int == 2400)
        #expect(report.context["model_volume_kind"] as? String == "removable")
        // A preparation failure reports -1 prompt tokens; the request's count fills in.
        #expect(report.context["prompt_tokens"] as? Int == 4096)
        #expect(report.context["input_units"] as? Int == 4096)
        #expect(report.context["generated_tokens"] == nil)
        #expect(report.context["output_units"] == nil)
        #expect(!encoded.contains("private-user"))
        #expect(!encoded.contains("secret.cpp"))
        #expect(!encoded.contains(signature))
        #expect(report.requestContext == context)
    }

    @Test func runtimePromptCountWinsOverTheRequestCount() throws {
        let report = try #require(HandledGPUFailureReport(
            failure: GenerationFailure(stage: .decoding, cause: signature),
            modelName: "public--model", promptTokens: 4100, generatedTokens: 7,
            context: HandledGPUFailureContext(promptTokens: 4096)))
        #expect(report.context["prompt_tokens"] as? Int == 4100)
        #expect(report.context["generated_tokens"] as? Int == 7)
        #expect(report.context["input_units"] as? Int == 4100)
        #expect(report.context["output_units"] as? Int == 7)
    }

    @Test func knownZeroCountsRemainNumericWithoutTokenNamedAliases() throws {
        let report = try #require(HandledGPUFailureReport(
            failure: GenerationFailure(stage: .preparation, cause: signature),
            modelName: "public--model", promptTokens: 0, generatedTokens: 0,
            context: HandledGPUFailureContext(restoredTokens: 0)))
        for key in ["input_units", "output_units", "restored_units"] {
            #expect(!key.contains("token"))
            #expect(report.context[key] as? Int == 0)
        }
        #expect(report.context["prompt_tokens"] as? Int == 0)
        #expect(report.context["generated_tokens"] as? Int == 0)
        #expect(report.context["restored_tokens"] as? Int == 0)
    }

    @Test func untrustedProgressDetailsCannotBecomeFailureTelemetry() throws {
        let privateDetail = "/Users/private-user/secret-model decode text"
        let report = try #require(HandledGPUFailureReport(
            failure: GenerationFailure(stage: .preparation, cause: signature),
            modelName: "public--model", promptTokens: 64, generatedTokens: 0,
            context: HandledGPUFailureContext(lastPrefillOperation: privateDetail, restoreDetail: privateDetail)))
        #expect(report.context["last_prefill_operation"] == nil)
        #expect(report.context["restore_detail"] == nil)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: report.context), as: UTF8.self)
        #expect(!encoded.contains(privateDetail))
    }

    @Test func volumeKindIsACoarseWordNeverAPath() {
        #expect(HandledGPUFailureReport.volumeKind(of: nil) == nil)
        let kind = HandledGPUFailureReport.volumeKind(of: FileManager.default.temporaryDirectory)
        #expect(["internal", "external", "removable", "unknown"].contains(kind ?? ""))
        let missing = HandledGPUFailureReport.volumeKind(
            of: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/model"))
        #expect(missing == "unknown")
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
        let failureContext = try #require(event.context?["gpu_generation_failure"] as? [String: Any])
        #expect(failureContext["input_units"] as? Int == 128)
        #expect(failureContext["output_units"] as? Int == 10)
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
