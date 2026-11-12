import Foundation
import Testing
import vMLXFlux

@testable import OsaurusCore

@Suite("Image family capability parity")
struct ImageFamilyCapabilityParityTests {
    init() throws {
        let env = ProcessInfo.processInfo.environment
        if let path = env["OSAURUS_TEST_EVIDENCE_DIR"] {
            let names = ["OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS", "OSAURUS_TEST_ROOT",
                "OSU_MODELS_DIR", "OSAURUS_IMAGE_MODELS_DIR", "OSAURUS_TEST_EVIDENCE_DIR"]
            let data = try JSONSerialization.data(withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "flags": Dictionary(uniqueKeysWithValues: names.map { ($0, env[$0] ?? "<absent>") }),
            ], options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: path)
                .appendingPathComponent("image-capabilities-\(UUID()).json"), options: [.withoutOverwriting])
        }
    }

    private func limits(negative: Bool, editNegative: Bool = false, ignored: Bool = false) -> FluxModelLimits {
        FluxModelLimits(dimensionMultiple: 16, minDimension: 16, minimumSteps: 1,
            supportsNegativePrompt: negative, supportsEditNegativePrompt: editNegative,
            ignoresNegativePrompt: ignored, supportsStrength: false, supportsMask: false,
            maxSourceImages: 4, supportedFormats: [.png])
    }

    private func observe(_ name: String, _ values: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["OSAURUS_TEST_EVIDENCE_DIR"] else { return }
        var row = values
        row["case"] = name
        row["pid"] = ProcessInfo.processInfo.processIdentifier
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path)
            .appendingPathComponent("image-values-\(UUID()).json"), options: [.withoutOverwriting])
    }

    @Test("Turbo presentation follows its publisher rather than base Z-Image CFG")
    func turboDoesNotOfferCFG() throws {
        #expect(!ImageModelRequestPolicy(canonical: "z-image-turbo").supportsGuidance)
        let caps = ImageGenerationService.capabilities(kind: .imageGen,
            canonical: "z-image-turbo", entry: nil, limits: limits(negative: false, ignored: true))
        try observe("turbo", [
            "guidance": ImageModelRequestPolicy(canonical: "z-image-turbo").supportsGuidance,
            "negative": caps.negativePrompt, "editNegative": caps.editNegativePrompt,
        ])
        #expect(caps.textToImage)
        #expect(!caps.imageEdit)
        #expect(!caps.negativePrompt)
        #expect(!caps.editNegativePrompt)
    }

    @Test("model controls do not advertise negative branches rejected by native limits")
    func nativeLimitsConstrainPresentation() throws {
        for canonical in ["flux1-schnell", "ideogram"] {
            let caps = ImageGenerationService.capabilities(kind: .imageGen,
                canonical: canonical, entry: nil, limits: limits(negative: false))
            try observe(canonical, ["negative": caps.negativePrompt, "editNegative": caps.editNegativePrompt])
            #expect(caps.textToImage)
            #expect(!caps.negativePrompt)
            #expect(!caps.editNegativePrompt)
        }
        let edit = ImageGenerationService.capabilities(kind: .imageEdit,
            canonical: "qwen-image-edit", entry: nil, limits: limits(negative: false))
        try observe("qwen-image-edit", ["negative": edit.negativePrompt, "editNegative": edit.editNegativePrompt])
        #expect(edit.imageEdit)
        #expect(edit.multipleSourceImages)
        #expect(!edit.negativePrompt)
        #expect(!edit.editNegativePrompt)
    }

    @Test("supported Qwen conditioning and distinct dual-use contracts remain available")
    func supportedFamiliesKeepTheirControls() {
        let qwen = ImageGenerationService.capabilities(kind: .imageGen,
            canonical: "qwen-image", entry: nil, limits: limits(negative: true))
        #expect(qwen.negativePrompt)
        #expect(ImageModelRequestPolicy(canonical: "qwen-image").supportsGuidance)
        let dual = ImageGenerationService.capabilities(kind: .imageGen,
            canonical: "qwen-image-2.1-turbo", entry: nil, limits: limits(negative: true))
        #expect(dual.textToImage && dual.imageEdit && dual.multipleSourceImages)
        #expect(dual.negativePrompt)
        #expect(!dual.editNegativePrompt)
        #expect(!ImageModelRequestPolicy(canonical: "flux3-image-klein").supportsGuidance)
    }
}
