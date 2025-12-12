//
//  ModelInfo.swift
//  osaurus
//
//  Provides detailed model metadata for the show command and API endpoint.
//

import Foundation

/// Detailed model information extracted from config files
struct ModelInfo: Codable, Sendable {
    /// Model name/identifier
    let name: String

    /// Model details section
    let model: ModelDetails

    /// Capabilities section
    let capabilities: [String]

    /// Generation parameters section
    let parameters: ModelParameters

    /// Ollama-compatible model details
    struct ModelDetails: Codable, Sendable {
        let architecture: String?
        let parameters: String?
        let contextLength: Int?
        let embeddingLength: Int?
        let quantization: String?

        private enum CodingKeys: String, CodingKey {
            case architecture
            case parameters
            case contextLength = "context_length"
            case embeddingLength = "embedding_length"
            case quantization
        }
    }

    /// Generation parameters from generation_config.json or defaults
    struct ModelParameters: Codable, Sendable {
        let temperature: Double?
        let topP: Double?
        let topK: Int?
        let stop: [String]?
        let repeatPenalty: Double?

        private enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "top_p"
            case topK = "top_k"
            case stop
            case repeatPenalty = "repeat_penalty"
        }
    }
}

// MARK: - Model Info Extraction

extension ModelInfo {
    /// Load model info from a model identifier (e.g., "mlx-community/Qwen3-1.7B-4bit" or "qwen3-1.7b-4bit")
    static func load(modelId: String) -> ModelInfo? {
        // Try to find the model directory
        guard let directory = findModelDirectory(for: modelId) else {
            return nil
        }

        return load(from: directory, modelId: modelId)
    }

    /// Load model info from a local directory
    static func load(from directory: URL, modelId: String) -> ModelInfo? {
        let configURL = directory.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configURL),
            let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
        else {
            return nil
        }

        // Extract architecture
        let architecture = extractArchitecture(from: config)

        // Extract context length
        let contextLength = extractContextLength(from: config)

        // Extract embedding length (hidden size)
        let embeddingLength = extractEmbeddingLength(from: config)

        // Extract parameter count from model name or compute from config
        let parameterCount = extractParameterCount(from: modelId, config: config)

        // Extract quantization from model name
        let quantization = extractQuantization(from: modelId)

        // Detect capabilities
        var capabilities = ["completion"]
        if ModelManager.isVisionModel(at: directory) {
            capabilities.append("vision")
        }

        // Load generation parameters
        let parameters = loadGenerationParameters(from: directory)

        let details = ModelDetails(
            architecture: architecture,
            parameters: parameterCount,
            contextLength: contextLength,
            embeddingLength: embeddingLength,
            quantization: quantization
        )

        return ModelInfo(
            name: modelId,
            model: details,
            capabilities: capabilities,
            parameters: parameters
        )
    }

    // MARK: - Private Helpers

    private static func findModelDirectory(for modelId: String) -> URL? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let root = DirectoryPickerService.effectiveModelsDirectory()
        let fm = FileManager.default

        // If modelId contains "/", try as full path (org/repo)
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/").map(String.init)
            let url = parts.reduce(root) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }
            if fm.fileExists(atPath: url.appendingPathComponent("config.json").path) {
                return url
            }
        }

        // Try to find by repo name only (search all org directories)
        let lowerName = trimmed.lowercased()
        if let orgDirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for orgURL in orgDirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: orgURL.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                if let repos = try? fm.contentsOfDirectory(
                    at: orgURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for repoURL in repos {
                        let repoName = repoURL.lastPathComponent.lowercased()
                        if repoName == lowerName {
                            if fm.fileExists(atPath: repoURL.appendingPathComponent("config.json").path) {
                                return repoURL
                            }
                        }
                    }
                }
            }
        }

        return nil
    }

    private static func extractArchitecture(from config: [String: Any]) -> String? {
        // Try model_type first (most common)
        if let modelType = config["model_type"] as? String {
            return modelType
        }

        // Try architectures array
        if let architectures = config["architectures"] as? [String], let first = architectures.first {
            // Remove "ForCausalLM" suffix if present
            return
                first
                .replacingOccurrences(of: "ForCausalLM", with: "")
                .replacingOccurrences(of: "ForConditionalGeneration", with: "")
        }

        return nil
    }

    private static func extractContextLength(from config: [String: Any]) -> Int? {
        // Try various keys used by different models
        let contextKeys = [
            "max_position_embeddings",
            "max_seq_len",
            "max_sequence_length",
            "n_positions",
            "seq_length",
            "context_length",
            "sliding_window",
        ]

        for key in contextKeys {
            if let value = config[key] as? Int {
                return value
            }
        }

        // Check text_config for VLM models
        if let textConfig = config["text_config"] as? [String: Any] {
            for key in contextKeys {
                if let value = textConfig[key] as? Int {
                    return value
                }
            }
        }

        return nil
    }

    private static func extractEmbeddingLength(from config: [String: Any]) -> Int? {
        // Try hidden_size first (most common)
        if let hiddenSize = config["hidden_size"] as? Int {
            return hiddenSize
        }

        // Try d_model (for some transformer variants)
        if let dModel = config["d_model"] as? Int {
            return dModel
        }

        // Try n_embd (GPT-style)
        if let nEmbd = config["n_embd"] as? Int {
            return nEmbd
        }

        // Check text_config for VLM models
        if let textConfig = config["text_config"] as? [String: Any] {
            if let hiddenSize = textConfig["hidden_size"] as? Int {
                return hiddenSize
            }
        }

        return nil
    }

    private static func extractParameterCount(from modelId: String, config: [String: Any]) -> String? {
        let lowerId = modelId.lowercased()

        // Try to extract from model name/id using regex patterns
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
                let range = NSRange(lowerId.startIndex..., in: lowerId)
                if let match = regex.firstMatch(in: lowerId, options: [], range: range) {
                    if let numRange = Range(match.range(at: 1), in: lowerId) {
                        let number = String(lowerId[numRange])
                        // Determine unit (B or M)
                        let fullMatch = String(lowerId[Range(match.range, in: lowerId)!]).uppercased()
                        let unit = fullMatch.contains("M") ? "M" : "B"
                        return "\(number)\(unit)"
                    }
                }
            }
        }

        return nil
    }

    private static func extractQuantization(from modelId: String) -> String? {
        let lowerId = modelId.lowercased()

        // Check for bit patterns: 4bit, 4-bit, 8bit, 8-bit, etc.
        if let regex = try? NSRegularExpression(pattern: #"(\d+)-?bit"#, options: .caseInsensitive) {
            let range = NSRange(lowerId.startIndex..., in: lowerId)
            if let match = regex.firstMatch(in: lowerId, options: [], range: range) {
                if let numRange = Range(match.range(at: 1), in: lowerId) {
                    return "Q\(lowerId[numRange])_0"
                }
            }
        }

        // Check for GGUF-style quantization patterns
        let quantPatterns = [
            ("q4_0", "Q4_0"),
            ("q4_k_m", "Q4_K_M"),
            ("q8_0", "Q8_0"),
            ("q8_k_m", "Q8_K_M"),
            ("fp16", "FP16"),
            ("bf16", "BF16"),
            ("fp32", "FP32"),
        ]

        for (pattern, result) in quantPatterns {
            if lowerId.contains(pattern) {
                return result
            }
        }

        return nil
    }

    private static func loadGenerationParameters(from directory: URL) -> ModelParameters {
        let generationConfigURL = directory.appendingPathComponent("generation_config.json")

        var temperature: Double?
        var topP: Double?
        var topK: Int?
        var stop: [String]?
        var repeatPenalty: Double?

        if let data = try? Data(contentsOf: generationConfigURL),
            let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            temperature = config["temperature"] as? Double
            topP = config["top_p"] as? Double
            topK = config["top_k"] as? Int
            repeatPenalty = config["repetition_penalty"] as? Double

            // Extract stop sequences (eos_token_id or stop_strings)
            if let stopStrings = config["stop_strings"] as? [String] {
                stop = stopStrings
            } else if let eosToken = config["eos_token"] as? String {
                stop = [eosToken]
            }
        }

        return ModelParameters(
            temperature: temperature,
            topP: topP,
            topK: topK,
            stop: stop,
            repeatPenalty: repeatPenalty
        )
    }
}

