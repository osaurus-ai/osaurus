//
//  NativeMTPWarmupFlagTests.swift
//  osaurusTests
//
//  Covers the registry warm-flag lifecycle the load-time MTP warmup relies
//  on: a successful warmup generation leaves the model warm (so the first
//  real request keeps MTP), and a failed warmup resets the flag (so the
//  request path's AR cold-warmup rule applies exactly as before).
//

import Foundation
import Testing

@testable import OsaurusCore

struct NativeMTPWarmupFlagTests {

    @Test func consumeMarksModelWarmExactlyOnce() async {
        let registry = MLXBatchAdapter.Registry.shared
        let model = "warmup-flag-test-\(UUID().uuidString)"

        #expect(await !registry.isNativeMTPWarm(modelName: model))
        // First consumption wins the cold warmup (AR generation)…
        #expect(await registry.consumeNativeMTPColdWarmup(modelName: model, requested: true))
        // …every later request sees the model as warm.
        #expect(await !registry.consumeNativeMTPColdWarmup(modelName: model, requested: true))
        #expect(await registry.isNativeMTPWarm(modelName: model))

        await registry.resetNativeMTPWarmup(modelName: model)
    }

    @Test func resetRestoresColdWarmupBehavior() async {
        let registry = MLXBatchAdapter.Registry.shared
        let model = "warmup-reset-test-\(UUID().uuidString)"

        _ = await registry.consumeNativeMTPColdWarmup(modelName: model, requested: true)
        await registry.resetNativeMTPWarmup(modelName: model)

        #expect(await !registry.isNativeMTPWarm(modelName: model))
        // After a reset the next request must win the cold warmup again.
        #expect(await registry.consumeNativeMTPColdWarmup(modelName: model, requested: true))

        await registry.resetNativeMTPWarmup(modelName: model)
    }

    @Test func nonMTPRequestsNeverTouchTheFlag() async {
        let registry = MLXBatchAdapter.Registry.shared
        let model = "warmup-nonmtp-test-\(UUID().uuidString)"

        #expect(await !registry.consumeNativeMTPColdWarmup(modelName: model, requested: false))
        #expect(await !registry.isNativeMTPWarm(modelName: model))
    }
}
