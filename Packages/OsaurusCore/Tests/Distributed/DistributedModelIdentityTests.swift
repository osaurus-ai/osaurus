//
//  DistributedModelIdentityTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

/// Builds a small on-disk bundle shaped like the installed Qwen Flash Next
/// JANG bundles (qwen4_exp, 24 attention / 2 KV heads, mixed-bit map).
private struct BundleFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distributed-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try write("config.json", Self.config)
        try write("tokenizer.json", #"{"model":{"type":"BPE"}}"#)
        try write("tokenizer_config.json", #"{"eos_token":"<|im_end|>"}"#)
        try write("generation_config.json", #"{"temperature":0.6,"top_k":20}"#)
        try write(
            "model.safetensors.index.json",
            #"""
            {"metadata":{},"weight_map":{"a.weight":"model-00001-of-00002.safetensors",
            "b.weight":"model-00002-of-00002.safetensors","c.weight":"model-00001-of-00002.safetensors"}}
            """#
        )
        try writeShard(
            "model-00001-of-00002.safetensors",
            header: #"{"a.weight":{"dtype":"U32","shape":[4,2],"data_offsets":[0,32]}}"#,
            payload: 32
        )
        try writeShard(
            "model-00002-of-00002.safetensors",
            header: #"{"b.weight":{"dtype":"U32","shape":[2,2],"data_offsets":[0,16]}}"#,
            payload: 16
        )
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: url.appendingPathComponent(name))
    }

    func writeShard(_ name: String, header: String, payload: Int, fill: UInt8 = 0) throws {
        var data = Data()
        var length = UInt64(header.utf8.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(Data(header.utf8))
        data.append(Data(repeating: fill, count: payload))
        try data.write(to: url.appendingPathComponent(name))
    }

    func identity() throws -> DistributedModelIdentity {
        try DistributedModelIdentity.compute(bundle: url)
    }

    static let config = #"""
        {"model_type":"qwen4_exp","text_config":{"model_type":"qwen4_exp_text","num_attention_heads":24,
        "num_key_value_heads":2,"linear_num_key_heads":16,"linear_num_value_heads":48,"num_experts":512,
        "num_hidden_layers":48},
        "jang_config":{"format":"jang_v2","family":"qwen4_exp"},
        "quantization":{"group_size":64,"bits":6,
          "language_model.embed_tokens":{"group_size":64,"bits":8},
          "language_model.layers.0.mlp.switch_mlp.up_proj":{"group_size":64,"bits":2},
          "language_model.layers.1.mlp.switch_mlp.up_proj":{"group_size":32,"bits":2}}}
        """#
}

struct DistributedModelIdentityTests {
    @Test func readsArchitectureAndMixedBitMap() throws {
        let bundle = try BundleFixture()
        defer { bundle.remove() }
        let identity = try bundle.identity()
        let a = identity.architecture
        #expect(a.modelType == "qwen4_exp")
        #expect(a.textModelType == "qwen4_exp_text")
        #expect(a.attentionHeads == 24 && a.keyValueHeads == 2)
        #expect(a.linearKeyHeads == 16 && a.linearValueHeads == 48)
        #expect(a.experts == 512 && a.layers == 48)
        #expect(a.quantFormat == "jang_v2")
        #expect(a.bitGroups.map { "\($0.bits)/\($0.groupSize)" } == ["2/32", "2/64", "6/64", "8/64"])
    }

    @Test func countsIndexedShardsAndBytes() throws {
        let bundle = try BundleFixture()
        defer { bundle.remove() }
        let identity = try bundle.identity()
        #expect(identity.shardCount == 2, "shards come from the index, de-duplicated")
        #expect(identity.isComplete)
        let expected = (8 + 64 + 32) + (8 + 64 + 16)
        #expect(identity.weightBytes == Int64(expected))
        #expect(identity.fingerprint.count == 64)
        #expect(identity.shortFingerprint.count == 12)
        #expect(identity.components.first { $0.name == "chat_template.jinja" }?.sha256 == nil)
    }

    @Test func fingerprintIsStableAndPathIndependent() throws {
        let one = try BundleFixture()
        let two = try BundleFixture()
        defer { one.remove(); two.remove() }
        let first = try one.identity().fingerprint
        let again = try one.identity().fingerprint
        let other = try two.identity().fingerprint
        #expect(first == again)
        #expect(first == other, "two Macs with identical bundles in different folders must agree")
    }

    @Test func tokenizerTemplateAndGenerationDefaultsChangeTheFingerprint() throws {
        let bundle = try BundleFixture()
        defer { bundle.remove() }
        var seen = [try bundle.identity().fingerprint]
        try bundle.write("tokenizer.json", #"{"model":{"type":"Unigram"}}"#)
        seen.append(try bundle.identity().fingerprint)
        try bundle.write("chat_template.jinja", "{{ messages }}")
        seen.append(try bundle.identity().fingerprint)
        try bundle.write("generation_config.json", #"{"temperature":1.0}"#)
        seen.append(try bundle.identity().fingerprint)
        #expect(Set(seen).count == seen.count)
    }

    @Test func sameSizeTensorLayoutChangeIsDetected() throws {
        let bundle = try BundleFixture()
        defer { bundle.remove() }
        let before = try bundle.identity()
        // Same byte length header and payload; only the declared shape differs.
        try bundle.writeShard(
            "model-00002-of-00002.safetensors",
            header: #"{"b.weight":{"dtype":"U32","shape":[4,1],"data_offsets":[0,16]}}"#,
            payload: 16
        )
        let after = try bundle.identity()
        #expect(before.weightBytes == after.weightBytes)
        #expect(before.fingerprint != after.fingerprint)
    }

    @Test func payloadBytesAreNotHashedByDesign() throws {
        let bundle = try BundleFixture()
        defer { bundle.remove() }
        let before = try bundle.identity()
        try bundle.writeShard(
            "model-00002-of-00002.safetensors",
            header: #"{"b.weight":{"dtype":"U32","shape":[2,2],"data_offsets":[0,16]}}"#,
            payload: 16,
            fill: 0xFF
        )
        let after = try bundle.identity().fingerprint
        #expect(after == before.fingerprint, "documented limitation: tensor payload bytes are not read; the UI says so")
    }

    @Test func missingShardIsIncompleteAndChangesTheFingerprint() throws {
        let bundle = try BundleFixture()
        defer { bundle.remove() }
        let before = try bundle.identity()
        try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("model-00002-of-00002.safetensors"))
        let after = try bundle.identity()
        #expect(after.missingShards == ["model-00002-of-00002.safetensors"])
        #expect(!after.isComplete)
        #expect(after.fingerprint != before.fingerprint)
    }

    @Test func corruptHeaderIsUnreadableNotAnAllocation() throws {
        let bundle = try BundleFixture()
        defer { bundle.remove() }
        var data = Data()
        var huge = UInt64.max.littleEndian
        withUnsafeBytes(of: &huge) { data.append(contentsOf: $0) }
        data.append(Data("{}".utf8))
        try data.write(to: bundle.url.appendingPathComponent("model-00001-of-00002.safetensors"))
        let identity = try bundle.identity()
        #expect(identity.unreadableShards == ["model-00001-of-00002.safetensors"])
        #expect(!identity.isComplete)
        try Data([1, 2, 3]).write(to: bundle.url.appendingPathComponent("model-00001-of-00002.safetensors"))
        let truncated = try bundle.identity()
        #expect(truncated.unreadableShards == ["model-00001-of-00002.safetensors"])
    }

    @Test func withoutAnIndexEveryTopLevelSafetensorsIsAShard() throws {
        let bundle = try BundleFixture()
        defer { bundle.remove() }
        try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("model.safetensors.index.json"))
        try bundle.writeShard(
            "extra.safetensors",
            header: #"{"z":{"dtype":"F16","shape":[1],"data_offsets":[0,2]}}"#,
            payload: 2
        )
        let identity = try bundle.identity()
        #expect(identity.shardCount == 3)
    }

    @Test func missingOrUnreadableConfigThrows() throws {
        let bundle = try BundleFixture()
        defer { bundle.remove() }
        try bundle.write("config.json", "{not json")
        #expect(throws: DistributedModelIdentity.Failure.unreadableConfig) { try bundle.identity() }
        try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("config.json"))
        #expect(throws: DistributedModelIdentity.Failure.missingConfig) { try bundle.identity() }
    }
}

struct TensorParallelDivisibilityTests {
    private let flashNext = DistributedModelIdentity.Architecture(
        modelType: "qwen4_exp",
        textModelType: "qwen4_exp_text",
        attentionHeads: 24,
        keyValueHeads: 2,
        linearKeyHeads: 16,
        linearValueHeads: 48,
        experts: 512,
        layers: 48,
        quantFormat: "jang_v2",
        bitGroups: []
    )

    @Test func flashNextHeadArithmetic() {
        #expect(TensorParallelDivisibility.check(flashNext, worldSize: 2).verdict == .divides)
        #expect(TensorParallelDivisibility.check(flashNext, worldSize: 4).verdict == .needsKVReplication)
        #expect(
            TensorParallelDivisibility.check(flashNext, worldSize: 3).verdict == .indivisible("16 linear key heads")
        )
        #expect(TensorParallelDivisibility.check(flashNext, worldSize: 5).verdict == .indivisible("24 attention heads"))
    }

    @Test func kvHeadsThatNeitherDivideNorReplicate() {
        var a = flashNext
        a.attentionHeads = 12
        a.keyValueHeads = 4
        a.linearKeyHeads = nil
        a.linearValueHeads = nil
        #expect(TensorParallelDivisibility.check(a, worldSize: 6).verdict == .indivisible("4 KV heads"))
    }

    @Test func undeclaredShapesAreUnknown() {
        var a = flashNext
        a.keyValueHeads = nil
        guard case .unknown = TensorParallelDivisibility.check(a, worldSize: 2).verdict else {
            Issue.record("missing KV heads must be unknown")
            return
        }
        guard case .unknown = TensorParallelDivisibility.check(flashNext, worldSize: 1).verdict else {
            Issue.record("world size 1 is not tensor parallelism")
            return
        }
    }
}
