//
//  ModelManagerResolveTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelManagerResolveTests {

    @Test @MainActor func resolveModel_basicHeuristicsAndAllowList() async throws {
        let mgr = ModelManager()

        // Should return nil for empty
        #expect(mgr.resolveModel(byRepoId: "") == nil)

        // Heuristic requires MLX hints AND allow list membership
        // Use curated id from ModelManager.curatedSuggestedModels which is in the allow list via SDK
        let allowedId = "mlx-community/Qwen3-1.7B-4bit"
        let m1 = mgr.resolveModel(byRepoId: allowedId)
        #expect(m1 != nil)
        #expect(mgr.availableModels.contains(where: { $0.id == allowedId }))

        // Non-MLX id should be rejected
        #expect(mgr.resolveModel(byRepoId: "someorg/SomeModel") == nil)
    }

    @Test @MainActor func resolveModelIfMLXCompatible_insertsWhenCompatible() async throws {
        let mgr = ModelManager()

        // Known curated id that should pass allow-list and compatibility
        let allowedId = "mlx-community/Qwen3-4B-4bit"
        let m1 = await mgr.resolveModelIfMLXCompatible(byRepoId: allowedId)
        #expect(m1 != nil)
        #expect(mgr.availableModels.contains(where: { $0.id == allowedId }))

        // Unknown id fails allow-list quickly
        let denied = await mgr.resolveModelIfMLXCompatible(byRepoId: "unknown/NotMLX")
        #expect(denied == nil)
    }
}
