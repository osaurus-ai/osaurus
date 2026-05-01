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

    @Test func downloadProgress_matchesState() async throws {
        let manager = await MainActor.run { ModelManager() }
        let testModelId = "test-progress-\(UUID().uuidString)"

        await MainActor.run { manager.downloadService.downloadStates[testModelId] = .notStarted }
        var p = await MainActor.run { manager.downloadProgress(for: testModelId) }
        #expect(p == 0.0)

        await MainActor.run { manager.downloadService.downloadStates[testModelId] = .downloading(progress: 0.25) }
        p = await MainActor.run { manager.downloadProgress(for: testModelId) }
        #expect(abs(p - 0.25) < 0.0001)

        await MainActor.run { manager.downloadService.downloadStates[testModelId] = .completed }
        p = await MainActor.run { manager.downloadProgress(for: testModelId) }
        #expect(p == 1.0)

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
                .appendingPathComponent("Laguna-XS.2-JANGTQ"))
        try makeBundle(
            jangqai.appendingPathComponent("OsaurusAI")
                .appendingPathComponent("Mistral-Medium-3.5-128B-mxfp4"))

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
        await MainActor.run { manager.deleteModel(testModel) }

        // Directory should no longer exist and state should reset
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        #expect(exists == false)

        let state = await MainActor.run { manager.downloadStates[testModel.id] }
        #expect(state == .notStarted)

        try? FileManager.default.removeItem(at: tempDir)
    }
}
