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
}
