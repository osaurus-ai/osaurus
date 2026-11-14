//
// osaurus#2633: loading a Gemma-4 audio bundle rewrote the user's config.json.
//
// The load preflight parsed config.json with JSONSerialization, added
// `quantization.multimodal`, and re-serialized the whole file. Every integral
// double lost its `.0` (`10000000000.0` → `10000000000`), keys were re-sorted,
// and the bundle no longer matched the Hub. These tests build the reporter's
// exact bundle shape (an ordinary mlx_lm affine 4-bit Gemma-4 with an audio
// embedder) and a JANG-stamped variant, run the preflight, and require the
// config.json bytes to be identical afterwards. They cover this preflight
// only; a config.json an earlier build already rewrote is not repaired.
//

import Foundation
import Testing

@testable import OsaurusCore

struct Gemma4AudioConfigRewriteTests {

    /// Number shapes copied from the report and from the Hub config of
    /// OsaurusAI/gemma-4-E4B-it-4bit; `quantization.mode == "affine"` is the
    /// ordinary mlx_lm stamp, not a JANG marker.
    private static func config(weightFormat: String?, multimodal: String?) -> String {
        var quant = #""group_size": 64, "bits": 4, "mode": "affine""#
        if let multimodal { quant += #", "multimodal": "\#(multimodal)""# }
        var top = #""model_type": "gemma4", "gradient_clipping": 10000000000.0, "attention_logit_cap": 50.0"#
        if let weightFormat { top += #", "weight_format": "\#(weightFormat)""# }
        return """
            {
              \(top),
              "text_config": {"rms_norm_eps": 9.9999999999999995e-07, "rope_theta": 1000000.0, "attention_dropout": 0.0},
              "quantization": {\(quant)}
            }
            """
    }

    private func makeBundle(config: String, audio: Bool) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-gemma4-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: dir.appendingPathComponent("config.json"))
        let key =
            audio
            ? "language_model.model.embed_audio.embedding_projection.weight"
            : "language_model.model.embed_vision.embedding_projection.weight"
        let index = #"{"metadata": {"total_size": 1}, "weight_map": {"\#(key)": "model.safetensors"}}"#
        try Data(index.utf8).write(to: dir.appendingPathComponent("model.safetensors.index.json"))
        return dir
    }

    private func configBytes(_ dir: URL) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent("config.json"))
    }

    @Test("reporter's mlx_lm affine audio bundle keeps config.json byte-identical")
    func reporterBundleIsLeftUntouched() throws {
        let dir = try makeBundle(config: Self.config(weightFormat: nil, multimodal: nil), audio: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try configBytes(dir)
        let missing = ModelRuntime.noteGemma4AudioBundleMissingMultimodalStamp(at: dir, name: "gemma-4-E4B-it-4bit")
        #expect(missing)
        let after = try configBytes(dir)
        #expect(after == before)
        let text = String(decoding: after, as: UTF8.self)
        #expect(text.contains("\"gradient_clipping\": 10000000000.0"))
        #expect(text.contains("\"attention_logit_cap\": 50.0"))
        #expect(!text.contains("multimodal"))
    }

    @Test("JANG-stamped audio bundle without the flag keeps config.json byte-identical")
    func jangBundleIsLeftUntouched() throws {
        let dir = try makeBundle(config: Self.config(weightFormat: "jang_4m", multimodal: nil), audio: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try configBytes(dir)
        #expect(ModelRuntime.noteGemma4AudioBundleMissingMultimodalStamp(at: dir, name: "gemma-4-12b-it-JANG_4M"))
        #expect(try configBytes(dir) == before)
    }

    @Test("already-stamped and vision-only bundles are untouched (control)")
    func stampedAndVisionOnlyBundlesAreUntouched() throws {
        let stamped = try makeBundle(
            config: Self.config(weightFormat: nil, multimodal: "fp16_passthrough_embedders_early_fusion"),
            audio: true
        )
        let visionOnly = try makeBundle(config: Self.config(weightFormat: "jang_4m", multimodal: nil), audio: false)
        defer {
            try? FileManager.default.removeItem(at: stamped)
            try? FileManager.default.removeItem(at: visionOnly)
        }
        let b1 = try configBytes(stamped), b2 = try configBytes(visionOnly)
        #expect(!ModelRuntime.noteGemma4AudioBundleMissingMultimodalStamp(at: stamped, name: "mxfp4"))
        #expect(!ModelRuntime.noteGemma4AudioBundleMissingMultimodalStamp(at: visionOnly, name: "vision-only"))
        #expect(try configBytes(stamped) == b1)
        #expect(try configBytes(visionOnly) == b2)
    }
}
