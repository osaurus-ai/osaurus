import Foundation
import XCTest
@testable import OsaurusCore

final class Flux3KleinBridgeTests: XCTestCase {
    private let canonical = "flux3-image-klein"
    private var info: ImageModelInfo {
        ImageModelInfo(id: "FLUX-3-Image-Klein-mflux-4bit", canonicalName: canonical,
            displayName: "FLUX 3 Image Klein", kind: "imageGen", ready: true, quantizationBits: 4,
            defaultSteps: 16, defaultGuidance: 1,
            capabilities: ImageModelRequestPolicy.capabilities(kind: "imageGen", canonical: canonical),
            blockedReasons: [], totalBytes: 0)
    }
    func testCapabilitiesAndAdvisoryEstimates() {
        let caps = info.capabilities
        XCTAssertTrue(caps.textToImage && caps.imageEdit && caps.multipleSourceImages)
        XCTAssertFalse(caps.negativePrompt || caps.editNegativePrompt || caps.editStrength || caps.mask)
        XCTAssertEqual(caps.dimensionMultiple, 16)
        XCTAssertFalse(ImageModelRequestPolicy(canonical: canonical).supportsGuidance)
        XCTAssertTrue(ImageModelRequestPolicy(canonical: canonical).estimatesAreAdvisory)
        XCTAssertFalse(ImageModelRequestPolicy(canonical: "qwen-image-2.1").estimatesAreAdvisory)
        XCTAssertEqual(ImageModelRequestPolicy(canonical: canonical).editStrength(nil), 1)
    }
    func testStampEnvelopeWithoutExtraStepOrPixelCap() throws {
        let policy = ImageModelRequestPolicy(canonical: canonical)
        try policy.validate(width: 4096, height: 4096, isEdit: false, guidance: 1,
            negativePrompt: "accepted and ignored", steps: 64, outputFormat: .png)
        try policy.validate(width: nil, height: nil, isEdit: true, guidance: 1,
            negativePrompt: "ignored", sourceCount: 10, steps: 1)
        for sourceCount in [0, 11] {
            XCTAssertThrowsError(try policy.validate(width: nil, height: nil, isEdit: true,
                guidance: 1, negativePrompt: nil, sourceCount: sourceCount))
        }
        XCTAssertThrowsError(try policy.validate(width: 1000, height: 1024, isEdit: false,
            guidance: 1, negativePrompt: nil))
        let limits = ImageHTTPParameterBuilder.limits(for: info)
        XCTAssertEqual(limits.max_dimension, 4096)
        XCTAssertEqual(limits.max_source_images, 10)
        XCTAssertNil(limits.max_steps)
        XCTAssertNil(limits.max_pixels)
    }
    func testComposerPreservesBundleDefaultsAndUnsizedReferences() throws {
        let settings = ImageComposerSettings(negativePrompt: "left over from another model")
        let caps = info.capabilities
        let request = try ImageComposerRequestBuilder.build(modelID: info.id, canonical: canonical,
            capabilities: caps, fallbackKind: "imageGen", prompt: "combine", sourceImages: [Data([1]), Data([2])], settings: settings)
        guard case .edit(let edit) = request else { return XCTFail("references must select edit") }
        XCTAssertNil(edit.width); XCTAssertNil(edit.height); XCTAssertNil(edit.steps)
        XCTAssertNil(edit.guidance); XCTAssertNil(edit.strength); XCTAssertNil(edit.negativePrompt)
        XCTAssertEqual(edit.sourceImages, [Data([1]), Data([2])])
        let controls = ImageComposerRequestBuilder.controls(capabilities: caps, fallbackKind: "imageGen", hasReferences: true)
        XCTAssertFalse(ImageComposerRequestBuilder.hasUnsupportedEditOverrides(controls: controls, settings: settings, canonical: canonical))
    }
    func testComposerPreservesExplicitSixteenAlignedDimensionsAndSteps() throws {
        let settings = ImageComposerSettings(steps: 64, guidance: 3.5, width: 1008, height: 1328)
        let request = try ImageComposerRequestBuilder.build(modelID: info.id, canonical: canonical,
            capabilities: info.capabilities, fallbackKind: "imageGen", prompt: "bakery", sourceImages: [], settings: settings)
        guard case .generate(let gen) = request else { return XCTFail("text-only must generate") }
        XCTAssertEqual(gen.width, 1008); XCTAssertEqual(gen.height, 1328); XCTAssertEqual(gen.steps, 64)
        XCTAssertNil(gen.guidance)
    }
    func testHTTPBuildersAcceptNegativeAndPreserveNilEditDimensions() throws {
        let decoder = JSONDecoder()
        let generate = try decoder.decode(ImageGenerationRequestDTO.self,
            from: Data(#"{"prompt":"bakery","negative_prompt":"ignored","width":1008,"height":1328,"steps":64}"#.utf8))
        let gen = try ImageHTTPParameterBuilder.generation(generate, info: info)
        XCTAssertEqual(gen.width, 1008); XCTAssertEqual(gen.height, 1328); XCTAssertEqual(gen.steps, 64)
        XCTAssertEqual(gen.negativePrompt, "ignored")
        let edit = try decoder.decode(ImageEditRequestDTO.self,
            from: Data(#"{"prompt":"combine","images":["a","b"],"negative_prompt":"ignored"}"#.utf8))
        // A real tiny PNG, decoded by the same host validator as API inputs.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+nmV8AAAAASUVORK5CYII=")!
        let built = try ImageHTTPParameterBuilder.edit(edit, info: info, decodedSources: [png, png])
        XCTAssertEqual(built.sourceImages.count, 2)
        XCTAssertNil(built.width); XCTAssertNil(built.height)
        XCTAssertEqual(built.negativePrompt, "ignored")
        XCTAssertNoThrow(try ImageModelRequestPolicy(canonical: canonical).validate(width: nil, height: nil,
            isEdit: true, guidance: 1, negativePrompt: built.negativePrompt, sourceCount: 2))
    }
    func testPanelSnapsOnlyToDeclaredDimensionEnvelope() {
        let policy = ImageModelRequestPolicy(canonical: canonical)
        XCTAssertEqual(policy.snappedDimension(1008, limits: nil), 1008)
        XCTAssertEqual(policy.snappedDimension(1328, limits: nil), 1328)
        XCTAssertEqual(policy.snappedDimension(1001, limits: nil), 1008)
        XCTAssertEqual(policy.snappedDimension(1, limits: nil), 64)
        XCTAssertEqual(policy.snappedDimension(5000, limits: nil), 4096)
    }
    func testCatalogIdentityAndLicense() {
        for bits in [4, 6, 8] {
            XCTAssertEqual(ImageModelRequestPolicy.catalogCanonical("OsaurusAI/FLUX-3-Image-Klein-mflux-\(bits)bit"), canonical)
        }
        XCTAssertNil(ImageModelRequestPolicy.catalogCanonical("FLUX-3-Image-Klein-Base-mflux-4bit"))
        XCTAssertEqual(ImageModelRequestPolicy.licenseLabel(canonical: canonical), "FLUX Kommunity (non-commercial)")
    }
}
