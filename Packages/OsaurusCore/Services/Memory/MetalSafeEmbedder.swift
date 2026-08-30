//
//  MetalSafeEmbedder.swift
//  osaurus
//
//  VecturaEmbedder wrapper that coordinates embedding work with MLX
//  generation through MetalGate. Pass this to VecturaKit instances so all
//  search and indexing operations are automatically Metal-safe.
//

import Foundation
import MLX
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
        // Throws CancellationError if cancelled while waiting; no gate is
        // held on that path, so the exit pairing below is untouched.
        try await MetalGate.shared.enterEmbedding()
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
        try await MetalGate.shared.enterEmbedding()
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

/// Model2Vec static-embedding embedder with a genuinely batched forward:
/// `embed(texts:)` runs ONE padded `[N, L]` gather + masked mean + eval for
/// the whole batch (vmlx-swift's `Model2VecStaticEmbeddingPipeline` only
/// loops `embed(text:)` per element, so it cannot back the micro-batcher).
/// Loads the same bundle layout the vmlx pipeline loads (`model.safetensors`
/// "embeddings" tensor, `config.json` `normalize` flag, tokenizer).
///
/// Must only run behind `MetalSafeEmbedder` (or another MetalGate holder):
/// both the lazy weight load and the forward submit MLX GPU work.
public actor VMLXModel2VecEmbedder: VecturaEmbedder {
    private struct LoadedModel {
        let embeddings: MLXArray
        let tokenizer: any Tokenizer
        let unknownTokenId: Int?
        let normalize: Bool
    }

    private struct BundleConfiguration: Decodable {
        /// Missing key defaults to false, matching the vmlx pipeline's
        /// `config?.normalize ?? false`.
        let normalize: Bool

        private enum CodingKeys: String, CodingKey {
            case normalize
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            normalize = try container.decodeIfPresent(Bool.self, forKey: .normalize) ?? false
        }
    }

    private let modelName: String
    private let dimensionValue: Int
    private let tokenizerLoader: any TokenizerLoader
    private var model: LoadedModel?

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
        guard !texts.isEmpty else { return [] }
        let model = try await loadedModel()

        // Bound the batched forward's working set: the padded gather
        // materializes [N, L_max, D] floats, and N is CLIENT-CONTROLLED on
        // the /v1/embeddings pass-through (CoalescingEmbedder hands
        // caller-assembled arrays straight here) — an unbounded request
        // would materialize an unbounded GPU allocation. Process in chunks
        // of at most `EmbeddingBatcher.defaultMaxBatchSize` (the same bound
        // the micro-batcher keeps for its coalesced batches: 16 × 512
        // tokens × 128 dims of Float is ~4 MB per chunk) and concatenate.
        // Sequential chunks all run inside the CALLER's single MetalGate
        // acquisition — `MetalSafeEmbedder.embed(texts:)` wraps this whole
        // method, so chunking never releases/re-acquires the gate mid-batch.
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for range in Self.forwardChunkRanges(
            count: texts.count,
            maxChunkSize: EmbeddingBatcher.defaultMaxBatchSize
        ) {
            results.append(contentsOf: embedChunk(Array(texts[range]), model: model))
        }
        return results
    }

    /// Contiguous ranges of at most `maxChunkSize` covering `0..<count`, in
    /// order. Pure helper backing the bounded chunked forward above; kept
    /// static so the boundary math is unit-testable without loading MLX.
    static func forwardChunkRanges(count: Int, maxChunkSize: Int) -> [Range<Int>] {
        guard count > 0, maxChunkSize > 0 else { return [] }
        return stride(from: 0, to: count, by: maxChunkSize).map { start in
            start..<min(start + maxChunkSize, count)
        }
    }

    /// One bounded batched forward: padded `[N, L]` gather + masked mean +
    /// eval for `texts.count <= EmbeddingBatcher.defaultMaxBatchSize` texts.
    private func embedChunk(_ texts: [String], model: LoadedModel) -> [[Float]] {
        let dimension = model.embeddings.shape[1]

        // Tokenize on CPU, dropping unknown tokens exactly like the vmlx
        // pipeline does.
        let tokenIDs: [[Int32]] = texts.map { text in
            model.tokenizer.encode(text: text, addSpecialTokens: false)
                .filter { token in
                    guard let unknownTokenId = model.unknownTokenId else { return true }
                    return token != unknownTokenId
                }
                .map(Int32.init)
        }

        let maxLength = tokenIDs.map(\.count).max() ?? 0
        guard maxLength > 0 else {
            // Every text tokenized to nothing: zero vectors, no GPU work.
            return texts.map { _ in [Float](repeating: 0, count: dimension) }
        }

        // Pad token ids to [N, L] with row 0 (any valid row); the mask zeroes
        // the padding's contribution to the mean.
        var flatIDs = [Int32]()
        flatIDs.reserveCapacity(texts.count * maxLength)
        var flatMask = [Float]()
        flatMask.reserveCapacity(texts.count * maxLength)
        for ids in tokenIDs {
            flatIDs.append(contentsOf: ids)
            flatIDs.append(contentsOf: repeatElement(0, count: maxLength - ids.count))
            flatMask.append(contentsOf: repeatElement(1, count: ids.count))
            flatMask.append(contentsOf: repeatElement(0, count: maxLength - ids.count))
        }

        let ids = MLXArray(flatIDs, [texts.count, maxLength])
        let mask = MLXArray(flatMask, [texts.count, maxLength, 1])
        let gathered = model.embeddings.take(ids, axis: 0)  // [N, L, D]
        // Masked mean; the max(count, 1) keeps an all-unknown text a clean
        // zero vector instead of 0/0 (matching the pipeline's empty-token
        // early return).
        let counts = maximum(mask.sum(axis: 1), MLXArray(Float(1)))  // [N, 1]
        let means = (gathered * mask).sum(axis: 1) / counts  // [N, D]
        let vectors: MLXArray
        if model.normalize {
            // Row-wise L2 normalize with the norm clamped away from zero,
            // matching `MLXArray.l2Normalized(axis:eps:)` (which is declared
            // identically in both MLX and MLXEmbedders and is therefore
            // ambiguous to call here).
            let norms = sqrt((means * means).sum(axis: -1, keepDims: true))
            vectors = means / maximum(norms, MLXArray(Float(1e-12)))
        } else {
            vectors = means
        }
        eval(vectors)

        let flat = vectors.asArray(Float.self)
        return (0..<texts.count).map { row in
            Array(flat[(row * dimension)..<((row + 1) * dimension)])
        }
    }

    public func embed(text: String) async throws -> [Float] {
        guard let vector = try await embed(texts: [text]).first else {
            throw VMLXModel2VecEmbedderError.invalidModelBundle(
                "Embedding forward returned no vector for a single-text batch"
            )
        }
        return vector
    }

    private func loadedModel() async throws -> LoadedModel {
        if let model {
            return model
        }
        let directory = try resolveModelDirectory()
        let weightsURL = directory.appending(component: "model.safetensors")
        let weights = try loadArrays(url: weightsURL)
        guard let embeddings = weights["embeddings"] else {
            throw VMLXModel2VecEmbedderError.invalidModelBundle(
                "Missing 'embeddings' tensor in \(weightsURL.path)"
            )
        }
        guard embeddings.shape.count == 2 else {
            throw VMLXModel2VecEmbedderError.invalidModelBundle(
                "Model2Vec embeddings tensor must be rank 2, got shape \(embeddings.shape)"
            )
        }
        eval(embeddings)

        let configURL = directory.appending(component: "config.json")
        let config = try? JSONDecoder.json5().decode(
            BundleConfiguration.self,
            from: Data(contentsOf: configURL)
        )
        let tokenizer = try await tokenizerLoader.load(from: directory)
        let loaded = LoadedModel(
            embeddings: embeddings,
            tokenizer: tokenizer,
            unknownTokenId: tokenizer.unknownTokenId,
            normalize: config?.normalize ?? false
        )
        model = loaded
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
    case invalidModelBundle(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let modelName):
            return
                "Could not find local Model2Vec embedding model '\(modelName)'. Set OSAURUS_EMBEDDING_MODEL_DIR or install minishlab/\(modelName) in the Hugging Face cache."
        case .invalidModelBundle(let reason):
            return "Invalid Model2Vec embedding model bundle: \(reason)"
        }
    }
}
