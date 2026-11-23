//
//  EmbeddingProfile.swift
//  osaurus
//
//  The embedding model every semantic index in the process is built with.
//  Resolved once at launch from Model Defaults → Embedding Model; changing
//  the setting takes effect on the next launch, because every Vectura index
//  is opened against one fixed dimension and vector space.
//

import Foundation

/// Which runtime produces the vectors.
public enum EmbeddingBackend: String, Codable, Sendable {
    /// Static token-embedding lookup (Model2Vec / Potion). No transformer pass.
    case model2vec
    /// Encoder or decoder transformer run through MLXEmbedders.
    case transformer
}

/// Whether the text being embedded is a search query, a stored document, or
/// raw API input. Retrieval models trained with asymmetric prompts need the
/// query and document sides prefixed differently; raw input is embedded as-is.
public enum EmbeddingRole: String, Sendable {
    case query
    case document
    case raw

    @TaskLocal public static var current: EmbeddingRole = .raw
}

/// How token states are reduced to one vector, as declared by the bundle's
/// sentence-transformers pooling config.
public enum EmbeddingPooling: String, Codable, Sendable {
    /// The first token's hidden state. Sentence-transformers "cls" pooling
    /// reads the raw `[CLS]` state, not BERT's tanh pooler head.
    case firstToken
    case mean
    case max
    /// The final non-padding token (decoder embedders such as Qwen3-Embedding).
    case lastToken
}

public struct EmbeddingProfile: Equatable, Sendable {
    /// Repository-style id, e.g. `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`.
    public let modelId: String
    public let backend: EmbeddingBackend
    public let dimension: Int
    /// `config.json` `model_type`, lowercased. `model2vec` for static models.
    public let modelType: String
    public let pooling: EmbeddingPooling
    public let queryPrefix: String
    public let documentPrefix: String
    /// Tokens kept per input after special tokens are added.
    public let maxSequenceLength: Int
    /// Bundle directory. `nil` only for the built-in model, which resolves
    /// its own bundled weights.
    public let directory: URL?
    /// Sum of the bundle's safetensors files, used for Memory Safety admission.
    public let weightBytes: Int64
    /// First position id. RoBERTa-family encoders number positions from
    /// `pad_token_id + 1`; every other family starts at 0.
    public let positionOffset: Int
    /// Transformer depth and attention heads, which size per-pass batches.
    public let layerCount: Int
    public let headCount: Int
    public let isBuiltIn: Bool

    public init(
        modelId: String,
        backend: EmbeddingBackend,
        dimension: Int,
        modelType: String,
        pooling: EmbeddingPooling,
        queryPrefix: String = "",
        documentPrefix: String = "",
        maxSequenceLength: Int = 512,
        directory: URL?,
        weightBytes: Int64 = 0,
        positionOffset: Int = 0,
        layerCount: Int = 12,
        headCount: Int = 12,
        isBuiltIn: Bool = false
    ) {
        self.modelId = modelId
        self.backend = backend
        self.dimension = dimension
        self.modelType = modelType
        self.pooling = pooling
        self.queryPrefix = queryPrefix
        self.documentPrefix = documentPrefix
        self.maxSequenceLength = maxSequenceLength
        self.directory = directory
        self.weightBytes = weightBytes
        self.positionOffset = positionOffset
        self.layerCount = layerCount
        self.headCount = headCount
        self.isBuiltIn = isBuiltIn
    }

    public static let builtInModelId = "minishlab/potion-base-4M"

    public static let builtIn = EmbeddingProfile(
        modelId: builtInModelId,
        backend: .model2vec,
        dimension: 128,
        modelType: "model2vec",
        pooling: .mean,
        directory: nil,
        isBuiltIn: true
    )

    /// The name clients send and receive in the `model` field of the
    /// embeddings APIs: the repository name without its owner.
    public var apiName: String {
        modelId.split(separator: "/").last.map(String.init) ?? modelId
    }

    /// The Vectura directory each search service stores this profile's index
    /// under. The built-in model keeps the original `vectura` name so
    /// existing installs reuse their index; any other profile gets its own
    /// directory, and switching back never reads vectors of another space.
    public var indexDirectoryName: String {
        isBuiltIn ? "vectura" : "vectura-\(Self.slug(modelId))-\(dimension)"
    }

    public func prefix(for role: EmbeddingRole) -> String {
        switch role {
        case .query: return queryPrefix
        case .document: return documentPrefix
        case .raw: return ""
        }
    }

    public static func isBuiltInId(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return lowered == builtInModelId.lowercased()
            || lowered == builtIn.apiName.lowercased()
    }

