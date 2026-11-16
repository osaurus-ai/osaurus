//
//  EmbeddingDetection.swift
//  osaurus
//
//  Single source of truth for embedding/encoder-only model detection.
//  Classifies a bundle from its config.json (`architectures` /
//  `model_type`) so embedding repos that arrive via the HF-cache or
//  LM Studio import (e.g. minishlab/potion-base-4M left in the HF cache
//  by older Osaurus builds, sentence-transformers/all-MiniLM-L6-v2 from
//  Python tooling) are not offered as chat models.
//
//  The classifier is deliberately conservative: a bundle is only called
//  an embedding model when its config positively identifies a known
//  encoder-only family. Unknown, missing, or malformed configs stay
//  chat-capable so a novel causal LM is never hidden from the picker.
//

import Foundation

enum EmbeddingDetection {
    // MARK: - Memoization

    // Mirrors VLMDetection: verdicts are pure functions of the on-disk
    // bundle, are read from SwiftUI body evaluations via
    // `MLXModel.isEmbedding`, and each cold call reads + parses
    // config.json synchronously. Cached per directory and dropped on
    // `.localModelsChanged` to stay in sync with downloads/deletions.
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var verdictCache: [String: Bool] = [:]
    private nonisolated(unsafe) static var didInstallObserver = false

    private static func cachedVerdict(_ key: String, compute: () -> Bool) -> Bool {
        ensureCacheObserverInstalled()
        cacheLock.lock()
        if let cached = verdictCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result = compute()

        cacheLock.lock()
        verdictCache[key] = result
        cacheLock.unlock()
        return result
    }

