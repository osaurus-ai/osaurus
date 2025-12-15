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

    // Capture the models root directory at initialization time to avoid
    // relying on a mutable global during tests or concurrent execution.
    private let rootDirectory: URL

    init(
        id: String,
        name: String,
        description: String,
        downloadURL: String,
        isTopSuggestion: Bool = false,
        rootDirectory: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.downloadURL = downloadURL
        self.isTopSuggestion = isTopSuggestion
        self.rootDirectory = rootDirectory ?? DirectoryPickerService.effectiveModelsDirectory()
    }

    /// Local directory where this model should be stored
    var localDirectory: URL {
        // Build the path using each component of the repository id separately.
        let components = id.split(separator: "/").map(String.init)
        return components.reduce(rootDirectory) { partial, component in
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

    /// Extracts parameter count from model name/id (e.g., "1.7B", "7B", "30B", "235B")
    var parameterCount: String? {
        let text = id.lowercased()
        // Match patterns like: 1.7b, 7b, 30b, 235b, 270m, 120b, etc.
        // Also handles formats like "3n-E4B" (Gemma 3n) or "A22B" (MoE active params)
        let patterns = [
            #"(\d+\.?\d*)[bm](?:-|$|\s|[^a-z])"#,  // Standard: 7b, 1.7b, 270m
            #"(\d+\.?\d*)b-"#,  // With suffix: 7b-instruct
            #"-(\d+\.?\d*)[bm]-"#,  // Middle: llama-7b-instruct
            #"[- ](\d+\.?\d*)[bm]$"#,  // End: model-7b
            #"e(\d+)[bm]"#,  // Gemma style: E4B
            #"a(\d+)[bm]"#,  // MoE active: A22B
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, options: [], range: range) {
                    if let numRange = Range(match.range(at: 1), in: text) {
                        let number = String(text[numRange])
                        // Determine unit (B or M)
                        let fullMatch = String(text[Range(match.range, in: text)!]).uppercased()
                        let unit = fullMatch.contains("M") ? "M" : "B"
                        return "\(number)\(unit)"
                    }
                }
            }
        }
        return nil
    }

    /// Extracts quantization level from model name/id (e.g., "4-bit", "8-bit", "fp16")
    var quantization: String? {
        let text = id.lowercased()

        // Check for bit patterns: 4bit, 4-bit, 8bit, 8-bit, etc.
        if let regex = try? NSRegularExpression(pattern: #"(\d+)-?bit"#, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range) {
                if let numRange = Range(match.range(at: 1), in: text) {
                    return "\(text[numRange])-bit"
                }
            }
        }

        // Check for precision formats: fp16, bf16, fp32
        if text.contains("fp16") { return "FP16" }
        if text.contains("bf16") { return "BF16" }
        if text.contains("fp32") { return "FP32" }

        return nil
    }

    /// Determines if this model is a Vision Language Model (VLM) based on name heuristics
    /// For downloaded models, use ModelManager.isVisionModel() for accurate detection
    var isLikelyVLM: Bool {
        let lowerId = id.lowercased()
        let vlmIndicators = [
            "-vl-", "-vl", "vl-",  // Qwen2-VL, Kimi-VL
            "llava",  // LLaVA family
            "pixtral",  // Mistral's vision model
            "paligemma",  // Google's VLM
            "idefics",  // HF's VLM
            "internvl",  // InternVL
            "cogvlm",  // CogVLM
            "minicpm-v",  // MiniCPM-V
            "phi3-v", "phi-3-v",  // Phi-3-Vision
            "florence",  // Florence
            "blip",  // BLIP family
            "instructblip",  // InstructBLIP
            "vision",  // Generic vision indicator
        ]
        return vlmIndicators.contains { lowerId.contains($0) }
    }

    /// Model type enum for display purposes
    enum ModelType: String {
        case llm = "LLM"
        case vlm = "VLM"
    }

    /// Returns the model type based on heuristics
    var modelType: ModelType {
        isLikelyVLM ? .vlm : .llm
    }
}

/// Download state for tracking progress
enum DownloadState: Equatable {
    case notStarted
    case downloading(progress: Double)
    case completed
    case failed(error: String)
}
