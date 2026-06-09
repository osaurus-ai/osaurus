//
//  ModelManagerTests.swift
//  osaurusTests
//
//  Created by Terence on 8/17/25.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelManagerTests {

    /// Suppress `ModelManager.init`'s background HF org fetch — its async
    /// response can otherwise land mid-test and perturb `suggestedModels`
    /// or trigger Combine emissions while the test is still asserting.
    init() {
        ModelManager.skipBackgroundOrgFetchForTests = true
    }

    @Test func loadAvailableModels_initializesStates() async throws {
        // `ModelManager.init` calls `loadAvailableModels()` synchronously, which
        // populates `availableModels` + `downloadStates` before init returns. No
        // sleep needed; the previous 2s `Task.sleep` predated the sync refactor.
        let manager = await MainActor.run { ModelManager() }

        let isLoading = await MainActor.run { manager.isLoadingModels }
        let models = await MainActor.run { manager.availableModels }
        let states = await MainActor.run { manager.downloadStates }

        #expect(isLoading == false)

        if models.count > 0 {
            for model in models {
                #expect(states[model.id] != nil)
            }
        }
    }

    @Test func cancelDownload_resetsStateWithoutTask() async throws {
        let manager = await MainActor.run { ModelManager() }

        let testModelId = "test-cancel-\(UUID().uuidString)"
        await MainActor.run { manager.downloadService.downloadStates[testModelId] = .downloading(progress: 0.5) }
        await MainActor.run { manager.cancelDownload(testModelId) }
        let state = await MainActor.run { manager.downloadStates[testModelId] }
        #expect(state == .notStarted)

    }

    /// Pausing a synthetic in-flight download (no active URLSession task —
    /// this is the rare "pause between files" path) must transition state
    /// to `.paused(progress)`, freeze the metrics (clear speed/ETA, keep
    /// received/total bytes), and seed `pausedDownloads` so a later
    /// `resume(_:)` call has somewhere to look. Regression for the
    /// onboarding "stuck Continue button" UX (issue #1071).
    @Test func pauseDownload_transitionsToPausedAndFreezesMetrics() async throws {
        let manager = await MainActor.run { ModelManager() }

        let testModelId = "test-pause-\(UUID().uuidString)"
        await MainActor.run {
            manager.downloadService.downloadStates[testModelId] = .downloading(progress: 0.42)
            manager.downloadService.downloadMetrics[testModelId] = ModelDownloadService.DownloadMetrics(
                bytesReceived: 4_200_000,
                totalBytes: 10_000_000,
                bytesPerSecond: 1_500_000,
                etaSeconds: 3.8
            )
        }

        await MainActor.run { manager.pauseDownload(testModelId) }

        let state = await MainActor.run { manager.downloadStates[testModelId] }
        let metrics = await MainActor.run { manager.downloadMetrics[testModelId] }

        #expect(state == .paused(progress: 0.42))
        // bytesReceived / totalBytes survive so the user still sees "X / Y"
        #expect(metrics?.bytesReceived == 4_200_000)
        #expect(metrics?.totalBytes == 10_000_000)
        // speed / ETA are frozen (cleared) so the UI doesn't display stale
        // numbers next to a paused pill.
        #expect(metrics?.bytesPerSecond == nil)
        #expect(metrics?.etaSeconds == nil)
    }

    /// Cancelling a paused download must drop both the state AND the
    /// `pausedDownloads` snapshot so a subsequent `download(_:)` starts
    /// fresh rather than trying to consume a stale resume-data blob.
    @Test func cancelDownload_clearsPausedState() async throws {
        let manager = await MainActor.run { ModelManager() }

        let testModelId = "test-cancel-paused-\(UUID().uuidString)"
        await MainActor.run {
            manager.downloadService.downloadStates[testModelId] = .downloading(progress: 0.3)
        }
        await MainActor.run { manager.pauseDownload(testModelId) }

        let pausedState = await MainActor.run { manager.downloadStates[testModelId] }
        #expect(pausedState == .paused(progress: 0.3))

        await MainActor.run { manager.cancelDownload(testModelId) }
        let finalState = await MainActor.run { manager.downloadStates[testModelId] }
        #expect(finalState == .notStarted)
    }

    @Test func downloadProgress_matchesState() async throws {
        let manager = await MainActor.run { ModelManager() }
        let testModelId = "test-progress-\(UUID().uuidString)"

        await MainActor.run { manager.downloadService.downloadStates[testModelId] = .notStarted }
        var p = await MainActor.run { manager.downloadProgress(for: testModelId) }
        #expect(p == 0.0)

        await MainActor.run { manager.downloadService.downloadStates[testModelId] = .downloading(progress: 0.25) }
        p = await MainActor.run { manager.downloadProgress(for: testModelId) }
        #expect(abs(p - 0.25) < 0.0001)

        // Paused state must report its frozen progress through the same
        // `progress(for:)` accessor — the paused row in Settings reads it.
        await MainActor.run { manager.downloadService.downloadStates[testModelId] = .paused(progress: 0.5) }
        p = await MainActor.run { manager.downloadProgress(for: testModelId) }
        #expect(abs(p - 0.5) < 0.0001)

        await MainActor.run { manager.downloadService.downloadStates[testModelId] = .completed }
        p = await MainActor.run { manager.downloadProgress(for: testModelId) }
        #expect(p == 1.0)

    }

    /// `effectiveState` must surface `.paused` as-is (rather than collapsing
    /// it to the `model.isDownloaded` fork) so the row UI can render the
    /// Resume control instead of the Download button.
    @Test func effectiveDownloadState_preservesPaused() async throws {
        let manager = await MainActor.run { ModelManager() }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-paused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let model = MLXModel(
            id: "paused/test",
            name: "Test Paused",
            description: "",
            downloadURL: "https://example.com/test",
            rootDirectory: tempDir
        )

        await MainActor.run {
            manager.downloadService.downloadStates[model.id] = .paused(progress: 0.6)
        }

        let state = await MainActor.run { manager.effectiveDownloadState(for: model) }
        #expect(state == .paused(progress: 0.6))
    }

    @Test func totalDownloadedSize_nonNegative() async throws {
        let manager = await MainActor.run { ModelManager() }

        let size = await MainActor.run { manager.totalDownloadedSize }
        #expect(size >= 0)

    }

    @Test func scanLocalModels_detectsThreeLevelMultiOrgLayout() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("osu-multi-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Layout the user's drive actually has:
        //   <root>/dealignai/<flatBundle>/{config.json,...}
        //   <root>/jangq-ai/JANGQ-AI/<repo>/{config.json,...}
        //   <root>/jangq-ai/OsaurusAI/<repo>/{config.json,...}
        let dealignai = root.appendingPathComponent("dealignai")
        let jangqai = root.appendingPathComponent("jangq-ai")
        try fm.createDirectory(at: dealignai, withIntermediateDirectories: true)
        try fm.createDirectory(at: jangqai, withIntermediateDirectories: true)

        func makeBundle(_ dir: URL) throws {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
            try Data().write(to: dir.appendingPathComponent("model.safetensors"))
        }

        // 2-level under dealignai (HF-style: <root>/dealignai/<flat>)
        try makeBundle(dealignai.appendingPathComponent("Mistral-Small-4-119B-JANG_6M-CRACK"))
        try makeBundle(dealignai.appendingPathComponent("Qwen3.6-27B-MXFP4-CRACK"))

        // 3-level under jangq-ai (HF-style: <root>/jangq-ai/<org>/<repo>)
        try makeBundle(
            jangqai.appendingPathComponent("JANGQ-AI")
                .appendingPathComponent("Laguna-XS.2-JANGTQ")
        )
        try makeBundle(
            jangqai.appendingPathComponent("OsaurusAI")
                .appendingPathComponent("Mistral-Medium-3.5-128B-mxfp4")
        )

        let detected = ModelManager.scanLocalModels(at: root)
        let ids = Set(detected.map { $0.id })
        #expect(ids.contains("dealignai/Mistral-Small-4-119B-JANG_6M-CRACK"))
        #expect(ids.contains("dealignai/Qwen3.6-27B-MXFP4-CRACK"))
        #expect(ids.contains("jangq-ai/JANGQ-AI/Laguna-XS.2-JANGTQ"))
        #expect(ids.contains("jangq-ai/OsaurusAI/Mistral-Medium-3.5-128B-mxfp4"))
        #expect(detected.count == 4)
    }

    @Test func scanLocalModels_detectsFlatAndNestedLayouts() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("osu-scan-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Flat: <root>/Nemotron-3-Flat/{config.json, tokenizer.json, model.safetensors}
        let flatBundle = root.appendingPathComponent("Nemotron-3-Flat")
        try fm.createDirectory(at: flatBundle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: flatBundle.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: flatBundle.appendingPathComponent("tokenizer.json"))
        try Data().write(to: flatBundle.appendingPathComponent("model.safetensors"))

        // Nested: <root>/JANGQ-AI/Laguna-XS.2/{config.json, tokenizer.json, model.safetensors}
        let nestedRepo = root.appendingPathComponent("JANGQ-AI").appendingPathComponent("Laguna-XS.2")
        try fm.createDirectory(at: nestedRepo, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: nestedRepo.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: nestedRepo.appendingPathComponent("tokenizer.json"))
        try Data().write(to: nestedRepo.appendingPathComponent("model.safetensors"))

        // Empty/garbage entry that should be ignored at both levels
        let junk = root.appendingPathComponent("not-a-model")
        try fm.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: junk.appendingPathComponent("README.md"))

        // BPE tokenizer variant under flat layout (merges.txt + vocab.json)
        let bpeBundle = root.appendingPathComponent("BPE-Model")
        try fm.createDirectory(at: bpeBundle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bpeBundle.appendingPathComponent("config.json"))
        try Data("a b\n".utf8).write(to: bpeBundle.appendingPathComponent("merges.txt"))
        try Data("{}".utf8).write(to: bpeBundle.appendingPathComponent("vocab.json"))
        try Data().write(to: bpeBundle.appendingPathComponent("model.safetensors"))

        let detected = ModelManager.scanLocalModels(at: root)
        let ids = Set(detected.map { $0.id })

        #expect(ids.contains("Nemotron-3-Flat"))
        #expect(ids.contains("JANGQ-AI/Laguna-XS.2"))
        #expect(ids.contains("BPE-Model"))
        #expect(!ids.contains("not-a-model"))
        #expect(detected.count == 3)

        // Flat-id resolution must round-trip through localDirectory.
        let flatModel = detected.first { $0.id == "Nemotron-3-Flat" }!
        let resolved = MLXModel(
            id: flatModel.id,
            name: flatModel.name,
            description: flatModel.description,
            downloadURL: flatModel.downloadURL,
            rootDirectory: root
        ).localDirectory
        #expect(resolved.path == flatBundle.path)
    }

    @Test func scanLocalModels_detectsShardedIndexWithoutListingAllWeights() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("osu-sharded-scan-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let repo = root.appendingPathComponent("JANGQ-AI").appendingPathComponent("Step-3.7-Flash-JANGTQ_K")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: repo.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: repo.appendingPathComponent("tokenizer.json"))
        try Data("{}".utf8).write(to: repo.appendingPathComponent("model.safetensors.index.json"))

        let detected = ModelManager.scanLocalModels(at: root)
        #expect(detected.map(\.id).contains("JANGQ-AI/Step-3.7-Flash-JANGTQ_K"))
    }

    @Test func scanLocalModels_skipsLargeSupportTreesBesideJANGBundles() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("osu-jangq-root-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let n2 = root.appendingPathComponent("Nex-N2-Pro-JANGTQ2")
        try fm.createDirectory(at: n2, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: n2.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: n2.appendingPathComponent("tokenizer.json"))
        try Data("{}".utf8).write(to: n2.appendingPathComponent("model.safetensors.index.json"))

        for supportName in ["sources", "__pycache__", "tokenizer", "transformer", "text_encoder", "vae"] {
            let supportDir = root.appendingPathComponent(supportName).appendingPathComponent("Nested")
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: supportDir.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: supportDir.appendingPathComponent("tokenizer.json"))
            try Data("{}".utf8).write(to: supportDir.appendingPathComponent("model.safetensors.index.json"))
        }

        let detected = ModelManager.scanLocalModels(at: root)
        #expect(detected.map(\.id) == ["Nex-N2-Pro-JANGTQ2"])
    }

    @Test func deleteModel_removesDirectoryAndResetsState() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let manager = await MainActor.run { ModelManager() }

        // Create a test model instead of relying on loaded models
        let testModel = MLXModel(
            id: "test/model",
            name: "Test Model",
            description: "Test model for unit tests",
            downloadURL: "https://example.com/test",
            rootDirectory: tempDir
        )

        let dir = testModel.localDirectory

        // Prepare directory with a dummy file
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(to: dir.appendingPathComponent("file.txt"))

        await MainActor.run { manager.downloadService.downloadStates[testModel.id] = .completed }
        await manager.deleteModel(testModel)

        // Directory should no longer exist and state should reset
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        #expect(exists == false)

        let state = await MainActor.run { manager.downloadStates[testModel.id] }
        #expect(state == .notStarted)

        try? FileManager.default.removeItem(at: tempDir)
    }
}
