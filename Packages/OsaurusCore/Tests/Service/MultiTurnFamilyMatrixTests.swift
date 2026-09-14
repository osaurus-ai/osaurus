import Foundation
import Testing
@testable import OsaurusCore

/// Checkpoint facts, not product-name expectations. These are routing tests,
/// not inference or multi-turn model-quality proof.
@Suite("ModelMediaCapabilities — bundle directory matrix")
struct CapabilityFromDirectoryTests {
    @Test(arguments: ["paligemma", "idefics3", "fastvlm", "llava_qwen2", "pixtral", "mistral3",
                      "ministral3", "lfm2_vl", "glm_ocr", "gemma3", "smolvlm", "muse_glimmer", "zaya1_vl"])
    func registeredVisionArchitectureRequiresWeights(type: String) throws {
        let dir = try VisionBundleFixture.make(type: type)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelMediaCapabilities.from(directory: dir, modelId: "neutral").supportsImage)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("model.safetensors"))
        #expect(!ModelMediaCapabilities.descriptor(directory: dir, modelId: "Qwen3-VL", refresh: true).capabilities.supportsImage)
    }

    @Test(arguments: ["step3p7", "nemotron_h", "mimo_v2", "unknown_vl_arch"])
    func unsupportedArchitectureCannotBeEnabledByVisionWeights(type: String) throws {
        let dir = try VisionBundleFixture.make(type: type)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!ModelMediaCapabilities.from(directory: dir, modelId: "Qwen3-VL").anyMedia)
    }

    @Test func sidecarPresenceAloneIsInsufficient() throws {
        let dir = try VisionBundleFixture.make(type: "nemotron_h")
        defer { try? FileManager.default.removeItem(at: dir) }
        try VisionBundleFixture.writeJSON(["enabled": true], to: dir.appendingPathComponent("config_omni.json"))
        #expect(!VLMDetection.isVLM(at: dir))
    }
}

@Suite("Composer — model switch capability isolation")
struct MultiTurnCapabilityStabilityTests {
    @Test func switchingBundlesDoesNotLeakMedia() throws {
        let imageVideo = try VisionBundleFixture.make(type: "qwen3_5")
        let imageOnly = try VisionBundleFixture.make(type: "gemma4")
        let textOnly = try VisionBundleFixture.make(type: "qwen3_5", omit: "merger")
        defer { for dir in [imageVideo, imageOnly, textOnly] { try? FileManager.default.removeItem(at: dir) } }
        for (dir, expected) in [(imageVideo, ModelMediaCapabilities.Capabilities.imageVideo),
                                (imageOnly, .imageOnly), (textOnly, .textOnly), (imageVideo, .imageVideo)] {
            let caps = ModelMediaCapabilities.from(directory: dir, modelId: "same-display-name")
            #expect(caps == expected)
            #expect(ModelMediaCapabilities.composerCapabilities(modelId: "Qwen3-VL",
                fallbackSupportsImages: true, localCapabilities: caps) == expected)
        }
    }
}

@Suite("Provider capability fallback")
struct CapabilityFromModelIdTests {
    @Test func unknownProviderImagePermissionDoesNotGrantAudioOrVideo() {
        for alias in ["Qwen3-VL", "Nemotron-3-Nano-Omni", "opaque-provider-id"] {
            #expect(ModelMediaCapabilities.composerCapabilities(modelId: alias,
                fallbackSupportsImages: true, localCapabilities: nil) == .imageOnly)
        }
    }
}
