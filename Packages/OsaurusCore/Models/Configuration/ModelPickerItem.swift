//
//  ModelPickerItem.swift
//  osaurus
//
//  Rich model picker item with metadata and source information.
//

import Foundation

/// Represents a model in the model picker with rich metadata
struct ModelPickerItem: Identifiable, Hashable {
    /// The source/provider of the model
    enum Source: Hashable {
        case foundation
        case local  // MLX models
        case imageGeneration  // on-device image models (vMLXFlux)
        case remote(providerName: String, providerId: UUID)

        var displayName: String {
            switch self {
            case .foundation:
                return "Foundation"
            case .local:
                return "Local Models"
            case .imageGeneration:
                return "Image Models"
            case .remote(let providerName, _):
                return providerName
            }
        }

        /// Stable identifier unique per source instance (safe for row IDs).
        var uniqueKey: String {
            switch self {
            case .foundation: return "foundation"
            case .local: return "local"
            case .imageGeneration: return "image"
            case .remote(_, let providerId): return "remote-\(providerId.uuidString)"
            }
        }

        var sortOrder: Int {
            switch self {
            case .foundation:
                return 0
            case .local:
                return 1
            case .imageGeneration:
                return 2
            case .remote:
                return 3
            }
        }

        /// True for the on-device image-generation source. Chat routes these
        /// through `ImageGenerationService` instead of the LLM engine.
        var isImageGeneration: Bool {
            if case .imageGeneration = self { return true }
            return false
        }
    }

    /// Full model identifier (used for selection)
    let id: String

    /// Short display name for the model
    let displayName: String

    /// Source/provider of the model
    let source: Source

    /// Parameter count if available (e.g., "7B", "1.7B")
    let parameterCount: String?

    /// Quantization level if available (e.g., "4-bit", "8-bit")
    let quantization: String?

    /// Whether this is a Vision Language Model
    let isVLM: Bool

    /// Whether the local bundle is in MLX format and therefore loadable by the
    /// local engine. Set from `MLXModel.isMLXFormat` for local items so the
    /// picker can grey out (and refuse to select) co-mingled non-MLX bundles
    /// that would otherwise fail at load. Always `true` for non-local sources
    /// (foundation, remote) and undownloaded catalog entries.
    let isMLXFormat: Bool

    /// Whether this is an embedding/encoder-only model (BERT family,
    /// model2vec, etc.). Set from `MLXModel.isEmbedding` for local items so
    /// `isLikelyChatCapable` can exclude them without re-reading config.json.
    let isEmbedding: Bool

    /// Description of the model (optional)
    let description: String?

    /// Input price in micro-USD per million tokens, parsed from the Osaurus
    /// router metadata. Used only to sort the Osaurus tab by price; `nil` for
    /// items without router pricing (foundation, local, plain remote).
    let inputPriceMicroPerMTok: Int64?

    /// Output price in micro-USD per million tokens (sort tiebreak). `nil` when
    /// unknown, matching `inputPriceMicroPerMTok`.
    let outputPriceMicroPerMTok: Int64?

    /// Context window in tokens, from the Osaurus router metadata. Used only to
    /// filter the Osaurus tab by context limit; `nil` when unknown.
    let contextLength: Int?

    /// Image-generation metadata. Nil for text/remote chat models.
    let imageKind: String?
    let imageCapabilities: ImageModelCapabilities?
    let imageDefaultSteps: Int?
    let imageDefaultGuidance: Float?
    let imageReady: Bool

    init(
        id: String,
        displayName: String,
        source: Source,
        parameterCount: String? = nil,
        quantization: String? = nil,
        isVLM: Bool = false,
        isMLXFormat: Bool = true,
        isEmbedding: Bool = false,
        description: String? = nil,
        inputPriceMicroPerMTok: Int64? = nil,
        outputPriceMicroPerMTok: Int64? = nil,
        contextLength: Int? = nil,
        imageKind: String? = nil,
        imageCapabilities: ImageModelCapabilities? = nil,
        imageDefaultSteps: Int? = nil,
        imageDefaultGuidance: Float? = nil,
        imageReady: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.isVLM = isVLM
        self.isMLXFormat = isMLXFormat
        self.isEmbedding = isEmbedding
        self.description = description
        self.inputPriceMicroPerMTok = inputPriceMicroPerMTok
        self.outputPriceMicroPerMTok = outputPriceMicroPerMTok
        self.contextLength = contextLength
        self.imageKind = imageKind
        self.imageCapabilities = imageCapabilities
        self.imageDefaultSteps = imageDefaultSteps
        self.imageDefaultGuidance = imageDefaultGuidance
        self.imageReady = imageReady
    }

