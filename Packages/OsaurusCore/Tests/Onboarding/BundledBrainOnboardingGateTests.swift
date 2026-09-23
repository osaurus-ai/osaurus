//
//  BundledBrainOnboardingGateTests.swift
//  osaurusTests
//
//  The full distribution skips the Configure AI step only when the bundled
//  Raptor 0.6 is genuinely usable. These tests pin the four gates in
//  `ConfigureAIState.bundledLocalBrainReady`: light build, seed not landed,
//  tight RAM, and the ready case — plus the commit that lets
//  `finishOnboarding` pin the model without a download.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct BundledBrainOnboardingGateTests {

    private let raptorBytes: Int64 = 3_677_829_017

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-bundled-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Curated Raptor 0.6 row pinned to a fixture root. `onDisk` writes the
    /// minimal complete bundle (`config.json` + tokenizer + weights sentinel)
    /// that `isDownloaded` requires.
    private func raptor(root: URL, onDisk: Bool, isTopSuggestion: Bool = true) throws -> MLXModel {
        let model = MLXModel(
            id: ConfigureAIState.preferredOnboardingModelId,
            name: "Raptor 0.6 4B",
            description: "",
            downloadURL: "https://huggingface.co/\(ConfigureAIState.preferredOnboardingModelId)",
            isTopSuggestion: isTopSuggestion,
            downloadSizeBytes: raptorBytes,
            rootDirectory: root
        )
        if onDisk {
            let dir = model.localDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
            try Data().write(to: dir.appendingPathComponent("model-00001-of-00001.safetensors"))
        }
        return model
    }

    private func other(root: URL) -> MLXModel {
        MLXModel(
            id: "OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M",
            name: "Raptor v0.5",
            description: "",
            downloadURL: "",
            isTopSuggestion: true,
            downloadSizeBytes: 6_783_354_784,
            rootDirectory: root
        )
    }

    @Test func readyWhenFullBuildSeededAndComfortable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try raptor(root: root, onDisk: true)

        let ready = ConfigureAIState.bundledLocalBrainReady(
            from: [other(root: root), model],
            totalMemoryGB: 64,
            isFullDistribution: true
        )

        #expect(ready?.id == ConfigureAIState.preferredOnboardingModelId)
    }

    @Test func lightBuildNeverSkips() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try raptor(root: root, onDisk: true)

        #expect(
            ConfigureAIState.bundledLocalBrainReady(
                from: [model],
                totalMemoryGB: 64,
                isFullDistribution: false
            ) == nil
        )
    }

    @Test func seedNotLandedFallsBackToConfigureAI() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try raptor(root: root, onDisk: false)

        #expect(
            ConfigureAIState.bundledLocalBrainReady(
                from: [model],
                totalMemoryGB: 64,
                isFullDistribution: true
            ) == nil
        )
    }

    @Test func tightRAMFallsBackToConfigureAI() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try raptor(root: root, onDisk: true)
        // Sanity: a 3.4 GiB bundle is not `.compatible` on a 4 GB budget.
        #expect(model.compatibility(totalMemoryGB: 4) != .compatible)

        #expect(
            ConfigureAIState.bundledLocalBrainReady(
                from: [model],
                totalMemoryGB: 4,
                isFullDistribution: true
            ) == nil
        )
    }

    @Test func nonTopPickOrMissingCatalogEntryFallsBack() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let demoted = try raptor(root: root, onDisk: true, isTopSuggestion: false)

        #expect(
            ConfigureAIState.bundledLocalBrainReady(
                from: [demoted],
                totalMemoryGB: 64,
                isFullDistribution: true
            ) == nil
        )
        #expect(
            ConfigureAIState.bundledLocalBrainReady(
                from: [other(root: root)],
                totalMemoryGB: 64,
                isFullDistribution: true
            ) == nil
        )
    }

    /// Committing the bundled brain must leave the state exactly as the
    /// Configure AI local path would for an on-disk model, so
    /// `finishOnboarding` pins it through `localDefaultModelIdToPin`.
    @Test func commitBundledLocalBrainPinsLocalModel() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try raptor(root: root, onDisk: true)
        let state = ConfigureAIState()
        state.diskSpaceWarning = "stale"

        state.commitBundledLocalBrain(model)

        #expect(state.selectedBrainSource == .local)
        #expect(state.hasCommittedLocal)
        #expect(state.localDefaultModelIdToPin == ConfigureAIState.preferredOnboardingModelId)
        #expect(state.diskSpaceWarning == nil)
        #expect(state.hasStartedLocalDownload == false)
    }
}
