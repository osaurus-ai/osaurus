//
//  MLXModelTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct MLXModelTests {

    @Test func localDirectory_buildsNestedPathFromRepoId() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let model = MLXModel(
            id: "mlx-community/Qwen3-1.7B-4bit",
            name: "Qwen3-1.7B-4bit",
            description: "Test model",
            downloadURL: "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit",
            rootDirectory: tempDir
        )

        let dir = model.localDirectory
        #expect(dir.lastPathComponent == "Qwen3-1.7B-4bit")
        #expect(dir.deletingLastPathComponent().lastPathComponent == "mlx-community")
    }

    @Test func isDownloaded_trueWhenCoreFilesPresent() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let model = MLXModel(
            id: "org/repo",
            name: "repo",
            description: "",
            downloadURL: "https://example.com/repo",
            rootDirectory: tempDir
        )

        let dir = model.localDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // config.json
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        // tokenizer.json
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        // at least one .safetensors
        try Data([0x00]).write(to: dir.appendingPathComponent("weights-00001-of-00001.safetensors"))

        #expect(model.isDownloaded == true)
    }

    @Test func localBundleSizeAndExactCatalogMergeUseInstalledMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-local-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = MLXModel(
            id: "JANGQ-AI/Laguna-S.2-21B-A3B-JANG_2L",
            name: "local",
            description: "detected",
            downloadURL: "https://example.invalid/local",
            downloadSizeBytes: 44_298_536_392,
            modelType: "laguna_s2",
            rootDirectory: root
        )
        try FileManager.default.createDirectory(
            at: local.localDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: local.localDirectory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: local.localDirectory.appendingPathComponent("tokenizer.json"))
        try Data("{}".utf8).write(
            to: local.localDirectory.appendingPathComponent("model.safetensors.index.json"))

        let catalog = MLXModel(
            id: local.id,
            name: "Laguna S.2 Curated",
            description: "Curated description",
            downloadURL: "https://huggingface.co/\(local.id)",
            isTopSuggestion: true,
            downloadSizeBytes: 20_432_000_000,
            modelType: nil,
            downloads: 123
        )
        let merged = catalog.mergingLocalInstallationMetadata(from: local)

        #expect(local.isDownloaded)
        #expect(merged.downloadSizeBytes == 44_298_536_392)
        #expect(merged.totalSizeEstimateBytes == 44_298_536_392)
        #expect(merged.name == catalog.name)
        #expect(merged.description == catalog.description)
        #expect(merged.isTopSuggestion)
        #expect(merged.downloads == 123)
        #expect(merged.modelType == "laguna_s2")
    }

    @Test func localBundleSizePrefersSafetensorsIndexMetadata() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-index-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(#"{"metadata":{"total_size":44298536392},"weight_map":{}}"#.utf8)
            .write(to: bundle.appendingPathComponent("model.safetensors.index.json"))

        #expect(MLXModel.localBundleWeightSizeBytes(at: bundle) == 44_298_536_392)
    }

    @Test func localBundleSizeFallsBackFromMalformedIndexToShallowWeights() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-fallback-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("not-json".utf8)
            .write(to: bundle.appendingPathComponent("model.safetensors.index.json"))
        try Data(repeating: 1, count: 17)
            .write(to: bundle.appendingPathComponent("model-00001-of-00002.safetensors"))
        try Data(repeating: 2, count: 23)
            .write(to: bundle.appendingPathComponent("model-00002-of-00002.safetensors"))

        #expect(MLXModel.localBundleWeightSizeBytes(at: bundle) == 40)
    }

    @Test func localBundleSizeRejectsIndexShardPathsOutsideBundle() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-contained-size-\(UUID().uuidString)")
        let bundle = parent.appendingPathComponent("bundle")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 99)
            .write(to: parent.appendingPathComponent("outside.safetensors"))
        try Data(#"{"weight_map":{"layer":"../outside.safetensors"}}"#.utf8)
            .write(to: bundle.appendingPathComponent("model.safetensors.index.json"))
        try Data(repeating: 1, count: 7)
            .write(to: bundle.appendingPathComponent("inside.safetensors"))

        #expect(MLXModel.localBundleWeightSizeBytes(at: bundle) == 7)
    }

    @Test func step37DownloadedModelIsTextOnlyForPickerEvenWithVisionConfig() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let model = MLXModel(
            id: "JANGQ-AI/Step-3.7-Flash-JANGTQ_K",
            name: "Step-3.7-Flash-JANGTQ_K",
            description: "",
            downloadURL: "https://example.com/repo",
            rootDirectory: tempDir
        )

        let dir = model.localDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"model_type":"step3","vision_config":{"hidden_size":1024}}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        try Data([0x00]).write(to: dir.appendingPathComponent("model-00001-of-00001.safetensors"))

        #expect(model.isDownloaded)
        #expect(!model.isVLM)
    }

    @Test func isDownloaded_falseWhenMissingConfig() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let model = MLXModel(
            id: "org/repo",
            name: "repo",
            description: "",
            downloadURL: "https://example.com/repo",
            rootDirectory: tempDir
        )

        let dir = model.localDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // tokenizer.json
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        // weights file
        try Data([0x00]).write(to: dir.appendingPathComponent("weights.safetensors"))

        #expect(model.isDownloaded == false)
    }

    @Test func isDownloaded_falseWhenMissingTokenizer() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let model = MLXModel(
            id: "org/repo",
            name: "repo",
            description: "",
            downloadURL: "https://example.com/repo",
            rootDirectory: tempDir
        )

        let dir = model.localDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // config.json
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        // weights file
        try Data([0x00]).write(to: dir.appendingPathComponent("weights.safetensors"))

        #expect(model.isDownloaded == false)
    }

    @Test func isDownloaded_falseWhenMissingWeights() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let model = MLXModel(
            id: "org/repo",
            name: "repo",
            description: "",
            downloadURL: "https://example.com/repo",
            rootDirectory: tempDir
        )

        let dir = model.localDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // config.json
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        // tokenizer.json
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))

        #expect(model.isDownloaded == false)
    }

    // MARK: - simplifiedName (onboarding chooser friendly title)

    private func model(named name: String) -> MLXModel {
        MLXModel(id: "org/\(name)", name: name, description: "", downloadURL: "https://example.com")
    }

    /// The chooser title strips instruction-tuned (`it`), quant/precision
    /// (`MXFP8`/`MXFP4`/`qat`/`4bit`/`MTP`), and MoE active-param (`A1B`/`A4B`)
    /// tokens so the name reads like a product, while keeping family + version +
    /// size tier (including the Gemma `E2B`/`E4B` tiers).
    @Test func simplifiedName_stripsPrecisionAndJargonTokens() {
        #expect(model(named: "Gemma 4 12B it MXFP8").simplifiedName == "Gemma 4 12B")
        #expect(model(named: "Gemma 4 12B it qat MXFP4").simplifiedName == "Gemma 4 12B")
        #expect(model(named: "Gemma 4 E2B it qat MXFP4").simplifiedName == "Gemma 4 E2B")
        #expect(model(named: "Gemma 4 26B A4B it qat MXFP4").simplifiedName == "Gemma 4 26B")
        #expect(model(named: "LFM2.5 8B A1B MXFP8").simplifiedName == "LFM2.5 8B")
        #expect(model(named: "Qwen3.6 27B MXFP8 MTP").simplifiedName == "Qwen3.6 27B")
        #expect(
            model(named: "Nemotron 3 Nano Omni 30B A3B MXFP4").simplifiedName
                == "Nemotron 3 Nano Omni 30B"
        )
    }

    /// Two same-size builds collapse to the same friendly title — that's why
    /// the onboarding chooser dedupes on `simplifiedName` and shows one
    /// hardware-chosen build per family (`ConfigureAIState.dedupedTopPicks`).
    @Test func simplifiedName_sameSizeVariantsCollapseToSameTitle() {
        let highPrecision = model(named: "Gemma 4 12B it MXFP8").simplifiedName
        let efficient = model(named: "Gemma 4 12B it qat MXFP4").simplifiedName
        #expect(highPrecision == efficient)
    }

    @Test func simplifiedName_normalizesBonsaiLowBitVariants() {
        let ternary = model(named: "Bonsai 27b Ternary JANG").simplifiedName
        let oneBit = model(named: "Bonsai 27b 1bit JANG").simplifiedName
        #expect(ternary == "Bonsai 27b")
        #expect(oneBit == ternary)
    }

    /// If stripping would leave nothing, fall back to the original name rather
    /// than rendering an empty row title.
    @Test func simplifiedName_fallsBackWhenAllTokensAreJargon() {
        #expect(model(named: "MXFP4").simplifiedName == "MXFP4")
        #expect(model(named: "it qat MXFP8").simplifiedName == "it qat MXFP8")
    }

    @Test func releasedAt_defaultsToNil() {
        let model = MLXModel(
            id: "org/repo",
            name: "repo",
            description: "",
            downloadURL: "https://example.com/repo"
        )
        #expect(model.releasedAt == nil)
    }

    @Test func releasedAt_isPreservedFromInit() {
        let date = Date(timeIntervalSince1970: 1_760_745_000)
        let model = MLXModel(
            id: "org/repo",
            name: "repo",
            description: "",
            downloadURL: "https://example.com/repo",
            releasedAt: date
        )
        #expect(model.releasedAt == date)
    }
}
