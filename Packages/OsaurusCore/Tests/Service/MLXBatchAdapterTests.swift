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

    @Test func maxBatchSize_defaultsToFour() {
        UserDefaults.standard.removeObject(forKey: "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize")
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize == 4)
    }

    @Test func maxBatchSize_respectsUserDefaults() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        UserDefaults.standard.set(8, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize == 8)
    }

    @Test func maxBatchSize_clampsAbsurdValues() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        UserDefaults.standard.set(9999, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        // Clamp to 32 so a typo doesn't blow out wired memory.
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize == 32)
    }

    @Test func maxBatchSize_zeroFallsBackToDefault() {
        let key = "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        UserDefaults.standard.set(0, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize == 4)
    }

    @Test func registry_shutdownNonexistentIsNoop() async {
        // Calling shutdown on a name that was never registered should not
        // throw or crash — important because `ModelRuntime.unload` always
        // calls it, even for models that never used the batch path.
        await MLXBatchAdapter.Registry.shared.shutdownEngine(
            for: "never-registered-\(UUID().uuidString)"
        )
    }
}
