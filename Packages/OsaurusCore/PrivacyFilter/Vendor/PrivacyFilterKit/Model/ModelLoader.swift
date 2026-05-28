//
//  ModelLoader.swift
//  osaurus / PrivacyFilter (vendored)
//
//  Vendored from https://github.com/kokluch/privacy-filter-swift
//  @ 2bb396cce542155e1923fff1e08520348f1af1c5.
//
//  Osaurus-local rewires:
//    • Reads the Hugging Face–style `config.json` (which embeds
//      `id2label`, the arch dims, MoE counts, vocab/positional info)
//      instead of upstream's split `id2label.json` + `model_config.json`.
//      This matches `mlx-community/openai-privacy-filter-bf16`'s file
//      layout so we don't have to repackage the bundle ourselves.
//    • Transitions resolution now also tolerates
//      `viterbi_calibration.json` (the upstream `mlx-community` repo
//      ships decoder-bias overrides under that name). When neither
//      that nor a real `transitions.json` matrix is present, the
//      validity mask derived from the BIOES label table is used.
//
//  Re-apply these rewires on every upstream sync; see
//  PrivacyFilter/Vendor/PrivacyFilterKit/README-vendoring.md.
//

import Foundation

public struct ModelBundle: Sendable {
    public let directory: URL
    public let labels: BIOESLabelTable
    public let transitions: [[Float]]
    public let modelConfig: ModelConfig
}

/// Architectural knobs we need from `config.json`. Field names are the
/// HF JSON keys; CodingKeys map snake_case → camelCase. Unknown extra
/// fields are ignored.
public struct ModelConfig: Sendable, Codable {
    public let hiddenSize: Int
    public let numLayers: Int
    public let numAttentionHeads: Int
    public let numKeyValueHeads: Int
    public let numExperts: Int
    public let topK: Int
    public let vocabSize: Int
    public let maxPositionEmbeddings: Int
    public let numLabels: Int

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case numLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case numExperts = "num_local_experts"
        case topK = "num_experts_per_tok"
        case vocabSize = "vocab_size"
        case maxPositionEmbeddings = "max_position_embeddings"
        case idToLabel = "id2label"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        self.numLayers = try container.decode(Int.self, forKey: .numLayers)
        self.numAttentionHeads = try container.decode(Int.self, forKey: .numAttentionHeads)
        self.numKeyValueHeads = try container.decode(Int.self, forKey: .numKeyValueHeads)
        self.numExperts = try container.decodeIfPresent(Int.self, forKey: .numExperts) ?? 1
        self.topK = try container.decodeIfPresent(Int.self, forKey: .topK) ?? 1
        self.vocabSize = try container.decode(Int.self, forKey: .vocabSize)
        self.maxPositionEmbeddings = try container.decode(Int.self, forKey: .maxPositionEmbeddings)
        // numLabels is implied by id2label's cardinality.
        let id2label = try container.decode([String: String].self, forKey: .idToLabel)
        self.numLabels = id2label.count
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hiddenSize, forKey: .hiddenSize)
        try container.encode(numLayers, forKey: .numLayers)
        try container.encode(numAttentionHeads, forKey: .numAttentionHeads)
        try container.encode(numKeyValueHeads, forKey: .numKeyValueHeads)
        try container.encode(numExperts, forKey: .numExperts)
        try container.encode(topK, forKey: .topK)
        try container.encode(vocabSize, forKey: .vocabSize)
        try container.encode(maxPositionEmbeddings, forKey: .maxPositionEmbeddings)
    }

    /// In-memory init used by tests that don't have a real config on disk.
    public init(
        hiddenSize: Int,
        numLayers: Int,
        numAttentionHeads: Int,
        numKeyValueHeads: Int,
        numExperts: Int,
        topK: Int,
        vocabSize: Int,
        maxPositionEmbeddings: Int,
        numLabels: Int
    ) {
        self.hiddenSize = hiddenSize
        self.numLayers = numLayers
        self.numAttentionHeads = numAttentionHeads
        self.numKeyValueHeads = numKeyValueHeads
        self.numExperts = numExperts
        self.topK = topK
        self.vocabSize = vocabSize
        self.maxPositionEmbeddings = maxPositionEmbeddings
        self.numLabels = numLabels
    }
}

