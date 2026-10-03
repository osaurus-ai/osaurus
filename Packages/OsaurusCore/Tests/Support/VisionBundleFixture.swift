import Foundation

/// Small, structurally valid safetensors fixtures. No MLX allocation or fake index-only weights.
enum VisionBundleFixture {
    static func makeMiMo(omit: String? = nil, sidecarOmit: String? = nil) throws -> URL {
        let root = try make(type: "mimo_v2")
        try writeJSON([
            "model_type": "mimo_v2", "attention_projection_layout": "fused_qkv",
            "quantization": ["mode": "affine", "gate": ["mode": "mxfp4"]],
            "vision_config": ["depth": 2, "temporal_patch_size": 2],
            "audio_config": ["audio_channels": 2, "input_local_layers": 2, "input_local_dim": 8],
            "video_token_id": 123, "audio_token_id": 124,
            "processor_config": ["video_token_id": 123, "audio_token_id": 124,
                "video_start_token_id": 125, "video_end_token_id": 126,
                "fps": 2.0, "audio_sampling_rate": 24000],
        ], to: root.appendingPathComponent("config.json"))
        // Deliberately stale sidecar: native nested configuration takes precedence.
        try writeJSON(["processor_class": "UnknownLegacyProcessor"],
                      to: root.appendingPathComponent("preprocessor_config.json"))
        let names = ["visual.patch_embed.proj.weight", "visual.merger.mlp.0.weight",
            "visual.merger.mlp.2.weight", "visual.blocks.0.attn.qkv.weight",
            "visual.blocks.1.attn.qkv.weight", "audio_encoder.projection.mlp.0.weight",
            "audio_encoder.projection.mlp.2.weight", "speech_embeddings.0.weight", "speech_embeddings.1.weight",
            "audio_encoder.input_local_transformer.layers.0.self_attn.q_proj.weight",
            "audio_encoder.input_local_transformer.layers.1.self_attn.q_proj.weight"]
        try writeWeights(names.filter { omit == nil || !$0.contains(omit!) },
                         to: root.appendingPathComponent("model.safetensors"))
        let sidecar = root.appendingPathComponent("audio_tokenizer")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        try writeJSON(["encoder_layers": 2, "num_quantizers": 2, "d_model": 8, "sampling_rate": 24000],
                      to: sidecar.appendingPathComponent("config.json"))
        let encoder = ["encoder.conv1.weight", "encoder.conv2.weight", "encoder.down_sample_layer.0.weight",
            "encoder.layers.0.self_attn.q_proj.weight", "encoder.layers.1.self_attn.q_proj.weight",
            "encoder.quantizer.vq.layers.0._codebook.embed", "encoder.quantizer.vq.layers.1._codebook.embed"]
        try writeWeights(encoder.filter { sidecarOmit == nil || !$0.contains(sidecarOmit!) },
                         to: sidecar.appendingPathComponent("model.safetensors"))
        return root
    }

    static func make(type: String = "qwen3_5", omit: String? = nil, indexed: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gemma = type.hasPrefix("gemma4") || type == "diffusion_gemma"
        let unified = type == "gemma4_unified"
        let vision: [String: Any] = unified
            ? ["model_type": "gemma4_unified_vision", "mm_embed_dim": 3840, "patch_size": 16]
            : [gemma ? "num_hidden_layers" : "depth": 2, "hidden_size": 1152]
        try writeJSON(["model_type": type, "vision_config": vision, "video_token_id": 123],
                      to: root.appendingPathComponent("config.json"))
        try writeJSON(["processor_class": unified ? "Gemma4UnifiedProcessor" : gemma ? "Gemma4Processor" : "Qwen3VLProcessor"],
                      to: root.appendingPathComponent("processor_config.json"))
        var names = gemma ? ["vision_tower.patch_embedder.input_proj.weight",
            "vision_tower.encoder.layers.0.self_attn.q_proj.weight",
            "vision_tower.encoder.layers.1.self_attn.q_proj.weight", "embed_vision.embedding_projection.weight"]
            : ["visual.patch_embed.proj.weight", "visual.blocks.0.attn.qkv.weight",
               "visual.blocks.1.attn.qkv.weight", "visual.merger.linear_fc2.weight"]
        if unified {
            names = ["vision_embedder.patch_dense.weight", "vision_embedder.patch_dense.bias",
                "vision_embedder.patch_ln1.weight", "vision_embedder.patch_ln1.bias",
                "vision_embedder.patch_ln2.weight", "vision_embedder.patch_ln2.bias",
                "vision_embedder.pos_embedding", "vision_embedder.pos_norm.weight",
                "vision_embedder.pos_norm.bias", "embed_vision.embedding_projection.weight"]
        }
        if let omit { names.removeAll { $0.contains(omit) } }
        try writeWeights(names, to: root.appendingPathComponent("model.safetensors"))
        if indexed {
            try writeJSON(["weight_map": Dictionary(uniqueKeysWithValues: names.map { ($0, "model.safetensors") })],
                          to: root.appendingPathComponent("model.safetensors.index.json"))
        }
        return root
    }

    static func writeWeights(
        _ names: [String], metadata: [String: String]? = nil,
        dtype: String = "F32", shape: [Int] = [1], payloadBytesPerTensor: Int = 4,
        to path: URL
    ) throws {
        var header: [String: Any] = [:]
        if let metadata { header["__metadata__"] = metadata }
        for (i, name) in names.enumerated() {
            header[name] = ["shape": shape, "dtype": dtype,
                "data_offsets": [i * payloadBytesPerTensor, (i + 1) * payloadBytesPerTensor]]
        }
        var json = try JSONSerialization.data(withJSONObject: header)
        while json.count % 8 != 0 { json.append(32) }
        var length = UInt64(json.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(json)
        data.append(Data(repeating: 0, count: names.count * payloadBytesPerTensor))
        try data.write(to: path)
    }

    static func writeJSON(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }
}
