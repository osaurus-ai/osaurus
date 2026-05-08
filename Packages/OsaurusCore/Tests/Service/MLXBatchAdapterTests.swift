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
        UserDefaults.standard.removeObject(forKey: "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize")
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize == 1)
    }

    @Test func maxBatchSize_respectsUserDefaults() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        UserDefaults.standard.set(8, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        // Server deployments override to multi-slot at the cost of the
        // compile path — same value the test pinned before; only the
        // default changed.
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize == 8)
    }

    @Test func maxBatchSize_clampsAbsurdValues() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        UserDefaults.standard.set(9999, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        // Clamp to 32 so a typo doesn't blow out wired memory.
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize == 32)
    }

    @Test func maxBatchSize_zeroFallsBackToDefault_one() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        UserDefaults.standard.set(0, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        // Zero is treated as "unset" — falls back to the compile-friendly
        // default of 1 (was 4 prior to fa694e9e).
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize == 1)
    }

    @Test func registry_shutdownNonexistentIsNoop() async {
        // Calling shutdown on a name that was never registered should not
        // throw or crash — important because `ModelRuntime.unload` always
        // calls it, even for models that never used the batch path.
        await MLXBatchAdapter.Registry.shared.shutdownEngine(
            for: "never-registered-\(UUID().uuidString)"
        )
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
                == true
        )
    }

    @Test func additionalContext_forcesLingThinkingOff() {
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
                )["enable_thinking"] as? Bool == false
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == false
            )
        }

        for modelName in ["linguistics-model-7b", "darling-llm"] {
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: unspecified,
                    modelName: modelName
                )["enable_thinking"] as? Bool == true
            )
        }
    }

    /// ZAYA1 (Zyphra; `model_type=zaya`) is served as non-reasoning per the
    /// 2026-05-06 vmlx Osaurus runtime handoff. Even when a stale persisted
    /// preference says `disableThinking=false`, the host short-circuit must
    /// emit `enable_thinking=false` so the request context does NOT override
    /// vmlx's `LLMUserInputProcessor.defaultContext` clamp (caller-wins
    /// merge). Negative cases lock the matcher boundary so that adjacent
    /// names like `dataset/zayasaurus` or `lazyaardvark` do NOT short-circuit.
    @Test func additionalContext_forcesZayaThinkingOff() {
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
                "ZAYA must default enable_thinking=false: \(modelName)"
            )
            #expect(
                MLXBatchAdapter.additionalContext(
                    for: userEnabled,
                    modelName: modelName
                )["enable_thinking"] as? Bool == false,
                "ZAYA must clamp enable_thinking=false even when host preference enables it: \(modelName)"
            )
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
                )["enable_thinking"] as? Bool == true,
                "non-ZAYA substring match must NOT force thinking off: \(modelName)"
            )
        }
    }
}
