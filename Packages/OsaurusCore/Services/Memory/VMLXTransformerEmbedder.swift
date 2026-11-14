//
//  VMLXTransformerEmbedder.swift
//  osaurus
//
//  Transformer embedding backend (BERT, XLM-RoBERTa, ModernBERT,
//  Qwen3-Embedding) run through MLXEmbedders. Weights load
//  lazily on the first embed, inside the embedding MetalGate hold that
//  `MetalSafeEmbedder` takes, and unload after a quiet period so an idle
//  index doesn't keep hundreds of megabytes resident.
//

import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import VecturaKit
import os

public actor VMLXTransformerEmbedder: VecturaEmbedder {
    /// Texts per MetalGate hold. Index rebuilds embed thousands of chunks;
    /// releasing the gate between groups lets generation interleave.
    static let textsPerGateHold = 16

    /// Activation memory one forward pass is sized for. MLX keeps each
    /// layer's intermediates until the pass completes, so deeper and wider
    /// models get smaller batches.
    static let activationBudgetBytes = 256 << 20

    struct BatchBudget: Equatable {
        /// Padded tokens per pass.
        let tokens: Int
        /// Rows × longest² per pass; attention scores grow with the square
        /// of length.
        let attentionCells: Int
    }

    static func batchBudget(for profile: EmbeddingProfile) -> BatchBudget {
        let layers = max(profile.layerCount, 1)
        let hidden = max(profile.dimension, 1)
        let heads = max(profile.headCount, 1)
        let tokens = activationBudgetBytes / (layers * hidden * 4 * 6)
        let cells = activationBudgetBytes / (layers * heads * 4)
        return BatchBudget(tokens: min(max(tokens, 512), 8192), attentionCells: max(cells, 4096))
    }

    private static let logger = Logger(subsystem: "ai.osaurus", category: "Embedding")

    private let profile: EmbeddingProfile
    private let tokenizerLoader: any TokenizerLoader
    private let idleUnloadDelay: Duration
    private var container: MLXEmbedders.ModelContainer?
    private var loadTask: Task<MLXEmbedders.ModelContainer, Error>?
    private var inFlight = 0
    private var idleTask: Task<Void, Never>?

    public init(
        profile: EmbeddingProfile,
        tokenizerLoader: any TokenizerLoader,
        idleUnloadDelay: Duration = .seconds(120)
    ) {
        self.profile = profile
        self.tokenizerLoader = tokenizerLoader
        self.idleUnloadDelay = idleUnloadDelay
    }

    public var dimension: Int {
        get async throws { profile.dimension }
    }

    public var isLoaded: Bool { container != nil }

    public func embed(text: String) async throws -> [Float] {
        try await embed(texts: [text]).first ?? []
    }

    public func embed(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        inFlight += 1
        idleTask?.cancel()
        defer {
            inFlight -= 1
            if inFlight == 0 { scheduleIdleUnload() }
        }
        let container = try await loadedContainer()
        let prefix = profile.prefix(for: EmbeddingRole.current)
        let inputs = texts.map { prefix + $0 }
        let budget = Self.batchBudget(for: profile)
        let spec = EncodeSpec(
            pooling: profile.pooling,
            maxTokens: profile.maxSequenceLength,
            dimension: profile.dimension,
            positionOffset: profile.positionOffset,
            tokenBudget: budget.tokens,
            attentionBudget: budget.attentionCells
        )
        // Runs inside the embedding MetalGate hold `MetalSafeEmbedder` takes.
        // Activation buffers would otherwise stay in MLX's reuse pool, which
        // has no cap until a chat model loads, and pin gigabytes after a
        // rebuild; drain them before the gate is released.
        defer {
            Stream.gpu.synchronize()
            Memory.clearCache()
        }
        return try await container.perform { model, tokenizer, _ in
            try Self.encode(inputs, model: model, tokenizer: tokenizer, spec: spec)
        }
    }

    // MARK: - Load / unload

    private func loadedContainer() async throws -> MLXEmbedders.ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        guard let directory = profile.directory else {
            throw EmbeddingProfileError.modelNotInstalled(modelId: profile.modelId)
        }
        try Self.admitMemory(profile)
        let loader = tokenizerLoader
        let task = Task { try await MLXEmbedders.loadModelContainer(from: directory, using: loader) }
        loadTask = task
        defer { loadTask = nil }
        do {
            let started = ContinuousClock.now
            let loaded = try await task.value
            container = loaded
            Self.logger.info(
                "Loaded embedding model \(self.profile.modelId, privacy: .public) in \(String(describing: ContinuousClock.now - started), privacy: .public)"
            )
            return loaded
        } catch let error as EmbeddingProfileError {
            throw error
        } catch {
            throw EmbeddingProfileError.loadFailed(modelId: profile.modelId, message: error.localizedDescription)
        }
    }

    /// Admission through the user's Memory Safety settings before any MLX
    /// allocation. Embedders keep no KV cache, so the working set is the
    /// weights plus one pass of activations (token and attention terms).
    static func admitMemory(_ profile: EmbeddingProfile) throws {
        let workingSet = UInt64(max(0, profile.weightBytes + 2 * Int64(activationBudgetBytes)))
        let plan = ServerRuntimeSettingsStore.resolvedMemorySafetyPlan(
            for: ServerRuntimeSettingsStore.snapshot(),
            baseLoadConfiguration: .osaurusProduction,
            host: MemoryStatus.snapshot(),
            request: VMLXMemoryRequestEstimate(workingSetBytes: workingSet)
        )
        if let issue = plan.blockingIssues.first {
            throw EmbeddingProfileError.memoryRefused(
                modelId: profile.modelId, field: issue.field, message: issue.message)
        }
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        let delay = idleUnloadDelay
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    /// Drops the weights when no embed is running. The teardown gate keeps
    /// the allocator flush from overlapping another model's Metal work.
    func unloadIfIdle() async {
        guard container != nil, inFlight == 0, loadTask == nil else { return }
        let owner = "embedding:\(profile.modelId)"
        await MetalGate.shared.enterModelTeardown(model: owner)
        if inFlight == 0, loadTask == nil, container != nil {
            container = nil
            Stream.gpu.synchronize()
            Memory.clearCache()
            Self.logger.info("Unloaded idle embedding model \(self.profile.modelId, privacy: .public)")
        }
        await MetalGate.shared.exitModelTeardown(model: owner)
    }

    // MARK: - Encoding

    struct EncodeSpec: Sendable {
        let pooling: EmbeddingPooling
        let maxTokens: Int
        let dimension: Int
        let positionOffset: Int
        let tokenBudget: Int
        let attentionBudget: Int
    }

    /// Tokenize, batch by similar length, run the model and pool. Runs inside
    /// `ModelContainer.perform`, so every array is evaluated before return.
    static func encode(
        _ texts: [String],
        model: EmbeddingModel,
        tokenizer: any Tokenizer,
        spec: EncodeSpec
    ) throws -> [[Float]] {
        let trailing = trailingSpecialTokenCount(tokenizer)
        let encoded = texts.map {
            truncate(tokenizer.encode(text: $0, addSpecialTokens: true), to: spec.maxTokens, keepingLast: trailing)
        }
        var vectors = [[Float]](repeating: [Float](repeating: 0, count: spec.dimension), count: texts.count)

        for batch in batches(
            lengths: encoded.map(\.count), tokenBudget: spec.tokenBudget, attentionBudget: spec.attentionBudget)
        {
            let longest = batch.map { encoded[$0].count }.max() ?? 0
            let rows = embedBatch(batch.map { encoded[$0] }, longest: longest, model: model, spec: spec)
            for (row, index) in zip(rows, batch) { vectors[index] = row }
            // Each pass has its own shapes; pooled buffers from one pass
            // aren't reused by the next and would add up across the call.
            Memory.clearCache()
        }
        return vectors
    }

    /// Groups input indices into forward passes. Sorting by length keeps
    /// padding low; each pass stays within both budgets unless a single
    /// input exceeds them alone. Empty inputs are left out.
    static func batches(lengths: [Int], tokenBudget: Int, attentionBudget: Int) -> [[Int]] {
        let order = lengths.indices.filter { lengths[$0] > 0 }.sorted { lengths[$0] < lengths[$1] }
        var result: [[Int]] = []
        var start = 0
        while start < order.count {
            var end = start
            var longest = 0
            while end < order.count {
                let candidate = max(longest, lengths[order[end]])
                let rows = end - start + 1
                if end > start, candidate * rows > tokenBudget || candidate * candidate * rows > attentionBudget {
                    break
                }
                longest = candidate
                end += 1
            }
            result.append(Array(order[start..<end]))
            start = end
        }
        return result
    }

    /// Special tokens the tokenizer appends after the content (`[SEP]`,
    /// `</s>`, `<|endoftext|>`). Truncation keeps them, as sentence-transformers
    /// truncates content before adding specials.
    static func trailingSpecialTokenCount(_ tokenizer: any Tokenizer) -> Int {
        let plain = tokenizer.encode(text: "a", addSpecialTokens: false)
        let full = tokenizer.encode(text: "a", addSpecialTokens: true)
        guard !plain.isEmpty, full.count >= plain.count else { return 0 }
        for start in 0...(full.count - plain.count) where Array(full[start..<(start + plain.count)]) == plain {
            return full.count - start - plain.count
        }
        return 0
    }

    static func truncate(_ tokens: [Int], to limit: Int, keepingLast trailing: Int) -> [Int] {
        guard limit > 0, tokens.count > limit else { return tokens }
        let tail = min(trailing, limit)
        return Array(tokens.prefix(limit - tail)) + Array(tokens.suffix(tail))
    }

    private static func embedBatch(
        _ tokens: [[Int]],
        longest: Int,
        model: EmbeddingModel,
        spec: EncodeSpec
    ) -> [[Float]] {
        let batch = tokens.count
        var ids: [Int32] = []
        var mask: [Int32] = []
        var positions: [Int32] = []
        ids.reserveCapacity(batch * longest)
        mask.reserveCapacity(batch * longest)
        for row in tokens {
            let padding = longest - row.count
            ids += row.map(Int32.init) + Array(repeating: 0, count: padding)
            mask += Array(repeating: 1, count: row.count) + Array(repeating: 0, count: padding)
            if spec.positionOffset > 0 {
                positions += (0..<row.count).map { Int32(spec.positionOffset + $0) }
                positions += Array(repeating: Int32(spec.positionOffset - 1), count: padding)
            }
        }
        let inputIds = MLXArray(ids, [batch, longest])
        let attentionMask = MLXArray(mask, [batch, longest])
        let positionIds = spec.positionOffset > 0 ? MLXArray(positions, [batch, longest]) : nil

        let output = model(
            inputIds,
            positionIds: positionIds,
            tokenTypeIds: MLXArray.zeros(like: inputIds),
            attentionMask: attentionMask
        )

        guard let hidden = output.hiddenStates?.asType(.float32) else {
            return tokens.map { _ in [Float](repeating: 0, count: spec.dimension) }
        }
        // ModernBERT returns states clamped to its position limit.
        let length = hidden.dim(1)
        let keep = attentionMask[0..., ..<length].asType(.float32).expandedDimensions(axis: -1)
        var pooled: MLXArray
        switch spec.pooling {
        case .firstToken:
            pooled = hidden[0..., 0, 0...]
        case .lastToken:
            pooled = stacked(tokens.enumerated().map { hidden[$0.offset, min($0.element.count, length) - 1] })
        case .max:
            pooled = which(keep .> MLXArray(Float(0)), hidden, MLXArray(-Float.infinity)).max(axis: 1)
        case .mean:
            pooled = (hidden * keep).sum(axis: 1) / maximum(keep.sum(axis: 1), MLXArray(Float(1)))
        }

        if pooled.dim(-1) > spec.dimension {
            pooled = pooled[0..., ..<spec.dimension]
        }
        // Normalize in float32: bf16 norms drift enough to reorder close neighbours.
        let norm = sqrt((pooled * pooled).sum(axis: -1, keepDims: true))
        pooled /= maximum(norm, MLXArray(Float(1e-12)))
        eval(pooled)

        let width = pooled.dim(-1)
        let flat = pooled.asArray(Float.self)
        return (0..<batch).map { Array(flat[($0 * width)..<(($0 + 1) * width)]) }
    }
}