    /// Check if model matches search query using fuzzy matching.
    func matches(searchQuery: String) -> Bool {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        return [displayName, id, source.displayName].contains { SearchService.matches(query: searchQuery, in: $0) }
    }

    /// Cross-provider key under which this model is stored in the favourites
    /// list — the source's unique key plus the id, so the same id offered by two
    /// providers is bookmarked independently.
    var favoriteKey: String {
        FavoriteModelsStore.key(sourceKey: source.uniqueKey, modelId: id)
    }
}

// MARK: - Factory Methods

extension ModelPickerItem {
    /// Create a Foundation model picker item
    static func foundation() -> ModelPickerItem {
        ModelPickerItem(
            id: "foundation",
            displayName: "Foundation",
            source: .foundation,
            description: "Apple's built-in on-device model"
        )
    }

    /// Create a local MLX model picker item from an MLXModel.
    static func fromMLXModel(_ model: MLXModel) -> ModelPickerItem {
        ModelPickerItem(
            id: model.id,
            displayName: model.name,
            source: .local,
            parameterCount: model.parameterCount,
            quantization: model.quantization,
            isVLM: model.isVLM,
            isMLXFormat: model.isMLXFormat,
            isEmbedding: model.isEmbedding,
            description: model.description
        )
    }

    /// Create an on-device image-generation model picker item.
    static func fromImageModel(_ model: ImageModelInfo) -> ModelPickerItem {
        ModelPickerItem(
            id: model.id,
            displayName: model.displayName,
            source: .imageGeneration,
            quantization: model.quantizationBits.map { "\($0)-bit" },
            description: model.ready ? nil : model.blockedReasons.first,
            imageKind: model.kind,
            imageCapabilities: model.capabilities,
            imageDefaultSteps: model.defaultSteps,
            imageDefaultGuidance: model.defaultGuidance,
            imageReady: model.ready
        )
    }

    /// Create a remote provider model picker item
    static func fromRemoteModel(
        modelId: String,
        providerName: String,
        providerId: UUID
    ) -> ModelPickerItem {
        ModelPickerItem(
            id: modelId,
            displayName: displayName(fromModelId: modelId),
            source: .remote(providerName: providerName, providerId: providerId)
        )
    }

