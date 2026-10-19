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
         "ple_embed_dim": 2560, "ple_conv_kernel_size": 4]
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
            let recurrent = Int64(36 * (48 * 128 * 128 * 4 + 3 * (2 * 16 * 128 + 48 * 128) * 2))
            let indexer = Int64(12 * 128 * (positions + positions / 4) * 2)
            let ple = Int64(48 * 2560 * 3 * 2)
            let state = attention + recurrent + indexer + ple
            let expected = max(512 << 20, state + state / 4)
            let actual = ModelRuntime.estimatedKVHeadroomBytes(
                forWeights: 28_840_000_000, modelDirectory: directory,
                kvRetentionCap: nil, requestPositionLimit: positions)
            #expect(actual == expected)
            #expect(actual < 2 << 30)
        }
    }
}
