//
//  EmbeddingServiceTests.swift
//  osaurus
//

import Foundation
import Testing

@testable import OsaurusCore

struct EmbeddingServiceTests {

    @Test func embeddingDimensionIs128() {
        #expect(EmbeddingService.embeddingDimension == 128)
    }

    @Test func modelNameIsPotion() {
        #expect(EmbeddingService.modelName == "potion-base-4M")
    }

    @Test func configuredModelsDirectoryFindsPublisherLayout() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.modelsRoot.appending(components: "minishlab", "potion-base-4M")
        try populateModel(at: model)

        let resolved = VMLXModel2VecEmbedder.locateModelDirectory(
            modelName: "potion-base-4M",
            modelsDirectory: fixture.modelsRoot,
            environment: [:],
            homeDirectory: fixture.home
        )

        #expect(resolved?.standardizedFileURL == model.standardizedFileURL)
    }

    @Test func configuredModelsDirectoryFindsRootLevelLayout() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.modelsRoot.appending(component: "potion-base-4M", directoryHint: .isDirectory)
        try populateModel(at: model)

        let resolved = VMLXModel2VecEmbedder.locateModelDirectory(
            modelName: "potion-base-4M",
            modelsDirectory: fixture.modelsRoot,
            environment: [:],
            homeDirectory: fixture.home
        )

        #expect(resolved?.standardizedFileURL == model.standardizedFileURL)
    }

    @Test func configuredModelsDirectoryPrecedesLegacyFallbacks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configured = fixture.modelsRoot.appending(components: "minishlab", "potion-base-4M")
        let legacy = fixture.home.appending(components: "models", "potion-base-4M")
        try populateModel(at: configured)
        try populateModel(at: legacy)

        let resolved = VMLXModel2VecEmbedder.locateModelDirectory(
            modelName: "potion-base-4M",
            modelsDirectory: fixture.modelsRoot,
            environment: [:],
            homeDirectory: fixture.home
        )

        #expect(resolved?.standardizedFileURL == configured.standardizedFileURL)
    }

    private func makeFixture() throws -> (root: URL, modelsRoot: URL, home: URL) {
        let root = FileManager.default.temporaryDirectory.appending(
            component: "osaurus-embedding-locator-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let modelsRoot = root.appending(component: "ConfiguredModels", directoryHint: .isDirectory)
        let home = root.appending(component: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (root, modelsRoot, home)
    }

    private func populateModel(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ["config.json", "model.safetensors", "tokenizer.json"] {
            try Data("fixture".utf8).write(to: directory.appending(component: file))
        }
    }
}
