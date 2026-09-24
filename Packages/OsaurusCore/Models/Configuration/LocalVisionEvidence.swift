import Foundation
import MLXLLM
import MLXVLM

/// Installed-checkpoint evidence, not a claim about inference quality. Names are
/// deliberately absent: the same directory must produce the same result under
/// every catalog alias. Only bounded safetensors headers are read, never weights.
enum LocalVisionEvidence {
    struct Result: Sendable {
        let modelType: String
        let hasVision: Bool
        let reason: String
        let tensorNames: Set<String>
        /// Derived once here because `Result` is memoized per directory while
        /// the composer reads capabilities from several SwiftUI getters per
        /// body pass. Re-running substring matches over every tensor name of a
        /// large checkpoint on each of those reads stalled the main thread.
        let hasAudioTensors: Bool
        let hasNativeVideo: Bool

        init(modelType: String, hasVision: Bool, reason: String, tensorNames: Set<String>,
             hasNativeAudio: Bool = false, hasNativeVideo: Bool = false) {
            self.modelType = modelType
            self.hasVision = hasVision
            self.reason = reason
            self.tensorNames = tensorNames
            self.hasNativeVideo = hasVision && hasNativeVideo
            hasAudioTensors = hasNativeAudio || tensorNames.contains {
                $0.contains("embed_audio.embedding_projection.") && $0.hasSuffix(".weight")
            } || (modelType.lowercased().contains("omni") && tensorNames.contains {
                $0.contains("sound_projection.") && $0.hasSuffix(".weight")
            })
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: (processorVersion: UInt64, result: Result)] = [:]
    private nonisolated(unsafe) static var generation: UInt64 = 0
    private nonisolated(unsafe) static let observer: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: .localModelsChanged, object: nil, queue: nil
    ) { _ in invalidate() }

