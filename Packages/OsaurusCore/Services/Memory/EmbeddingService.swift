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
    /// Known dimension for potion-base-4M so VecturaKit can init without loading the model.
    public static let embeddingDimension = 128

    /// Single shared embedder used by all VecturaKit indexes and the embedding API.
    /// Using one instance prevents concurrent CoreML model loads that can SIGSEGV
    /// on Apple Silicon (observed on M3, macOS 26.4).
    public static let sharedEmbedder = SwiftEmbedder(modelSource: .default)

    // MARK: - Startup GPU gate

    /// Prevents concurrent CoreML (embedding) and MLX (inference) Metal
    /// operations at startup.  AppDelegate registers the startup embedding
    /// task; ModelRuntime awaits it before the first inference call.
    private static let startupLock = NSLock()
    private static nonisolated(unsafe) var _startupInitTask: Task<Void, Never>?

    public nonisolated static func setStartupInitTask(_ task: Task<Void, Never>) {
        startupLock.withLock { _startupInitTask = task }
    }

    public nonisolated static func awaitStartupInit() async {
        let task = startupLock.withLock { _startupInitTask }
        guard let task else { return }
        await task.value
        startupLock.withLock { _startupInitTask = nil }
    }

    private static let logger = Logger(subsystem: "ai.osaurus", category: "EmbeddingService")

    private var isInitialized = false

    private init() {}

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
