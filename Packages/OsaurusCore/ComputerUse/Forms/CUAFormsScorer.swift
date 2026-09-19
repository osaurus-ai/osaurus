// Native port of trycua/cua libs/cua-s1 at 83f142c4290a0f7d9ed545ae8532858c6e4f8145.
// Byte collation / AttentionHead derive from jevlike (MIT, 2026 Minimal Labs).
// See Resources/Licenses/CUA-S1-Forms.txt. No Python or pickle in the app.
import CryptoKit
import Foundation
import MLX

struct CUAFormsModelConfig: Decodable, Sendable {
    let encoder: String
    let width: Int
    let rank: Int
    let context_tokens: Int
    let option_tokens: Int
    let layers: Int
    let heads: Int

    func validate() throws {
        guard encoder == "tinyx", (1 ... 256).contains(width), (1 ... 256).contains(rank),
            (1 ... 4).contains(layers), (1 ... 16).contains(heads), width % heads == 0,
            (1 ... 512).contains(context_tokens), (1 ... 256).contains(option_tokens)
        else { throw CUAFormsError.invalid("Unsupported or oversized CUA tinyx configuration.") }
    }

    var tensorShapes: [String: [Int]] {
        var shapes = [
            "embedding.weight": [257, width],
            "position.weight": [max(context_tokens, option_tokens), width],
            "head.context_norm.weight": [width], "head.context_norm.bias": [width],
            "head.option_norm.weight": [width], "head.option_norm.bias": [width],
            "head.query.weight": [rank, width], "head.key.weight": [rank, width],
            "head.value.weight": [rank, width],
        ]
        for prefix in (0 ..< layers).map({ "encoder.layers.\($0)" }) + ["option_encoder.layers.0"] {
            shapes[prefix + ".self_attn.in_proj_weight"] = [3 * width, width]
            shapes[prefix + ".self_attn.in_proj_bias"] = [3 * width]
            shapes[prefix + ".self_attn.out_proj.weight"] = [width, width]
            shapes[prefix + ".self_attn.out_proj.bias"] = [width]
            shapes[prefix + ".linear1.weight"] = [4 * width, width]
            shapes[prefix + ".linear1.bias"] = [4 * width]
            shapes[prefix + ".linear2.weight"] = [width, 4 * width]
            shapes[prefix + ".linear2.bias"] = [width]
            for norm in ["norm1", "norm2"] {
                shapes[prefix + ".\(norm).weight"] = [width]
                shapes[prefix + ".\(norm).bias"] = [width]
            }
        }
        return shapes
    }
}

/// Validate immutable bytes before handing them to MLX. Content signatures
/// bind config to every tensor; exact keys/shapes bound allocation and indexing.
struct CUAFormsCheckpoint {
    let config: CUAFormsModelConfig
    let weights: Data
    let signature: String

    init(directory: URL) throws {
        let configData = try CUAFormsFile.read(directory.appendingPathComponent("config.json"), limit: 65_536)
        let weightsData = try CUAFormsFile.read(
            directory.appendingPathComponent("model.safetensors"),
            limit: 16_777_216
        )
        try self.init(configData: configData, weightsData: weightsData)
    }

