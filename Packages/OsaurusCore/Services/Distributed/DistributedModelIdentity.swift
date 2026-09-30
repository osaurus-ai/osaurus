//
//  DistributedModelIdentity.swift
//  osaurus
//
//  Identity of a model bundle as found in THIS Mac's own Osaurus model
//  directory (or a supported imported location). Every participating Mac must
//  compute this from its own copy; paths are never shared between hosts.
//
//  The fingerprint covers config, generation defaults, tokenizer, chat
//  template, quantization metadata, the tensor→shard index and every shard's
//  safetensors header (dtype, shape and byte offsets of each tensor). Tensor
//  payload bytes are NOT hashed — reading hundreds of GB to paint a settings
//  panel is not acceptable — and the UI says so.
//

import CryptoKit
import Foundation

struct DistributedModelIdentity: Equatable, Sendable {
    struct Architecture: Equatable, Sendable {
        var modelType: String?
        var textModelType: String?
        var attentionHeads: Int?
        var keyValueHeads: Int?
        var linearKeyHeads: Int?
        var linearValueHeads: Int?
        var experts: Int?
        var layers: Int?
        /// `jang_config.format` / `quantization_config.quant_method`, when declared.
        var quantFormat: String?
        /// Distinct (bits, group size) pairs declared by the quantization map.
        var bitGroups: [BitGroup]
    }

    struct BitGroup: Hashable, Comparable, Sendable {
        let bits: Int
        let groupSize: Int
        static func < (a: Self, b: Self) -> Bool { (a.bits, a.groupSize) < (b.bits, b.groupSize) }
    }

    struct Component: Equatable, Sendable {
        let name: String
        /// nil when the file is absent from this bundle.
        let sha256: String?
    }

    let bundlePath: String
    let architecture: Architecture
    let components: [Component]
    let shardCount: Int
    let weightBytes: Int64
    /// Shards the index references that are missing on this Mac.
    let missingShards: [String]
    /// Shards whose safetensors header could not be read.
    let unreadableShards: [String]
    /// SHA-256 over all component hashes and shard names, sizes and headers.
    let fingerprint: String

    var isComplete: Bool { missingShards.isEmpty && unreadableShards.isEmpty && shardCount > 0 }
    var shortFingerprint: String { String(fingerprint.prefix(12)) }

    /// Files whose bytes are hashed in full. Order is part of the fingerprint.
    static let componentFiles = [
        "config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json",
        "chat_template.jinja", "chat_template.json", "jang_config.json", "quantization_config.json",
        "model.safetensors.index.json",
    ]

    enum Failure: Error, Equatable {
        case missingConfig
        case unreadableConfig
    }

    static func compute(bundle: URL, fileManager: FileManager = .default) throws -> DistributedModelIdentity {
        let configURL = bundle.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path) else { throw Failure.missingConfig }
        guard let configData = try? Data(contentsOf: configURL),
            let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
        else { throw Failure.unreadableConfig }

        var digest = SHA256()
        var components: [Component] = []
        for name in componentFiles {
            let url = bundle.appendingPathComponent(name)
            let hash = (try? Data(contentsOf: url, options: .mappedIfSafe)).map { hex(SHA256.hash(data: $0)) }
            components.append(Component(name: name, sha256: hash))
            digest.update(data: Data("\(name)=\(hash ?? "absent")\n".utf8))
        }

