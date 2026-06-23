//
//  MetalSafeEmbedder.swift
//  osaurus
//
//  VecturaEmbedder wrapper that coordinates embedding work with MLX
//  generation through MetalGate. Pass this to VecturaKit instances so all
//  search and indexing operations are automatically Metal-safe.
//

import Foundation
import MLXEmbedders
import MLXLMCommon
import VecturaKit

public actor MetalSafeEmbedder: VecturaEmbedder {
    private let inner: any VecturaEmbedder

    public init(inner: any VecturaEmbedder) {
        self.inner = inner
    }

    public var dimension: Int {
        get async throws { try await inner.dimension }
    }

    public func embed(texts: [String]) async throws -> [[Float]] {
        await MetalGate.shared.enterEmbedding()
        do {
            let result = try await inner.embed(texts: texts)
            await MetalGate.shared.exitEmbedding()
            return result
        } catch {
            await MetalGate.shared.exitEmbedding()
            throw error
        }
    }

    public func embed(text: String) async throws -> [Float] {
        await MetalGate.shared.enterEmbedding()
        do {
            let result = try await inner.embed(text: text)
            await MetalGate.shared.exitEmbedding()
            return result
        } catch {
            await MetalGate.shared.exitEmbedding()
            throw error
        }
    }
}

public actor VMLXModel2VecEmbedder: VecturaEmbedder {
    private let modelName: String
    private let dimensionValue: Int
    private let tokenizerLoader: any TokenizerLoader
    private var pipeline: Model2VecStaticEmbeddingPipeline?

    public init(
        modelName: String,
        dimension: Int,
        tokenizerLoader: any TokenizerLoader
    ) {
        self.modelName = modelName
        self.dimensionValue = dimension
        self.tokenizerLoader = tokenizerLoader
    }

    public var dimension: Int {
        get async throws { dimensionValue }
    }

    public func embed(texts: [String]) async throws -> [[Float]] {
        let pipeline = try await pipeline()
        return try await pipeline.embed(texts: texts)
    }

    public func embed(text: String) async throws -> [Float] {
        let pipeline = try await pipeline()
        return try await pipeline.embed(text: text)
    }

    private func pipeline() async throws -> Model2VecStaticEmbeddingPipeline {
        if let pipeline {
            return pipeline
        }
        let directory = try resolveModelDirectory()
        let loaded = try await Model2VecStaticEmbeddingPipeline.load(
            from: directory,
            using: tokenizerLoader
        )
        pipeline = loaded
        return loaded
    }

    private func resolveModelDirectory() throws -> URL {
        guard let directory = Self.locateModelDirectory(modelName: modelName) else {
            throw VMLXModel2VecEmbedderError.modelNotFound(modelName)
        }
        return directory
    }

    /// Non-throwing resolution shared by the loader and by availability
    /// probes (e.g. `EmbeddingService.ensureModelPresent()`). Returns the
    /// usable model directory from the env override, `~/models`, or the
    /// Hugging Face cache, or `nil` when no usable copy exists locally.
    public static func locateModelDirectory(modelName: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["OSAURUS_EMBEDDING_MODEL_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if isUsableModelDirectory(url) {
                return url
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(components: "models", "minishlab--\(modelName)"),
            home.appending(components: "models", modelName),
            home.appending(components: ".cache", "huggingface", "hub", "models--minishlab--\(modelName)")
                .appending(component: "snapshots"),
        ]

        for candidate in candidates {
            if isUsableModelDirectory(candidate) {
                return candidate
            }
            if let snapshot = latestUsableSnapshot(in: candidate) {
                return snapshot
            }
        }

        return nil
    }

    private static func isUsableModelDirectory(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(component: "model.safetensors").path)
            && FileManager.default.fileExists(atPath: url.appending(component: "tokenizer.json").path)
            && FileManager.default.fileExists(atPath: url.appending(component: "config.json").path)
    }

    private static func latestUsableSnapshot(in directory: URL) -> URL? {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        return
            contents
            .filter(Self.isUsableModelDirectory(_:))
            .sorted { lhs, rhs in
                let leftDate =
                    (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                let rightDate =
                    (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return leftDate > rightDate
            }
            .first
    }
}

public enum VMLXModel2VecEmbedderError: LocalizedError {
    case modelNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let modelName):
            return
                "Could not find local Model2Vec embedding model '\(modelName)'. Set OSAURUS_EMBEDDING_MODEL_DIR or install minishlab/\(modelName) in the Hugging Face cache."
        }
    }
}