public enum ModelLoaderError: Error, Equatable {
    case directoryNotFound(URL)
    case missingFile(String)
    case manifestMismatch(String)
}

public enum ModelLoader {
    public static func resolve(source: ModelSource) throws -> ModelBundle {
        let directory: URL
        switch source {
        case let .directory(url):
            directory = url
        case let .bundle(bundle, subdirectory):
            guard let url = bundle.url(forResource: subdirectory ?? ".", withExtension: nil) else {
                throw ModelLoaderError.directoryNotFound(bundle.bundleURL)
            }
            directory = url
        }

        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw ModelLoaderError.directoryNotFound(directory)
        }

        let (labels, modelConfig) = try loadLabelsAndConfig(in: directory)
        let transitions = try loadTransitions(in: directory, labels: labels)
        return ModelBundle(
            directory: directory,
            labels: labels,
            transitions: transitions,
            modelConfig: modelConfig
        )
    }

    /// Single pass over `config.json` to extract both the model
    /// architecture knobs and the `id2label` mapping.
    private static func loadLabelsAndConfig(in directory: URL) throws -> (BIOESLabelTable, ModelConfig) {
        let url = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ModelLoaderError.missingFile("config.json")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ModelLoaderError.manifestMismatch("could not read config.json: \(error.localizedDescription)")
        }

        // First decode the strongly-typed config.
        let modelConfig: ModelConfig
        do {
            modelConfig = try JSONDecoder().decode(ModelConfig.self, from: data)
        } catch {
            throw ModelLoaderError.manifestMismatch("config.json schema mismatch: \(error.localizedDescription)")
        }

        // Then re-parse to pull out id2label specifically (it lives at
        // the top level alongside the arch knobs in HF configs).
        struct Id2LabelHolder: Decodable { let id2label: [String: String] }
        let holder: Id2LabelHolder
        do {
            holder = try JSONDecoder().decode(Id2LabelHolder.self, from: data)
        } catch {
            throw ModelLoaderError.manifestMismatch("config.json missing id2label: \(error.localizedDescription)")
        }

        var mapped: [Int: String] = [:]
        for (key, value) in holder.id2label {
            guard let id = Int(key) else {
                throw ModelLoaderError.manifestMismatch("id2label key not an Int: \(key)")
            }
            mapped[id] = value
        }
        let labels: BIOESLabelTable
        do {
            labels = try BIOESLabelTable(idToLabel: mapped)
        } catch {
            throw ModelLoaderError.manifestMismatch("label table construction failed: \(error)")
        }
        return (labels, modelConfig)
    }

    private static func loadTransitions(in directory: URL, labels: BIOESLabelTable) throws -> [[Float]] {
        // 1. Upstream-style explicit transition matrix wins if present.
        let matrixURL = directory.appendingPathComponent("transitions.json")
        if FileManager.default.fileExists(atPath: matrixURL.path) {
            let data = try Data(contentsOf: matrixURL)
            let raw = try JSONDecoder().decode([[Float]].self, from: data)
            guard raw.count == labels.count else {
                throw ModelLoaderError.manifestMismatch(
                    "transitions.json size \(raw.count) != \(labels.count)"
                )
            }
            return raw
        }

        // 2. `mlx-community/openai-privacy-filter-bf16` ships
        //    `viterbi_calibration.json` which carries decoder-bias
        //    overrides, NOT a full matrix. Use those biases on top of
        //    the validity mask so the decoder honors any tuning.
        let calibURL = directory.appendingPathComponent("viterbi_calibration.json")
        if FileManager.default.fileExists(atPath: calibURL.path) {
            if let biases = (try? ViterbiCalibration.load(from: calibURL))?.defaultBiases {
                return BIOESDecoder.validityMask(labels: labels, biases: biases)
            }
        }

        // 3. Fallback: pure BIOES validity mask.
        return BIOESDecoder.validityMask(labels: labels)
    }
}
