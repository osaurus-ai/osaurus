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