    static func slug(_ id: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in id.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public enum EmbeddingProfileError: LocalizedError, Equatable, Sendable {
    case modelNotInstalled(modelId: String)
    case unsupportedModel(modelId: String, reason: String)
    case memoryRefused(modelId: String, field: String, message: String)
    case loadFailed(modelId: String, message: String)

    public var modelId: String {
        switch self {
        case .modelNotInstalled(let id), .unsupportedModel(let id, _),
            .memoryRefused(let id, _, _), .loadFailed(let id, _):
            return id
        }
    }

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let id):
            return
                "The embedding model \(id) is not installed. Download it from Local Models → Embedding, or switch Model Defaults → Embedding Model back to the built-in model."
        case .unsupportedModel(let id, let reason):
            return "The embedding model \(id) can't run in Osaurus: \(reason)"
        case .memoryRefused(let id, let field, let message):
            return "Memory Safety refused to load the embedding model \(id) (\(field)): \(message)"
        case .loadFailed(let id, let message):
            return "The embedding model \(id) failed to load: \(message)"
        }
    }
}

// MARK: - Bundle metadata

/// What an embedding bundle declares about itself on disk.
struct EmbeddingBundleInfo: Equatable, Sendable {
    var modelType: String?
    var architectures: [String]
    var hiddenSize: Int?
    var maxPositionEmbeddings: Int?
    var padTokenId: Int?
    var layerCount: Int?
    var headCount: Int?
    /// Pooling declared by `1_Pooling/config.json`.
    var declaredPooling: EmbeddingPooling?
    /// `config_sentence_transformers.json` `prompts`.
    var prompts: [String: String]
    /// `sentence_bert_config.json` `max_seq_length`.
    var maxSequenceLength: Int?
    var hasVisionConfig: Bool
    var hasSentenceTransformersMarkers: Bool
    var hasTokenizer: Bool
    var weightBytes: Int64

    var hasWeights: Bool { weightBytes > 0 }

    static func read(at directory: URL) -> EmbeddingBundleInfo? {
        guard let config = jsonObject(directory.appendingPathComponent("config.json")) else { return nil }
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }

        let poolingConfig = jsonObject(directory.appendingPathComponent("1_Pooling/config.json"))
        let stConfig = jsonObject(directory.appendingPathComponent("config_sentence_transformers.json"))
        let sbertConfig = jsonObject(directory.appendingPathComponent("sentence_bert_config.json"))
        let textConfig = config["text_config"] as? [String: Any]

        var prompts: [String: String] = [:]
        if let raw = stConfig?["prompts"] as? [String: Any] {
            for (key, value) in raw {
                if let value = value as? String { prompts[key] = value }
            }
        }

        let hasTokenizer =
            exists("tokenizer.json")
            || exists("tokenizer.model") || exists("spiece.model")
            || (exists("vocab.txt") || exists("vocab.json"))

        return EmbeddingBundleInfo(
            modelType: (config["model_type"] as? String)?.lowercased(),
            architectures: config["architectures"] as? [String] ?? [],
            hiddenSize: int(config["hidden_size"]) ?? int(config["hidden_dim"]) ?? int(config["d_model"])
                ?? int(textConfig?["hidden_size"]),
            maxPositionEmbeddings: int(config["max_position_embeddings"])
                ?? int(textConfig?["max_position_embeddings"]),
            padTokenId: int(config["pad_token_id"]),
            layerCount: int(config["num_hidden_layers"]) ?? int(config["n_layer"])
                ?? int(textConfig?["num_hidden_layers"]),
            headCount: int(config["num_attention_heads"]) ?? int(config["n_head"])
                ?? int(textConfig?["num_attention_heads"]),
            declaredPooling: poolingConfig.flatMap(pooling(from:)),
            prompts: prompts,
            maxSequenceLength: int(sbertConfig?["max_seq_length"]),
            hasVisionConfig: config["vision_config"] != nil,
            hasSentenceTransformersMarkers: exists("modules.json") || poolingConfig != nil || stConfig != nil,
            hasTokenizer: hasTokenizer,
            weightBytes: safetensorsBytes(in: directory)
        )
    }

    /// Sentence-transformers pooling flags. Order matches its own precedence
    /// when more than one flag is set.
    static func pooling(from config: [String: Any]) -> EmbeddingPooling? {
        if let mode = config["pooling_mode"] as? String {
            switch mode.lowercased() {
            case "cls": return .firstToken
            case "mean": return .mean
            case "max": return .max
            case "lasttoken": return .lastToken
            default: break
            }
        }
        if config["pooling_mode_cls_token"] as? Bool == true { return .firstToken }
        if config["pooling_mode_max_tokens"] as? Bool == true { return .max }
        if config["pooling_mode_mean_tokens"] as? Bool == true { return .mean }
        if config["pooling_mode_lasttoken"] as? Bool == true { return .lastToken }
        return nil
    }

    private static func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        return nil
    }

    private static func safetensorsBytes(in directory: URL) -> Int64 {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return 0 }
        return entries.reduce(Int64(0)) { total, url in
            guard url.pathExtension == "safetensors" else { return total }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }
}

