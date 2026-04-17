//
//  BatchEngineAdapterTests.swift
//  osaurus
//
//  Coverage for the parts of `BatchEngineAdapter` that don't require a
//  loaded MLX model. Engine submission/streaming itself is covered by the
//  upstream `BatchEngineTests` in vmlx-swift-lm — duplicating those would
//  drag in a 1+ GB model download per run, which we keep out of CI.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct BatchEngineAdapterTests {

    @Test func batchEngineEnabledFlag_defaultIsOff() {
        // Off by default — preserves prior behaviour for users who haven't
        // explicitly opted in via `defaults write`.
        UserDefaults.standard.removeObject(forKey: "ai.osaurus.scheduler.mlxBatchEngine")
        #expect(!InferenceFeatureFlags.mlxBatchEngineEnabled)
        #expect(!BatchEnginePlan.isActive)
    }

    @Test func batchEngineEnabledFlag_respectsUserDefaults() {
        let key = "ai.osaurus.scheduler.mlxBatchEngine"
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(InferenceFeatureFlags.mlxBatchEngineEnabled)
        #expect(BatchEnginePlan.isActive)
    }

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
        await BatchEngineAdapter.Registry.shared.shutdownEngine(
            for: "never-registered-\(UUID().uuidString)"
        )
    }

    @Test func planExposesOpenBlockers() {
        // Sanity-check the documentation-level surface: if these change
        // (upstream lands KV-quant batching, etc.) we want the test to
        // remind us to update the doc + flag default.
        let blockers = BatchEnginePlan.openBlockers
        #expect(blockers.contains(.kvQuantization))
        #expect(blockers.contains(.compileSupport))
    }
}
