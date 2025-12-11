//
//  ModelOption.swift
//  osaurus
//
//  Rich model option for the model picker with metadata and source information.
//

import Foundation

/// Represents a model option in the model picker with rich metadata
struct ModelOption: Identifiable, Hashable {
    /// The source/provider of the model
    enum Source: Hashable {
        case foundation
        case local  // MLX models
        case remote(providerName: String, providerId: UUID)

        var displayName: String {
            switch self {
            case .foundation:
                return "Foundation"
            case .local:
                return "Local Models"
            case .remote(let providerName, _):
                return providerName
            }
        }

        var sortOrder: Int {
            switch self {
            case .foundation:
                return 0
            case .local:
                return 1
            case .remote:
                return 2
            }
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

    /// Description of the model (optional)
    let description: String?

    init(
        id: String,
        displayName: String,
        source: Source,
        parameterCount: String? = nil,
        quantization: String? = nil,
        isVLM: Bool = false,
        description: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.isVLM = isVLM
        self.description = description
    }

    /// Check if model matches search query
    func matches(searchQuery: String) -> Bool {
        let query = searchQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        // Match against display name, id, or provider name
        if displayName.lowercased().contains(query) { return true }
        if id.lowercased().contains(query) { return true }
        if source.displayName.lowercased().contains(query) { return true }

        return false
    }
}

// MARK: - Factory Methods

extension ModelOption {
    /// Create a Foundation model option
    static func foundation() -> ModelOption {
        ModelOption(
            id: "foundation",
            displayName: "Foundation",
            source: .foundation,
            description: "Apple's built-in on-device model"
        )
    }

    /// Create a local MLX model option from an MLXModel
    static func fromMLXModel(_ model: MLXModel) -> ModelOption {
        ModelOption(
            id: model.id,
            displayName: model.name,
            source: .local,
            parameterCount: model.parameterCount,
            quantization: model.quantization,
            isVLM: model.isLikelyVLM,
            description: model.description
        )
    }

    /// Create a local MLX model option from just the model name (fallback)
    static func fromLocalModelName(_ name: String, fullId: String) -> ModelOption {
        // Try to extract metadata from the name
        let paramCount = extractParameterCount(from: fullId)
        let quant = extractQuantization(from: fullId)
        let isVLM = detectVLM(from: fullId)

        return ModelOption(
            id: fullId,
            displayName: formatDisplayName(name),
            source: .local,
            parameterCount: paramCount,
            quantization: quant,
            isVLM: isVLM
        )
    }

    /// Create a remote provider model option
    static func fromRemoteModel(
        modelId: String,
        providerName: String,
        providerId: UUID
    ) -> ModelOption {
        // Remote model IDs are prefixed like "provider-name/model-id"
        let displayName: String
        if let slashIndex = modelId.lastIndex(of: "/") {
            displayName = String(modelId[modelId.index(after: slashIndex)...])
        } else {
            displayName = modelId
        }

        return ModelOption(
            id: modelId,
            displayName: displayName,
            source: .remote(providerName: providerName, providerId: providerId)
        )
    }

    // MARK: - Private Helpers

    private static func formatDisplayName(_ name: String) -> String {
        // Convert repo name to readable format
        let spaced = name.replacingOccurrences(of: "-", with: " ")
        return
            spaced
            .replacingOccurrences(of: "llama", with: "Llama", options: .caseInsensitive)
            .replacingOccurrences(of: "qwen", with: "Qwen", options: .caseInsensitive)
            .replacingOccurrences(of: "gemma", with: "Gemma", options: .caseInsensitive)
            .replacingOccurrences(of: "deepseek", with: "DeepSeek", options: .caseInsensitive)
            .replacingOccurrences(of: "mistral", with: "Mistral", options: .caseInsensitive)
            .replacingOccurrences(of: "phi", with: "Phi", options: .caseInsensitive)
    }

    private static func extractParameterCount(from text: String) -> String? {
        let lowered = text.lowercased()
        let patterns = [
            #"(\d+\.?\d*)[bm](?:-|$|\s|[^a-z])"#,
            #"(\d+\.?\d*)b-"#,
            #"-(\d+\.?\d*)[bm]-"#,
            #"[- ](\d+\.?\d*)[bm]$"#,
            #"e(\d+)[bm]"#,
            #"a(\d+)[bm]"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(lowered.startIndex..., in: lowered)
                if let match = regex.firstMatch(in: lowered, options: [], range: range) {
                    if let numRange = Range(match.range(at: 1), in: lowered) {
                        let number = String(lowered[numRange])
                        let fullMatch = String(lowered[Range(match.range, in: lowered)!]).uppercased()
                        let unit = fullMatch.contains("M") ? "M" : "B"
                        return "\(number)\(unit)"
                    }
                }
            }
        }
        return nil
    }

    private static func extractQuantization(from text: String) -> String? {
        let lowered = text.lowercased()

        if let regex = try? NSRegularExpression(pattern: #"(\d+)-?bit"#, options: .caseInsensitive) {
            let range = NSRange(lowered.startIndex..., in: lowered)
            if let match = regex.firstMatch(in: lowered, options: [], range: range) {
                if let numRange = Range(match.range(at: 1), in: lowered) {
                    return "\(lowered[numRange])-bit"
                }
            }
        }

        if lowered.contains("fp16") { return "FP16" }
        if lowered.contains("bf16") { return "BF16" }
        if lowered.contains("fp32") { return "FP32" }

        return nil
    }

    private static func detectVLM(from text: String) -> Bool {
        let lowered = text.lowercased()
        let indicators = [
            "-vl-", "-vl", "vl-",
            "llava",
            "pixtral",
            "paligemma",
            "idefics",
            "internvl",
            "cogvlm",
            "minicpm-v",
            "phi3-v", "phi-3-v",
            "florence",
            "blip",
            "instructblip",
            "vision",
        ]
        return indicators.contains { lowered.contains($0) }
    }
}

// MARK: - Grouping

extension Array where Element == ModelOption {
    /// Group models by source for display in sections
    func groupedBySource() -> [(source: ModelOption.Source, models: [ModelOption])] {
        var groups: [ModelOption.Source: [ModelOption]] = [:]

        for model in self {
            groups[model.source, default: []].append(model)
        }

        // Sort groups by source order, then sort models within each group
        return
            groups
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { (source: $0.key, models: $0.value.sorted { $0.displayName < $1.displayName }) }
    }
}
