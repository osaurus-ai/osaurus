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