        let shards = shardNames(bundle: bundle, fileManager: fileManager)
        var missing: [String] = []
        var unreadable: [String] = []
        var bytes: Int64 = 0
        for shard in shards {
            let url = bundle.appendingPathComponent(shard)
            guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
                missing.append(shard)
                digest.update(data: Data("\(shard)=missing\n".utf8))
                continue
            }
            bytes += size.int64Value
            guard let header = safetensorsHeader(url) else {
                unreadable.append(shard)
                digest.update(data: Data("\(shard)=\(size.int64Value):unreadable\n".utf8))
                continue
            }
            digest.update(data: Data("\(shard)=\(size.int64Value):".utf8))
            digest.update(data: header)
            digest.update(data: Data("\n".utf8))
        }

        return DistributedModelIdentity(
            bundlePath: bundle.path,
            architecture: architecture(config: config, bundle: bundle),
            components: components,
            shardCount: shards.count,
            weightBytes: bytes,
            missingShards: missing,
            unreadableShards: unreadable,
            fingerprint: hex(digest.finalize())
        )
    }

    /// Shards named by the index when present (the index is what the loader
    /// follows); otherwise every top-level `*.safetensors`.
    static func shardNames(bundle: URL, fileManager: FileManager = .default) -> [String] {
        let index = bundle.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let map = object["weight_map"] as? [String: String]
        {
            return Set(map.values).sorted()
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: bundle.path)) ?? []
        return names.filter { $0.hasSuffix(".safetensors") }.sorted()
    }

    /// The JSON header of a safetensors file: 8-byte little-endian length then
    /// that many bytes. Bounded so a corrupt length cannot allocate gigabytes.
    static func safetensorsHeader(_ url: URL, maximumBytes: UInt64 = 64 * 1024 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else { return nil }
        let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard length > 1, length <= maximumBytes,
            let header = try? handle.read(upToCount: Int(length)), header.count == Int(length),
            header.first == UInt8(ascii: "{")
        else { return nil }
        return header
    }

    static func architecture(config: [String: Any], bundle: URL) -> Architecture {
        let text = config["text_config"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (text[key] as? Int) ?? (config[key] as? Int) }
        let jang =
            (config["jang_config"] as? [String: Any])
            ?? ((try? Data(contentsOf: bundle.appendingPathComponent("jang_config.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let quantization =
            (config["quantization"] as? [String: Any])
            ?? (config["quantization_config"] as? [String: Any])
        return Architecture(
            modelType: config["model_type"] as? String,
            textModelType: text["model_type"] as? String,
            attentionHeads: int("num_attention_heads"),
            keyValueHeads: int("num_key_value_heads"),
            linearKeyHeads: int("linear_num_key_heads"),
            linearValueHeads: int("linear_num_value_heads"),
            experts: int("num_experts") ?? int("n_routed_experts"),
            layers: int("num_hidden_layers"),
            quantFormat: (jang?["format"] as? String) ?? (quantization?["quant_method"] as? String),
            bitGroups: bitGroups(quantization)
        )
    }

    /// Top-level default plus every per-module override in the map.
    static func bitGroups(_ quantization: [String: Any]?) -> [BitGroup] {
        guard let quantization else { return [] }
        var groups = Set<BitGroup>()
        func add(_ entry: [String: Any]) {
            if let bits = entry["bits"] as? Int, let group = entry["group_size"] as? Int {
                groups.insert(BitGroup(bits: bits, groupSize: group))
            }
        }
        add(quantization)
        for value in quantization.values { if let entry = value as? [String: Any] { add(entry) } }
        return groups.sorted()
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Head-count arithmetic for a proposed tensor-parallel world size. This is a
/// divisibility check on the bundle's declared shapes — not a sharding plan,
/// and not evidence that the runtime can shard this architecture.
struct TensorParallelDivisibility: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        case divides
        /// KV heads fewer than ranks: each rank needs replicated KV heads.
        case needsKVReplication
        case indivisible(String)
        case unknown(String)
    }

    let worldSize: Int
    let verdict: Verdict

    static func check(_ architecture: DistributedModelIdentity.Architecture, worldSize: Int) -> Self {
        guard worldSize >= 2 else {
            return Self(worldSize: worldSize, verdict: .unknown("world size must be at least 2"))
        }
        guard let heads = architecture.attentionHeads, let kv = architecture.keyValueHeads, heads > 0, kv > 0 else {
            return Self(worldSize: worldSize, verdict: .unknown("attention head counts not declared"))
        }
        guard heads % worldSize == 0 else {
            return Self(worldSize: worldSize, verdict: .indivisible("\(heads) attention heads"))
        }
        for (label, value) in [
            ("linear key", architecture.linearKeyHeads), ("linear value", architecture.linearValueHeads),
        ] {
            if let value, value % worldSize != 0 {
                return Self(worldSize: worldSize, verdict: .indivisible("\(value) \(label) heads"))
            }
        }
        if kv % worldSize == 0 { return Self(worldSize: worldSize, verdict: .divides) }
        if worldSize % kv == 0 { return Self(worldSize: worldSize, verdict: .needsKVReplication) }
        return Self(worldSize: worldSize, verdict: .indivisible("\(kv) KV heads"))
    }
}
