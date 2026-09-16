import Foundation

/// Small, structurally valid safetensors fixtures. No MLX allocation or fake index-only weights.
enum VisionBundleFixture {
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
