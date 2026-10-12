import Foundation
import Testing
@testable import OsaurusCore

struct QwenImage21BridgeTests {
    @Test func dualCapabilitiesAdmitBothOperations() {
        let caps = ImageModelRequestPolicy.capabilities(kind: "imageGen", canonical: "qwen-image-2.1")
        #expect(caps.textToImage && caps.imageEdit && caps.multipleSourceImages)
        #expect(ImageModelRequestPolicy.supports("imageGen", capabilities: caps))
        #expect(ImageModelRequestPolicy.supports("imageEdit", capabilities: caps))
        #expect(!caps.mask && !caps.editNegativePrompt && !caps.editStrength)
        #expect(caps.dimensionMultiple == 32)
    }
    @Test func olderFamiliesRetainTheirAdmission() {
        let gen = ImageModelRequestPolicy.capabilities(kind: "imageGen", canonical: "qwen-image")
        let edit = ImageModelRequestPolicy.capabilities(kind: "imageEdit", canonical: "qwen-image-edit")
        #expect(gen.textToImage && !gen.imageEdit && gen.dimensionMultiple == 16)
        #expect(edit.imageEdit && !edit.textToImage && edit.multipleSourceImages)
        #expect(!ImageModelRequestPolicy.supports("imageEdit", capabilities: gen))
        #expect(ImageModelRequestPolicy(canonical: "qwen-image-edit").editStrength(nil) == 0.75)
    }
    @Test func explicitDimensionsAreNotSilentlyResized() throws {
        let policy = ImageModelRequestPolicy(canonical: "qwen-image-2.1")
        try policy.validate(width: 1024, height: 832, isEdit: false, guidance: 1, negativePrompt: nil)
        #expect(throws: ImageGenerationError.self) {
            try policy.validate(width: 1008, height: 1024, isEdit: false, guidance: 1, negativePrompt: nil)
        }
        try ImageModelRequestPolicy(canonical: "qwen-image").validate(
            width: 1008, height: 1024, isEdit: false, guidance: 3.5, negativePrompt: nil)
    }
    @Test func nativeReferenceSizeAndOmittedStrengthRemainOmitted() throws {
        let policy = ImageModelRequestPolicy(canonical: "qwen-image-2.1")
        let params = ImageEditParameters(model: "q21", prompt: "edit", sourceImages: [Data()])
        #expect(params.width == nil && params.height == nil && params.strength == nil)
        #expect(policy.editStrength(params.strength) == 1)
        try policy.validate(width: nil, height: nil, isEdit: true, guidance: 1,
            negativePrompt: nil, sourceCount: 4)
    }
    @Test func unsupportedEditParametersReturnErrors() {
        let p = ImageModelRequestPolicy(canonical: "qwen-image-2.1")
        #expect(!p.supportsEditNegativePrompt && !p.supportsEditStrength)
        #expect(throws: ImageGenerationError.self) {
            try p.validate(width: nil, height: nil, isEdit: true, guidance: 1,
                negativePrompt: "blur", sourceCount: 1)
        }
        #expect(throws: ImageGenerationError.self) {
            try p.validate(width: nil, height: nil, isEdit: true, guidance: 1,
                negativePrompt: nil, strength: 0.75, sourceCount: 1)
        }
        #expect(throws: ImageGenerationError.self) {
            try p.validate(width: nil, height: nil, isEdit: true, guidance: 1,
                negativePrompt: nil, hasMask: true, sourceCount: 1)
        }
        #expect(throws: ImageGenerationError.self) {
            try p.validate(width: nil, height: nil, isEdit: true, guidance: 1,
                negativePrompt: nil, sourceCount: 5)
        }
    }
    @Test func negativePromptRequiresExplicitCFG() throws {
        let p = ImageModelRequestPolicy(canonical: "qwen-image-2.1")
        #expect(throws: ImageGenerationError.self) {
            try p.validate(width: 1024, height: 1024, isEdit: false, guidance: 1, negativePrompt: "blur")
        }
        try p.validate(width: 1024, height: 1024, isEdit: false, guidance: 2.5, negativePrompt: "blur")
    }
    @Test func catalogAliasesDoNotClaimFutureQwenFamilies() {
        for alias in ["Qwen-Image-2.1-mflux-8bit", "Qwen-Image-2-1-mflux-6bit", "Qwen-Image-21-mflux-4bit"] {
            #expect(ImageModelRequestPolicy.catalogCanonical(alias) == "qwen-image-2.1")
        }
        #expect(ImageModelRequestPolicy.catalogCanonical("Qwen-Image-2.2-mflux-8bit") == nil)
        #expect(ImageModelRequestPolicy.licenseLabel(canonical: "qwen-image-2.1") != nil)
        #expect(ImageModelRequestPolicy.licenseLabel(canonical: "ideogram") != nil)
    }

    // Qwen-Image-2.1-Turbo: same engine class and dual bundle, own canonical id (8-step grid).
    @Test func turboSharesTheQwen21ContractAndDualCapability() throws {
        #expect(ImageModelRequestPolicy.isQwen21Family("qwen-image-2.1-turbo"))
        #expect(ImageModelRequestPolicy.isQwen21Family("qwen-image-2.1"))
        #expect(!ImageModelRequestPolicy.isQwen21Family("qwen-image") && !ImageModelRequestPolicy.isQwen21Family(nil))
        let caps = ImageModelRequestPolicy.capabilities(kind: "imageGen", canonical: "qwen-image-2.1-turbo")
        #expect(caps.textToImage && caps.imageEdit && caps.multipleSourceImages)
        #expect(!caps.mask && !caps.editNegativePrompt && !caps.editStrength && caps.dimensionMultiple == 32)
        let policy = ImageModelRequestPolicy(canonical: "qwen-image-2.1-turbo")
        #expect(policy.isQwen21 && policy.editStrength(nil) == 1)
        try policy.validate(width: nil, height: nil, isEdit: true, guidance: 1, negativePrompt: nil, sourceCount: 2)
        #expect(throws: ImageGenerationError.self) {
            try policy.validate(width: 1008, height: 1024, isEdit: false, guidance: 1, negativePrompt: nil)
        }
    }
    @Test func turboCatalogIdentityAndLicense() {
        for alias in ["Qwen-Image-2.1-Turbo-mflux-8bit", "OsaurusAI/Qwen-Image-2.1-Turbo-mflux-4bit", "qwen_image_21_turbo"] {
            #expect(ImageModelRequestPolicy.catalogCanonical(alias) == "qwen-image-2.1-turbo")
        }
        #expect(ImageModelRequestPolicy.catalogCanonical("Qwen-Image-2.1-mflux-6bit") == "qwen-image-2.1")
        #expect(ImageModelRequestPolicy.catalogCanonical("Z-Image-Turbo-mflux-4bit") == nil)
        #expect(ImageModelRequestPolicy.licenseLabel(canonical: "qwen-image-2.1-turbo") != nil)
    }
}
