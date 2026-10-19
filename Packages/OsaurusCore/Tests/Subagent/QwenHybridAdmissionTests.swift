import Foundation
import Testing

@testable import OsaurusCore

@Suite("Qwen hybrid child memory accounting")
struct QwenHybridAdmissionTests {
    private var decoder: [String: Any] {
        ["model_type": "qwen4_exp_text", "num_hidden_layers": 48,
         "full_attention_interval": 4, "num_key_value_heads": 2,
         "head_dim": 256, "max_position_embeddings": 262_144,
         "dtype": "bfloat16", "linear_num_value_heads": 48,
         "linear_num_key_heads": 16, "linear_key_head_dim": 128,
         "linear_value_head_dim": 128, "linear_conv_kernel_dim": 4,
         "indexer_head_dim": 128, "indexer_compress_ratio": 4,
         "hidden_size": 2560, "hc_count": 4, "ngram_size": 3,
         "ple_layer_ids": [2], "ple_embed_dim": 2560, "ple_conv_kernel_size": 4]
    }

    @Test("interval topology matches the engine without an explicit layer list")
    func intervalTopology() {
        let mix = ModelRuntime.attentionLayerMix(in: decoder)
        #expect(mix.fullAttention == 12)
        #expect(mix.linearState == 36)
        #expect(mix.declaredPerLayer)
        var partial = decoder
        partial["num_hidden_layers"] = 47
        let trailing = ModelRuntime.attentionLayerMix(in: partial)
        #expect(trailing.fullAttention == 11)
        #expect(trailing.linearState == 36)
        partial["model_type"] = "unrelated_decoder"
        #expect(ModelRuntime.attentionLayerMix(in: partial).fullAttention == 47)
        partial["layer_types"] = ["full_attention", "linear_attention", "full_attention"]
        #expect(ModelRuntime.attentionLayerMix(in: partial).fullAttention == 2)
    }

    @Test("bounded children include float32 GDN and live QSA companions")
    func boundedPricing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrapper: [String: Any] = ["model_type": "qwen4_exp", "text_config": decoder]
        try JSONSerialization.data(withJSONObject: wrapper).write(to: directory.appendingPathComponent("config.json"))
        for positions in [2048, 8192, 32768] {
            let attention = Int64(12 * positions * 2 * 2 * 256 * 2)
            let statePerLayer: Int64 = 48 * 128 * 128 * 4
            let convWidth: Int64 = 2 * 16 * 128 + 48 * 128
            let convPerLayer: Int64 = 3 * convWidth * 2
            let recurrent: Int64 = 36 * (statePerLayer + convPerLayer)
            let indexer = Int64(12 * 128 * (positions + positions / 4) * 2)
            let pleConv: Int64 = 2560 * 4 * 9 * 2
            let pleHistory: Int64 = 2 * 4
            let ple = pleConv + pleHistory
            let state = attention + recurrent + indexer + ple
            let expected = max(512 << 20, state + state / 4)
            let actual = ModelRuntime.estimatedKVHeadroomBytes(
                forWeights: 28_840_000_000, modelDirectory: directory,
                kvRetentionCap: nil, requestPositionLimit: positions)
            #expect(actual == expected)
            #expect(actual < 2 << 30)
        }
    }

    @Test("omitted Qwen dimensions match runtime defaults")
    func defaultDimensions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var explicit = decoder
        explicit["linear_num_value_heads"] = 64
        explicit["linear_key_head_dim"] = 192
        func price(_ config: [String: Any]) throws -> Int64 {
            try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("config.json"))
            return ModelRuntime.estimatedKVHeadroomBytes(
                forWeights: 28_840_000_000, modelDirectory: directory,
                kvRetentionCap: nil, requestPositionLimit: 32768)
        }
        let expected = try price(explicit)
        for key in ["linear_num_value_heads", "linear_num_key_heads", "linear_key_head_dim",
                    "linear_value_head_dim", "linear_conv_kernel_dim", "hc_count", "ngram_size",
                    "ple_layer_ids", "ple_conv_kernel_size"] {
            explicit.removeValue(forKey: key)
        }
        #expect(try price(explicit) == expected)
    }
}
