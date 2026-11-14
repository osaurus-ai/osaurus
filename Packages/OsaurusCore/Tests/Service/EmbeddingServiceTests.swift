//
//  EmbeddingServiceTests.swift
//  osaurus
//

import Foundation
import Testing

@testable import OsaurusCore

struct EmbeddingServiceTests {

    @Test(arguments: ["potion-base-4M", "minishlab/potion-base-4M"])
    func acceptsSupportedAPIModel(_ model: String) throws {
        try EmbeddingService.validateAPIModel(model)
    }

    @Test(arguments: ["mxbai-embed-large-v1", "bge-small-en-v1.5", "other/potion-base-4M", "", "potion-base-4M-extra"])
    func rejectsUnsupportedAPIModel(_ model: String) {
        #expect(throws: EmbeddingService.APIModelError.self) {
            try EmbeddingService.validateAPIModel(model)
        }
    }

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

    @Test func bundledCopyPrecedesConfiguredAndCacheCopies() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundled = fixture.root.appending(components: "Bundle", "potion-base-4M")
        let configured = fixture.modelsRoot.appending(components: "minishlab", "potion-base-4M")
        let cache = fixture.home.appending(
            components: ".cache",
            "huggingface",
            "hub",
            "models--minishlab--potion-base-4M",
            "snapshots",
            "rev"
        )
        try populateModel(at: bundled)
        try populateModel(at: configured)
        try populateModel(at: cache)

        let resolved = VMLXModel2VecEmbedder.locateModelDirectory(
            modelName: "potion-base-4M",
            modelsDirectory: fixture.modelsRoot,
            environment: [:],
            homeDirectory: fixture.home,
            bundledDirectory: bundled
        )

        #expect(resolved?.standardizedFileURL == bundled.standardizedFileURL)
    }

    @Test func environmentOverridePrecedesBundledCopy() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundled = fixture.root.appending(components: "Bundle", "potion-base-4M")
        let override = fixture.root.appending(components: "Override", "potion-base-4M")
        try populateModel(at: bundled)
        try populateModel(at: override)

        let resolved = VMLXModel2VecEmbedder.locateModelDirectory(
            modelName: "potion-base-4M",
            modelsDirectory: fixture.modelsRoot,
            environment: ["OSAURUS_EMBEDDING_MODEL_DIR": override.path],
            homeDirectory: fixture.home,
            bundledDirectory: bundled
        )

        #expect(resolved?.standardizedFileURL == override.standardizedFileURL)
    }

    @Test func incompleteBundledCopyFallsThroughToConfiguredDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundled = fixture.root.appending(components: "Bundle", "potion-base-4M")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundled.appending(component: "config.json"))
        let configured = fixture.modelsRoot.appending(components: "minishlab", "potion-base-4M")
        try populateModel(at: configured)

        let resolved = VMLXModel2VecEmbedder.locateModelDirectory(
            modelName: "potion-base-4M",
            modelsDirectory: fixture.modelsRoot,
            environment: [:],
            homeDirectory: fixture.home,
            bundledDirectory: bundled
        )

        #expect(resolved?.standardizedFileURL == configured.standardizedFileURL)
    }

    /// The model shipped in OsaurusCore's resource bundle is complete and is
    /// what the production resolver returns without an env override.
    @Test func shippedBundleContainsTheModel() throws {
        let bundled = try #require(
            VMLXModel2VecEmbedder.bundledModelDirectory(modelName: EmbeddingService.modelName)
        )
        for file in ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"] {
            #expect(FileManager.default.fileExists(atPath: bundled.appending(component: file).path))
        }
        let configData = try Data(contentsOf: bundled.appending(component: "config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
        #expect(config?["model_type"] as? String == "model2vec")
        #expect(config?["hidden_dim"] as? Int == EmbeddingService.embeddingDimension)

        if ProcessInfo.processInfo.environment["OSAURUS_EMBEDDING_MODEL_DIR"]?.isEmpty ?? true {
            let resolved = VMLXModel2VecEmbedder.locateModelDirectory(modelName: EmbeddingService.modelName)
            #expect(resolved?.standardizedFileURL == bundled.standardizedFileURL)
        }
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
