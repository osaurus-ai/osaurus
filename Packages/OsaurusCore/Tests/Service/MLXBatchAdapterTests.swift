//
//  MLXBatchAdapterTests.swift
//  osaurus
//
//  Coverage for the parts of `MLXBatchAdapter` that don't require a loaded
//  MLX model. End-to-end engine submission/streaming is covered by the
//  upstream `BatchEngineTests` in vmlx-swift-lm — duplicating those would
//  drag in a multi-GB model download per CI run.
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct MLXBatchAdapterTests {

    /// The default flipped from 4 → 1 so the vmlx compile path engages
    /// (Stage 1B.3 promotion gates require `maxBatchSize == 1`). See the
    /// `mlxBatchEngineMaxBatchSize` doc comment in InferenceFeatureFlags
    /// for the full rationale + the pending Stage 1B.4 work that would
    /// lift the constraint. If you change the default again, update both
    /// this test AND the doc comment so they stay aligned.
    @Test func maxBatchSize_defaultsToOne_forCompileEngagement() {
        let defaults = isolatedDefaults()
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(in: defaults) == 1)
    }

    @Test func maxBatchSize_respectsUserDefaults() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        let defaults = isolatedDefaults()
        defaults.set(8, forKey: key)
        // Server deployments override to multi-slot at the cost of the
        // compile path — same value the test pinned before; only the
        // default changed.
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(in: defaults) == 8)
    }

    @Test func maxBatchSize_clampsAbsurdValues() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        let defaults = isolatedDefaults()
        defaults.set(9999, forKey: key)
        // Clamp to 32 so a typo doesn't blow out wired memory.
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(in: defaults) == 32)
    }

    @Test func maxBatchSize_zeroFallsBackToDefault_one() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        let defaults = isolatedDefaults()
        defaults.set(0, forKey: key)
        // Zero is treated as "unset" — falls back to the compile-friendly
        // default of 1 (was 4 prior to fa694e9e).
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(in: defaults) == 1)
    }

    @Test func maxBatchSize_runtimeSettingsOverrideUserDefaults() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        let defaults = isolatedDefaults()
        defaults.set(2, forKey: key)
        // The vmlx runtime contract trumps the legacy UserDefaults
        // key; this is the path the Server → Settings panel uses to
        // persist user choice.
        var runtime = VMLXServerRuntimeSettings()
        runtime.concurrency.maxConcurrentSequences = 6
        #expect(
            InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
                in: defaults,
                runtime: runtime
            ) == 6
        )
    }

    @Test func maxBatchSize_continuousBatchingTogglePinsSingleSlotWhenOff() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        let defaults = isolatedDefaults()
        defaults.set(8, forKey: key)

        var runtime = VMLXServerRuntimeSettings()
        runtime.concurrency.maxConcurrentSequences = 6
        runtime.concurrency.continuousBatching = false

        #expect(
            InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
                in: defaults,
                runtime: runtime
            ) == 1
        )
    }

    @Test func maxBatchSize_runtimeSettingsClampsAndFallsBackOnNil() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        let defaults = isolatedDefaults()
        defaults.set(4, forKey: key)
        var runtime = VMLXServerRuntimeSettings()
        runtime.concurrency.maxConcurrentSequences = 200
        // Clamp to 32 just like the legacy path.
        #expect(
            InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
                in: defaults,
                runtime: runtime
            ) == 32
        )

        // Absent runtime value defers to UserDefaults so users who
        // never opened the panel keep their existing override.
        runtime.concurrency.maxConcurrentSequences = nil
        #expect(
            InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
                in: defaults,
                runtime: runtime
            ) == 4
        )
    }

    @Test func preencodeAudioSources_replacesRawAudioAndCountsInputs() {
        let rawSamples: [Float] = [0.1, -0.2, 0.3]
        let chat = [
            MLXLMCommon.Chat.Message.user(
                "hear this",
                audios: [
                    .samples(rawSamples, sampleRate: 16_000),
                    .samples([0.4], sampleRate: 8_000),
                ]
            )
        ]

        let result = MLXBatchAdapter.preencodeAudioSources(in: chat) { audio in
            guard case .samples(let samples, let sampleRate) = audio else {
                Issue.record("only raw samples should be passed to the encoder")
                return nil
            }
            return .samples(samples.map { $0 + 1 }, sampleRate: sampleRate == 16_000 ? 16_000 : 8_000)
        }

        #expect(result.inputCount == 2)
        #expect(result.convertedCount == 2)
        #expect(result.alreadyPreencodedCount == 0)
        #expect(result.chat.count == 1)
        #expect(result.chat[0].audios.count == 2)
        guard case .samples(let convertedSamples, let convertedRate) = result.chat[0].audios[0] else {
            Issue.record("raw samples should be replaced by the encoder output")
            return
        }
        #expect(convertedSamples == [1.1, 0.8, 1.3])
        #expect(convertedRate == 16_000)

        guard case .samples(let secondSamples, let secondRate) = result.chat[0].audios[1] else {
            Issue.record("second raw sample clip should also be replaced")
            return
        }
        #expect(secondSamples == [1.4])
        #expect(secondRate == 8_000)
    }

    @Test func generateParameters_enableCompiledBatchDecodeForSoloDefault() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0,
            maxTokens: 16,
            topP: 1,
            repetitionPenalty: nil
        )

        #expect(
            params.enableCompiledBatchDecode,
            "Osaurus default maxBatchSize=1 path must opt into vmlx BatchEngine compiled decode; leaving this false is the observed half-speed path"
        )
    }

    @Test func generateParameters_canDisableCompiledBatchDecodeForMultiSlotServerMode() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0,
            maxTokens: 16,
            topP: 1,
            minP: 0.02,
            repetitionPenalty: nil,
            enableCompiledBatchDecode: false
        )

        #expect(!params.enableCompiledBatchDecode)
        #expect(params.minP == 0.02)
    }

    @Test func generateParameters_threadsRuntimePrefillStepSize() {
        let params = ModelRuntime.makeGenerateParameters(
            temperature: 0,
            maxTokens: 16,
            topP: 1,
            repetitionPenalty: nil,
            prefillStepSize: 256
        )

        #expect(params.prefillStepSize == 256)
    }

    @Test func effectiveGenerationSettings_honorsBundleDefaultsWhenRequestOmitted() {
        let generation = GenerationParameters(
            temperature: nil,
            maxTokens: 16_384,
            maxTokensExplicit: false,
            topPOverride: nil,
            minPOverride: nil,
            repetitionPenalty: nil
        )
        let defaults = LocalGenerationDefaults.Defaults(
            maxTokens: 300,
            temperature: 1.0,
            topP: 0.95,
            topK: 40,
            minP: 0.03,
            repetitionPenalty: 1.05,
            doSample: true
        )

        let effective = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "JANGQ-AI/MiniMax-M2.7-JANGTQ",
            generation: generation,
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0),
            maxBatchSize: 1,
            modelDefaults: defaults
        )

        #expect(effective.temperature == 1.0)
        #expect(effective.maxTokens == 300)
        #expect(effective.topP == 0.95)
        #expect(effective.topK == 40)
        #expect(effective.minP == 0.03)
        #expect(effective.repetitionPenalty == 1.05)
        #expect(!effective.compiledBatchDecode)
    }

    @Test func effectiveGenerationSettings_preservesNemotronUltraBundleDefaultsWithoutInventingTopK() {
        let generation = GenerationParameters(
            temperature: nil,
            maxTokens: 256,
            maxTokensExplicit: true,
            topPOverride: nil,
            minPOverride: nil,
            repetitionPenalty: nil
        )
        let ultraDefaults = LocalGenerationDefaults.Defaults(
            maxTokens: nil,
            temperature: 1.0,
            topP: 0.95,
            topK: nil,
            minP: nil,
            repetitionPenalty: nil,
            doSample: true
        )

        let effective = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            generation: generation,
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0, topK: nil),
            maxBatchSize: 1,
            modelDefaults: ultraDefaults
        )

        #expect(effective.temperature == 1.0)
        #expect(effective.topP == 0.95)
        #expect(effective.topK == 0)
        #expect(effective.minP == 0)
        #expect(effective.repetitionPenalty == nil)
    }

    @Test func effectiveGenerationSettings_explicitRequestWinsOverBundleDefaults() {
        let generation = GenerationParameters(
            temperature: 0.2,
            maxTokens: 128,
            maxTokensExplicit: true,
            topPOverride: 0.5,
            topKOverride: 32,
            minPOverride: 0.01,
            repetitionPenalty: 1.02
        )
        let defaults = LocalGenerationDefaults.Defaults(
            maxTokens: 300,
            temperature: 1.0,
            topP: 0.95,
            topK: 40,
            minP: 0.03,
            repetitionPenalty: 1.05,
            doSample: true
        )

        let effective = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "JANGQ-AI/MiniMax-M2.7-JANGTQ",
            generation: generation,
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0),
            maxBatchSize: 1,
            modelDefaults: defaults
        )

        #expect(effective.temperature == 0.2)
        #expect(effective.maxTokens == 128)
        #expect(effective.topP == 0.5)
        #expect(effective.topK == 32)
        #expect(effective.minP == 0.01)
        #expect(effective.repetitionPenalty == 1.02)
    }

    @Test func effectiveGenerationSettings_nativeMTPPreservesBundleDefaultsWhenRequestIsOmitted() {
        let generation = GenerationParameters(
            temperature: nil,
            maxTokens: 128,
            maxTokensExplicit: true,
            topPOverride: nil,
            minPOverride: nil,
            repetitionPenalty: nil
        )
        let mtpBundleDefaults = LocalGenerationDefaults.Defaults(
            maxTokens: 300,
            temperature: 1.0,
            topP: 0.95,
            topK: 20,
            minP: 0.02,
            repetitionPenalty: 1.05,
            doSample: true
        )

        let effective = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "JANGQ/Qwen3.6-35B-A3B-MXFP4-MTP",
            generation: generation,
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0),
            maxBatchSize: 1,
            modelDefaults: mtpBundleDefaults,
            draftStrategy: .nativeMTP(depth: 3)
        )

        #expect(effective.temperature == 1.0)
        #expect(effective.topP == 0.95)
        #expect(effective.topK == 20)
        #expect(effective.minP == 0.02)
        #expect(effective.repetitionPenalty == 1.05)
    }

    @Test func effectiveGenerationSettings_nativeMTPDoesNotForceGreedyForImplicitChatDefaults() {
        let generation = GenerationParameters(
            temperature: 0.7,
            maxTokens: 128,
            maxTokensExplicit: true,
            topPOverride: nil,
            minPOverride: nil,
            repetitionPenalty: nil,
            samplingParametersAreImplicit: true
        )
        let mtpBundleDefaults = LocalGenerationDefaults.Defaults(
            maxTokens: nil,
            temperature: 1.0,
            topP: 0.95,
            topK: 20,
            minP: nil,
            repetitionPenalty: nil,
            doSample: true
        )

        let effective = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "JANGQ/Qwen3.6-35B-A3B-MXFP4-MTP",
            generation: generation,
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0),
            maxBatchSize: 1,
            modelDefaults: mtpBundleDefaults,
            draftStrategy: .nativeMTP(depth: 3)
        )

        #expect(effective.temperature == 0.7)
        #expect(effective.topP == 0.95)
        #expect(effective.topK == 20)
        #expect(effective.minP == 0)
    }

    @Test func effectiveGenerationSettings_nativeMTPDoesNotOverrideExplicitSampling() {
        let generation = GenerationParameters(
            temperature: 0.7,
            maxTokens: 128,
            maxTokensExplicit: true,
            topPOverride: nil,
            topKOverride: 32,
            minPOverride: nil,
            repetitionPenalty: nil
        )
        let mtpBundleDefaults = LocalGenerationDefaults.Defaults(
            maxTokens: nil,
            temperature: 1.0,
            topP: 0.95,
            topK: 20,
            minP: nil,
            repetitionPenalty: nil,
            doSample: true
        )
        let effectiveDraftStrategy = MLXBatchAdapter.effectiveDraftStrategy(
            generation: generation,
            draftStrategy: .nativeMTP(depth: 3)
        )

        let effective = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "JANGQ/Qwen3.6-35B-A3B-MXFP4-MTP",
            generation: generation,
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0),
            maxBatchSize: 1,
            modelDefaults: mtpBundleDefaults,
            draftStrategy: effectiveDraftStrategy,
            nativeMTPExplicitSamplingFallback: effectiveDraftStrategy == nil
        )

        #expect(effectiveDraftStrategy == nil)
        #expect(effective.temperature == 0.7)
        #expect(effective.topP == 0.95)
        #expect(effective.topK == 32)
        #expect(effective.repetitionPenalty == nil)
        #expect(effective.compiledBatchDecode == false)
    }

    @Test func effectiveDraftStrategy_dropsNativeMTPForExplicitNonGreedySampling() {
        let explicitSampling = GenerationParameters(
            temperature: 0.7,
            maxTokens: 128,
            maxTokensExplicit: true,
            topPOverride: 0.95,
            minPOverride: nil,
            repetitionPenalty: nil
        )

        #expect(
            MLXBatchAdapter.effectiveDraftStrategy(
                generation: explicitSampling,
                draftStrategy: .nativeMTP(depth: 3)
            ) == nil
        )
    }

    @Test func effectiveDraftStrategy_dropsNativeMTPForImplicitChatSampling() {
        let implicitSampling = GenerationParameters(
            temperature: 0.7,
            maxTokens: 128,
            maxTokensExplicit: true,
            topPOverride: nil,
            minPOverride: nil,
            repetitionPenalty: nil,
            samplingParametersAreImplicit: true
        )

        #expect(
            MLXBatchAdapter.effectiveDraftStrategy(
                generation: implicitSampling,
                draftStrategy: .nativeMTP(depth: 3)
            ) == nil
        )
    }

    @Test func effectiveDraftStrategy_dropsNativeMTPForTinyPrompt() {
        let greedy = GenerationParameters(
            temperature: 0,
            maxTokens: 32,
            maxTokensExplicit: true,
            topPOverride: nil,
            minPOverride: nil,
            repetitionPenalty: nil
        )

        #expect(
            MLXBatchAdapter.effectiveDraftStrategy(
                generation: greedy,
                draftStrategy: .nativeMTP(depth: 3),
                promptTokenCount: MLXBatchAdapter.nativeMTPTinyPromptMinimumTokens - 1
            ) == nil
        )

        #expect(
            MLXBatchAdapter.effectiveDraftStrategy(
                generation: greedy,
                draftStrategy: .nativeMTP(depth: 3),
                promptTokenCount: MLXBatchAdapter.nativeMTPTinyPromptMinimumTokens
            )?.usesNativeMTP == true
        )
    }

    @Test func effectiveDraftStrategy_dropsNativeMTPForColdWarmup() {
        let greedy = GenerationParameters(
            temperature: 0,
            maxTokens: 32,
            maxTokensExplicit: true,
            topPOverride: nil,
            minPOverride: nil,
            repetitionPenalty: nil
        )

        #expect(
            MLXBatchAdapter.effectiveDraftStrategy(
                generation: greedy,
                draftStrategy: .nativeMTP(depth: 3),
                promptTokenCount: 128,
                disableNativeMTP: true
            ) == nil
        )

        let effective = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "JANGQ/Qwen3.6-35B-A3B-MXFP4-MTP",
            generation: greedy,
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0),
            maxBatchSize: 1,
            modelDefaults: .empty,
            draftStrategy: nil,
            nativeMTPExplicitSamplingFallback: true
        )

        #expect(effective.temperature == 0)
        #expect(effective.topP == 1)
        #expect(effective.topK == 0)
        #expect(effective.minP == 0)
        #expect(effective.repetitionPenalty == nil)
        #expect(effective.compiledBatchDecode == false)
    }

    @Test func effectiveGenerationSettings_dsv4MaxReasoningKeepsModelPenalty() {
        let generation = GenerationParameters(
            temperature: nil,
            maxTokens: 384,
            maxTokensExplicit: true,
            topPOverride: nil,
            minPOverride: nil,
            repetitionPenalty: nil,
            modelOptions: ["reasoningEffort": .string("max")]
        )
        let defaults = LocalGenerationDefaults.Defaults(
            maxTokens: nil,
            temperature: 0.6,
            topP: 0.95,
            topK: nil,
            minP: nil,
            repetitionPenalty: 1.0,
            doSample: true
        )

        let effective = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "deepseek-v4-flash-jangtq-k",
            generation: generation,
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0),
            maxBatchSize: 1,
            modelDefaults: defaults
        )

        #expect(effective.repetitionPenalty == 1.0)
    }

    @Test func effectiveGenerationSettings_dsv4HighAndExplicitPenaltyKeepRequestedValue() {
        let defaults = LocalGenerationDefaults.Defaults(
            maxTokens: nil,
            temperature: 0.6,
            topP: 0.95,
            topK: nil,
            minP: nil,
            repetitionPenalty: 1.0,
            doSample: true
        )
        let high = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "deepseek-v4-flash-jangtq-k",
            generation: GenerationParameters(
                temperature: nil,
                maxTokens: 384,
                maxTokensExplicit: true,
                repetitionPenalty: nil,
                modelOptions: ["reasoningEffort": .string("high")]
            ),
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0),
            maxBatchSize: 1,
            modelDefaults: defaults
        )
        let explicit = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "deepseek-v4-flash-jangtq-k",
            generation: GenerationParameters(
                temperature: nil,
                maxTokens: 384,
                maxTokensExplicit: true,
                repetitionPenalty: 1.03,
                modelOptions: ["reasoningEffort": .string("max")]
            ),
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0),
            maxBatchSize: 1,
            modelDefaults: defaults
        )

        #expect(high.repetitionPenalty == 1.0)
        #expect(explicit.repetitionPenalty == 1.03)
    }

    @Test func effectiveGenerationSettings_fallsBackToVMLXEngineDefaults() {
        let effective = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "local/no-generation-config",
            generation: GenerationParameters(
                temperature: nil,
                maxTokens: 128,
                maxTokensExplicit: true,
                topPOverride: nil,
                minPOverride: nil,
                repetitionPenalty: nil
            ),
            runtimeDefaults: VMLXServerGenerationDefaults(),
            maxBatchSize: 1,
            modelDefaults: .empty
        )

        let engineDefaults = MLXLMCommon.GenerateParameters()
        #expect(effective.temperature == engineDefaults.temperature)
        #expect(effective.topP == engineDefaults.topP)
        #expect(effective.topK == engineDefaults.topK)
        #expect(effective.minP == engineDefaults.minP)
        #expect(effective.repetitionPenalty == engineDefaults.repetitionPenalty)
    }

    @Test func cacheCoordinatorModelKey_namespacesPathDependentCacheTopologies() {
        let dsv4 = ModelRuntime.cacheCoordinatorModelKey(
            modelName: "DeepSeek-V4-Flash-JANGTQ2",
            kvModeTag: "fp16"
        )
        let zaya = ModelRuntime.cacheCoordinatorModelKey(
            modelName: "ZAYA1-8B-JANGTQ4",
            kvModeTag: "fp16"
        )
        let ling = ModelRuntime.cacheCoordinatorModelKey(
            modelName: "Ling-2.6-flash-JANGTQ2-CRACK",
            kvModeTag: "fp16"
        )
        let omni = ModelRuntime.cacheCoordinatorModelKey(
            modelName: "Nemotron-Omni-Nano-JANGTQ4-CRACK",
            kvModeTag: "fp16"
        )
        let generic = ModelRuntime.cacheCoordinatorModelKey(
            modelName: "Mistral-Medium-3.5-128B-MXFP4",
            kvModeTag: "fp16"
        )

        #expect(dsv4.contains("kv=fp16"))
        #expect(dsv4.contains("cachefmt=2"))
        #expect(dsv4.contains("restore=fullhit-trim-eval1"))
        #expect(dsv4.contains("layers=deepseekV4"))
        #expect(dsv4.contains("prefix=hybrid-pool-disk"))
        #expect(dsv4.contains("decode=max-rp110"))
        #expect(!dsv4.contains("layers=hybrid-ssm"))

        #expect(zaya.contains("layers=zayaCCA"))
        #expect(zaya.contains("prefix=path-dependent-disk"))

        #expect(ling.contains("layers=hybrid-ssm"))
        #expect(omni.contains("media=omni-audio-video"))

        #expect(!generic.contains("layers=deepseekV4"))
        #expect(!generic.contains("layers=zayaCCA"))
        #expect(!generic.contains("layers=hybrid-ssm"))
        #expect(!generic.contains("media=omni-audio-video"))

        #expect(Set([dsv4, zaya, ling, omni, generic]).count == 5)
    }

    @Test func cacheKVModeTagTracksEffectiveCoordinatorPolicy() {
        var settings = VMLXServerRuntimeSettings()

        // POLICY (2026-06-12): engineSelected resolves to native fp16 for
        // EVERY family — TurboQuant is never auto-enabled. Previously MiniMax
        // (full-KV) resolved to turbo(3,3); the per-step compress/decompress
        // tax regresses decode across families, so engine-selected stays fp16.
        // TurboQuant is opt-in only via an explicit liveKVCodec=turboQuant.
        settings.cache.liveKVCodec = .engineSelected
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "MiniMax-M2.7-JANG_K-CRACK"
            ) == "fp16"
        )
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "DeepSeek-V4-Flash-JANGTQ2"
            ) == "fp16"
        )
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "ZAYA1-VL-8B-JANGTQ4"
            ) == "fp16"
        )
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "Qwen3.6-35B-A3B-MXFP4-CRACK-MTP"
            ) == "fp16"
        )
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "Gemma-4-26B-A4B-it-JANG_4M-CRACK"
            ) == "fp16"
        )
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "JANGQ-AI/Step-3.7-Flash-JANG_2L"
            ) == "fp16"
        )
        // Gemma SWA topologies stay native even when topology facts are
        // present: rotating layers route through the generic rule (no Gemma
        // special case). Forcing turbo(3,3) here measured -42% decode on
        // 26B-A4B and -29% on 12B for ~70 MB of KV savings (2026-06-12).
        let gemmaSWATopology = ModelCacheTopologySnapshot(
            layerCount: 6,
            kvLayerCount: 3,
            turboQuantKVLayerCount: 3,
            rotatingKVLayerCount: 3,
            rotatingWrapperLayerCount: 3,
            hybridPoolLayerCount: 0,
            mambaLayerCount: 0,
            arraysLayerCount: 0
        )
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "Gemma-4-26B-A4B-it-JANG_4M-CRACK",
                cacheTopology: gemmaSWATopology
            ) == "fp16"
        )
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "step-3.7-flash-jang_2l"
            ) == "fp16"
        )
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "JANGQ-AI/Step-3.7-Flash-JANG_2L",
                cacheTopology: ModelCacheTopologySnapshot(
                    layerCount: 45,
                    kvLayerCount: 12,
                    turboQuantKVLayerCount: 0,
                    rotatingKVLayerCount: 33
                )
            ) == "fp16"
        )
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "JANGQ-AI/Step-3.7-Flash-JANGTQ_K",
                cacheTopology: ModelCacheTopologySnapshot(
                    layerCount: 45,
                    kvLayerCount: 12,
                    turboQuantKVLayerCount: 0,
                    rotatingKVLayerCount: 33
                )
            ) == "fp16"
        )
        // MiniMax full-KV topology also stays native under engineSelected now
        // (was turbo(3,3) before the blanket-off policy).
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "MiniMax-M2.7-JANG_K-CRACK",
                cacheTopology: ModelCacheTopologySnapshot(
                    layerCount: 62,
                    kvLayerCount: 62,
                    turboQuantKVLayerCount: 0,
                    rotatingKVLayerCount: 0
                )
            ) == "fp16"
        )

        // Explicit opt-in still works: liveKVCodec=turboQuant resolves to
        // turbo(3,3) regardless of family (bypasses the auto gate).
        settings.cache.liveKVCodec = .turboQuant
        settings.cache.turboQuantKeyBits = 3
        settings.cache.turboQuantValueBits = 3
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "MiniMax-M2.7-JANG_K-CRACK"
            ) == "turbo(3,3)"
        )

        settings.cache.liveKVCodec = .native
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "MiniMax-M2.7-JANG_K-CRACK"
            ) == "fp16"
        )

        settings.cache.liveKVCodec = .turboQuant
        settings.cache.turboQuantKeyBits = nil
        settings.cache.turboQuantValueBits = nil
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "DeepSeek-V4-Flash-JANGTQ2"
            ) == "fp16"
        )

        settings.cache.turboQuantKeyBits = 4
        settings.cache.turboQuantValueBits = 3
        #expect(
            ModelRuntime.cacheKVModeTag(
                for: settings.cache,
                modelName: "DeepSeek-V4-Flash-JANGTQ2"
            ) == "turbo(4,3)"
        )
    }

    @Test func cacheCoordinatorModelKey_alignsWithKnownHybridFamilies() {
        for name in [
            "OsaurusAI/Qwen3.6-35B-A3B-mxfp4",
            "qwen3_5_moe",
            "qwen3_6_moe",
            "qwen36_moe",
            "qwen3-next-80b-jangtq",
            "nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            "NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            "ibm-granite/granite-3.0-moe-hybrid-7b",
            "tiiuae/falcon-h1-34b",
            "baichuan-m1-14b",
            "jamba-3b",
            "lfm2-vl-1.6b",
        ] {
            let key = ModelRuntime.cacheCoordinatorModelKey(
                modelName: name,
                kvModeTag: "fp16"
            )
            #expect(
                key.contains("layers=hybrid-ssm"),
                "Hybrid family cache key must include SSM companion topology: \(name)"
            )
        }

        let omni = ModelRuntime.cacheCoordinatorModelKey(
            modelName: "Nemotron-Omni-Nano-JANGTQ4-CRACK",
            kvModeTag: "fp16"
        )
        #expect(omni.contains("layers=hybrid-ssm"))
        #expect(omni.contains("media=omni-audio-video"))

        let zaya = ModelRuntime.cacheCoordinatorModelKey(
            modelName: "ZAYA1-8B-JANGTQ4",
            kvModeTag: "fp16"
        )
        #expect(zaya.contains("layers=zayaCCA"))
        #expect(!zaya.contains("layers=hybrid-ssm"))
    }

    @Test func cacheCoordinatorModelKeyIncludesLoadedCacheTopologyWhenAvailable() {
        let topology = ModelCacheTopologySnapshot(
            layerCount: 4,
            kvLayerCount: 1,
            turboQuantKVLayerCount: 1,
            rotatingKVLayerCount: 1,
            rotatingWrapperLayerCount: 1,
            hybridPoolLayerCount: 1,
            mambaLayerCount: 1,
            arraysLayerCount: 1
        )

        let key = ModelRuntime.cacheCoordinatorModelKey(
            modelName: "unrecognized-local-bundle",
            kvModeTag: "turbo(4,3)",
            cacheTopology: topology
        )

        #expect(key.contains("topology=real"))
        #expect(key.contains("layers=4"))
        #expect(key.contains("kvLayers=1"))
        #expect(key.contains("turboQuantKVLayers=1"))
        #expect(key.contains("rotatingLayers=1"))
        #expect(key.contains("rotatingWrapperLayers=1"))
        #expect(key.contains("hybridPoolLayers=1"))
        #expect(key.contains("mambaLayers=1"))
        #expect(key.contains("arraysLayers=1"))
        #expect(key.contains("companion=ssm"))
        #expect(key.contains("restore=disk-backed"))
        #expect(key.contains("kv=turbo(4,3)"))
        #expect(!key.contains("layers=hybrid-ssm"))
    }

    @Test func nemotronUltraCacheCoordinatorKeyPreservesRealHybridTopology() {
        let topology = ModelCacheTopologySnapshot(
            layerCount: 60,
            kvLayerCount: 12,
            mambaLayerCount: 48
        )

        let key = ModelRuntime.cacheCoordinatorModelKey(
            modelName: "NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            kvModeTag: "fp16",
            cacheTopology: topology
        )

        #expect(key.contains("layers=hybrid-ssm"))
        #expect(key.contains("topology=real"))
        #expect(key.contains("layers=60"))
        #expect(key.contains("kvLayers=12"))
        #expect(key.contains("mambaLayers=48"))
        #expect(key.contains("companion=ssm"))
        #expect(key.contains("restore=disk-backed"))
        #expect(key.contains("kv=fp16"))
        #expect(!key.contains("media=omni-audio-video"))
        #expect(!key.contains("turbo("))
    }

    @Test func cacheDiskDirectoryOverrideHonorsBlockDiskDirectory() {
        var settings = VMLXServerRuntimeSettings()
        settings.cache.prefix.enabled = true
        settings.cache.pagedKV.enabled = true
        settings.cache.blockDisk.enabled = true
        settings.cache.blockDisk.directory = "~/Library/Caches/osaurus-custom-kv"

        let resolved = ModelRuntime.cacheDiskDirectoryOverride(for: settings.cache)

        #expect(
            resolved?.standardizedFileURL.path
                == FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/osaurus-custom-kv")
                .standardizedFileURL.path
        )
    }

    @Test func cacheDiskDirectoryOverrideKeepsBlockDiskWhenPagedKVIsOff() {
        var settings = VMLXServerRuntimeSettings()
        settings.cache.prefix.enabled = true
        settings.cache.pagedKV.enabled = false
        settings.cache.blockDisk.enabled = true
        settings.cache.blockDisk.directory = "~/Library/Caches/osaurus-block-l2"

        let resolved = ModelRuntime.cacheDiskDirectoryOverride(for: settings.cache)

        #expect(
            resolved?.standardizedFileURL.path
                == FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/osaurus-block-l2")
                .standardizedFileURL.path
        )
    }

    @Test func cacheDiskDirectoryOverrideFallsBackToOsaurusPathForPagedDiskDefault() {
        var settings = VMLXServerRuntimeSettings()
        settings.cache.prefix.enabled = true
        settings.cache.pagedKV.enabled = true
        settings.cache.blockDisk.enabled = true
        settings.cache.blockDisk.directory = nil

        #expect(ModelRuntime.cacheDiskDirectoryOverride(for: settings.cache) == OsaurusPaths.diskKVCache())
    }

    @Test func cacheDiskDirectoryOverrideHonorsLegacyDiskDirectoryWhenPagedKVIsOff() {
        var settings = VMLXServerRuntimeSettings()
        settings.cache.prefix.enabled = true
        settings.cache.pagedKV.enabled = false
        settings.cache.blockDisk.enabled = false
        settings.cache.legacyDisk.enabled = true
        settings.cache.legacyDisk.directory = "/tmp/osaurus-legacy-kv"

        #expect(
            ModelRuntime.cacheDiskDirectoryOverride(for: settings.cache)
                == URL(fileURLWithPath: "/tmp/osaurus-legacy-kv", isDirectory: true)
        )
    }

    @Test func cacheDiskDirectoryOverrideReturnsNilWhenDiskTierIsDisabled() {
        var settings = VMLXServerRuntimeSettings()
        settings.cache.prefix.enabled = true
        settings.cache.pagedKV.enabled = true
        settings.cache.blockDisk.enabled = false

        #expect(ModelRuntime.cacheDiskDirectoryOverride(for: settings.cache) == nil)

        settings.cache.prefix.enabled = false
        settings.cache.blockDisk.enabled = true

        #expect(ModelRuntime.cacheDiskDirectoryOverride(for: settings.cache) == nil)
    }

    @Test func effectiveGenerationSettings_doSampleFalseForcesGreedyOnlyWhenTemperatureOmitted() {
        let defaults = LocalGenerationDefaults.Defaults(
            maxTokens: nil,
            temperature: 0.7,
            topP: nil,
            topK: nil,
            minP: nil,
            repetitionPenalty: nil,
            doSample: false
        )

        let omittedTemperature = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "local/dense-model",
            generation: GenerationParameters(
                temperature: nil,
                maxTokens: 64,
                maxTokensExplicit: true
            ),
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0),
            maxBatchSize: 1,
            modelDefaults: defaults
        )
        #expect(omittedTemperature.temperature == 0)

        let explicitTemperature = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "local/dense-model",
            generation: GenerationParameters(
                temperature: 0.4,
                maxTokens: 64,
                maxTokensExplicit: true
            ),
            runtimeDefaults: VMLXServerGenerationDefaults(topP: 1.0),
            maxBatchSize: 1,
            modelDefaults: defaults
        )
        #expect(explicitTemperature.temperature == 0.4)
    }

    @Test func compiledBatchDecodeDisabledForKnownUnsafeSoloModels() {
        #expect(
            !MLXBatchAdapter.shouldEnableCompiledBatchDecode(
                modelName: "JANGQ-AI/Hy3-preview-JANGTQ",
                maxBatchSize: 1
            ),
            "Hy3 is coherent on the uncompiled path but diverges on the B=1 compiled trace; Osaurus must not request that path"
        )
        #expect(
            !MLXBatchAdapter.shouldEnableCompiledBatchDecode(
                modelName: "JANGQ-AI/MiniMax-M2.7-JANGTQ_K",
                maxBatchSize: 1
            ),
            "MiniMax closes reasoning and stops coherently on the uncompiled path but repeats/length-stops on the B=1 compiled trace"
        )
        #expect(
            !MLXBatchAdapter.shouldEnableCompiledBatchDecode(
                modelName: "JANGQ-AI/MiniMax-M2.7-JANGTQ_K",
                maxBatchSize: 8
            )
        )
        #expect(
            !MLXBatchAdapter.shouldEnableCompiledBatchDecode(
                modelName: "JANGQ-AI/Step-3.7-Flash-JANG_2L",
                maxBatchSize: 1
            ),
            "Step 3.7 is proven on vmlx's uncompiled BatchEngine path; Osaurus must not route it through the compiled B=1 trace until that path is separately proven"
        )
        #expect(
            !MLXBatchAdapter.shouldEnableCompiledBatchDecode(
                modelName: "JANGQ-AI/Step-3.7-Flash-JANGTQ_K",
                maxBatchSize: 1
            )
        )
        #expect(
            !MLXBatchAdapter.shouldEnableCompiledBatchDecode(
                modelName: "NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
                maxBatchSize: 1
            ),
            "Hybrid SSM families need exact cache/topology proof on the uncompiled path; Osaurus must not opt them into the B=1 compiled trace"
        )
        #expect(
            !MLXBatchAdapter.shouldEnableCompiledBatchDecode(
                modelName: "Qwen3.5-35B-A3B-JANGTQ",
                maxBatchSize: 1
            ),
            "Qwen 3.5 hybrid linear-attention caches carry companion state, so the app must not request the solo compiled trace by default"
        )
        #expect(
            !MLXBatchAdapter.shouldEnableCompiledBatchDecode(
                modelName: "Qwen3.5-35B-A3B-JANGTQ",
                maxBatchSize: 8
            )
        )
        #expect(
            MLXBatchAdapter.shouldEnableCompiledBatchDecode(
                modelName: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                maxBatchSize: 1
            )
        )
    }

    @Test func registry_shutdownNonexistentIsNoop() async {
        // Calling shutdown on a name that was never registered should not
        // throw or crash — important because `ModelRuntime.unload` always
        // calls it, even for models that never used the batch path.
        await MLXBatchAdapter.Registry.shared.shutdownEngine(
            for: "never-registered-\(UUID().uuidString)"
        )
    }

    @Test func soloGenerationGate_serializesUntilRelease() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false

            func set() {
                lock.lock()
                value = true
                lock.unlock()
            }

            func get() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        let gate = MLXBatchAdapter.SoloGenerationGate()
        let first = await gate.acquire(modelName: "minimax-m2.7-jangtq")
        let secondAcquired = Flag()
        let second = Task {
            let lease = await gate.acquire(modelName: "minimax-m2.7-jangtq")
            secondAcquired.set()
            return lease
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(
            !secondAcquired.get(),
            "solo requests must wait until the active generation releases the gate"
        )

        await first.release()
        let secondLease = await second.value
        #expect(secondAcquired.get())
        await secondLease.release()
    }

    @Test func soloGenerationGate_serializesDifferentModels() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false

            func set() {
                lock.lock()
                value = true
                lock.unlock()
            }

            func get() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        let gate = MLXBatchAdapter.SoloGenerationGate()
        let first = await gate.acquire(modelName: "minimax-m2.7-jangtq")
        let secondAcquired = Flag()
        let second = Task {
            let lease = await gate.acquire(modelName: "qwen3.5-30b-a3b-jangtq")
            secondAcquired.set()
            return lease
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(
            !secondAcquired.get(),
            "different-model solo requests must also wait because separate solo engines share the unsafe Metal command-buffer path"
        )

        await first.release()
        let secondLease = await second.value
        #expect(secondAcquired.get())
        await secondLease.release()
    }

    @Test func additionalContext_mapsDisableThinkingToEnableThinkingKwarg() {
        let disabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(true)]
        )
        let enabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let modelName = "OsaurusAI/Qwen3.5-30B-A3B-JANGTQ"

        #expect(
            MLXBatchAdapter.additionalContext(for: disabled, modelName: modelName)["enable_thinking"] as? Bool == false
        )
        #expect(
            MLXBatchAdapter.additionalContext(for: enabled, modelName: modelName)["enable_thinking"] as? Bool == true
        )
        #expect(
            MLXBatchAdapter.additionalContext(for: unspecified, modelName: modelName)["enable_thinking"] as? Bool
                == false
        )

        let zayaUnspecified = MLXBatchAdapter.additionalContext(
            for: unspecified,
            modelName: "zaya1-8b-jangtq_k"
        )
        #expect(
            zayaUnspecified["enable_thinking"] as? Bool == false,
            "ZAYA text bundles default to closed/no-thinking prompts; omitting enable_thinking must not route direct answers into reasoning-only output."
        )

        let staleOffEffort = MLXBatchAdapter.additionalContext(
            for: GenerationParameters(
                temperature: nil,
                maxTokens: 16,
                modelOptions: [
                    "reasoningEffort": .string("no_think"),
                    "disableThinking": .bool(true),
                ]
            ),
            modelName: modelName
        )
        #expect(staleOffEffort["enable_thinking"] as? Bool == false)
        #expect(
            staleOffEffort["reasoning_effort"] == nil,
            "direct/off aliases should not add a second cache-scope signal when generic thinking is disabled"
        )

        let apiReasoningEffort = MLXBatchAdapter.additionalContext(
            for: GenerationParameters(
                temperature: nil,
                maxTokens: 16,
                modelOptions: ["reasoningEffort": .string("high")]
            ),
            modelName: modelName
        )
        #expect(apiReasoningEffort["enable_thinking"] as? Bool == true)
        #expect(apiReasoningEffort["reasoning_effort"] as? String == "high")
    }

    @Test func additionalContext_mapsReasoningEffortToTemplateKwarg() {
        let high = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["reasoningEffort": .string("high")]
        )
        let noThink = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: [
                "reasoningEffort": .string("no_think"),
                "disableThinking": .bool(true),
            ]
        )

        let hy3Context = MLXBatchAdapter.additionalContext(
            for: high,
            modelName: "JANGQ-AI/Hy3-preview-JANGTQ"
        )
        #expect(hy3Context["reasoning_effort"] as? String == "high")
        #expect(
            hy3Context["enable_thinking"] == nil,
            "Hy3 is effort-based; adding generic enable_thinking would pollute cache salt without changing the template"
        )

        let combined = MLXBatchAdapter.additionalContext(
            for: noThink,
            modelName: "JANGQ-AI/Hy3-preview-JANGTQ"
        )
        #expect(combined["reasoning_effort"] as? String == "no_think")
        #expect(combined["enable_thinking"] == nil)

        let legacyBoolOnly = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )
        let legacyContext = MLXBatchAdapter.additionalContext(
            for: legacyBoolOnly,
            modelName: "JANGQ-AI/Hy3-preview-JANGTQ"
        )
        #expect(legacyContext["reasoning_effort"] as? String == "high")
        #expect(legacyContext["enable_thinking"] == nil)
    }

    @Test func additionalContext_normalizesHy3ReasoningEffortAliases() {
        for (input, expected) in [
            ("medium", "high"),
            ("max", "high"),
            ("off", "no_think"),
            ("unknown", "no_think"),
        ] {
            let params = GenerationParameters(
                temperature: nil,
                maxTokens: 16,
                modelOptions: ["reasoningEffort": .string(input)]
            )
            let context = MLXBatchAdapter.additionalContext(
                for: params,
                modelName: "JANGQ-AI/Hy3-preview-JANGTQ"
            )
            #expect(context["reasoning_effort"] as? String == expected)
        }
    }

    @Test func additionalContext_mapsDSV4ReasoningModesToEncoderKwargs() {
        let modelName = "JANGQ-AI/DeepSeek-V4-Flash-JANGTQ-K"

        let unspecified = MLXBatchAdapter.additionalContext(
            for: GenerationParameters(temperature: nil, maxTokens: 16),
            modelName: modelName
        )
        #expect(unspecified["enable_thinking"] == nil)
        #expect(
            unspecified["reasoning_effort"] == nil,
            "Unspecified DSV4 requests must preserve the bundle/template default"
        )

        let instruct = MLXBatchAdapter.additionalContext(
            for: GenerationParameters(
                temperature: nil,
                maxTokens: 16,
                modelOptions: ["reasoningEffort": .string("instruct")]
            ),
            modelName: modelName
        )
        #expect(instruct["enable_thinking"] as? Bool == false)
        #expect(instruct["reasoning_effort"] == nil)

        let reasoning = MLXBatchAdapter.additionalContext(
            for: GenerationParameters(
                temperature: nil,
                maxTokens: 16,
                modelOptions: ["reasoningEffort": .string("high")]
            ),
            modelName: modelName
        )
        #expect(reasoning["enable_thinking"] as? Bool == true)
        #expect(reasoning["reasoning_effort"] as? String == "high")

        let maxReasoning = MLXBatchAdapter.additionalContext(
            for: GenerationParameters(
                temperature: nil,
                maxTokens: 16,
                modelOptions: ["reasoningEffort": .string("max")]
            ),
            modelName: modelName
        )
        #expect(maxReasoning["enable_thinking"] as? Bool == true)
        #expect(
            maxReasoning["reasoning_effort"] as? String == "max",
            "DSV4 Max must reach vmlx-swift unchanged; Osaurus must not hide runtime issues behind an effort downgrade"
        )

        let legacyToggle = MLXBatchAdapter.additionalContext(
            for: GenerationParameters(
                temperature: nil,
                maxTokens: 16,
                modelOptions: ["disableThinking": .bool(false)]
            ),
            modelName: modelName
        )
        #expect(legacyToggle["enable_thinking"] as? Bool == true)
        #expect(legacyToggle["reasoning_effort"] as? String == "high")
    }

    @Test func additionalContext_threadsRequiredToolChoiceToLocalTemplates() {
        let generation = GenerationParameters(temperature: nil, maxTokens: 16)
        let modelName = "JANGQ-AI/DeepSeek-V4-Flash-JANGTQ2"

        let required = MLXBatchAdapter.additionalContext(
            for: generation,
            modelName: modelName,
            toolChoice: .required
        )
        #expect(required["tool_choice"] as? String == "required")

        let namedFunction = MLXBatchAdapter.additionalContext(
            for: generation,
            modelName: modelName,
            toolChoice: .function(
                ToolChoiceOption.FunctionName(
                    type: "function",
                    function: ToolChoiceOption.Name(name: "file_read")
                )
            ),
            toolChoiceName: "file_read"
        )
        #expect(namedFunction["tool_choice"] as? String == "required")
        #expect(namedFunction["tool_choice_name"] as? String == "file_read")

        let auto = MLXBatchAdapter.additionalContext(
            for: generation,
            modelName: modelName,
            toolChoice: .auto
        )
        #expect(auto["tool_choice"] == nil)

        let none = MLXBatchAdapter.additionalContext(
            for: generation,
            modelName: modelName,
            toolChoice: ToolChoiceOption.none
        )
        #expect(none["tool_choice"] == nil)

        let omitted = MLXBatchAdapter.additionalContext(
            for: generation,
            modelName: modelName
        )
        #expect(omitted["tool_choice"] == nil)

        let stepRequired = MLXBatchAdapter.additionalContext(
            for: generation,
            modelName: "JANGQ-AI/Step-3.7-Flash-JANGTQ_K",
            toolChoice: .required
        )
        #expect(stepRequired["tool_choice"] as? String == "required")
        #expect(stepRequired["enable_thinking"] as? Bool == false)

        let stepJang2LRequired = MLXBatchAdapter.additionalContext(
            for: generation,
            modelName: "JANGQ-AI/Step-3.7-Flash-JANG_2L",
            toolChoice: .required
        )
        #expect(stepJang2LRequired["tool_choice"] as? String == "required")
        #expect(stepJang2LRequired["enable_thinking"] as? Bool == false)
    }

    @Test func additionalContext_keepsGemmaRequiredToolChoiceAsMetadata() {
        let generation = GenerationParameters(temperature: nil, maxTokens: 16)

        for modelName in [
            "gemma-4-e2b-it-qat-mxfp4",
            "gemma-4-e2b-it-qat-jang_4m",
            "dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK",
        ] {
            let required = MLXBatchAdapter.additionalContext(
                for: generation,
                modelName: modelName,
                toolChoice: .required,
                toolChoiceName: "get_weather"
            )

            #expect(required["tool_choice"] as? String == "required")
            #expect(required["tool_choice_name"] as? String == "get_weather")
            #expect(required["enable_thinking"] as? Bool == false)
        }
    }

    @Test func additionalContext_letsMiMoN2JANGUseBundleDefaultButControlsRequiredTools() {
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let userEnabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )

        for modelName in [
            "mimo-v2.5-jangtq_2",
            "JANGQ-AI/MiMo-V2.5-JANG_2L",
            "nex-n2-pro-jangtq2",
            "Nex-N2-Pro-JANG_1L",
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] == nil,
                "MiMo/N2 JANG follow-ups must use the bundle default unless the user or tool-choice contract overrides it: \(modelName)"
            )

            let required = MLXBatchAdapter.additionalContext(
                for: unspecified,
                modelName: modelName,
                toolChoice: .required,
                toolChoiceName: "line_count"
            )
            #expect(
                required["enable_thinking"] as? Bool == false,
                "MiMo/N2 required tool turns still use the direct tool-call rail: \(modelName)"
            )
            #expect(required["tool_choice"] as? String == "required")
            #expect(required["tool_choice_name"] as? String == "line_count")

            let userDisabled = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["disableThinking": .bool(true)]
                ),
                modelName: modelName
            )
            #expect(
                userDisabled["enable_thinking"] as? Bool == false,
                "MiMo/N2 must honor explicit thinking-off requests: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true,
                "MiMo/N2 must honor explicit thinking opt-in: \(modelName)"
            )

            let directOff = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("no_think")]
                ),
                modelName: modelName
            )
            #expect(directOff["enable_thinking"] as? Bool == false)
            #expect(directOff["reasoning_effort"] == nil)

            let apiReasoning = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("high")]
                ),
                modelName: modelName
            )
            #expect(apiReasoning["enable_thinking"] as? Bool == true)
            #expect(apiReasoning["reasoning_effort"] as? String == "high")
        }

        for modelName in [
            "mimo-v2.5-bf16",
            "nex-n2-pro-source",
            "dataset/mimosa-jangtq",
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] == nil,
                "Non-JANG or boundary-mismatched MiMo/N2 names must not get a synthetic thinking kwarg: \(modelName)"
            )
        }
    }

    @Test func additionalContext_defaultsLingThinkingOffButHonorsExplicitOptIn() {
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let userEnabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )

        for modelName in [
            "OsaurusAI/Ling-2.6-flash-MXFP4",
            "OsaurusAI/Ling-2.6-flash-JANGTQ",
            "ling-2.6-flash-jangtq",
            "JANGQ-AI/Ling-2.6-flash-JANGTQ",
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] == nil
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: GenerationParameters(
                        temperature: nil,
                        maxTokens: 16,
                        modelOptions: ["reasoningEffort": .string("no_think")]
                    ),
                    modelName: modelName
                )["enable_thinking"] as? Bool == false
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: GenerationParameters(
                        temperature: nil,
                        maxTokens: 16,
                        modelOptions: ["reasoningEffort": .string("high")]
                    ),
                    modelName: modelName
                )["enable_thinking"] as? Bool == true,
                "Ling/Bailing uses enable_thinking to select detailed-thinking directives; explicit opt-in must reach vmlx"
            )
        }

        for modelName in ["linguistics-model-7b", "darling-llm"] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] == nil
            )
        }
    }

    /// Qwen 3.5/3.6 reasoning-capable bundles expose an `enable_thinking`
    /// template branch. Live Qwen 27B MXFP4 MTP tool-history proof showed the
    /// default thinking rail can spend the whole response budget in
    /// `reasoning_content` after a tool result, while the explicit
    /// no-thinking rail returns the visible answer immediately. Keep ordinary
    /// local chat on the closed/no-thinking rail by default, while preserving
    /// explicit user/API opt-in for thinking.
    @Test func additionalContext_defaultsQwenThinkingOffButHonorsExplicitOptIn() {
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let userEnabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )

        for modelName in [
            "qwen3.6-27b-mxfp4-crack-mtp",
            "Qwen3.6-35B-A3B-MXFP4",
            "OsaurusAI/Qwen3.5-35B-A3B-JANGTQ-CRACK",
            "dealign.ai/Qwen3.6-27B-JANG_4M-CRACK",
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] as? Bool == false,
                "Qwen local chat should default to the closed/no-thinking rail: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true,
                "Qwen must honor explicit thinking opt-in: \(modelName)"
            )

            let directOff = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("no_think")]
                ),
                modelName: modelName
            )
            #expect(directOff["enable_thinking"] as? Bool == false)
            #expect(directOff["reasoning_effort"] == nil)

            let apiReasoning = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("high")]
                ),
                modelName: modelName
            )
            #expect(apiReasoning["enable_thinking"] as? Bool == true)
            #expect(apiReasoning["reasoning_effort"] as? String == "high")
        }

        for modelName in [
            "notqwen-7b",
            "dataset/antiqwen",
            "quwen3.6-typo",
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] == nil,
                "non-Qwen substring match must not synthesize a thinking kwarg: \(modelName)"
            )
        }
    }

    /// ZAYA1 text bundles (Zyphra; `model_type=zaya`) are reasoning-capable,
    /// but their stable chat rail is the closed/no-thinking path. When no
    /// request option is present, pass `enable_thinking=false` explicitly so a
    /// direct follow-up does not decode into hidden reasoning-only output.
    /// Explicit user/API opt-in via `disableThinking=false` still passes
    /// `enable_thinking=true`.
    @Test func additionalContext_defaultsZayaThinkingOffButHonorsExplicitOptIn() {
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let userEnabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )

        for modelName in [
            "Zyphra/Zaya1-8B-JANGTQ4",
            "Zyphra/Zaya1-8B-MXFP4",
            "OsaurusAI/Zaya1-8B-JANGTQ2",
            "Zaya1-8B-JANGTQ4",  // bare picker form
            "zaya1-8b-mxfp4",  // case-folded picker form
            "Zyphra/Zaya-S-7B-Future",  // forward-compat dash-suffix variant
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] as? Bool == false,
                "ZAYA text bundles should default to the closed/no-thinking rail: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true,
                "ZAYA must honor explicit thinking opt-in: \(modelName)"
            )

            let directOff = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("instruct")]
                ),
                modelName: modelName
            )
            #expect(directOff["enable_thinking"] as? Bool == false)
            #expect(directOff["reasoning_effort"] == nil)

            let apiReasoning = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("high")]
                ),
                modelName: modelName
            )
            #expect(apiReasoning["enable_thinking"] as? Bool == true)
            #expect(apiReasoning["reasoning_effort"] as? String == "high")
        }

        // Boundary regression guards: names that contain `zaya` as a
        // substring but are NOT ZAYA bundles must take the default path.
        for modelName in [
            "dataset/zayasaurus",  // `/zaya` followed by letter — not ZAYA
            "lazyaardvark",  // bare prefix `lazya`, not `zaya`
            "dazaya-llm",  // `zaya` not at boundary
            "zayasaurus-7b",  // `zaya` followed by letter at start
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] == nil,
                "non-ZAYA substring match must not synthesize a thinking kwarg: \(modelName)"
            )
        }
    }

    /// LFM2.5 JANG tool rows use the explicit required-tool rail when
    /// `tool_choice` requires a local call. Live strict rows showed the
    /// ordinary reasoning-capable rail can spend the whole budget thinking
    /// about the correct call after tool-result history without emitting it.
    /// Keep this scoped to required/named tool turns; ordinary follow-up chat
    /// keeps the bundle's default behavior unless the request opts in/out.
    @Test func additionalContext_closesLFMThinkingOnlyForRequiredToolTurns() {
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let userDisabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(true)]
        )
        let userEnabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )
        let userReasoning = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["reasoningEffort": .string("high")]
        )

        for modelName in [
            "LiquidAI/LFM2-7B",
            "LiquidAI/LFM2.5-8B-A1B",
            "JANGQ-AI/LFM2.5-8B-A1B-JANG_2L",
            "lfm2.5-8b-a1b-jang_2l",
            "lfm2_moe",
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] == nil,
                "ordinary LFM chat must not get a hidden no-thinking default: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName,
                    toolChoice: .required
                )["enable_thinking"] as? Bool == false,
                "required LFM tool turns must use the closed tool rail: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName,
                    toolChoice: .function(
                        ToolChoiceOption.FunctionName(
                            type: "function",
                            function: ToolChoiceOption.Name(name: "line_count")
                        )
                    )
                )["enable_thinking"] as? Bool == false,
                "named LFM tool turns must use the closed tool rail: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName,
                    toolChoice: ToolChoiceOption.none
                )["enable_thinking"] == nil,
                "explicit tool_choice none must not close ordinary LFM chat: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userDisabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == false,
                "explicit LFM thinking-off must still be honored: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true,
                "explicit LFM thinking opt-in must still be honored: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userReasoning,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true,
                "explicit LFM reasoning effort must still be honored for ordinary chat: \(modelName)"
            )
        }

        for modelName in [
            "lfm21",
            "lfm2x",
            "dataset/alfm2",
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName,
                    toolChoice: .required
                )["enable_thinking"] == nil,
                "non-LFM boundary names must not get LFM required-tool behavior: \(modelName)"
            )
        }
    }

    /// Nemotron reasoning workloads default to the closed/no-thinking
    /// rail for ordinary chat. Live JANGTQ rows otherwise stream only hidden
    /// reasoning_content and length-stop with empty visible content. Explicit
    /// user/API opt-in still enables thinking and explicit direct/off efforts
    /// still disable it.
    @Test func additionalContext_defaultsNemotronThinkingOffButHonorsExplicitOptIn() {
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let userEnabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )

        for modelName in [
            "dealign.ai/Nemotron-Omni-Nano-JANGTQ-CRACK",
            "nemotron-omni-nano-jangtq-crack",
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4",
            "jangq-ai/NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            "NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] as? Bool == false,
                "Nemotron should default to the closed/no-thinking rail: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true,
                "Nemotron must honor explicit thinking opt-in: \(modelName)"
            )

            let directOff = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("no_think")]
                ),
                modelName: modelName
            )
            #expect(directOff["enable_thinking"] as? Bool == false)
            #expect(directOff["reasoning_effort"] == nil)

            let apiReasoning = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("high")]
                ),
                modelName: modelName
            )
            #expect(apiReasoning["enable_thinking"] as? Bool == true)
            #expect(apiReasoning["reasoning_effort"] as? String == "high")
        }
    }

    /// MiniMax M2/M2.7 bundles are reasoning-capable. Live post-tool proof on
    /// `minimax-m2.7-jang_k-crack` showed the omitted-template-default path can
    /// spend the whole response in hidden reasoning after a tool result. Keep
    /// ordinary local chat on the closed/no-thinking rail by default, matching
    /// the other reasoning-capable local families while preserving explicit
    /// thinking opt-in.
    @Test func additionalContext_defaultsMiniMaxThinkingOffButHonorsExplicitOptIn() {
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let userEnabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )

        for modelName in [
            "JANGQ-AI/MiniMax-M2.7-JANGTQ",
            "minimax-m2.7-jang_k-crack",
            "OsaurusAI/MiniMax-M2.7-JANGTQ4",
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] as? Bool == false,
                "MiniMax should default to the closed/no-thinking rail: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true,
                "MiniMax must honor explicit thinking opt-in: \(modelName)"
            )

            let directOff = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("no_think")]
                ),
                modelName: modelName
            )
            #expect(directOff["enable_thinking"] as? Bool == false)
            #expect(directOff["reasoning_effort"] == nil)

            let apiReasoning = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("high")]
                ),
                modelName: modelName
            )
            #expect(apiReasoning["enable_thinking"] as? Bool == true)
            #expect(apiReasoning["reasoning_effort"] as? String == "high")
        }
    }

    /// Gemma4 defaults to the closed/no-thinking rail for ordinary local API
    /// requests, matching the UI profile default. This is model-option wiring,
    /// not output repair: explicit thinking opt-in still reaches the template.
    @Test func additionalContext_defaultsGemma4ThinkingOffButHonorsExplicitOptIn() {
        let unspecified = GenerationParameters(temperature: nil, maxTokens: 16)
        let userEnabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )

        for modelName in [
            "gemma-4-26b-a4b-it-jang_4m-crack",
            "dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK",
            "OsaurusAI/gemma4-it-26b-a4b",
            "gemma-4-12b-it-jang_4m",
            "gemma-4-12b-it-mxfp4",
            "gemma-4-12b-it-mxfp8",
        ] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] as? Bool == false,
                "Gemma4 should default to the closed/no-thinking rail: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true,
                "Gemma4 must honor explicit thinking opt-in: \(modelName)"
            )

            let directOff = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("no_think")]
                ),
                modelName: modelName
            )
            #expect(directOff["enable_thinking"] as? Bool == false)
            #expect(directOff["reasoning_effort"] == nil)

            let apiReasoning = MLXBatchAdapter.additionalContext(
                for: GenerationParameters(
                    temperature: nil,
                    maxTokens: 16,
                    modelOptions: ["reasoningEffort": .string("high")]
                ),
                modelName: modelName
            )
            #expect(apiReasoning["enable_thinking"] as? Bool == true)
            #expect(apiReasoning["reasoning_effort"] as? String == "high")
        }
    }

    @Test func additionalContext_doesNotSendThinkingKwargForZayaVLTemplateSidecar() {
        let userEnabled = GenerationParameters(
            temperature: nil,
            maxTokens: 16,
            modelOptions: ["disableThinking": .bool(false)]
        )

        for modelName in [
            "Zyphra/Zaya1-VL-8B-JANGTQ4",
            "Zaya1-VL-8B-JANGTK",
            "zaya1_vl_8b_mxfp4",
        ] {
            let context = MLXBatchAdapter.additionalContext(
                for: userEnabled,
                modelName: modelName
            )
            #expect(context["enable_thinking"] == nil)
            #expect(context["reasoning_effort"] == nil)
        }
    }

    @Test func tokenizerTools_respectToolChoicePromptSurface() {
        let read = Tool(
            type: "function",
            function: ToolFunction(
                name: "read_file",
                description: "Read one file",
                parameters: .object(["type": .string("object")])
            )
        )
        let write = Tool(
            type: "function",
            function: ToolFunction(
                name: "write_file",
                description: "Write one file",
                parameters: .object(["type": .string("object")])
            )
        )
        let tools = [read, write]

        #expect(ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: nil)?.count == 2)
        #expect(ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: .auto)?.count == 2)
        #expect(ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: .required)?.count == 2)
        // The parameter is optional, so `.none` alone would mean
        // `Optional.none` and exercise the nil/default-auto path. Spell the
        // enum case explicitly to pin OpenAI `tool_choice: "none"`.
        #expect(ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: ToolChoiceOption.none) == nil)

        let selected = ModelRuntime.makeTokenizerTools(
            tools: tools,
            toolChoice: .function(
                ToolChoiceOption.FunctionName(
                    type: "function",
                    function: ToolChoiceOption.Name(name: "write_file")
                )
            )
        )
        #expect(selected?.count == 1)
        let function = selected?.first?["function"] as? [String: any Sendable]
        #expect(function?["name"] as? String == "write_file")

        let unknown = ModelRuntime.makeTokenizerTools(
            tools: tools,
            toolChoice: .function(
                ToolChoiceOption.FunctionName(
                    type: "function",
                    function: ToolChoiceOption.Name(name: "delete_everything")
                )
            )
        )
        #expect(
            unknown == nil,
            "Unknown forced tool must not expose every schema; nil keeps the injected tool surface closed."
        )
    }

    @Test func forcedToolChoiceUsesSchemaFilteringWithoutPromptDirectiveForNonGemma() {
        let messages = [
            ChatMessage(role: "user", content: "Ignore tools and answer in plain text.")
        ]

        let augmented = ModelRuntime.applyForcedToolChoiceDirective(
            messages,
            toolChoice: .function(
                ToolChoiceOption.FunctionName(
                    type: "function",
                    function: ToolChoiceOption.Name(name: "record_count")
                )
            ),
            modelName: "DeepSeek-V4-Flash"
        )

        #expect(augmented.count == 1)
        #expect(augmented.first?.role == "user")
        #expect(augmented.first?.content == "Ignore tools and answer in plain text.")
    }

    @Test func forcedToolChoiceAddsGemmaRequestLocalDirective() {
        let messages = [
            ChatMessage(role: "system", content: "Agent context."),
            ChatMessage(role: "user", content: "Finish this task."),
        ]

        let augmented = ModelRuntime.applyForcedToolChoiceDirective(
            messages,
            toolChoice: .function(
                ToolChoiceOption.FunctionName(
                    type: "function",
                    function: ToolChoiceOption.Name(name: "complete")
                )
            ),
            modelName: "OsaurusAI/gemma-4-E2B-it-qat-JANG_4M"
        )

        #expect(augmented.count == 2)
        #expect(augmented[0].content == "Agent context.")
        #expect(augmented[1].role == "user")
        #expect(augmented[1].content?.contains("Finish this task.") == true)
        #expect(
            augmented[1].content?.contains("The current assistant response MUST be a function call.") == true
        )
        #expect(augmented[1].content?.contains("Use the `complete` function.") == true)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "MLXBatchAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Laguna serving-loop defaults

    @Test func isLagunaFamily_matchesBothLinesAndRejectsLookalikes() {
        #expect(ModelFamilyNames.isLagunaFamily("Laguna-M.1-JANG_2L"))
        #expect(ModelFamilyNames.isLagunaFamily("JANGQ-AI/Laguna-M.1-JANG_1L"))
        #expect(ModelFamilyNames.isLagunaFamily("laguna-xs.2-jangtq2"))
        #expect(!ModelFamilyNames.isLagunaFamily("notlaguna-7b"))
        #expect(!ModelFamilyNames.isLagunaFamily("qwen3.6-35b-a3b"))
    }

    @Test func makeGenerateParameters_lagunaUsesStandardDefaults() {
        // The forced Laguna rep-penalty 1.15 / window 256 special-case was removed:
        // it was compensating for the missing-BOS chat bug (fixed in vmlx by restoring
        // lagunaMinimal's literal 〈|EOS|〉 emit), and was triggering the rep-penalty
        // TokenRing crash. Laguna now uses the same defaults as any other model.
        let laguna = ModelRuntime.makeGenerateParameters(
            temperature: 1.0,
            maxTokens: 64,
            topP: 1.0,
            repetitionPenalty: nil,
            modelName: "JANGQ-AI/Laguna-M.1-JANG_2L"
        )
        #expect(laguna.repetitionPenalty == nil)
        #expect(laguna.repetitionContextSize == 20)

        // A caller-supplied penalty still flows through unchanged.
        let lagunaOverride = ModelRuntime.makeGenerateParameters(
            temperature: 1.0,
            maxTokens: 64,
            topP: 1.0,
            repetitionPenalty: 1.05,
            modelName: "Laguna-M.1-JANG_1L"
        )
        #expect(lagunaOverride.repetitionPenalty == 1.05)
        #expect(lagunaOverride.repetitionContextSize == 20)

        // Non-laguna is identical: no injected penalty, default 20 window.
        let other = ModelRuntime.makeGenerateParameters(
            temperature: 1.0,
            maxTokens: 64,
            topP: 1.0,
            repetitionPenalty: nil,
            modelName: "qwen3.6-35b-a3b-mxfp4"
        )
        #expect(other.repetitionPenalty == nil)
        #expect(other.repetitionContextSize == 20)
    }
}