    /// Create an Osaurus Router model picker item enriched with the router's
    /// per-model metadata (underlying provider, pricing, context, capabilities).
    /// The metadata is rendered in the picker row's existing second line via
    /// `description`, so no table-layout changes are needed.
    static func fromOsaurusRouterModel(
        prefixedId: String,
        providerName: String,
        providerId: UUID,
        metadata: OsaurusRouterModel
    ) -> ModelPickerItem {
        ModelPickerItem(
            id: prefixedId,
            displayName: displayName(fromModelId: prefixedId),
            source: .remote(providerName: providerName, providerId: providerId),
            isVLM: metadata.supportsVision,
            description: metadata.pickerDescription,
            inputPriceMicroPerMTok: Int64(
                metadata.inputMicroPerMTok.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            outputPriceMicroPerMTok: Int64(
                metadata.outputMicroPerMTok.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            contextLength: metadata.contextLength > 0 ? metadata.contextLength : nil
        )
    }

    /// Short display name from a (possibly provider-prefixed) model id: the
    /// segment after the last "/", e.g. "osaurus/<upstream>/model-b" -> "model-b".
    private static func displayName(fromModelId id: String) -> String {
        guard let slashIndex = id.lastIndex(of: "/") else { return id }
        return String(id[id.index(after: slashIndex)...])
    }
}

// MARK: - Osaurus Router metadata presentation

extension OsaurusRouterModel {
    /// Compact one-line summary for the model picker: underlying provider,
    /// input/output price, and context window. e.g.
    /// "<upstream> · $2.00/M in · $4.00/M out · 131K ctx".
    var pickerDescription: String? {
        var parts: [String] = []

        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProvider.isEmpty {
            parts.append(trimmedProvider)
        }

        let input = inputDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.isEmpty {
            parts.append("\(input) in")
        }

        let output = outputDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            parts.append("\(output) out")
        }

        if let context = Self.formatContextLength(contextLength) {
            parts.append("\(context) ctx")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// True when the model advertises a vision/image capability, so the picker
    /// can show its "Vision" badge. Capability keys vary, so match common ones.
    var supportsVision: Bool {
        guard let capabilities else { return false }
        let visionKeys: Set<String> = ["vision", "image", "images", "multimodal"]
        return capabilities.contains { key, value in
            value && visionKeys.contains(key.lowercased())
        }
    }

    /// Human-friendly context window (e.g. 131072 -> "131K", 1048576 -> "1M").
    static func formatContextLength(_ context: Int) -> String? {
        guard context > 0 else { return nil }
        if context >= 1_000_000 {
            let millions = Double(context) / 1_000_000
            let format = millions == millions.rounded() ? "%.0fM" : "%.1fM"
            return String(format: format, millions)
        }
        if context >= 1000 {
            return "\(context / 1000)K"
        }
        return "\(context)"
    }
}

// MARK: - Default-selection capability heuristic

extension ModelPickerItem {
    /// Heuristic used only for default-selection: is this item plausibly a
    /// chat-capable model?
    ///
    /// Remote providers expose `/v1/models` as a flat list of IDs with no
    /// capability metadata, so an embedding or reranker model is
    /// indistinguishable by type from a chat model. When such a model happens
    /// to be first in the list, the Chat tab previously auto-selected it and
    /// every message failed with an opaque HTTP 500. This check lets the
    /// default-selection step skip obvious non-chat IDs while remaining
    /// conservative: if a chat model has an unusual name that trips the
    /// heuristic, the array helper below falls back to the first item so the
    /// picker is never left empty when models exist.
    var isLikelyChatCapable: Bool {
        switch source {
        case .foundation:
            // Foundation is Apple's on-device chat model.
            return true
        case .local:
            // `.local` items include disk-scanned and externally-imported
            // bundles (HF cache, LM Studio), not just the curated chat
            // catalog, so an embedding repo can appear here. The flag is
            // detected from the bundle's config.json at item construction.
            // Non-MLX bundles can't load locally, so never auto-pick one.
            // AppleScript bundles only ever emit AppleScript (a dedicated
            // subagent model), so they are never a chat pick either.
            return !isEmbedding && isMLXFormat && !isAppleScriptCatalogModel
        case .imageGeneration:
            // Image models produce images, not chat completions — never a
            // default chat pick (but still selectable to enter image mode).
            return false
        case .remote:
            return !Self.isLikelyEmbeddingOrRerankerID(id)
        }
    }

    /// True when this is one of the curated on-device AppleScript models (a
    /// `.local` MLX bundle whose repo id matches `AppleScriptModelCatalog`).
    /// These bundles only emit AppleScript, so they're hidden from the chat
    /// model picker and never auto-selected as a chat model — they're chosen in
    /// the dedicated AppleScript model picker instead. Their installed-ness
    /// still drives `ModelPickerItemCache.hasReadyAppleScriptModel`.
    var isAppleScriptCatalogModel: Bool {
        if case .local = source {
            return AppleScriptModelCatalog.isAppleScriptModel(id: id)
        }
        return false
    }

    var isImageGenerationDelegateCandidate: Bool {
        source.isImageGeneration && imageReady && (imageCapabilities?.textToImage == true)
    }

    var isImageEditDelegateCandidate: Bool {
        source.isImageGeneration && imageReady && (imageCapabilities?.imageEdit == true)
    }

    /// Ranking used only when Chat needs an automatic fallback selection.
    ///
    /// Local discovery can include source/unquantized Gemma folders alongside
    /// the OsaurusAI QAT bundles users are expected to run. Keep every model in
    /// the picker, but do not let a source folder win the default slot just
    /// because it sorts earlier on disk.
    var defaultChatSelectionRank: Int {
        let lower = id.lowercased()
        switch source {
        case .imageGeneration:
            return 40
        case .local:
            if lower.contains("gemma-4"), lower.contains("qat"),
                lower.contains("osaurusai--"),
                lower.contains("jang_4m") || lower.contains("mxfp4")
            {
                return 0
            }
            if lower.contains("gemma-4"),
                lower.contains("unquantized") || lower.contains("q4_0-unquantized")
            {
                return 20
            }
            return 5
        case .foundation:
            return 10
        case .remote:
            return isLikelyChatCapable ? 15 : 30
        }
    }

    /// Token- and prefix-based classifier that returns `true` when the model
    /// ID almost certainly belongs to an embedding or reranker family.
    ///
    /// Matching is word-boundary so "embedded" in a chat model's description
    /// would not trigger (though only the ID is inspected). A provider prefix
    /// like `"provider-name/model-id"` is stripped before matching.
    static func isLikelyEmbeddingOrRerankerID(_ id: String) -> Bool {
        // Strip any `"provider/"` prefix added by `fromRemoteModel`.
        let tail = id.split(separator: "/").last.map(String.init) ?? id
        let lower = tail.lowercased()

        // Whole-token match on non-alphanumerics so we catch, e.g.,
        // `text-embedding-ada-002`, `nomic-embed-text`, `bge-reranker-v2-m3`
        // without misfiring on substrings like `embedded` or `rerankable`.
        let tokens = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for token in tokens {
            switch token {
            case "embedding", "embeddings", "embed",
                "reranker", "rerank",
                "colbert":
                return true
            default:
                break
            }
        }

        // Family prefixes whose IDs don't always literally contain the word
        // "embed" (e.g. `bge-small-en-v1.5`). Kept deliberately short to avoid
        // false positives on ambiguous families like `e5-mistral-*-instruct`.
        for prefix in ["bge-", "nomic-embed-"] where lower.hasPrefix(prefix) {
            return true
        }
        return false
    }
}

// MARK: - Sorting

/// User-chosen ordering for the Osaurus tab. The default keeps the existing
/// alphabetical order; the price options sort by per-million-token cost.
enum ModelPickerSortOrder: Hashable {
    case `default`
    case priceLowToHigh
    case priceHighToLow
}

/// Minimum-context filter for the Osaurus tab. Each case keeps models whose
/// context window is at least `minTokens`; `.any` disables the filter.
enum ModelPickerContextFilter: CaseIterable, Identifiable, Hashable {
    case any
    case min32K
    case min128K
    case min256K
    case min1M

    var id: Self { self }

    /// Inclusive lower bound in tokens. `.any` has no bound.
    var minTokens: Int? {
        switch self {
        case .any: return nil
        case .min32K: return 32_000
        case .min128K: return 128_000
        case .min256K: return 256_000
        case .min1M: return 1_000_000
        }
    }

    /// Short chip label.
    var label: String {
        switch self {
        case .any: return "Any"
        case .min32K: return "32K+"
        case .min128K: return "128K+"
        case .min256K: return "256K+"
        case .min1M: return "1M+"
        }
    }
}

/// Vision-capability filter for the Osaurus tab.
enum ModelPickerVisionFilter: CaseIterable, Identifiable, Hashable {
    case any
    case visionOnly
    case nonVision

    var id: Self { self }

    /// Short chip label.
    var label: String {
        switch self {
        case .any: return "Any"
        case .visionOnly: return "Vision"
        case .nonVision: return "Non-vision"
        }
    }
}

extension Array where Element == ModelPickerItem {
    /// Keep only models whose context window meets the filter's minimum. Items
    /// with unknown context are dropped when a minimum is set; `.any` is a
    /// no-op that returns the receiver unchanged.
    func filteredByContext(_ context: ModelPickerContextFilter) -> [ModelPickerItem] {
        guard let minTokens = context.minTokens else { return self }
        return filter { ($0.contextLength ?? 0) >= minTokens }
    }

    /// Keep only models matching the vision filter; `.any` returns the receiver
    /// unchanged.
    func filteredByVision(_ vision: ModelPickerVisionFilter) -> [ModelPickerItem] {
        switch vision {
        case .any: return self
        case .visionOnly: return filter { $0.isVLM }
        case .nonVision: return filter { !$0.isVLM }
        }
    }

    /// Sort by Osaurus router price (input rate primary, output as tiebreak).
    /// Items without pricing sort last in either direction so a missing rate
    /// never jumps to the top of a "cheapest first" list. Falls back to the
    /// receiver unchanged for `.default`.
    func sortedByPrice(_ order: ModelPickerSortOrder) -> [ModelPickerItem] {
        guard order != .default else { return self }
        let ascending = order == .priceLowToHigh
        return sorted { lhs, rhs in
            switch (lhs.inputPriceMicroPerMTok, rhs.inputPriceMicroPerMTok) {
            case let (l?, r?):
                if l != r { return ascending ? l < r : l > r }
                let lo = lhs.outputPriceMicroPerMTok ?? 0
                let ro = rhs.outputPriceMicroPerMTok ?? 0
                if lo != ro { return ascending ? lo < ro : lo > ro }
                return lhs.displayName < rhs.displayName
            case (nil, _?):
                return false  // unknown price always sorts last
            case (_?, nil):
                return true
            case (nil, nil):
                return lhs.displayName < rhs.displayName
            }
        }
    }
}

// MARK: - Tabs

/// A horizontal tab in the model picker: "Local" (Foundation + on-device MLX
/// models) followed by one tab per connected remote provider.
struct ModelPickerTab: Identifiable, Equatable {
    /// Stable key: "local" or "remote-<providerId>".
    let key: String

    /// Display title: "Local" or the provider name.
    let title: String

    /// Models shown when this tab is active. For the Local tab, Foundation
    /// items come first, then on-device models sorted by name.
    let models: [ModelPickerItem]

    var id: String { key }

    /// The Osaurus Router tab, identified by provider title (matching how
    /// `groupedByTab()` pins it). This is the only tab whose models carry
    /// pricing, so it's the only one offering the price-sort control.
    var isOsaurus: Bool { title == "Osaurus" }
}

// MARK: - Grouping

extension Array where Element == ModelPickerItem {
    /// Default-selection helper used by the Chat tab.
    ///
    /// Returns the first item that appears chat-capable per
    /// `isLikelyChatCapable`. Falls back to the absolute first item when no
    /// item passes the heuristic, so the picker is never left unset while
    /// items exist — a chat model with an unusual name still gets selected,
    /// just not preferentially.
    var firstChatCapable: ModelPickerItem? {
        let ranked = enumerated()
            .filter { $0.element.isLikelyChatCapable }
            .min {
                let lhs = ($0.element.defaultChatSelectionRank, $0.offset)
                let rhs = ($1.element.defaultChatSelectionRank, $1.offset)
                return lhs < rhs
            }
        return ranked?.element ?? first
    }

    var imageGenerationDelegateCandidates: [ModelPickerItem] {
        filter(\.isImageGenerationDelegateCandidate)
    }

    var imageEditDelegateCandidates: [ModelPickerItem] {
        filter(\.isImageEditDelegateCandidate)
    }

    /// Chat-capable candidates for the per-agent subagent model picker
    /// (`computer_use` / `spawn` override). Filters via
    /// `isLikelyChatCapable` so embedding / image-only items are excluded.
    var chatModelCandidates: [ModelPickerItem] {
        filter(\.isLikelyChatCapable)
    }

    /// The chat candidate matching a stored subagent override id, or `nil` when
    /// the id is unset/blank or no longer present (drives the picker's stale
    /// "(unavailable)" tag).
    func subagentChatModelCandidate(id: String?) -> ModelPickerItem? {
        guard let id else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return chatModelCandidates.first { $0.id == trimmed }
    }

    func subagentModelCandidate(
        id: String?,
        kind: SubagentModelKind
    ) -> ModelPickerItem? {
        guard let id else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return candidates(for: kind).first { $0.id == trimmed }
    }

    func defaultSubagentModelCandidate(kind: SubagentModelKind) -> ModelPickerItem? {
        candidates(for: kind).first
    }

    private func candidates(for kind: SubagentModelKind) -> [ModelPickerItem] {
        switch kind {
        case .imageGeneration:
            return imageGenerationDelegateCandidates
        case .imageEdit:
            return imageEditDelegateCandidates
        }
    }

    /// Group models by source for display in sections
    func groupedBySource() -> [(source: ModelPickerItem.Source, models: [ModelPickerItem])] {
        var groups: [ModelPickerItem.Source: [ModelPickerItem]] = [:]

        for model in self {
            // AppleScript bundles surface only in the dedicated AppleScript
            // model picker, never the chat model picker.
            if model.isAppleScriptCatalogModel { continue }
            groups[model.source, default: []].append(model)
        }

        // Sort groups by source order, then sort models within each group
        return
            groups
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { (source: $0.key, models: $0.value.sorted { $0.displayName < $1.displayName }) }
    }

    /// Group models into picker tabs: a single "Local" tab (Foundation first,
    /// then on-device models sorted by name) followed by one tab per remote
    /// provider in source order. Tabs with no models are omitted.
    func groupedByTab() -> [ModelPickerTab] {
        var foundationModels: [ModelPickerItem] = []
        var localModels: [ModelPickerItem] = []
        // Keyed by uniqueKey; insertion order preserved separately so provider
        // tabs keep a stable order matching the incoming options array.
        var remoteModels: [String: [ModelPickerItem]] = [:]
        var remoteOrder: [(key: String, title: String)] = []

        for model in self {
            // AppleScript bundles surface only in the dedicated AppleScript
            // model picker, never the chat model picker's Local tab.
            if model.isAppleScriptCatalogModel { continue }
            switch model.source {
            case .foundation:
                foundationModels.append(model)
            case .local, .imageGeneration:
                // On-device image models live in the Local tab alongside LLMs.
                localModels.append(model)
            case .remote(let providerName, _):
                let key = model.source.uniqueKey
                if remoteModels[key] == nil {
                    remoteOrder.append((key: key, title: providerName))
                }
                remoteModels[key, default: []].append(model)
            }
        }

        var tabs: [ModelPickerTab] = []
        tabs.reserveCapacity(remoteOrder.count + 1)

        if !foundationModels.isEmpty || !localModels.isEmpty {
            tabs.append(
                ModelPickerTab(
                    key: "local",
                    title: "Local",
                    models: foundationModels + localModels.sorted { $0.displayName < $1.displayName }
                )
            )
        }

        let osaurusTabs = remoteOrder.filter { $0.title == "Osaurus" }
        let otherRemoteTabs = remoteOrder.filter { $0.title != "Osaurus" }
        let orderedRemoteTabs = osaurusTabs + otherRemoteTabs

        for entry in orderedRemoteTabs {
            guard let models = remoteModels[entry.key], !models.isEmpty else { continue }
            tabs.append(
                ModelPickerTab(
                    key: entry.key,
                    title: entry.title,
                    models: models.sorted { $0.displayName < $1.displayName }
                )
            )
        }

        return tabs
    }
}

// MARK: - Mock Data (For Testing Performance)

#if DEBUG
    extension ModelPickerItem {
        /// Generate a large list of mock models for testing scroll performance
        static func generateMockModels(count: Int = 500) -> [ModelPickerItem] {
            var models: [ModelPickerItem] = []

            // foundation model
            models.append(.foundation())

            // local models (MLX)
            let localModels = [
                ("Llama", ["3.2", "3.1", "3", "2"]),
                ("Qwen", ["2.5", "2", "1.5"]),
                ("Mistral", ["7B", "Nemo", "Small"]),
                ("Gemma", ["2", "1.1"]),
                ("DeepSeek", ["V2.5", "V2", "Coder"]),
                ("Phi", ["4", "3.5", "3"]),
            ]

            let quantizations = ["4-bit", "8-bit", "FP16"]
            let sizes = ["1B", "3B", "7B", "8B", "14B", "27B", "70B"]

            for (baseName, versions) in localModels {
                for version in versions {
                    for quant in quantizations {
                        for size in sizes {
                            let isVLM = Bool.random() && Double.random(in: 0 ... 1) > 0.8
                            let displayName = "\(baseName) \(version) \(size) \(quant)\(isVLM ? " Vision" : "")"
                            let id = "mlx-community/\(baseName)-\(version)-\(size)-\(quant)"
                            let description =
                                "A powerful language model optimized for local inference\(isVLM ? " with vision capabilities" : "")"

                            models.append(
                                ModelPickerItem(
                                    id: id,
                                    displayName: displayName,
                                    source: .local,
                                    parameterCount: size,
                                    quantization: quant,
                                    isVLM: isVLM,
                                    description: description
                                )
                            )

                            if models.count >= count { break }
                        }
                        if models.count >= count { break }
                    }
                    if models.count >= count { break }
                }
                if models.count >= count { break }
            }

            // remote models (OpenAI-like provider)
            let openAIProviderId = UUID()
            let openAIModels = [
                ("gpt-4o", "Most advanced GPT-4 model with vision capabilities", true),
                ("gpt-4-turbo", "High performance GPT-4 variant", false),
                ("gpt-4", "Original GPT-4 model", false),
                ("gpt-3.5-turbo", "Fast and efficient for most tasks", false),
            ]

            for (modelId, desc, isVLM) in openAIModels {
                models.append(
                    ModelPickerItem(
                        id: "openai/\(modelId)",
                        displayName: modelId,
                        source: .remote(providerName: "OpenAI", providerId: openAIProviderId),
                        isVLM: isVLM,
                        description: desc
                    )
                )
            }

            // remote models (Anthropic-like provider)
            let anthropicProviderId = UUID()
            let anthropicModels = [
                ("claude-opus-4", "Most capable Claude model", false),
                ("claude-sonnet-3.5", "Balanced performance and speed", false),
                ("claude-haiku-3.5", "Fast and efficient", false),
            ]

            for (modelId, desc, isVLM) in anthropicModels {
                models.append(
                    ModelPickerItem(
                        id: "anthropic/\(modelId)",
                        displayName: modelId,
                        source: .remote(providerName: "Anthropic", providerId: anthropicProviderId),
                        isVLM: isVLM,
                        description: desc
                    )
                )
            }

            // remote models (OpenRouter - large catalog)
            let openRouterProviderId = UUID()
            let baseRemoteModels = [
                "meta-llama/llama-3.2-90b-vision-instruct",
                "meta-llama/llama-3.1-405b-instruct",
                "meta-llama/llama-3.1-70b-instruct",
                "google/gemini-pro-1.5",
                "google/gemini-flash-1.5",
                "mistralai/mistral-large-2",
                "mistralai/pixtral-12b",
                "cohere/command-r-plus",
                "perplexity/llama-3.1-sonar-large",
                "x-ai/grok-beta",
            ]

            // generate many variants
            while models.count < count {
                for baseModel in baseRemoteModels {
                    let variants = ["", "-free", "-preview", "-turbo", "-extended"]
                    for variant in variants {
                        let modelId = baseModel + variant
                        let name = modelId.split(separator: "/").last.map(String.init) ?? modelId
                        let isVLM = modelId.contains("vision") || modelId.contains("pixtral")

                        models.append(
                            ModelPickerItem(
                                id: modelId,
                                displayName: name,
                                source: .remote(providerName: "OpenRouter", providerId: openRouterProviderId),
                                isVLM: isVLM,
                                description: "Available via OpenRouter"
                            )
                        )

                        if models.count >= count { break }
                    }
                    if models.count >= count { break }
                }
            }

            return Array(models.prefix(count))
        }
    }
#endif
