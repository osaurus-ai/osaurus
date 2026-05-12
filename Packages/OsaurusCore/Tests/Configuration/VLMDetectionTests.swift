//
//  VLMDetectionTests.swift
//  osaurus
//
//  Locks the model-type and vision_config detection that decides whether
//  a request routes through the VLM factory or the LLM factory in vmlx.
//
//  The VLM factory in vmlx-swift-lm registers `zaya1_vl` (real native
//  runtime as of vmlx 7e29418); ZAYA1-VL bundles silently mis-route to
//  the LLM path and fail at first inference if `VLMTypeRegistry.
//  supportedModelTypes` ever drops the entry. These tests catch that
//  regression at the osaurus layer without needing a loaded MLX model.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite struct VLMDetectionTests {

    // MARK: - model_type registry

    /// ZAYA1-VL was added to the VLM factory in vmlx commit `7e29418`;
    /// this test pins that osaurus's `VLMDetection` sees it as VLM via
    /// the `VLMTypeRegistry.supportedModelTypes` delegation. If this
    /// fails, the picker will route ZAYA1-VL bundles through the LLM
    /// path and the user will hit a vmlx unsupported-model throw.
    @Test func isVLMModelType_recognizesZaya1VL() {
        #expect(VLMDetection.isVLM(modelType: "zaya1_vl"))
    }

    /// Text ZAYA (`model_type=zaya`) is an LLM, not a VLM. Even though
    /// the family is related, ZAYA1-VL bundles use `model_type=zaya1_vl`
    /// and bare `zaya` must route through the LLM factory.
    @Test func isVLMModelType_rejectsTextZaya() {
        #expect(
            !VLMDetection.isVLM(modelType: "zaya"),
            "Text ZAYA (`model_type=zaya`) must not route through the VLM factory."
        )
    }

    @Test func isVLMModelType_recognizesQwen2_5VL() {
        #expect(VLMDetection.isVLM(modelType: "qwen2_5_vl"))
    }

    @Test func isVLMModelType_preservesCaseSensitiveRegistryEntries() {
        #expect(VLMDetection.isVLM(modelType: "NemotronH_Nano_Omni_Reasoning_V3"))
    }

    @Test func isVLMModelType_rejectsUnknownArchitecture() {
        #expect(!VLMDetection.isVLM(modelType: "totally_made_up_arch_xyz"))
    }

    @Test func isVLMModelType_rejectsEmptyString() {
        #expect(!VLMDetection.isVLM(modelType: ""))
    }

    // MARK: - directory-based detection (vision_config disambiguator)

    /// Bundles with both LLM and VLM `model_type` registrations (e.g.
    /// `gemma4`) are disambiguated by `vision_config` presence in
    /// `config.json`. This test pins the truthy path.
    @Test func isVLMAtDirectory_trueWhenVisionConfigPresent() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeConfig(
            at: tmp,
            json: #"{"model_type": "qwen2_5_vl", "vision_config": {"hidden_size": 1280}}"#
        )
        #expect(VLMDetection.isVLM(at: tmp))
    }

    @Test func isVLMAtDirectory_falseWhenVisionConfigAbsent() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeConfig(
            at: tmp,
            json: #"{"model_type": "zaya"}"#
        )
        #expect(!VLMDetection.isVLM(at: tmp))
    }

    @Test func isVLMAtDirectory_falseWhenConfigMissing() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        // Directory does not exist; isVLM must not crash and must
        // return false.
        #expect(!VLMDetection.isVLM(at: tmp))
    }

    @Test func isVLMAtDirectory_falseOnMalformedJSON() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Truncated JSON — the helper must swallow the parse error and
        // treat the bundle as non-VLM rather than crashing the picker.
        try writeConfig(at: tmp, json: #"{"model_type": "qwen2_5_vl""#)
        #expect(!VLMDetection.isVLM(at: tmp))
    }

    // MARK: - readModelType

    @Test func readModelType_returnsValueFromConfig() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeConfig(
            at: tmp,
            json: #"{"model_type": "zaya1_vl", "vision_config": {}}"#
        )
        #expect(VLMDetection.readModelType(at: tmp) == "zaya1_vl")
    }

    @Test func readModelType_nilWhenConfigMissing() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        #expect(VLMDetection.readModelType(at: tmp) == nil)
    }

    @Test func readModelType_nilWhenModelTypeFieldAbsent() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeConfig(at: tmp, json: #"{"hidden_size": 4096}"#)
        #expect(VLMDetection.readModelType(at: tmp) == nil)
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tmp,
            withIntermediateDirectories: true
        )
        return tmp
    }

    private func writeConfig(at directory: URL, json: String) throws {
        try json.data(using: .utf8)!.write(
            to: directory.appendingPathComponent("config.json")
        )
    }
}