    private static func ensureCacheObserverInstalled() {
        cacheLock.lock()
        let already = didInstallObserver
        didInstallObserver = true
        cacheLock.unlock()
        if already { return }

        NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: nil
        ) { _ in
            EmbeddingDetection.cacheLock.lock()
            EmbeddingDetection.verdictCache.removeAll(keepingCapacity: true)
            EmbeddingDetection.cacheLock.unlock()
        }
    }

    /// Whether the bundle at `directory` is an embedding model. Missing or
    /// unparseable configs return `false`.
    ///
    /// Decoder embedders (Qwen3-Embedding, EmbeddingGemma) declare a causal
    /// architecture, so the config classifier alone would offer them as chat
    /// models. A sentence-transformers layout identifies them first; a vision
    /// config still vetoes. Curated bundles without that layout (the MLX
    /// Qwen3-Embedding conversions) are recognized by `EmbeddingModelCatalog`.
    static func isEmbedding(at directory: URL) -> Bool {
        cachedVerdict("dir:\(directory.path)") {
            guard let json = readConfigJSON(at: directory) else { return false }
            if json["vision_config"] != nil { return false }
            if hasSentenceTransformersMarkers(at: directory) {
                return true
            }
            return isEmbeddingConfig(json)
        }
    }

    static func hasSentenceTransformersMarkers(at directory: URL) -> Bool {
        let fm = FileManager.default
        return ["modules.json", "1_Pooling/config.json", "config_sentence_transformers.json"].contains {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    // MARK: - Runtime support

    enum RuntimeSupport: Equatable, Sendable {
        case model2vec
        case transformer(modelType: String)
        case unsupported(reason: String)

        var isSupported: Bool {
            if case .unsupported = self { return false }
            return true
        }
    }

    /// `model_type` keys MLXEmbedders' model registry creates. The registry
    /// is private to vmlx-swift, so this mirrors its keys exactly.
    static let transformerModelTypes: Set<String> = [
        "bert", "roberta", "xlm-roberta", "distilbert", "nomic_bert", "modernbert",
        "qwen3", "gemma3", "gemma3_text", "gemma3n",
    ]

    /// Registry types whose vmlx-swift implementation can't load real
    /// checkpoints. Refused before load: EmbeddingGemma traps the process,
    /// and every NomicBERT checkpoint fails the weight check.
    static let unloadableModelTypes: [String: String] = {
        let gemma =
            "the MLX EmbeddingGemma implementation in vmlx-swift stops Osaurus while loading its projection layers."
        return [
            "gemma3": gemma,
            "gemma3_text": gemma,
            "gemma3n": gemma,
            "nomic_bert":
                "the MLX NomicBERT implementation in vmlx-swift expects learned position embeddings, but NomicBERT checkpoints use rotary positions.",
        ]
    }()

    /// Whether Osaurus can run the bundle at `directory` as its embedding model.
    static func runtimeSupport(at directory: URL) -> RuntimeSupport {
        guard let info = EmbeddingBundleInfo.read(at: directory) else {
            return .unsupported(reason: "the bundle has no readable config.json.")
        }
        return runtimeSupport(of: info, directory: directory)
    }

    static func runtimeSupport(of info: EmbeddingBundleInfo, directory: URL? = nil) -> RuntimeSupport {
        if info.hasVisionConfig {
            return .unsupported(reason: "vision-language bundles can't be used for text embeddings.")
        }
        guard let modelType = info.modelType else {
            return .unsupported(reason: "config.json does not declare a model_type.")
        }
        if modelType == "model2vec" {
            if let directory {
                let fm = FileManager.default
                let required = ["model.safetensors", "tokenizer.json"]
                guard required.allSatisfy({ fm.fileExists(atPath: directory.appendingPathComponent($0).path) })
                else {
                    return .unsupported(reason: "Model2Vec bundles need model.safetensors and tokenizer.json.")
                }
            }
            return .model2vec
        }
        guard transformerModelTypes.contains(modelType) else {
            return .unsupported(reason: "the \(modelType) architecture isn't supported by the MLX embedding runtime.")
        }
        if let reason = unloadableModelTypes[modelType] {
            return .unsupported(reason: reason)
        }
        return .transformer(modelType: modelType)
    }

    /// Pure classifier over a parsed config.json. Exposed for tests.
    ///
    /// Decision order:
    /// 1. Any generative architecture marker (`*ForCausalLM`,
    ///    `*ForConditionalGeneration`, `*LMHeadModel`, ...) → not embedding.
    /// 2. A `vision_config` block → not embedding (VLM, handled elsewhere).
    /// 3. A known encoder-only `model_type` (bert, model2vec, ...) → embedding.
    /// 4. A non-empty `architectures` list whose entries are all
    ///    encoder-style heads (`*Model`, `*ForMaskedLM`, ...) → embedding.
    /// 5. Anything else → not embedding (stay chat-capable).
    static func isEmbeddingConfig(_ json: [String: Any]) -> Bool {
        let architectures = (json["architectures"] as? [String]) ?? []

        if architectures.contains(where: isGenerativeArchitecture(_:)) {
            return false
        }
        if json["vision_config"] != nil {
            return false
        }

        if let modelType = json["model_type"] as? String {
            let normalized =
                modelType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            if embeddingModelTypes.contains(normalized) {
                return true
            }
        }

        if !architectures.isEmpty,
            architectures.allSatisfy(isEncoderArchitecture(_:))
        {
            return true
        }

        return false
    }

    // MARK: - Private

    /// Encoder-only families used by embedding models. Normalized to
    /// lowercase with `-` folded to `_` before lookup.
    private static let embeddingModelTypes: Set<String> = [
        "bert",
        "camembert",
        "deberta",
        "deberta_v2",
        "distilbert",
        "electra",
        "model2vec",
        "modernbert",
        "mpnet",
        "nomic_bert",
        "roberta",
        "xlm_roberta",
    ]

    /// Architecture-head markers that imply text generation. Substring match
    /// so family prefixes (`Qwen2ForCausalLM`, `GPT2LMHeadModel`,
    /// `Gemma3ForConditionalGeneration`) are all caught.
    private static let generativeArchitectureMarkers = [
        "ForCausalLM",
        "ForConditionalGeneration",
        "LMHeadModel",
        "ForImageTextToText",
        "ForVision2Seq",
        "ForSpeechSeq2Seq",
    ]

    /// Encoder task heads that cannot generate chat completions.
    private static let encoderArchitectureMarkers = [
        "ForMaskedLM",
        "ForSequenceClassification",
        "ForTokenClassification",
        "ForQuestionAnswering",
        "ForMultipleChoice",
        "ForNextSentencePrediction",
        "ForPreTraining",
    ]

    private static func isGenerativeArchitecture(_ name: String) -> Bool {
        generativeArchitectureMarkers.contains { name.contains($0) }
    }

    /// True for the bare encoder (`BertModel`, `XLMRobertaModel`, model2vec's
    /// `StaticModel`) or an encoder task head. Generative markers are checked
    /// first, so the `*Model` suffix here can't swallow a causal-LM entry.
    private static func isEncoderArchitecture(_ name: String) -> Bool {
        if isGenerativeArchitecture(name) { return false }
        return name.hasSuffix("Model")
            || encoderArchitectureMarkers.contains { name.contains($0) }
    }

    private static func readConfigJSON(at directory: URL) -> [String: Any]? {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}
