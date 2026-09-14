import Foundation
import Testing
@testable import OsaurusCore

@Suite("ModelMediaCapabilities — config and weight evidence")
struct ModelMediaCapabilitiesMCDCTests {
    @Test(arguments: ["qwen2_vl", "qwen2_5_vl", "qwen3_vl", "qwen3_5", "qwen3_5_moe", "qwen4_exp", "gemma4", "gemma4_unified"])
    func installedFamilies(type: String) throws {
        let root = try VisionBundleFixture.make(type: type)
        defer { try? FileManager.default.removeItem(at: root) }
        for alias in ["ordinary-local-model", "Qwen3-VL", "Nemotron-3-Ultra-Local", "Step-3.7-Local"] {
            let caps = ModelMediaCapabilities.from(directory: root, modelId: alias)
            #expect(caps.supportsImage)
            #expect(caps.supportsVideo == type.hasPrefix("qwen"))
            #expect(!caps.supportsAudio)
            #expect(VLMDetection.isVLM(at: root) == caps.supportsImage)
        }
    }

    @Test(arguments: ["Qwen3-VL", "Gemma-4-it", "Nemotron-3-Nano-Omni", "Holo3-VL", "unrelated-name"])
    func missingBundleNeverUsesName(name: String) {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(ModelMediaCapabilities.from(directory: absent, modelId: name) == .textOnly)
    }

    @Test func explicitLocalNegativeCannotBeOverridden() {
        #expect(ModelMediaCapabilities.composerCapabilities(modelId: "Qwen3-VL",
            fallbackSupportsImages: true, localHasAudioTensors: true, localCapabilities: .textOnly) == .textOnly)
        #expect(ModelMediaCapabilities.composerCapabilities(modelId: "opaque-provider-id",
            fallbackSupportsImages: true) == .imageOnly)
        #expect(ModelMediaCapabilities.composerCapabilities(modelId: "Qwen3-VL",
            fallbackSupportsImages: true, localModelType: "qwen3_5") == .textOnly)
    }

    @Test func missingVisionDoesNotHideIndependentAudioWeights() throws {
        let root = try VisionBundleFixture.make(type: "gemma4")
        defer { try? FileManager.default.removeItem(at: root) }
        try VisionBundleFixture.writeJSON([
            "model_type": "gemma4", "vision_config": NSNull(),
            "audio_config": ["model_type": "gemma4_audio"],
        ], to: root.appendingPathComponent("config.json"))
        try VisionBundleFixture.writeWeights(["embed_audio.embedding_projection.weight"],
                                             to: root.appendingPathComponent("model.safetensors"))
        let caps = ModelMediaCapabilities.from(directory: root, modelId: "neutral")
        #expect(!caps.supportsImage)
        #expect(!caps.supportsVideo)
        #expect(caps.supportsAudio)
        try VisionBundleFixture.writeWeights(["language_model.weight"],
                                             to: root.appendingPathComponent("model.safetensors"))
        #expect(!ModelMediaCapabilities.descriptor(directory: root, modelId: "neutral", refresh: true)
            .capabilities.supportsAudio)
    }

    @Test(arguments: ["patch_embed", "blocks.1", "merger"])
    func missingComponentRejected(component: String) throws {
        let root = try VisionBundleFixture.make(omit: component)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!VLMDetection.isVLM(at: root))
    }

    @Test func configAndWeightsBothRequired() throws {
        for value: Any in [NSNull(), [:] as [String: Any], ["depth": 2]] {
            let root = try VisionBundleFixture.make()
            defer { try? FileManager.default.removeItem(at: root) }
            try VisionBundleFixture.writeJSON(["model_type": "qwen3_5", "vision_config": value],
                                             to: root.appendingPathComponent("config.json"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("model.safetensors"))
            #expect(!LocalVisionEvidence.inspect(root).hasVision)
        }
        let root = try VisionBundleFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try VisionBundleFixture.writeJSON(["model_type": "qwen3_5", "vision_config": NSNull()],
                                         to: root.appendingPathComponent("config.json"))
        #expect(!VLMDetection.isVLM(at: root))
    }

    @Test func staleIndexCannotProveWeights() throws {
        let root = try VisionBundleFixture.make(indexed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(LocalVisionEvidence.inspect(root).hasVision)
        try VisionBundleFixture.writeWeights(["language_model.weight"], to: root.appendingPathComponent("model.safetensors"))
        #expect(!LocalVisionEvidence.inspect(root, refresh: true).hasVision)
    }

    @Test func refreshAndNotificationInvalidateBothDirections() throws {
        let root = try VisionBundleFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(VLMDetection.isVLM(at: root))
        let file = root.appendingPathComponent("config.json")
        let original = try Data(contentsOf: file)
        try VisionBundleFixture.writeJSON(["model_type": "qwen3_5"], to: file)
        #expect(!ModelMediaCapabilities.descriptor(directory: root, modelId: "Qwen3-VL", refresh: true).capabilities.supportsImage)
        try original.write(to: file)
        NotificationCenter.default.post(name: .localModelsChanged, object: nil)
        #expect(VLMDetection.isVLM(at: root))
    }

    @Test func newUnsupportedPayloadFailsInsteadOfDropping() throws {
        let image = Attachment.image(Data([1, 2, 3]))
        #expect(throws: ModelMediaCapabilities.UnsupportedAttachment.self) {
            try ModelMediaCapabilities.validateAttachments([image], capabilities: .textOnly)
        }
        try ModelMediaCapabilities.validateAttachments([image], capabilities: .imageOnly)
    }

    @Test func corruptHeaderAndAbsentProcessorRejected() throws {
        let root = try VisionBundleFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([255, 255, 255]).write(to: root.appendingPathComponent("model.safetensors"))
        #expect(!LocalVisionEvidence.inspect(root).hasVision)
        let other = try VisionBundleFixture.make()
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.removeItem(at: other.appendingPathComponent("processor_config.json"))
        #expect(!LocalVisionEvidence.inspect(other).hasVision)
    }
}
