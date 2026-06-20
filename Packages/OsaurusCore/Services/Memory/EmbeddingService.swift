//
//  EmbeddingService.swift
//  osaurus
//
//  Provides text embedding generation via vmlx-swift's Model2Vec embedder.
//  Used by the /v1/embeddings (OpenAI) and /api/embed (Ollama) endpoints.
//

import Foundation
import MLXEmbedders
import VecturaKit
import os

public actor EmbeddingService {
    public static let shared = EmbeddingService()
    public static let modelName = "potion-base-4M"
    /// Known dimension for potion-base-4M so VecturaKit can init without loading the model.
    public static let embeddingDimension = 128

    /// Single shared embedder used by all VecturaKit indexes and the embedding API.
    /// Wrapped in MetalSafeEmbedder to coordinate embedding and generation work.
    public static let sharedEmbedder: MetalSafeEmbedder = MetalSafeEmbedder(
        inner: VMLXModel2VecEmbedder(
            modelName: modelName,
            dimension: embeddingDimension,
            tokenizerLoader: SwiftTransformersTokenizerLoader()
        )
    )

    private static let logger = Logger(subsystem: "ai.osaurus", category: "EmbeddingService")

    private var isInitialized = false

    private init() {}

    /// Verifies the embedding model is locally available and logs a loud,
    /// actionable warning if it isn't — so a capability_search / eval run
    /// doesn't silently build an EMPTY semantic index and report
    /// unreliable retrieval. Does NOT download (that's the job of
    /// `scripts/evals/prepare-evals-env.sh` or the memory feature's
    /// downloader); this is a fast existence probe only.
    public static func ensureModelPresent() {
        if VMLXModel2VecEmbedder.locateModelDirectory(modelName: modelName) == nil {
            logger.warning(
                "Embedding model '\(modelName, privacy: .public)' not found locally — semantic search will be EMPTY and unreliable. Run `make evals-prep`, set OSAURUS_EMBEDDING_MODEL_DIR, or install minishlab/\(modelName, privacy: .public) in the Hugging Face cache."
            )
        }
    }

    /// Generate embeddings for one or more texts.
    public func embed(texts: [String]) async throws -> [[Float]] {
        if !isInitialized {
            _ = try await Self.sharedEmbedder.dimension
            isInitialized = true
            Self.logger.info("EmbeddingService initialized")
        }
        return try await Self.sharedEmbedder.embed(texts: texts)
    }
}
