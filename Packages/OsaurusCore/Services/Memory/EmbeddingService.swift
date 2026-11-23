//
//  EmbeddingService.swift
//  osaurus
//
//  Provides text embedding generation for every semantic index and for the
//  /v1/embeddings (OpenAI) and /api/embed (Ollama) endpoints. The model is
//  the one chosen in Model Defaults → Embedding Model, resolved once at
//  launch: the built-in Model2Vec model, a downloaded Model2Vec bundle, or a
//  transformer embedder run through MLXEmbedders.
//

import Foundation
import MLXEmbedders
import VecturaKit
import os

/// The embedding model the running process resolved at launch.
public struct EmbeddingLaunchState: Sendable {
    /// The id stored in Model Defaults when the process started.
    public let requestedModelId: String
    public let result: Result<EmbeddingProfile, EmbeddingProfileError>

    public var profile: EmbeddingProfile? { try? result.get() }

    public var error: EmbeddingProfileError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

public actor EmbeddingService {
    public static let shared = EmbeddingService()

    /// Resolved on first use and fixed for the life of the process. Every
    /// Vectura index is opened against this profile's dimension, so a new
    /// selection applies on the next launch.
    public static let launchState: EmbeddingLaunchState = {
        let settings = EmbeddingSettingsStore.snapshot()
        let result = EmbeddingProfileResolver.resolve(settings: settings)
        if case .failure(let error) = result {
            logger.error(
                "Embedding profile unavailable: \(error.localizedDescription, privacy: .public). Semantic indexes stay closed; no other model is substituted."
            )
        }
        return EmbeddingLaunchState(requestedModelId: settings.effectiveModelId, result: result)
    }()

    /// The active profile, or `nil` when the selected model failed to resolve.
    public static var activeProfile: EmbeddingProfile? { launchState.profile }

    public static var launchError: EmbeddingProfileError? { launchState.error }

    /// Whether search services may open their Vectura indexes. False when the
    /// selected model can't run: the indexes stay closed rather than being
    /// rebuilt with vectors from a different model.
    public static var vectorIndexesAvailable: Bool { launchState.profile != nil }

    /// Name reported in the `model` field of the embeddings APIs and logs.
    public static var modelName: String {
        activeProfile?.apiName
            ?? launchState.requestedModelId.split(separator: "/").last.map(String.init)
            ?? launchState.requestedModelId
    }

    public static var modelId: String { activeProfile?.modelId ?? launchState.requestedModelId }

    /// Vector width of the active profile, known without loading the model so
    /// VecturaKit can open its indexes at launch.
    public static var embeddingDimension: Int { activeProfile?.dimension ?? EmbeddingProfile.builtIn.dimension }

    /// Vectura directory name each search service stores its index under.
    public static var indexDirectoryName: String {
        (activeProfile ?? .builtIn).indexDirectoryName
    }

    enum APIModelError: LocalizedError {
        case unsupportedModel(String)
        case unavailable(EmbeddingProfileError)

        var errorDescription: String? {
            switch self {
            case .unsupportedModel(let requested):
                return "Embedding model '\(requested)' is not supported by this endpoint. "
                    + "Use '\(EmbeddingService.modelName)' or '\(EmbeddingService.modelId)', "
                    + "the model selected in Model Defaults → Embedding Model. "
                    + "No embeddings were generated."
            case .unavailable(let error):
                return error.localizedDescription
            }
        }
    }

    /// The API serves the active profile only. Reject other identities before
    /// loading it: returning one model's vectors for a different requested
    /// model silently corrupts callers' vector indexes.
    nonisolated static func validateAPIModel(_ requested: String) throws {
        if let error = launchError { throw APIModelError.unavailable(error) }
        let accepted = [modelName, modelId].map { $0.lowercased() }
        guard accepted.contains(requested.lowercased()) else {
            throw APIModelError.unsupportedModel(requested)
        }
    }

    /// Single shared embedder used by all VecturaKit indexes and the embedding API.
    /// Wrapped in MetalSafeEmbedder to coordinate embedding and generation work.
    public static let sharedEmbedder: MetalSafeEmbedder = makeEmbedder(for: launchState)

    static func makeEmbedder(for state: EmbeddingLaunchState) -> MetalSafeEmbedder {
        let profile: EmbeddingProfile
        switch state.result {
        case .success(let resolved): profile = resolved
        case .failure(let error): return MetalSafeEmbedder(inner: UnavailableEmbedder(error: error))
        }
        switch profile.backend {
        case .model2vec:
            return MetalSafeEmbedder(
                inner: VMLXModel2VecEmbedder(
                    modelName: profile.apiName,
                    dimension: profile.dimension,
                    tokenizerLoader: SwiftTransformersTokenizerLoader(),
                    directory: profile.directory
                )
            )
        case .transformer:
            return MetalSafeEmbedder(
                inner: VMLXTransformerEmbedder(
                    profile: profile,
                    tokenizerLoader: SwiftTransformersTokenizerLoader()
                ),
                maxTextsPerGateHold: VMLXTransformerEmbedder.textsPerGateHold
            )
        }
    }

    private static let logger = Logger(subsystem: "ai.osaurus", category: "EmbeddingService")

    private var isInitialized = false

    private init() {}

    /// Verifies the embedding model is locally available and logs a loud,
    /// actionable warning if it isn't — so a capability_search / eval run
    /// doesn't silently build an EMPTY semantic index and report
    /// unreliable retrieval. A miss on the built-in model means a broken
    /// build or install; a miss on a selected model is reported by
    /// `launchError`. This is a fast existence probe only.
    public static func ensureModelPresent() {
        guard let profile = activeProfile else { return }
        guard profile.isBuiltIn else { return }
        if VMLXModel2VecEmbedder.locateModelDirectory(modelName: profile.apiName) == nil {
            logger.warning(
                "Embedding model '\(profile.apiName, privacy: .public)' is missing from the OsaurusCore bundle — semantic search will be EMPTY and unreliable. Rebuild/reinstall Osaurus or set OSAURUS_EMBEDDING_MODEL_DIR."
            )
        }
    }

    /// Generate embeddings for one or more texts.
    public func embed(texts: [String]) async throws -> [[Float]] {
        if !isInitialized {
            _ = try await Self.sharedEmbedder.dimension
            isInitialized = true
            Self.logger.info("EmbeddingService initialized with \(Self.modelId, privacy: .public)")
        }
        return try await Self.sharedEmbedder.embed(texts: texts)
    }
}

/// Stands in for an embedding model that failed to resolve at launch, so
/// every caller gets the typed reason instead of vectors from another model.
struct UnavailableEmbedder: VecturaEmbedder {
    let error: EmbeddingProfileError

    var dimension: Int {
        get async throws { throw error }
    }

    func embed(texts: [String]) async throws -> [[Float]] { throw error }

    func embed(text: String) async throws -> [Float] { throw error }
}