    static func invalidate() {
        lock.lock()
        generation &+= 1
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    static func inspect(_ directory: URL, refresh: Bool = false) -> Result {
        _ = observer
        let key = directory.path
        let processorVersion = VLMProcessorTypeRegistry.shared.registrationVersion
        lock.lock()
        let version = generation
        let cached = cache[key]
        lock.unlock()
        if !refresh, let cached, cached.processorVersion == processorVersion { return cached.result }
        let result = read(directory)
        lock.lock()
        // An invalidation while reading must not republish the old generation.
        if version == generation,
            processorVersion == VLMProcessorTypeRegistry.shared.registrationVersion {
            cache[key] = (processorVersion, result)
        }
        lock.unlock()
        return result
    }

    /// Posted on the main queue when a background `cachedOrWarm` read lands, so
    /// SwiftUI getters that saw `nil` re-evaluate against the cached result.
    static let evidenceReady = Notification.Name("localVisionEvidenceReady")

    private nonisolated(unsafe) static var inFlight: Set<String> = []
    private static let warmQueue = DispatchQueue(
        label: "ai.osaurus.local-vision-evidence", qos: .utility)

    /// Non-blocking variant for SwiftUI getters. A miss used to run `read` on
    /// the main thread (config JSON plus every safetensors header of the
    /// bundle), which hung the composer on first selection of a model and
    /// again after each `.localModelsChanged` invalidation. Returns the cached
    /// result or nil; on nil a single background read per directory fills the
    /// cache through `inspect`, which keeps the generation check, then posts
    /// `evidenceReady`. Send and load paths keep calling `inspect`, so the
    /// authoritative gate never sees a pending nil.
    static func cachedOrWarm(_ directory: URL) -> Result? {
        _ = observer
        let key = directory.path
        let processorVersion = VLMProcessorTypeRegistry.shared.registrationVersion
        lock.lock()
        if let cached = cache[key], cached.processorVersion == processorVersion {
            lock.unlock()
            return cached.result
        }
        let shouldStart = inFlight.insert(key).inserted
        lock.unlock()
        if shouldStart {
            warmQueue.async {
                _ = inspect(directory)
                lock.lock()
                inFlight.remove(key)
                lock.unlock()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: evidenceReady, object: nil)
                }
            }
        }
        return nil
    }

    private static func object(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func read(_ directory: URL) -> Result {
        var modelType = ""
        var names = Set<String>()
        var nativeAudio = false
        var nativeVideo = false
        func result(_ supported: Bool, _ reason: String) -> Result {
            Result(modelType: modelType, hasVision: supported, reason: reason, tensorNames: names,
                   hasNativeAudio: nativeAudio, hasNativeVideo: nativeVideo)
        }
        guard let config = object(directory.appendingPathComponent("config.json")) else {
            return result(false, "The installed bundle has no readable config.json.")
        }
        let omni = object(directory.appendingPathComponent("config_omni.json"))
        modelType = (omni?["model_type"] ?? config["model_type"]) as? String ?? ""
        let mimo = (try? JSONSerialization.data(withJSONObject: config)).map(MiMoV26Contract.matches) ?? false
        if modelType == "mimo_v2", !mimo {
            return result(false, "The configured MiMo representation has no registered multimodal runtime.")
        }
        guard VLMTypeRegistry.supportedModelTypes.contains(modelType) else {
            return result(false, "The configured architecture has no local vision runtime.")
        }
        // Mirror the factory's file precedence. A declaration in a file the
        // loader does not select is not proof of a usable processor.
        let processorURL = ["preprocessor_config.json", "processor_config.json",
            "audio_preprocessor/preprocessor_config.json"]
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let processor: [String: Any]
        if mimo {
            // Match vMLX's factory: this representation uses the nested native
            // configuration, even when an older Qwen sidecar is present.
            guard let native = config["processor_config"] as? [String: Any], !native.isEmpty else {
                return result(false, "The MiMo bundle has no native processor configuration.")
            }
            processor = native.merging(["processor_class": "MiMoV26Processor"]) { _, new in new }
        } else {
            guard let processorURL, let selected = object(processorURL), !selected.isEmpty else {
                return result(false, "The installed bundle has no readable processor configuration.")
            }
            processor = selected
        }
        let processorClass = processor["processor_class"] as? String ?? ""
        let processorType = VLMProcessorTypeRegistry.processorType(
            modelType: modelType, declaredProcessorType: processorClass)
        guard VLMProcessorTypeRegistry.shared.containsProcessorType(processorType) else {
            return result(false, "The selected processor configuration has no registered local processor.")
        }
        do {
            names = try tensorNames(directory)
        } catch {
            return result(false, "Cannot verify the installed vision weights: \(error.localizedDescription)")
        }
        guard ModelFormatDetection.isMLXFormat(at: directory, refresh: true) else {
            return result(false, "The installed weight format is rejected by the local runtime preflight.")
        }
        if mimo {
            nativeAudio = mimoAudioEvidence(directory: directory, config: config,
                                            processor: processor, names: names)
            nativeVideo = (config["video_token_id"] as? Int).map {
                $0 >= 0 && $0 == (processor["video_token_id"] as? Int)
            } ?? false
            nativeVideo = nativeVideo && (processor["fps"] as? Double ?? 0) > 0
                && (processor["video_start_token_id"] as? Int ?? -1) >= 0
                && (processor["video_end_token_id"] as? Int ?? -1) >= 0
                && ((config["vision_config"] as? [String: Any])?["temporal_patch_size"] as? Int ?? 0) > 0
        }
        // Retain independent audio tensor evidence even when this configured
        // multimodal architecture has no vision tower. Gemma supports optional
        // vision and audio components; one missing modality must not hide another.
        // Apertus uses a discrete vision tokenizer instead of a projected tower.
        let visionKey = modelType == "apertus1p5" ? "vision_tokenizer_config" : "vision_config"
        guard let vision = (omni?[visionKey] ?? config[visionKey]) as? [String: Any],
            !vision.isEmpty
        else {
            return result(false, "The installed bundle has no nonempty vision configuration.")
        }
        if mimo {
            guard let depth = vision["depth"] as? Int, (1...1024).contains(depth),
                names.contains("visual.patch_embed.proj.weight"),
                names.contains("visual.merger.mlp.0.weight"),
                names.contains("visual.merger.mlp.2.weight"),
                (0..<depth).allSatisfy({ names.contains("visual.blocks.\($0).attn.qkv.weight") }) else {
                return result(false, "The MiMo vision configuration is missing encoder or projection weights.")
            }
            return result(true, "Media input is backed by the native MiMo processor and installed component weights.")
        }
        if modelType == "apertus1p5" {
            let required = ["vision_tokenizer.encoder.conv_in.weight",
                "vision_tokenizer.encoder.down.0.block.0.conv1.weight",
                "vision_tokenizer.encoder.conv_out.weight", "vision_tokenizer.quant_conv.weight",
                "vision_tokenizer.quantize.embedding.weight"]
            guard required.allSatisfy({ suffix in
                names.contains { $0 == suffix || $0.hasSuffix("." + suffix) }
            }) else {
                return result(false, "The configured vision tokenizer is missing encoder or codebook weights.")
            }
            return result(true, "Image input is backed by the installed vision tokenizer configuration and weights.")
        }
        let gemma4 = ["gemma4", "gemma4_unified", "diffusion_gemma"].contains(modelType)
        // Gemma4's nested vision architecture selects an encoder-free embedder.
        // It has no vision_tower or encoder depth: require its real patch,
        // normalization, position and language-projection tensors instead.
        if gemma4, vision["model_type"] as? String == "gemma4_unified_vision" {
            let required = ["vision_embedder.patch_dense.weight", "vision_embedder.patch_dense.bias",
                "vision_embedder.patch_ln1.weight", "vision_embedder.patch_ln1.bias",
                "vision_embedder.patch_ln2.weight", "vision_embedder.patch_ln2.bias",
                "vision_embedder.pos_embedding", "vision_embedder.pos_norm.weight",
                "vision_embedder.pos_norm.bias", "embed_vision.embedding_projection.weight"]
            guard required.allSatisfy({ suffix in
                names.contains { $0 == suffix || $0.hasSuffix("." + suffix) }
            }) else {
                return result(false, "The unified vision embedder is missing configured component weights.")
            }
            return result(true, "Image input is backed by the installed unified vision configuration and embedder weights.")
        }
        let weights = names.filter { $0.hasSuffix(".weight") || $0.hasSuffix(".weights") }
        let visionWeights = weights.filter { key in
            !Set(key.split(separator: ".").map(String.init))
                .isDisjoint(with: ["visual", "vision_tower", "vision_model", "vision_encoder"])
        }
        guard !visionWeights.isEmpty else {
            return result(false, "The configured vision encoder has no backing weight tensors.")
        }
        // Verify the Qwen and Gemma component roles and every declared encoder
        // block. A lone visual weight or a stale index cannot grant vision.
        let qwen = ["qwen2_vl", "qwen2_5_vl", "qwen3_vl", "qwen3_5", "qwen3_5_moe", "qwen4_exp"]
            .contains(modelType)
        let hasInput = visionWeights.contains {
            $0.contains("patch_embed") || $0.contains("patch_embedding") || $0.contains("patch_generator")
                || $0.contains("patch_conv.weight") || $0.contains("conv1.weight")
        }
        let hasBlocks = visionWeights.contains { $0.contains(".blocks.") || $0.contains(".layers.") }
        guard hasInput, hasBlocks else {
            return result(false, "The vision encoder is missing input or encoder-block weights.")
        }
        if qwen || gemma4 {
            guard let depth = (vision[qwen ? "depth" : "num_hidden_layers"] as? NSNumber)?.intValue,
                depth > 0, depth <= 1024
            else { return result(false, "The vision configuration has no valid encoder depth.") }
            let block = qwen ? ".blocks." : ".encoder.layers."
            guard (0..<depth).allSatisfy({ i in visionWeights.contains { $0.contains("\(block)\(i).") } }) else {
                return result(false, "The installed weights are missing configured vision encoder blocks.")
            }
            let hasProjection = qwen
                ? visionWeights.contains { $0.contains(".merger.") }
                : weights.contains { $0.contains("embed_vision.embedding_projection.") }
            guard hasProjection else {
                return result(false, "The vision-to-language projection has no backing weights.")
            }
        }
        return result(true, "Image input is backed by the installed configuration and vision weights.")
    }

    private struct InvalidWeights: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    private static func mimoAudioEvidence(
        directory: URL, config: [String: Any], processor: [String: Any], names: Set<String>
    ) -> Bool {
        let sidecar = directory.appendingPathComponent("audio_tokenizer")
        guard let audio = config["audio_config"] as? [String: Any],
            let tokenizer = object(sidecar.appendingPathComponent("config.json")),
            let channels = audio["audio_channels"] as? Int, (1...1024).contains(channels),
            let layers = audio["input_local_layers"] as? Int, (1...1024).contains(layers),
            let encoderLayers = tokenizer["encoder_layers"] as? Int, (1...1024).contains(encoderLayers),
            channels == (tokenizer["num_quantizers"] as? Int),
            let inputDimension = audio["input_local_dim"] as? Int, inputDimension > 0,
            inputDimension == (tokenizer["d_model"] as? Int),
            (processor["audio_sampling_rate"] as? Int) == (tokenizer["sampling_rate"] as? Int),
            (processor["audio_sampling_rate"] as? Int ?? 0) > 0,
            let token = config["audio_token_id"] as? Int, token >= 0,
            token == (processor["audio_token_id"] as? Int),
            names.contains("audio_encoder.projection.mlp.0.weight"),
            names.contains("audio_encoder.projection.mlp.2.weight"),
            (0..<channels).allSatisfy({ names.contains("speech_embeddings.\($0).weight") }),
            (0..<layers).allSatisfy({ names.contains("audio_encoder.input_local_transformer.layers.\($0).self_attn.q_proj.weight") }),
            let encoder = try? tensorNames(sidecar) else { return false }
        return ["encoder.conv1.weight", "encoder.conv2.weight", "encoder.down_sample_layer.0.weight"]
            .allSatisfy(encoder.contains)
            && (0..<encoderLayers).allSatisfy { encoder.contains("encoder.layers.\($0).self_attn.q_proj.weight") }
            && (0..<channels).allSatisfy { encoder.contains("encoder.quantizer.vq.layers.\($0)._codebook.embed") }
    }

    /// Budget every auxiliary tower too, although the runtime loads them lazily.
    /// MTP and a separate draft directory are not part of this AR-only runtime.
    static func residentMiMoPayloadBytes(_ directory: URL) -> UInt64? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
            MiMoV26Contract.matches(data),
            let tensors = try? tensorPayloadSizes(directory) else { return nil }
        var total: UInt64 = 0
        for (name, bytes) in tensors where !name.hasPrefix("model.mtp") {
            let sum = total.addingReportingOverflow(bytes)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        let audio = directory.appendingPathComponent("audio_tokenizer")
        if FileManager.default.fileExists(atPath: audio.path) {
            guard let tensors = try? tensorPayloadSizes(audio) else { return nil }
            for bytes in tensors.values {
                let sum = total.addingReportingOverflow(bytes)
                guard !sum.overflow else { return nil }
                total = sum.partialValue
            }
        }
        return total > 0 ? total : nil
    }

    private static func tensorNames(_ directory: URL) throws -> Set<String> {
        Set(try tensorPayloadSizes(directory).keys)
    }

    private static func tensorPayloadSizes(_ directory: URL) throws -> [String: UInt64] {
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        let indexExists = FileManager.default.fileExists(atPath: indexURL.path)
        let index = object(indexURL)?["weight_map"] as? [String: String]
        if indexExists && (index == nil || index!.isEmpty) {
            throw InvalidWeights(detail: "invalid safetensors index")
        }
        let files: [URL]
        if let index {
            files = try Set(index.values).sorted().map { name in
                guard !name.contains("/"), name.hasSuffix(".safetensors") else {
                    throw InvalidWeights(detail: "invalid shard path")
                }
                return directory.appendingPathComponent(name)
            }
        } else {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "safetensors" && !$0.lastPathComponent.hasPrefix("jangtq_runtime") }
        }
        guard !files.isEmpty else { throw InvalidWeights(detail: "no safetensors weight files") }
        var sizes: [String: UInt64] = [:]
        for file in files {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
                throw InvalidWeights(detail: "truncated shard header")
            }
            let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
            guard fileSize >= 8, length > 0, length <= 64 * 1024 * 1024, length <= fileSize - 8,
                let data = try handle.read(upToCount: Int(length)), data.count == Int(length),
                let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw InvalidWeights(detail: "invalid shard header") }
            var fileKeys = Set<String>()
            for (name, value) in header where name != "__metadata__" {
                guard let tensor = value as? [String: Any],
                    let shape = tensor["shape"] as? [Int], shape.allSatisfy({ $0 > 0 }),
                    let dtype = tensor["dtype"] as? String,
                    let offsets = tensor["data_offsets"] as? [UInt64], offsets.count == 2,
                    offsets[0] < offsets[1], offsets[1] <= fileSize - 8 - length,
                    SafetensorsPayloadSize.matches(dtype: dtype, shape: shape, byteCount: offsets[1] - offsets[0])
                else { throw InvalidWeights(detail: "invalid tensor metadata: \(name)") }
                fileKeys.insert(name)
                guard sizes.updateValue(offsets[1] - offsets[0], forKey: name) == nil else {
                    throw InvalidWeights(detail: "duplicate tensor: \(name)")
                }
            }
            if let index {
                let declared = Set(index.filter { $0.value == file.lastPathComponent }.keys)
                guard declared.isSubset(of: fileKeys) else {
                    throw InvalidWeights(detail: "index names tensors absent from \(file.lastPathComponent)")
                }
                // Use the selected shard's actual header, including legitimate
                // preserved tensors omitted by an older index.
            }
        }
        return sizes
    }
}