// MARK: - Ollama-compatible response format

/// Request body for /api/show endpoint
struct ShowRequest: Codable, Sendable {
    let name: String
}

/// Response body for /api/show endpoint (Ollama-compatible)
struct ShowResponse: Codable, Sendable {
    let modelfile: String
    let parameters: String
    let template: String
    let details: ShowDetails
    let modelInfo: [String: AnyCodable]

    private enum CodingKeys: String, CodingKey {
        case modelfile
        case parameters
        case template
        case details
        case modelInfo = "model_info"
    }

    struct ShowDetails: Codable, Sendable {
        let parentModel: String
        let format: String
        let family: String
        let families: [String]
        let parameterSize: String
        let quantizationLevel: String

        private enum CodingKeys: String, CodingKey {
            case parentModel = "parent_model"
            case format
            case family
            case families
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }
    }
}

/// Type-erased Codable wrapper for heterogeneous JSON values
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Show Response Builder

extension ModelInfo {
    /// Convert ModelInfo to Ollama-compatible ShowResponse
    func toShowResponse() -> ShowResponse {
        // Build parameters string (Ollama format)
        var paramLines: [String] = []
        if let temp = parameters.temperature {
            paramLines.append("temperature \(temp)")
        }
        if let topP = parameters.topP {
            paramLines.append("top_p \(topP)")
        }
        if let topK = parameters.topK {
            paramLines.append("top_k \(topK)")
        }
        if let stops = parameters.stop {
            for s in stops {
                paramLines.append("stop \"\(s)\"")
            }
        }
        if let repeat_penalty = parameters.repeatPenalty {
            paramLines.append("repeat_penalty \(repeat_penalty)")
        }

        // Build model_info dictionary
        var modelInfoDict: [String: AnyCodable] = [:]
        if let arch = model.architecture {
            modelInfoDict["general.architecture"] = AnyCodable(arch)
        }
        if let params = model.parameters {
            modelInfoDict["general.parameter_count"] = AnyCodable(params)
        }
        if let ctx = model.contextLength {
            modelInfoDict["\(model.architecture ?? "model").context_length"] = AnyCodable(ctx)
        }
        if let embed = model.embeddingLength {
            modelInfoDict["\(model.architecture ?? "model").embedding_length"] = AnyCodable(embed)
        }

        let details = ShowResponse.ShowDetails(
            parentModel: "",
            format: "safetensors",
            family: model.architecture ?? "unknown",
            families: [model.architecture ?? "unknown"],
            parameterSize: model.parameters ?? "",
            quantizationLevel: model.quantization ?? ""
        )

        return ShowResponse(
            modelfile: "",
            parameters: paramLines.joined(separator: "\n"),
            template: "",
            details: details,
            modelInfo: modelInfoDict
        )
    }
}
