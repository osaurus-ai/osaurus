import Foundation
import Testing
@testable import OsaurusCore

struct Flux3KleinToolWiringTests {
    @Test func generationUsesInstalledBundleDefaultsAndExplicitOverrides() {
        let info = ImageModelInfo(id: "local", canonicalName: "flux3-image-klein",
            displayName: "FLUX 3", kind: "imageGen", ready: true, quantizationBits: 4,
            defaultSteps: 23, defaultGuidance: 1,
            capabilities: ImageModelRequestPolicy.capabilities(kind: "imageGen", canonical: "flux3-image-klein"),
            blockedReasons: [], totalBytes: 0, defaultWidth: 768, defaultHeight: 1008)
        let defaults = ImageGenerationService.generationRequest(.init(model: "local", prompt: "bakery"),
            info: info, index: 0, outputDir: URL(fileURLWithPath: "/tmp"))
        #expect(defaults.width == 768 && defaults.height == 1008 && defaults.steps == 23)
        let explicit = ImageGenerationService.generationRequest(.init(model: "local", prompt: "bakery",
            width: 1008, height: 1328, steps: 101, seed: UInt64.max),
            info: info, index: 0, outputDir: URL(fileURLWithPath: "/tmp"))
        #expect(explicit.width == 1008 && explicit.height == 1328 && explicit.steps == 101)
        #expect(explicit.seed == UInt64.max)
    }
    @Test func toolAndSubagentPreserveExplicitParametersAfterResolution() throws {
        let raw = #"{"prompt":"bakery","width":1008,"height":1328,"steps":64,"negative_prompt":"ignored","seed":42}"#
        let args = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let legacy = ImageTool.buildParams(args: args, prompt: "bakery")
        let kind = ImageSubagentKind(params: legacy, argumentsJSON: raw)
        try kind.prepareLocalParameters(canonical: "flux3-image-klein", defaultGuidance: 1)
        let request = kind.localGenerateRequest(.init(name: "FLUX 3 Image Klein",
            id: "FLUX-3-Image-Klein-mflux-4bit", isLocal: true), context: .empty)
        #expect(request.width == 1008 && request.height == 1328 && request.steps == 64)
        #expect(request.negativePrompt == "ignored" && request.seed == 42)
    }
    @Test func toolKeepsAllOrderedReferencePathsAndOmittedSize() throws {
        let paths = (1...10).map { "/tmp/reference-\($0).png" }
        let object: [String: Any] = ["prompt": "combine", "source_paths": paths, "negative_prompt": "ignored"]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let parsed = try ImageTool.paramsForResolvedLocalModel(ImageJobParams(prompt: "combine", sourcePaths: []),
            argumentsJSON: raw, canonical: "flux3-image-klein", defaultGuidance: 1)
        #expect(parsed.sourcePaths == paths)
        #expect(parsed.width == nil && parsed.height == nil && parsed.steps == nil)
    }
}
