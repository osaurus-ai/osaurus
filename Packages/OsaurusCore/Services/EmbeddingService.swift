//
//  EmbeddingService.swift
//  osaurus
//
//  Provides text embedding generation via VecturaKit's SwiftEmbedder.
//  Used by the /v1/embeddings (OpenAI) and /api/embed (Ollama) endpoints.
//

import Foundation
import VecturaKit
import os

public actor EmbeddingService {
    public static let shared = EmbeddingService()
    public static let modelName = "potion-base-4M"

    private static let logger = Logger(subsystem: "ai.osaurus", category: "EmbeddingService")

    private var embedder: SwiftEmbedder?
    private var isInitialized = false

    private init() {}

    enum Error: Swift.Error, LocalizedError {
        case notInitialized

        var errorDescription: String? {
            switch self {
            case .notInitialized: "Embedding service failed to initialize"
            }
        }
    }

    /// Generate embeddings for one or more texts.
    public func embed(texts: [String]) async throws -> [[Float]] {
        try await ensureInitialized()

        guard let emb = embedder else {
            throw Error.notInitialized
        }

        return try await emb.embed(texts: texts)
    }

    private func ensureInitialized() async throws {
        guard !isInitialized else { return }

        let emb = SwiftEmbedder(modelSource: .default)
        _ = try await emb.dimension
        self.embedder = emb
        self.isInitialized = true
        Self.logger.info("EmbeddingService initialized")
    }
}
