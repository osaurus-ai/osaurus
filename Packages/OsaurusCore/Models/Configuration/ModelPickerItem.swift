//
//  ModelPickerItem.swift
//  osaurus
//
//  Rich model picker item with metadata and source information.
//

import Foundation

enum ModelChatEndpointCapability: String, Codable, Sendable {
    case supported
    case unsupported
    case unknown
}

/// Represents a model in the model picker with rich metadata
struct ModelPickerItem: Identifiable, Hashable {
    /// The source/provider of the model
    enum Source: Hashable {
        case foundation
        case local  // MLX models
        case imageGeneration  // on-device image models (vMLXFlux)
        /// The locally-installed Claude Code CLI, driven as a subprocess.
        /// Local in the sense that matters here — no Osaurus-held credential
        /// and no Osaurus-managed connection — but it does reach the network
        /// through the user's own signed-in CLI.
        case claudeCode
        case remote(providerName: String, providerId: UUID)

        var displayName: String {
            switch self {
            case .foundation:
                return "Foundation"
            case .local:
                return "Local Models"
            case .imageGeneration:
                return "Image Models"
            case .claudeCode:
                return "Claude Code"
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
            case .claudeCode: return "claude-code"
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
            case .claudeCode:
                return 3
            case .remote:
                return 4
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

    /// Canonical local-bundle architecture from config.json. Nil for remote,
    /// Foundation, image-generation, or legacy picker entries that do not
    /// expose bundle metadata. Prompt-family routing must prefer this over
    /// marketing/repository names when it is available.
    let modelType: String?

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
    /// Provider-scoped chat endpoint support. OpenAI's `/v1/models` listing
    /// exposes only ids, so those rows remain explicitly unknown instead of a
    /// successful listing being misrepresented as a chat capability claim.
    let chatEndpointCapability: ModelChatEndpointCapability

    /// Description of the model (optional)
    let description: String?

    /// Human-readable provenance for externally-discovered local bundles
    /// (e.g. "LM Studio", "Hugging Face cache"), from
    /// `MLXModel.externalSource`. `nil` for Osaurus-managed local models and
    /// every non-local source. Drives the Local tab's source filter so users
    /// with other apps' models on disk can narrow to Osaurus-managed ones.
    let externalSource: String?

    /// Input price in micro-USD per million tokens, parsed from the Osaurus
    /// router metadata. Used only to sort the Osaurus tab by price; `nil` for
    /// items without router pricing (foundation, local, plain remote).
    let inputPriceMicroPerMTok: Int64?

    /// Output price in micro-USD per million tokens (sort tiebreak). `nil` when
    /// unknown, matching `inputPriceMicroPerMTok`.
    let outputPriceMicroPerMTok: Int64?

    /// Context window in tokens, from the Osaurus router metadata or the
    /// ChatGPT/Codex catalog's `context_window`. Also read by
    /// `AgentToolLoop.providerContextWindow` to resolve the runtime/chat
    /// budget for remote models; `nil` when the source has no window.
    let contextLength: Int?

    /// Whether Router metadata explicitly advertises tool calling. Nil for
    /// non-Router models and older catalogs that do not publish the capability.
    /// The first-run temporary Cloud selector uses this with price + context to
    /// choose a lower-cost model that can still run the agent experience.
    let supportsToolCalling: Bool?

    /// Catalog-driven reasoning-effort capabilities for remote models: the
    /// live ChatGPT/Codex catalog contract, or the documented official
    /// OpenAI GPT-5.6 API-key contract. Nil for models without a dynamic
    /// effort surface (they keep the static profile fallback).
    let reasoningCapabilities: ModelReasoningCapabilities?

    /// Whether the provider's catalog advertises a reasoning/thinking
    /// channel. Nil when the provider made no claim. Display-only: the
    /// runtime's reasoning contract is still auto-detected per model.
    let supportsReasoning: Bool?

    /// Maximum output tokens the provider publishes, when known.
    let maxOutputTokens: Int?

    /// Whether the provider flagged this model as deprecated/retiring.
    let isDeprecated: Bool

    /// Why the row carries a Recommended badge, when it does. Only ever set
    /// from a real signal: the provider's own ranking (Venice traits), the
    /// curated local `isTopSuggestion` list, or a catalog default. Nil means
    /// no badge.
    let recommendedReason: String?

    /// Ready-to-show price string when the provider publishes prices in a
    /// unit other than USD (the Osaurus Router's credits display). The row
    /// prefers this over formatting the micro-USD fields.
    let priceDisplay: String?

    /// The upstream vendor for gateway models (Osaurus Router's `provider`),
    /// shown as the leading part of the metadata line.
    let upstreamProvider: String?

    /// Image-generation metadata. Nil for text/remote chat models.
    let imageKind: String?
    let imageCapabilities: ImageModelCapabilities?
    let imageDefaultSteps: Int?
    let imageDefaultGuidance: Float?
    let imageReady: Bool
    /// Provider-neutral media metadata for remote image/video rows. Local
    /// image rows retain their existing `image*` fields.
    let mediaModel: MediaModelInfo?

    init(
        id: String,
        displayName: String,
        source: Source,
        parameterCount: String? = nil,
        quantization: String? = nil,
        isVLM: Bool = false,
        modelType: String? = nil,
        isMLXFormat: Bool = true,
        isEmbedding: Bool = false,
        chatEndpointCapability: ModelChatEndpointCapability = .supported,
        description: String? = nil,
        externalSource: String? = nil,
        inputPriceMicroPerMTok: Int64? = nil,
        outputPriceMicroPerMTok: Int64? = nil,
        contextLength: Int? = nil,
        supportsToolCalling: Bool? = nil,
        reasoningCapabilities: ModelReasoningCapabilities? = nil,
        supportsReasoning: Bool? = nil,
        maxOutputTokens: Int? = nil,
        isDeprecated: Bool = false,
        recommendedReason: String? = nil,
        priceDisplay: String? = nil,
        upstreamProvider: String? = nil,
        imageKind: String? = nil,
        imageCapabilities: ImageModelCapabilities? = nil,
        imageDefaultSteps: Int? = nil,
        imageDefaultGuidance: Float? = nil,
        imageReady: Bool = false,
        mediaModel: MediaModelInfo? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.isVLM = isVLM
        self.modelType = modelType
        self.isMLXFormat = isMLXFormat
        self.isEmbedding = isEmbedding
        self.chatEndpointCapability = chatEndpointCapability
        self.description = description
        self.externalSource = externalSource
        self.inputPriceMicroPerMTok = inputPriceMicroPerMTok
        self.outputPriceMicroPerMTok = outputPriceMicroPerMTok
        self.contextLength = contextLength
        self.supportsToolCalling = supportsToolCalling
        self.reasoningCapabilities = reasoningCapabilities
        self.supportsReasoning = supportsReasoning
        self.maxOutputTokens = maxOutputTokens
        self.isDeprecated = isDeprecated
        self.recommendedReason = recommendedReason
        self.priceDisplay = priceDisplay
        self.upstreamProvider = upstreamProvider
        self.imageKind = imageKind
        self.imageCapabilities = imageCapabilities
        self.imageDefaultSteps = imageDefaultSteps
        self.imageDefaultGuidance = imageDefaultGuidance
        self.imageReady = imageReady
        self.mediaModel = mediaModel
    }

    /// Structured one-line summary for the picker row's second line, built
    /// only from what is actually known: upstream vendor (gateways), context
    /// window, and price. Falls back to the free-text `description` when no
    /// structured metadata exists. Media rows are summarized separately by
    /// the picker (`mediaDetails`), so they return nil here.
    var metadataLine: String? {
        if mediaModel != nil { return nil }
        var parts: [String] = []
        if let upstreamProvider, !upstreamProvider.isEmpty {
            parts.append(upstreamProvider)
        }
        if let contextLength, let formatted = OsaurusRouterModel.formatContextLength(contextLength) {
            parts.append("\(formatted) ctx")
        }
        if let price = ModelPriceFormatter.line(for: self) {
            parts.append(price)
        }
        if parts.isEmpty { return description }
        return parts.joined(separator: " · ")
    }

    /// Whether any structured pricing is known (used to decide if the
    /// price sort is meaningful for a group).
    var hasPricing: Bool {
        priceDisplay != nil || inputPriceMicroPerMTok != nil || outputPriceMicroPerMTok != nil
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
        return ModelPickerItem(
            id: "foundation",
            displayName: "Foundation",
            source: .foundation,
            description: "Apple's built-in on-device model"
        )
    }

    /// Create a picker item for one Claude Code CLI model alias.
    static func claudeCode(_ model: ClaudeCodeModel) -> ModelPickerItem {
        ModelPickerItem(
            id: model.pickerId,
            displayName: model.displayName,
            source: .claudeCode,
            description: L("Runs through your signed-in Claude Code CLI"),
            supportsToolCalling: true
        )
    }

    /// Create a local MLX model picker item from an MLXModel. Installed
    /// models on the curated top-suggestion list carry the Recommended badge
    /// — the same curation the Models catalog pins first, never a heuristic.
    static func fromMLXModel(_ model: MLXModel) -> ModelPickerItem {
        let isTopSuggestion =
            model.isTopSuggestion || ModelManager.topSuggestionModelIds.contains(model.id.lowercased())
        return ModelPickerItem(
            id: model.id,
            displayName: model.name,
            source: .local,
            parameterCount: model.parameterCount,
            quantization: model.quantization,
            isVLM: model.isVLM,
            modelType: model.modelType,
            isMLXFormat: model.isMLXFormat,
            isEmbedding: model.isEmbedding,
            description: model.description,
            externalSource: model.externalSource,
            recommendedReason: isTopSuggestion ? L("Recommended by Osaurus") : nil
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

    /// Create a remote provider model picker item. `contextLength` is the
    /// window the provider's `/models` endpoint advertised (e.g. vLLM's
    /// `max_model_len`), when known; it feeds the same provider-metadata
    /// resolution step router models use, ahead of the 128k fallback.
    static func fromRemoteModel(
        modelId: String,
        providerName: String,
        providerId: UUID,
        contextLength: Int? = nil
    ) -> ModelPickerItem {
        fromRemoteModel(
            modelId: modelId,
            providerName: providerName,
            providerId: providerId,
            metadata: contextLength.map { RemoteModelMetadata(contextLength: $0) }
        )
    }

    /// Create a remote provider model picker item enriched with whatever the
    /// provider's catalog published (`RemoteModelMetadata`). Every field is
    /// optional and only rendered when present, so a bare `/models` id still
    /// produces the plain row it always did.
    static func fromRemoteModel(
        modelId: String,
        providerName: String,
        providerId: UUID,
        metadata: RemoteModelMetadata?
    ) -> ModelPickerItem {
        let fallbackName = displayName(fromModelId: modelId)
        return ModelPickerItem(
            id: modelId,
            displayName: metadata?.displayName ?? fallbackName,
            source: .remote(providerName: providerName, providerId: providerId),
            parameterCount: metadata?.parameterCount,
            quantization: metadata?.quantization,
            isVLM: metadata?.supportsVision ?? false,
            description: metadata?.description,
            inputPriceMicroPerMTok: metadata?.inputPriceMicroPerMTok,
            outputPriceMicroPerMTok: metadata?.outputPriceMicroPerMTok,
            contextLength: metadata?.contextLength,
            supportsToolCalling: metadata?.supportsToolCalling,
            supportsReasoning: metadata?.supportsReasoning,
            maxOutputTokens: metadata?.maxOutputTokens,
            isDeprecated: metadata?.isDeprecated ?? false,
            recommendedReason: metadata?.recommendedReason
        )
    }

    static func fromMediaModel(_ model: MediaModelInfo, providerId: UUID) -> ModelPickerItem {
        let details = [
            model.privacy,
            model.pricing?.minimumUSD.map { "From \(OsaurusRouter.formatUSDAsCredits($0))" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        return ModelPickerItem(
            id: model.id,
            displayName: model.displayName,
            source: .remote(providerName: model.providerName, providerId: providerId),
            description: details.isEmpty ? nil : details,
            imageReady: model.isAvailable,
            mediaModel: model
        )
    }

    /// Create a ChatGPT/Codex remote model picker item enriched with the
    /// live catalog's display name and per-model reasoning capabilities.
    /// `metadata` is nil for fallback (pre-catalog) slugs, which then behave
    /// exactly like plain remote items.
    static func fromCodexRemoteModel(
        modelId: String,
        providerName: String,
        providerId: UUID,
        metadata: CodexModelMetadata?
    ) -> ModelPickerItem {
        let catalogDisplayName = metadata?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelPickerItem(
            id: modelId,
            displayName: (catalogDisplayName?.isEmpty == false ? catalogDisplayName : nil)
                ?? displayName(fromModelId: modelId),
            source: .remote(providerName: providerName, providerId: providerId),
            isVLM: metadata?.supportsImageInput ?? true,
            contextLength: metadata?.contextWindow,
            reasoningCapabilities: metadata.flatMap(ModelReasoningCapabilities.init(codex:))
        )
    }

    /// Create a picker item for the official `api.openai.com` API-key route.
    /// GPT-5.6 models attach the documented public reasoning profile
    /// (`none` … `max`, never Codex-only `ultra`); every other id keeps the
    /// plain `/v1/models` id/display behavior and the generic static
    /// profile fallback. Context length comes from `officialOpenAIContextWindow`
    /// since `/v1/models` never reports one (see that table's doc comment).
    static func fromOfficialOpenAIModel(
        modelId: String,
        providerName: String,
        providerId: UUID
    ) -> ModelPickerItem {
        ModelPickerItem(
            id: modelId,
            displayName: displayName(fromModelId: modelId),
            source: .remote(providerName: providerName, providerId: providerId),
            chatEndpointCapability: .unknown,
            description:
                "Chat compatibility is unknown because OpenAI /v1/models does not publish endpoint capabilities.",
            contextLength: officialOpenAIContextWindow(forModelId: modelId),
            reasoningCapabilities: isPublicGPT56ModelId(modelId) ? .officialOpenAIGPT56 : nil
        )
    }

    /// Context window (tokens) for known `api.openai.com` model families,
    /// keyed by the documented slug prefix (longest match wins so dated
    /// snapshots like `gpt-5.5-2026-01-01` still resolve). OpenAI's `/v1/models`
    /// endpoint never reports a context window — confirmed against the live
    /// API, which returns only `id`/`object`/`created`/`owned_by` — so this is
    /// the only source for the official API-key route. Values are from
    /// `developers.openai.com/api/docs/models/<slug>`; update when OpenAI ships
    /// a new family. Scoped to the official host only — never applied to
    /// OpenAI-compatible proxies, whose `id` values aren't OpenAI's to trust.
    private static let officialOpenAIContextWindows: [(prefix: String, tokens: Int)] = [
        ("gpt-5.6", 1_050_000),
        ("gpt-5.5", 1_050_000),
        ("gpt-5.4", 1_050_000),
        ("gpt-5.2", 400_000),
        ("gpt-5", 400_000),
        ("gpt-4.1", 1_047_576),
        ("gpt-4o", 128_000),
        ("o4-mini", 200_000),
        ("o3", 200_000),
        ("gpt-3.5-turbo", 16_385),
    ]

    static func officialOpenAIContextWindow(forModelId modelId: String) -> Int? {
        let bare = (modelId.split(separator: "/").last.map(String.init) ?? modelId).lowercased()
        return officialOpenAIContextWindows
            .filter { bare.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .tokens
    }

    /// Whether a (possibly provider-prefixed) id names a GPT-5.6 model
    /// covered by the documented public API reasoning contract.
    static func isPublicGPT56ModelId(_ id: String) -> Bool {
        let bare = id.split(separator: "/").last.map(String.init) ?? id
        return bare.lowercased().hasPrefix("gpt-5.6")
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
        let upstream = metadata.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelPickerItem(
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
            contextLength: metadata.contextLength > 0 ? metadata.contextLength : nil,
            supportsToolCalling: metadata.supportsToolCalling,
            priceDisplay: metadata.pickerPriceDisplay,
            upstreamProvider: upstream.isEmpty ? nil : upstream
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
    /// input/output price, and context window. Prefers the router's
    /// ready-to-show credits pricing (e.g. "<upstream> · 28.8 credits/M in ·
    /// 100 credits/M out · 131K ctx"), falling back to the legacy `$` display
    /// strings when the server doesn't ship the credits siblings.
    var pickerDescription: String? {
        var parts: [String] = []

        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProvider.isEmpty {
            parts.append(trimmedProvider)
        }

        let inputCredits = inputCreditsDisplay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let input = inputCredits.isEmpty
            ? inputDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
            : inputCredits
        if !input.isEmpty {
            parts.append("\(input) in")
        }

        let outputCredits = outputCreditsDisplay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let output = outputCredits.isEmpty
            ? outputDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
            : outputCredits
        if !output.isEmpty {
            parts.append("\(output) out")
        }

        if let context = Self.formatContextLength(contextLength) {
            parts.append("\(context) ctx")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Just the price portion of `pickerDescription` ("28.8 credits/M in ·
    /// 100 credits/M out"), for rows that render context and upstream
    /// separately. Nil when the router shipped no price strings.
    var pickerPriceDisplay: String? {
        var parts: [String] = []
        let inputCredits = inputCreditsDisplay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let input = inputCredits.isEmpty
            ? inputDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
            : inputCredits
        if !input.isEmpty { parts.append("\(input) in") }
        let outputCredits = outputCreditsDisplay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let output = outputCredits.isEmpty
            ? outputDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
            : outputCredits
        if !output.isEmpty { parts.append("\(output) out") }
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

    /// Router catalogs currently use `tools`; accept common aliases so a
    /// backend naming cleanup does not silently make first-run selection less
    /// capable. Nil means the catalog did not make a claim either way.
    var supportsToolCalling: Bool? {
        guard let capabilities else { return nil }
        let toolKeys: Set<String> = ["tools", "tool_calling", "function_calling"]
        let matches = capabilities.filter { toolKeys.contains($0.key.lowercased()) }
        guard !matches.isEmpty else { return nil }
        return matches.contains { $0.value }
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
        if mediaModel != nil { return false }
        if chatEndpointCapability == .unsupported { return false }
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
        case .claudeCode:
            return true
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
        (source.isImageGeneration && imageReady && (imageCapabilities?.textToImage == true))
            || (mediaModel?.kind == .image && mediaModel?.isAvailable == true)
    }

    var isImageEditDelegateCandidate: Bool {
        source.isImageGeneration && imageReady && (imageCapabilities?.imageEdit == true)
    }

    var isVideoGenerationDelegateCandidate: Bool {
        mediaModel?.kind.isVideo == true && mediaModel?.isAvailable == true
    }

    var isMediaGeneration: Bool {
        source.isImageGeneration || mediaModel != nil
    }

    /// Ranking used only when Chat needs an automatic fallback selection.
    ///
    /// Local discovery can include source/unquantized Gemma folders alongside
    /// the OsaurusAI QAT bundles users are expected to run. Keep every model in
    /// the picker, but do not let a source folder win the default slot just
    /// because it sorts earlier on disk.
    var defaultChatSelectionRank: Int {
        let lower = id.lowercased()
        if mediaModel != nil { return 40 }
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
        case .claudeCode:
            return 12
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

/// User-chosen ordering for a picker group. The default keeps the group's
/// display order; the price options sort by per-million-token cost.
enum ModelPickerSortOrder: Hashable {
    case `default`
    case priceLowToHigh
    case priceHighToLow
}

/// Minimum-context filter, offered on every group. Each case keeps models
/// whose context window is at least `minTokens`; `.any` disables the filter.
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

/// Source filter for the Local tab, so users who run other model apps on the
/// same machine (LM Studio, a shared Hugging Face cache) can narrow the list
/// to Osaurus-managed models or to one external source. The external cases
/// are built dynamically from the sources actually present, so the chips only
/// ever offer real choices.
enum ModelPickerLocalSourceFilter: Identifiable, Hashable {
    case any
    /// Osaurus-managed models: catalog downloads, Foundation, and on-device
    /// image models — everything without an external provenance.
    case osaurus
    /// One externally-discovered provenance, matched against
    /// `ModelPickerItem.externalSource` (e.g. "LM Studio").
    case external(String)

    var id: Self { self }

    /// Short chip label. External sources render their provenance verbatim.
    var label: String {
        switch self {
        case .any: return "Any"
        case .osaurus: return "Osaurus"
        case .external(let source): return source
        }
    }
}

/// Vision-capability filter, offered on every group.
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

/// Tool-calling filter. `toolsOnly` keeps models whose provider catalog
/// positively advertises tool support; models with no claim are dropped
/// (unknown is not "yes").
enum ModelPickerToolsFilter: CaseIterable, Identifiable, Hashable {
    case any
    case toolsOnly

    var id: Self { self }

    var label: String {
        switch self {
        case .any: return "Any"
        case .toolsOnly: return "Tools"
        }
    }
}

extension Array where Element == ModelPickerItem {
    /// Keep only models matching the tools filter; `.any` returns the
    /// receiver unchanged.
    func filteredByTools(_ tools: ModelPickerToolsFilter) -> [ModelPickerItem] {
        switch tools {
        case .any: return self
        case .toolsOnly: return filter { $0.supportsToolCalling == true }
        }
    }

    /// Keep only models whose context window meets the filter's minimum. Items
    /// with unknown context are dropped when a minimum is set; `.any` is a
    /// no-op that returns the receiver unchanged.
    func filteredByContext(_ context: ModelPickerContextFilter) -> [ModelPickerItem] {
        guard let minTokens = context.minTokens else { return self }
        return filter { ($0.contextLength ?? 0) >= minTokens }
    }

    /// Keep only models matching the local source filter; `.any` returns the
    /// receiver unchanged. `.osaurus` keeps everything without an external
    /// provenance (Foundation and image models included).
    func filteredByLocalSource(_ source: ModelPickerLocalSourceFilter) -> [ModelPickerItem] {
        switch source {
        case .any: return self
        case .osaurus: return filter { $0.externalSource == nil }
        case .external(let name): return filter { $0.externalSource == name }
        }
    }

    /// The distinct external provenances present, sorted for stable chip
    /// order. Empty when every model is Osaurus-managed, which hides the
    /// Local tab's source filter entirely.
    var distinctExternalSources: [String] {
        Set(compactMap(\.externalSource)).sorted()
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

    /// Sort by published price (input rate primary, output as tiebreak).
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

// MARK: - Groups

/// One entry in the model picker's sidebar: Favorites, "On this Mac",
/// Osaurus Cloud, one group per configured remote provider (connected or
/// not), and Claude Code. The right pane shows the active group's models.
struct ModelPickerGroup: Identifiable, Equatable {
    enum Kind: Equatable, Hashable {
        case favorites
        case local
        case osaurusCloud
        case remote(providerId: UUID)
        case claudeCode
    }

    /// Connection status for provider-backed groups, driving the sidebar
    /// status dot and the empty-state copy. `.none` for groups that have no
    /// connection concept (Favorites, On this Mac, Claude Code).
    enum Status: Equatable {
        case none
        case connected
        case connecting
        /// Configured but not connected; the message is the provider's last
        /// error when one exists.
        case disconnected(message: String?)
        /// Providers whose OAuth session expired and need a fresh sign-in.
        case needsSignIn

        var isConnected: Bool { self == .connected }
    }

    /// Stable key: "favorites", "local", "remote-<providerId>", "claude-code".
    let key: String
    /// Sidebar / header title.
    let title: String
    let kind: Kind
    /// Models shown when this group is active, already ordered for display.
    let models: [ModelPickerItem]
    var status: Status = .none
    /// SF Symbol for the sidebar icon rail.
    var icon: String = "cloud"

    var id: String { key }

    var isFavorites: Bool { kind == .favorites }
    var isLocal: Bool { kind == .local }
    var isOsaurusCloud: Bool { kind == .osaurusCloud }
    var isClaudeCode: Bool { kind == .claudeCode }

    var providerId: UUID? {
        switch kind {
        case .remote(let providerId): return providerId
        case .osaurusCloud: return RemoteProviderManager.osaurusRouterProviderId
        case .favorites, .local, .claudeCode: return nil
        }
    }

    /// Provider-backed groups (Osaurus Cloud + remote) can be reconnected /
    /// managed from the header; the others cannot.
    var isProviderBacked: Bool {
        switch kind {
        case .remote, .osaurusCloud: return true
        case .favorites, .local, .claudeCode: return false
        }
    }

    /// Whether at least one model in the group publishes a price, so the
    /// price sort is offered only where it changes anything.
    var hasPricing: Bool { models.contains(where: \.hasPricing) }

    static let favoritesKey = "favorites"
    static let localKey = "local"
    static let claudeCodeKey = "claude-code"

    static func key(forProviderId providerId: UUID) -> String {
        "remote-\(providerId.uuidString)"
    }
}

/// What the picker needs to know about a configured provider to emit its
/// sidebar group — including providers that currently have no models
/// (disconnected, connecting, failed) so the user can see and fix them
/// without leaving the picker. Built by the view from
/// `RemoteProviderManager`; kept as a plain value so grouping stays testable.
struct ModelPickerProviderDescriptor: Equatable {
    let id: UUID
    let name: String
    let status: ModelPickerGroup.Status
    /// SF Symbol (from `ProviderPreset.icon`) when a preset matches.
    var icon: String? = nil
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

    var videoGenerationDelegateCandidates: [ModelPickerItem] {
        filter(\.isVideoGenerationDelegateCandidate)
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

    /// Group models into picker sidebar groups, in display order:
    ///
    /// 1. Favorites — every model whose favorite key is in `favoriteKeys`,
    ///    in the order the models appear across the other groups. Emitted
    ///    whenever any other group exists (possibly empty, so the sidebar
    ///    can explain how to star a model).
    /// 2. On this Mac — Foundation first, then on-device models by name.
    ///    Omitted when there are none.
    /// 3. Osaurus Cloud — the managed router provider, pinned ahead of
    ///    user-configured providers.
    /// 4. One group per entry in `providers`, in that order, *including*
    ///    providers with no models (disconnected / connecting / failed) so
    ///    the user can see and reconnect them without leaving the picker.
    ///    Remote models whose provider is not in `providers` (e.g. a
    ///    descriptor list that hasn't caught up yet, or tests) follow in
    ///    first-appearance order.
    /// 5. Claude Code — its own group rather than On this Mac: the CLI is
    ///    local but inference is not.
    func groupedIntoPickerGroups(
        providers: [ModelPickerProviderDescriptor] = [],
        favoriteKeys: Set<String> = [],
        osaurusRouterProviderId: UUID = RemoteProviderManager.osaurusRouterProviderId
    ) -> [ModelPickerGroup] {
        var foundationModels: [ModelPickerItem] = []
        var localModels: [ModelPickerItem] = []
        var claudeCodeModels: [ModelPickerItem] = []
        // Keyed by provider id; insertion order preserved separately so
        // provider groups without a descriptor keep a stable order matching
        // the incoming options array.
        var remoteModels: [UUID: [ModelPickerItem]] = [:]
        var remoteOrder: [(id: UUID, title: String)] = []

        for model in self {
            // AppleScript bundles surface only in the dedicated AppleScript
            // model picker, never the chat model picker.
            if model.isAppleScriptCatalogModel { continue }
            switch model.source {
            case .foundation:
                foundationModels.append(model)
            case .local, .imageGeneration:
                // On-device image models live alongside on-device LLMs.
                localModels.append(model)
            case .claudeCode:
                claudeCodeModels.append(model)
            case .remote(let providerName, let providerId):
                if remoteModels[providerId] == nil {
                    remoteOrder.append((id: providerId, title: providerName))
                }
                remoteModels[providerId, default: []].append(model)
            }
        }

        let byName: (ModelPickerItem, ModelPickerItem) -> Bool = {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        var groups: [ModelPickerGroup] = []
        groups.reserveCapacity(remoteOrder.count + providers.count + 3)

        if !foundationModels.isEmpty || !localModels.isEmpty {
            groups.append(
                ModelPickerGroup(
                    key: ModelPickerGroup.localKey,
                    title: L("On this Mac"),
                    kind: .local,
                    models: foundationModels + localModels.sorted(by: byName),
                    icon: "desktopcomputer"
                )
            )
        }

        // Osaurus Cloud: pinned right after On this Mac whether or not the
        // descriptor list mentions it (it's a managed provider).
        let routerDescriptor = providers.first { $0.id == osaurusRouterProviderId }
        let routerModels = remoteModels[osaurusRouterProviderId] ?? []
        if routerDescriptor != nil || !routerModels.isEmpty {
            groups.append(
                ModelPickerGroup(
                    key: ModelPickerGroup.key(forProviderId: osaurusRouterProviderId),
                    title: L("Osaurus Cloud"),
                    kind: .osaurusCloud,
                    models: routerModels.sorted(by: byName),
                    status: routerDescriptor?.status ?? (routerModels.isEmpty ? .none : .connected),
                    icon: "cloud.fill"
                )
            )
        }

        var emitted: Set<UUID> = [osaurusRouterProviderId]
        for descriptor in providers where !emitted.contains(descriptor.id) {
            emitted.insert(descriptor.id)
            let models = (remoteModels[descriptor.id] ?? []).sorted(by: byName)
            groups.append(
                ModelPickerGroup(
                    key: ModelPickerGroup.key(forProviderId: descriptor.id),
                    title: descriptor.name,
                    kind: .remote(providerId: descriptor.id),
                    models: models,
                    status: descriptor.status,
                    icon: descriptor.icon ?? "cloud"
                )
            )
        }
        for entry in remoteOrder where !emitted.contains(entry.id) {
            emitted.insert(entry.id)
            guard let models = remoteModels[entry.id], !models.isEmpty else { continue }
            groups.append(
                ModelPickerGroup(
                    key: ModelPickerGroup.key(forProviderId: entry.id),
                    title: entry.title,
                    kind: .remote(providerId: entry.id),
                    models: models.sorted(by: byName),
                    status: .connected,
                    icon: "cloud"
                )
            )
        }

        if !claudeCodeModels.isEmpty {
            groups.append(
                ModelPickerGroup(
                    key: ModelPickerGroup.claudeCodeKey,
                    title: ModelPickerItem.Source.claudeCode.displayName,
                    kind: .claudeCode,
                    models: claudeCodeModels,
                    icon: "terminal.fill"
                )
            )
        }

        guard !groups.isEmpty else { return [] }

        // Favorites: walk the groups in display order so the Favorites list
        // mirrors where each model lives; dedupe by favorite key.
        var favorites: [ModelPickerItem] = []
        var seenFavoriteKeys: Set<String> = []
        for group in groups {
            for model in group.models {
                let key = FavoriteModelsStore.key(sourceKey: model.source.uniqueKey, modelId: model.id)
                guard favoriteKeys.contains(key), !seenFavoriteKeys.contains(key) else { continue }
                seenFavoriteKeys.insert(key)
                favorites.append(model)
            }
        }
        groups.insert(
            ModelPickerGroup(
                key: ModelPickerGroup.favoritesKey,
                title: L("Favorites"),
                kind: .favorites,
                models: favorites,
                icon: "star.fill"
            ),
            at: 0
        )

        return groups
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
