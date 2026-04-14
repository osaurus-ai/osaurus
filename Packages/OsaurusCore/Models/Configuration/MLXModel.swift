//
//  MLXModel.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation

/// Represents an MLX-compatible LLM that can be downloaded and used
struct MLXModel: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let downloadURL: String

    /// Whether this model should appear at the top of the suggested models list
    let isTopSuggestion: Bool

    /// Approximate download size in bytes (optional, for display purposes)
    let downloadSizeBytes: Int64?

    /// The model_type from config.json (e.g. "gemma4", "qwen3_5_moe").
    /// Set on curated entries to enable pre-download VLM detection via VLMTypeRegistry.
    let modelType: String?

    // When non-nil, pins the model to a specific directory (used by tests).
    // When nil, `localDirectory` resolves dynamically so that user-selected
    // storage path changes are always respected.
    private let rootDirectory: URL?

    init(
        id: String,
        name: String,
        description: String,
        downloadURL: String,
        isTopSuggestion: Bool = false,
        downloadSizeBytes: Int64? = nil,
        modelType: String? = nil,
        rootDirectory: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.downloadURL = downloadURL
        self.isTopSuggestion = isTopSuggestion
        self.downloadSizeBytes = downloadSizeBytes
        self.modelType = modelType
        self.rootDirectory = rootDirectory
    }

    /// Formatted download size string (e.g., "3.9 GB")
    var formattedDownloadSize: String? {
        guard let bytes = totalSizeEstimateBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    /// Best estimate of the total model size in bytes.
    /// Uses explicit downloadSizeBytes if available, otherwise estimates based on parameters/quantization.
    var totalSizeEstimateBytes: Int64? {
        if let bytes = downloadSizeBytes { return bytes }

        // Estimate based on params and quantization (without the runtime overhead multiplier)
        if let params = parameterCountBillions {
            return Int64(params * bytesPerParameter * 1024 * 1024 * 1024)
        }

        return nil
    }

    /// Local directory where this model should be stored.
    /// Resolves against the current effective models directory unless an
    /// explicit `rootDirectory` was provided at init (e.g. in tests).
    var localDirectory: URL {
        let baseDir = rootDirectory ?? DirectoryPickerService.effectiveModelsDirectory()
        let components = id.split(separator: "/").map(String.init)
        return components.reduce(baseDir) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    /// Check if model is downloaded
    /// A model is considered complete if:
    /// - Core config exists: config.json
    /// - Tokenizer assets exist in ANY of the supported variants:
    ///   - tokenizer.json (HF consolidated JSON)
    ///   - BPE: merges.txt + (vocab.json OR vocab.txt)
    ///   - SentencePiece: tokenizer.model OR spiece.model
    /// - At least one *.safetensors file exists (weights)
    var isDownloaded: Bool {
        let fileManager = FileManager.default
        let directory = localDirectory

        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }

        // Core config
        guard exists("config.json") else { return false }

        // Tokenizer variants
        let hasTokenizerJSON = exists("tokenizer.json")
        let hasBPE = exists("merges.txt") && (exists("vocab.json") || exists("vocab.txt"))
        let hasSentencePiece = exists("tokenizer.model") || exists("spiece.model")
        let hasTokenizerAssets = hasTokenizerJSON || hasBPE || hasSentencePiece
        guard hasTokenizerAssets else { return false }

        // Weights
        if let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            let hasWeights = items.contains { $0.pathExtension == "safetensors" }
            return hasWeights
        }
        return false
    }

    /// Approximate download timestamp based on directory creation/modification time
    /// Newer downloads should have more recent dates.
    var downloadedAt: Date? {
        let directory = localDirectory
        let values = try? directory.resourceValues(forKeys: [
            .creationDateKey, .contentModificationDateKey,
        ])
        return values?.creationDate ?? values?.contentModificationDate
    }

    // MARK: - Metadata Extraction

    var parameterCount: String? { ModelMetadataParser.parameterCount(from: id) }
    var quantization: String? { ModelMetadataParser.quantization(from: id) }

    /// Whether this model supports vision/multimodal input.
    /// For downloaded models, checks vision_config in config.json.
    /// For undownloaded models, checks modelType against VLMTypeRegistry.
    var isVLM: Bool {
        if isDownloaded { return VLMDetection.isVLM(at: localDirectory) }
        if let mt = modelType { return VLMDetection.isVLM(modelType: mt) }
        return VLMDetection.isVLM(modelId: id)
    }

    /// Extracts the model family from the name/id (e.g., "Llama", "Qwen", "Gemma", "Phi")
    var family: String {
        let name = self.name.lowercased()

        // 1. Check for common families first (strong matches)
        let strongMatches = [
            "llama": "Llama",
            "qwen": "Qwen",
            "gemma": "Gemma",
            "phi": "Phi",
            "mistral": "Mistral",
            "mixtral": "Mixtral",
            "deepseek": "DeepSeek",
            "nemotron": "Nemotron",
            "command-r": "Command-R",
            "grok": "Grok",
            "yi": "Yi",
            "falcon": "Falcon",
            "internlm": "InternLM",
            "stablelm": "StableLM",
            "smollm": "SmolLM",
            "hermes": "Hermes",
            "liquid": "Liquid",
            "lfm": "Liquid",
            "starcoder": "StarCoder",
            "granite": "Granite",
            "exat": "Exat",
            "opcoder": "OpCoder",
            "opencoder": "OpenCoder",
        ]

        for (key, value) in strongMatches {
            if name.contains(key) { return value }
        }

        // 2. Fallback heuristic: clean up the name and take the first part
        // Remove common vendor prefixes
        var cleaned = self.name
        let prefixes = [
            "Meta-", "Google-", "Mistral-", "MistralAI-", "Microsoft-", "NousResearch-", "Qwen-", "DeepSeek-",
        ]
        for prefix in prefixes {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                break
            }
        }

        // Take first semantic part (before dash or dot)
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: "-. "))
        if let first = parts.first, !first.isEmpty {
            // Filter out junk or purely numeric parts
            if first.rangeOfCharacter(from: .letters) != nil {
                return first.capitalized
            }
        }

        return "Other"
    }

    // MARK: - Memory Estimation & Hardware Compatibility

    private static let bytesPerGB: Double = 1024 * 1024 * 1024
    private static let overheadMultiplier: Double = 1.2

    /// Numeric parameter count in billions (e.g. "7B" -> 7.0, "270M" -> 0.27)
    var parameterCountBillions: Double? {
        guard let params = parameterCount else { return nil }
        let text = params.uppercased()
        guard let num = Double(text.dropLast()) else { return nil }
        return text.hasSuffix("M") ? num / 1000.0 : num
    }

    /// Bytes per parameter based on the quantization extracted from the model name.
    private var bytesPerParameter: Double {
        guard let quant = quantization?.lowercased() else { return 0.5 }

        let bitWidths: [(String, Double)] = [
            ("2-bit", 0.25), ("3-bit", 0.375), ("4-bit", 0.5),
            ("5-bit", 0.625), ("6-bit", 0.75), ("8-bit", 1.0),
        ]
        for (label, bytes) in bitWidths {
            if quant.contains(label) { return bytes }
        }

        switch quant {
        case "fp16", "bf16": return 2.0
        case "fp32": return 4.0
        default: return 0.5
        }
    }

    /// Estimated memory required to run this model (in GB), including overhead
    /// for KV cache, activations, and runtime buffers.
    var estimatedMemoryGB: Double? {
        if let params = parameterCountBillions {
            return params * bytesPerParameter * 1e9 * Self.overheadMultiplier / Self.bytesPerGB
        }
        if let dlBytes = downloadSizeBytes {
            return Double(dlBytes) * Self.overheadMultiplier / Self.bytesPerGB
        }
        return nil
    }

    /// Formatted estimated memory string (e.g. "~3.5 GB")
    var formattedEstimatedMemory: String? {
        guard let gb = estimatedMemoryGB else { return nil }
        return gb < 1.0
            ? String(format: "~%.0f MB", gb * 1024)
            : String(format: "~%.1f GB", gb)
    }

    /// Assess whether this model can run on the given hardware.
    func compatibility(totalMemoryGB: Double) -> ModelCompatibility {
        guard let required = estimatedMemoryGB, totalMemoryGB > 0 else { return .unknown }
        let ratio = required / totalMemoryGB
        if ratio < 0.75 { return .compatible }
        if ratio < 0.95 { return .tight }
        return .tooLarge
    }
}

/// Hardware compatibility assessment for a model.
enum ModelCompatibility {
    case compatible
    case tight
    case tooLarge
    case unknown
}

/// Download state for tracking progress
enum DownloadState: Equatable {
    case notStarted
    case downloading(progress: Double)
    case completed
    case failed(error: String)
}
