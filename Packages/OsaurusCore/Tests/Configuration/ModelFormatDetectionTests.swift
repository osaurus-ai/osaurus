//
//  ModelFormatDetectionTests.swift
//  OsaurusCoreTests
//
//  Pins the file-level "is this an MLX bundle" classifier that greys out and
//  blocks non-MLX (e.g. PyTorch / transformers) safetensors bundles co-mingled
//  in a shared model store. Two signals, either sufficient: a top-level
//  `quantization` block in config.json, or a safetensors header
//  `__metadata__.format == "mlx"`. The transformers `quantization_config` key
//  must NOT be mistaken for the MLX `quantization` block.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelFormatDetectionTests {

    // MARK: - Fixtures

    /// Build a bundle directory with an optional config.json and optional
    /// synthetic safetensors files. Each call uses a fresh UUID directory so
    /// the path-keyed verdict cache never bleeds across tests.
    private func makeBundle(
        config: [String: Any]? = nil,
        safetensors: [(name: String, metadata: [String: String]?)] = [],
        extraFiles: [String] = []
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-mlx-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let config {
            let data = try JSONSerialization.data(withJSONObject: config)
            try data.write(to: dir.appendingPathComponent("config.json"))
        }
        for file in safetensors {
            try writeSafetensors(
                at: dir.appendingPathComponent(file.name),
                metadata: file.metadata
            )
        }
        for name in extraFiles {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    /// Write a minimal valid safetensors file: an 8-byte little-endian header
    /// length followed by the JSON header. The detector reads only this header,
    /// so no tensor bytes are needed. `metadata == nil` omits `__metadata__`.
    private func writeSafetensors(at url: URL, metadata: [String: String]?) throws {
        var header: [String: Any] = [
            // A token tensor entry so the header looks like a real safetensors.
            "weight": [
                "dtype": "F32",
                "shape": [1],
                "data_offsets": [0, 4],
            ]
        ]
        if let metadata { header["__metadata__"] = metadata }
        let headerData = try JSONSerialization.data(withJSONObject: header)
        var file = Data()
        var length = UInt64(headerData.count).littleEndian
        withUnsafeBytes(of: &length) { file.append(contentsOf: $0) }
        file.append(headerData)
        file.append(Data(count: 4))  // the single F32 weight's bytes
        try file.write(to: url)
    }

    // MARK: - Positive signals

    @Test func mlxQuantizationBlockIsMLX() throws {
        // Quantized MLX builds carry a top-level `quantization` block; the
        // safetensors metadata tag may be absent (e.g. first-party MXFP8).
        let dir = try makeBundle(
            config: [
                "model_type": "lfm2",
                "quantization": ["group_size": 64, "bits": 8, "mode": "affine"],
            ],
            safetensors: [("model.safetensors", nil)]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelFormatDetection.isMLXFormat(at: dir))
    }

    @Test func mxfp8QuantizationBlockIsMLX() throws {
        // First-party MXFP8 bundles: no `format: mlx` tag, but a `quantization`
        // block with mode mxfp8.
        let dir = try makeBundle(
            config: [
                "model_type": "lfm2",
                "quantization": ["bits": 8, "group_size": 32, "mode": "mxfp8"],
            ],
            safetensors: [("model-00001-of-00001.safetensors", nil)]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelFormatDetection.isMLXFormat(at: dir))
    }

    @Test func safetensorsFormatTagIsMLX() throws {
        // Unquantized (bf16) MLX builds have no `quantization` block but tag
        // their safetensors header with `format: mlx`.
        let dir = try makeBundle(
            config: ["model_type": "lfm2"],
            safetensors: [("model.safetensors", ["format": "mlx"])]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelFormatDetection.isMLXFormat(at: dir))
    }

    @Test func mlxFormatTagIsCaseInsensitive() throws {
        let dir = try makeBundle(
            config: ["model_type": "lfm2"],
            safetensors: [("model.safetensors", ["format": "MLX"])]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelFormatDetection.isMLXFormat(at: dir))
    }

    @Test func mlxTagOnAnyShardIsSufficient() throws {
        // Only the second shard carries the tag; scanning must not stop at the
        // first untagged shard.
        let dir = try makeBundle(
            config: ["model_type": "lfm2"],
            safetensors: [
                ("model-00001-of-00002.safetensors", nil),
                ("model-00002-of-00002.safetensors", ["format": "mlx"]),
            ]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelFormatDetection.isMLXFormat(at: dir))
    }

    // MARK: - Negative signals

    @Test func pytorchBundleIsNotMLX() throws {
        // Plain PyTorch export: same config + safetensors shape, but a `pt`
        // format tag and no `quantization` block. This is the co-mingled case
        // the feature exists to catch.
        let dir = try makeBundle(
            config: [
                "model_type": "glm",
                "architectures": ["GlmForCausalLM"],
            ],
            safetensors: [("model.safetensors", ["format": "pt"])]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!ModelFormatDetection.isMLXFormat(at: dir))
    }

    @Test func safetensorsWithoutMetadataIsNotMLX() throws {
        let dir = try makeBundle(
            config: ["model_type": "glm"],
            safetensors: [("model.safetensors", nil)]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!ModelFormatDetection.isMLXFormat(at: dir))
    }

    @Test func transformersQuantizationConfigIsNotMLX() throws {
        // The false-positive guard: transformers quantized models use
        // `quantization_config`, NOT the top-level `quantization` block, and
        // tag their weights `pt`. Must not be read as MLX.
        let dir = try makeBundle(
            config: [
                "model_type": "llama",
                "quantization_config": ["quant_method": "bitsandbytes", "bits": 4],
            ],
            safetensors: [("model.safetensors", ["format": "pt"])]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!ModelFormatDetection.isMLXFormat(at: dir))
    }

    @Test func emptyBundleIsNotMLX() throws {
        let dir = try makeBundle(config: ["model_type": "glm"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!ModelFormatDetection.isMLXFormat(at: dir))
    }

    // MARK: - MLXModel integration

    @Test func mlxModelIsMLXFormatReadsBundleDirectory() throws {
        // A complete, MLX-format external bundle must report `isMLXFormat`.
        let dir = try makeBundle(
            config: [
                "model_type": "lfm2",
                "quantization": ["group_size": 64, "bits": 4],
            ],
            safetensors: [("model.safetensors", ["format": "mlx"])],
            extraFiles: ["tokenizer.json"]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = MLXModel(
            id: "test/lfm2-mlx",
            name: "LFM2 MLX",
            description: "fixture",
            downloadURL: "https://example.invalid/lfm2",
            bundleDirectory: dir,
            externalSource: "Hugging Face cache"
        )
        #expect(model.isDownloaded)
        #expect(model.isMLXFormat)
    }

    @Test func nonMLXDownloadedModelIsNotMLXFormat() throws {
        let dir = try makeBundle(
            config: ["model_type": "glm"],
            safetensors: [("model.safetensors", ["format": "pt"])],
            extraFiles: ["tokenizer.json"]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = MLXModel(
            id: "test/glm-pytorch",
            name: "GLM PyTorch",
            description: "fixture",
            downloadURL: "https://example.invalid/glm",
            bundleDirectory: dir,
            externalSource: "Hugging Face cache"
        )
        #expect(model.isDownloaded)
        #expect(!model.isMLXFormat)
    }

    @Test func undownloadedModelIsAssumedMLX() {
        // Catalog entries not on disk can't be inspected; the curated catalog
        // is MLX, so they must not be greyed.
        let model = MLXModel(
            id: "test/not-downloaded",
            name: "Not Downloaded",
            description: "fixture",
            downloadURL: "https://example.invalid/x",
            bundleDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("osu-missing-\(UUID().uuidString)", isDirectory: true)
        )
        #expect(!model.isDownloaded)
        #expect(model.isMLXFormat)
    }

    // MARK: - Diagnostics integration

    @Test func diagnosticsBlocksNonMLXBundle() throws {
        let dir = try makeBundle(
            config: ["model_type": "glm"],
            safetensors: [("model.safetensors", ["format": "pt"])],
            extraFiles: ["tokenizer.json"]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = MLXModel(
            id: "test/glm-pytorch",
            name: "GLM PyTorch",
            description: "fixture",
            downloadURL: "https://example.invalid/glm",
            bundleDirectory: dir,
            externalSource: "Hugging Face cache"
        )
        let report = ModelCompatibilityDiagnostics.report(for: model)
        #expect(report.preflight.status == .unsupported)
        #expect(report.preflight.reason == .notMLXFormat)
        #expect(report.preflight.blocksRuntimeLoad)
    }

    @Test func diagnosticsAllowsMLXBundle() throws {
        let dir = try makeBundle(
            config: [
                "model_type": "lfm2",
                "quantization": ["group_size": 64, "bits": 4],
            ],
            safetensors: [("model.safetensors", ["format": "mlx"])],
            extraFiles: ["tokenizer.json"]
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = MLXModel(
            id: "test/lfm2-mlx",
            name: "LFM2 MLX",
            description: "fixture",
            downloadURL: "https://example.invalid/lfm2",
            bundleDirectory: dir,
            externalSource: "Hugging Face cache"
        )
        let report = ModelCompatibilityDiagnostics.report(for: model)
        #expect(report.preflight.reason != .notMLXFormat)
    }
}