    init(configData: Data, weightsData: Data) throws {
        guard let document = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
            document["format"] as? String == "cua-s1", document["format_version"] as? Int == 1,
            let configObject = document["config"] as? [String: Any],
            let signature = document["state_signature"] as? String,
            signature.count == 64, weightsData.count >= 8, weightsData.count <= 16_777_216
        else {
            throw CUAFormsError.invalid("Expected CUA S1 safetensors plus version-1 config.json, not a .pt checkpoint.")
        }
        let canonicalConfig = try Self.canonicalJSON(configObject)
        let config = try JSONDecoder().decode(CUAFormsModelConfig.self, from: canonicalConfig)
        try config.validate()
        let headerLength = weightsData.prefix(8).enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << (8 * $1.offset))
        }
        guard headerLength <= 65_536, headerLength <= weightsData.count - 8 else {
            throw CUAFormsError.invalid("Invalid safetensors header length.")
        }
        let payloadStart = 8 + Int(headerLength)
        guard var header = try JSONSerialization.jsonObject(with: weightsData[8 ..< payloadStart]) as? [String: Any],
            let metadata = header.removeValue(forKey: "__metadata__") as? [String: String],
            metadata["format"] == "cua-s1", metadata["format_version"] == "1",
            metadata["state_signature"] == signature,
            Set(header.keys) == Set(config.tensorShapes.keys)
        else { throw CUAFormsError.invalid("Checkpoint keys or metadata do not match the model contract.") }
        struct Tensor: Decodable {
            let dtype: String
            let shape: [Int]
            let data_offsets: [Int]
        }
        var digest = SHA256()
        digest.update(data: canonicalConfig)
        var spans: [Range<Int>] = []
        for name in header.keys.sorted() {
            let tensor = try JSONDecoder().decode(Tensor.self, from: Self.canonicalJSON(header[name] as Any))
            guard tensor.dtype == "F32", tensor.shape == config.tensorShapes[name],
                tensor.data_offsets.count == 2
            else { throw CUAFormsError.invalid("Checkpoint requires exact FP32 tensor shapes.") }
            let start = tensor.data_offsets[0], end = tensor.data_offsets[1]
            guard start >= 0, end >= start, end <= weightsData.count - payloadStart,
                end - start == tensor.shape.reduce(1, *) * 4
            else { throw CUAFormsError.invalid("Invalid safetensors payload bounds.") }
            let bytes = weightsData[(payloadStart + start) ..< (payloadStart + end)]
            // Reject non-finite inputs before native arithmetic. No read assumes alignment.
            let finite = bytes.withUnsafeBytes { raw in
                stride(from: 0, to: raw.count, by: 4).allSatisfy {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                        .isFinite
                }
            }
            guard finite else { throw CUAFormsError.invalid("Checkpoint contains non-finite weights.") }
            digest.update(data: try Self.canonicalJSON([name, "torch.float32", tensor.shape]))
            digest.update(data: bytes)
            spans.append(start ..< end)
        }
        let ordered = spans.sorted { $0.lowerBound < $1.lowerBound }
        var cursor = 0
        for span in ordered {
            guard span.lowerBound == cursor else {
                throw CUAFormsError.invalid("Overlapping or incomplete tensor payload.")
            }
            cursor = span.upperBound
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard cursor == weightsData.count - payloadStart, actual == signature else {
            throw CUAFormsError.invalid("Checkpoint content signature mismatch.")
        }
        self.config = config
        self.weights = weightsData
        self.signature = signature
    }

    private static func canonicalJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

protocol CUAFormsScoring: Sendable {
    func probabilities(contexts: [String], options: [String]) async throws -> [[Float]]
}

