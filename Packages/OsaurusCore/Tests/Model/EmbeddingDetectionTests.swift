//
//  EmbeddingDetectionTests.swift
//  OsaurusCoreTests
//
//  Pins the config.json-based embedding/encoder-only classifier that keeps
//  embedding repos (potion-base-4M pulled into the HF cache by the memory
//  feature, all-MiniLM-L6-v2 from Python tooling, etc.) out of the chat
//  picker. The classifier must be conservative: only positively-identified
//  encoder-only configs are flagged; unknown or malformed configs stay
//  chat-capable so a novel causal LM is never hidden.
//

import Foundation
import Testing

@testable import OsaurusCore

struct EmbeddingDetectionTests {

    // MARK: - Pure config classifier: embedding configs

    @Test func potionStyleModel2VecConfigIsEmbedding() {
        // minishlab/potion-base-4M: model2vec static embedding model.
        let config: [String: Any] = [
            "model_type": "model2vec",
            "architectures": ["StaticModel"],
            "hidden_dim": 128,
            "normalize": true,
        ]
        #expect(EmbeddingDetection.isEmbeddingConfig(config))
    }

    @Test func miniLMStyleBertConfigIsEmbedding() {
        // sentence-transformers/all-MiniLM-L6-v2.
        let config: [String: Any] = [
            "model_type": "bert",
            "architectures": ["BertModel"],
            "hidden_size": 384,
        ]
        #expect(EmbeddingDetection.isEmbeddingConfig(config))
    }

    @Test func knownEmbeddingModelTypesAreFlagged() {
        for modelType in [
            "bert", "distilbert", "roberta", "xlm-roberta", "XLM-RoBERTa",
            "nomic_bert", "modernbert", "model2vec", "mpnet",
        ] {
            #expect(
                EmbeddingDetection.isEmbeddingConfig(["model_type": modelType]),
                "Expected model_type \(modelType) to be flagged as embedding"
            )
        }
    }

    @Test func encoderOnlyArchitecturesWithoutModelTypeAreFlagged() {
        // Architecture-suffix fallback for configs whose model_type isn't in
        // the known family set.
        #expect(EmbeddingDetection.isEmbeddingConfig(["architectures": ["NewEncoderModel"]]))
        #expect(EmbeddingDetection.isEmbeddingConfig(["architectures": ["SomeBertForMaskedLM"]]))
        #expect(
            EmbeddingDetection.isEmbeddingConfig([
                "architectures": ["XForSequenceClassification"]
            ])
        )
    }

    // MARK: - Pure config classifier: chat configs must NOT be flagged

    @Test func causalLMConfigsAreNotEmbedding() {
        for architectures in [
            ["Qwen2ForCausalLM"],
            ["LlamaForCausalLM"],
            ["GPT2LMHeadModel"],
            ["Gemma3ForConditionalGeneration"],
        ] {
            #expect(
                !EmbeddingDetection.isEmbeddingConfig(["architectures": architectures]),
                "Did not expect \(architectures) to be flagged as embedding"
            )
        }
    }

    @Test func generativeArchitectureWinsOverEmbeddingModelType() {
        // A causal-LM head must override a model_type that happens to be in
        // the embedding family set.
        let config: [String: Any] = [
            "model_type": "bert",
            "architectures": ["BertLMHeadModel"],
        ]
        #expect(!EmbeddingDetection.isEmbeddingConfig(config))
    }

    @Test func mixedArchitecturesAreNotEmbedding() {
        let config: [String: Any] = [
            "architectures": ["SomethingModel", "SomethingForCausalLM"]
        ]
        #expect(!EmbeddingDetection.isEmbeddingConfig(config))
    }

    @Test func vlmConfigIsNotEmbedding() {
        // VLM configs carry vision_config; even when architectures look
        // encoder-ish, the VLM path owns them.
        let config: [String: Any] = [
            "model_type": "qwen2_vl",
            "architectures": ["Qwen2VLModel"],
            "vision_config": ["depth": 32],
        ]
        #expect(!EmbeddingDetection.isEmbeddingConfig(config))
    }

    @Test func unknownOrEmptyConfigsAreNotEmbedding() {
        #expect(!EmbeddingDetection.isEmbeddingConfig([:]))
        #expect(!EmbeddingDetection.isEmbeddingConfig(["model_type": "qwen2"]))
        #expect(!EmbeddingDetection.isEmbeddingConfig(["model_type": "llama"]))
        // MLX conversions sometimes drop `architectures`; an unknown
        // model_type alone must not flag.
        #expect(!EmbeddingDetection.isEmbeddingConfig(["model_type": "some_new_family"]))
    }

    // MARK: - On-disk detection

    private func makeBundle(config: [String: Any]?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-embed-detect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let config {
            let data = try JSONSerialization.data(withJSONObject: config)
            try data.write(to: dir.appendingPathComponent("config.json"))
        }
        return dir
    }

    @Test func detectsEmbeddingBundleOnDisk() throws {
        let dir = try makeBundle(config: [
            "model_type": "bert",
            "architectures": ["BertModel"],
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(EmbeddingDetection.isEmbedding(at: dir))
    }

    @Test func causalBundleOnDiskIsNotEmbedding() throws {
        let dir = try makeBundle(config: [
            "model_type": "qwen2",
            "architectures": ["Qwen2ForCausalLM"],
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!EmbeddingDetection.isEmbedding(at: dir))
    }

    @Test func missingConfigIsNotEmbedding() throws {
        let dir = try makeBundle(config: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!EmbeddingDetection.isEmbedding(at: dir))
    }

    @Test func mlxModelIsEmbeddingReadsBundleDirectory() throws {
        // External bundles (HF cache / LM Studio) pin `bundleDirectory`;
        // `MLXModel.isEmbedding` must resolve through it.
        let dir = try makeBundle(config: [
            "model_type": "model2vec",
            "architectures": ["StaticModel"],
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = MLXModel(
            id: "minishlab/potion-base-4M",
            name: "Potion Base 4M",
            description: "fixture",
            downloadURL: "https://example.invalid/potion",
            bundleDirectory: dir,
            externalSource: "Hugging Face cache"
        )
        #expect(model.isEmbedding)
    }
}