// MARK: - Resolution

enum EmbeddingProfileResolver {
    /// Longest input the transformer backend keeps. Long-context embedders
    /// (Qwen3, ModernBERT) advertise 32K+ positions; chunks the indexers
    /// produce are far shorter, and the per-batch token budget bounds memory.
    static let maxSequenceCap = 8192

    /// Resolve the stored selection to a runnable profile. Pure apart from
    /// the bundle reads, so tests drive it with fixture directories.
    static func resolve(
        settings: EmbeddingSettings,
        locate: (String) -> URL? = locateInstalled(modelId:)
    ) -> Result<EmbeddingProfile, EmbeddingProfileError> {
        guard let modelId = settings.selectedModelId, !EmbeddingProfile.isBuiltInId(modelId) else {
            return .success(.builtIn)
        }
        let stored = settings.selectedModelPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let candidates = [stored, locate(modelId)].compactMap { $0 }
        guard
            let directory = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path)
            })
        else {
            return .failure(.modelNotInstalled(modelId: modelId))
        }
        return profile(modelId: modelId, directory: directory, catalogEntry: EmbeddingModelCatalog.entry(for: modelId))
    }

    static func profile(
        modelId: String,
        directory: URL,
        catalogEntry: EmbeddingModelCatalog.Entry?
    ) -> Result<EmbeddingProfile, EmbeddingProfileError> {
        guard let info = EmbeddingBundleInfo.read(at: directory) else {
            return .failure(.modelNotInstalled(modelId: modelId))
        }
        guard info.hasWeights else {
            return .failure(.unsupportedModel(modelId: modelId, reason: "the bundle has no safetensors weights."))
        }
        guard info.hasTokenizer else {
            return .failure(.unsupportedModel(modelId: modelId, reason: "the bundle has no tokenizer."))
        }

        let backend: EmbeddingBackend
        let modelType: String
        switch EmbeddingDetection.runtimeSupport(of: info, directory: directory) {
        case .model2vec:
            backend = .model2vec
            modelType = "model2vec"
        case .transformer(let type):
            backend = .transformer
            modelType = type
        case .unsupported(let reason):
            return .failure(.unsupportedModel(modelId: modelId, reason: reason))
        }

        guard let dimension = info.hiddenSize ?? catalogEntry?.dimension, dimension > 0 else {
            return .failure(
                .unsupportedModel(modelId: modelId, reason: "config.json does not declare a hidden size."))
        }

        let positionOffset =
            ["roberta", "xlm-roberta"].contains(modelType) ? (info.padTokenId ?? 1) + 1 : 0
        let lengths =
            [info.maxSequenceLength, info.maxPositionEmbeddings.map { $0 - positionOffset }]
            .compactMap { $0 }.filter { $0 > 0 }
        let maxSequence = min(lengths.min() ?? 512, maxSequenceCap)

        return .success(
            EmbeddingProfile(
                modelId: modelId,
                backend: backend,
                dimension: dimension,
                modelType: modelType,
                pooling: pooling(modelType: modelType, info: info),
                queryPrefix: info.prompt(for: .query) ?? catalogEntry?.queryPrefix ?? "",
                documentPrefix: info.prompt(for: .document) ?? catalogEntry?.documentPrefix ?? "",
                maxSequenceLength: maxSequence,
                directory: directory,
                weightBytes: info.weightBytes,
                positionOffset: positionOffset,
                layerCount: info.layerCount ?? 12,
                headCount: info.headCount ?? max(dimension / 64, 1)
            ))
    }

    static func pooling(modelType: String, info: EmbeddingBundleInfo) -> EmbeddingPooling {
        if let declared = info.declaredPooling { return declared }
        switch modelType {
        case "qwen3": return .lastToken
        case "modernbert": return .firstToken
        default: return .mean
        }
    }

    /// Where Osaurus keeps a downloaded model, falling back to bundles found
    /// in registered external sources (Hugging Face cache, LM Studio).
    static func locateInstalled(modelId: String) -> URL? {
        let managed = modelId.split(separator: "/").reduce(DirectoryPickerService.effectiveModelsDirectory()) {
            $0.appendingPathComponent(String($1), isDirectory: true)
        }
        if FileManager.default.fileExists(atPath: managed.appendingPathComponent("config.json").path) {
            return managed
        }
        return ExternalModelLocator.path(forId: modelId)
    }
}

extension EmbeddingBundleInfo {
    /// Prompt keys sentence-transformers bundles use for each side of retrieval.
    func prompt(for role: EmbeddingRole) -> String? {
        let keys: [String]
        switch role {
        case .query: keys = ["query", "search_query", "Retrieval-query"]
        case .document: keys = ["document", "passage", "search_document", "corpus", "Retrieval-document"]
        case .raw: return nil
        }
        return keys.lazy.compactMap { prompts[$0] }.first
    }
}