/// Small, serial, CPU-only native scorer. Never changes the app's global MLX
/// device, memory budget, loaded language model, or model-residency policy.
actor CUAFormsScorer: CUAFormsScoring {
    private let config: CUAFormsModelConfig
    private let tensors: [String: MLXArray]
    let signature: String

    init(directory: URL) throws {
        let checkpoint = try CUAFormsCheckpoint(directory: directory)
        config = checkpoint.config
        signature = checkpoint.signature
        tensors = try MLX.loadArrays(data: checkpoint.weights, stream: .cpu)
    }

    static func byteIDs(_ text: String, limit: Int) -> [Int32] {
        text.utf8.prefix(limit).map { Int32($0) + 1 }
    }

    func probabilities(contexts: [String], options: [String]) throws -> [[Float]] {
        guard (1 ... 64).contains(contexts.count), (2 ... 67).contains(options.count),
            contexts.allSatisfy({ $0.utf8.count <= 4096 }),
            options.allSatisfy({ $0.utf8.count <= 2048 })
        else { throw CUAFormsError.invalid("Scoring supports 1–64 elements and 2–67 bounded options.") }
        try Task.checkCancellation()
        return try Stream.withNewDefaultStream(device: .cpu) {
            try MLX.withError {
                let (contextIDs, contextMask, safeContextMask) = collate(contexts, limit: config.context_tokens)
                let (optionIDs, optionMask, safeOptionMask) = collate(options, limit: config.option_tokens)
                var context = embed(contextIDs)
                for layer in 0 ..< config.layers {
                    context = encode(context, mask: safeContextMask, prefix: "encoder.layers.\(layer)")
                }
                // Every row has the same explicit entity options. Encode each
                // option once, not once per field; no cross-run context cache.
                let optionHidden = encode(embed(optionIDs), mask: safeOptionMask, prefix: "option_encoder.layers.0")
                let weights = optionMask.expandedDimensions(axis: -1)
                let pooled = (optionHidden * weights).sum(axis: 1) / maximum(weights.sum(axis: 1), 1)
                let query = linear(norm(pooled, "head.option_norm"), "head.query", bias: false)
                let normalizedContext = norm(context, "head.context_norm")
                let key = linear(normalizedContext, "head.key", bias: false)
                let value = linear(normalizedContext, "head.value", bias: false)
                let scale = Float(1 / sqrt(Double(config.rank)))
                let scores = matmul(query, key.transposed(0, 2, 1)) * scale
                let masked = which(contextMask.expandedDimensions(axis: 1), scores, -Float.greatestFiniteMagnitude)
                let attended = matmul(softmax(masked, axis: -1, precise: true), value)
                let logits = (query * attended).sum(axis: -1) * scale
                let result = softmax(logits, axis: -1, precise: true)
                let flat = result.asArray(Float.self)
                try Task.checkCancellation()
                guard flat.count == contexts.count * options.count,
                    flat.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) })
                else { throw CUAFormsError.invalid("Scorer returned invalid probabilities.") }
                return stride(from: 0, to: flat.count, by: options.count).map {
                    Array(flat[$0 ..< ($0 + options.count)])
                }
            }
        }
    }

    private func collate(_ texts: [String], limit: Int) -> (MLXArray, MLXArray, MLXArray) {
        let rows = texts.map { Self.byteIDs($0, limit: limit) }
        let length = max(1, rows.map(\.count).max() ?? 0)
        var ids = [Int32](), mask = [Float](), safeMask = [Float]()
        for row in rows {
            ids.append(contentsOf: row + Array(repeating: 0, count: length - row.count))
            mask.append(contentsOf: (0 ..< length).map { $0 < row.count ? 1 : 0 })
            safeMask.append(contentsOf: (0 ..< length).map { $0 == 0 || $0 < row.count ? 1 : 0 })
        }
        return (
            MLXArray(ids, [rows.count, length]), MLXArray(mask, [rows.count, length]),
            MLXArray(safeMask, [rows.count, length])
        )
    }

    private func embed(_ ids: MLXArray) -> MLXArray {
        tensors["embedding.weight"]!.take(ids, axis: 0)
            + tensors["position.weight"]!.take(MLXArray(0 ..< ids.dim(1)), axis: 0)
    }

    private func norm(_ input: MLXArray, _ prefix: String) -> MLXArray {
        let centered = input - input.mean(axis: -1, keepDims: true)
        let normalized = centered * rsqrt((centered * centered).mean(axis: -1, keepDims: true) + Float(1e-5))
        return normalized * tensors[prefix + ".weight"]! + tensors[prefix + ".bias"]!
    }

    private func linear(_ input: MLXArray, _ prefix: String, bias: Bool = true) -> MLXArray {
        let result = matmul(input, tensors[prefix + ".weight"]!.T)
        return bias ? result + tensors[prefix + ".bias"]! : result
    }

    private func encode(_ input: MLXArray, mask: MLXArray, prefix: String) -> MLXArray {
        let batch = input.dim(0), length = input.dim(1), headWidth = config.width / config.heads
        let normalized = norm(input, prefix + ".norm1")
        let qkv =
            matmul(normalized, tensors[prefix + ".self_attn.in_proj_weight"]!.T)
            + tensors[prefix + ".self_attn.in_proj_bias"]!
        let parts = qkv.split(parts: 3, axis: -1).map {
            $0.reshaped([batch, length, config.heads, headWidth]).transposed(0, 2, 1, 3)
        }
        let scores = matmul(parts[0], parts[1].transposed(0, 1, 3, 2)) * Float(1 / sqrt(Double(headWidth)))
        let masked = which(mask.expandedDimensions(axes: [1, 2]), scores, -Float.greatestFiniteMagnitude)
        let attended = matmul(softmax(masked, axis: -1, precise: true), parts[2])
            .transposed(0, 2, 1, 3).reshaped([batch, length, config.width])
        let residual = input + linear(attended, prefix + ".self_attn.out_proj")
        let hidden = maximum(linear(norm(residual, prefix + ".norm2"), prefix + ".linear1"), 0)
        return residual + linear(hidden, prefix + ".linear2")
    }
}
