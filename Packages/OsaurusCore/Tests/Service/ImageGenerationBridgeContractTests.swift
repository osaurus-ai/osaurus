// Copyright 2026 Osaurus AI. All rights reserved.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Image generation bridge contract")
struct ImageGenerationBridgeContractTests {
    @Test("image models route through the image-generation picker source")
    func imageModelPickerItemUsesImageGenerationSource() {
        let model = ImageModelInfo(
            id: "Qwen-Image-Edit-mflux-q8",
            canonicalName: "qwen-image-edit",
            displayName: "Qwen Image Edit q8",
            kind: "imageEdit",
            ready: true,
            quantizationBits: 8,
            defaultSteps: 20,
            defaultGuidance: 4.0,
            capabilities: ImageModelCapabilities(imageEdit: true, multipleSourceImages: true),
            blockedReasons: [],
            totalBytes: 42
        )

        let item = ModelPickerItem.fromImageModel(model)

        #expect(item.id == "Qwen-Image-Edit-mflux-q8")
        #expect(item.displayName == "Qwen Image Edit q8")
        #expect(item.quantization == "8-bit")
        #expect(item.source.isImageGeneration)
        #expect(item.source.displayName == "Image Models")
    }

    @Test("source wiring keeps vMLXFlux bridge, routes, Metal gate, and proven revision")
    func sourceContractMatchesProvenVMLXRevision() throws {
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot =
            coreRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let packageSwift = try String(
            contentsOf: coreRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let service = try String(
            contentsOf: coreRoot.appendingPathComponent("Services/ModelRuntime/ImageGenerationService.swift"),
            encoding: .utf8
        )
        let gate = try String(
            contentsOf: coreRoot.appendingPathComponent("Services/ModelRuntime/MetalGate.swift"),
            encoding: .utf8
        )
        let handler = try String(
            contentsOf: coreRoot.appendingPathComponent("Networking/HTTPHandler.swift"),
            encoding: .utf8
        )
        let packageResolved = try String(
            contentsOf: coreRoot.appendingPathComponent("Package.resolved"),
            encoding: .utf8
        )
        let workspaceResolved = try String(
            contentsOf: repoRoot.appendingPathComponent("osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
            encoding: .utf8
        )
        let appResolved = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            ),
            encoding: .utf8
        )

        #expect(packageSwift.contains(#"revision: "8dffa0a8e69d7617d68f0843635158684120a3dc""#))
        #expect(packageResolved.contains(#""revision" : "8dffa0a8e69d7617d68f0843635158684120a3dc""#))
        #expect(workspaceResolved.contains(#""revision" : "8dffa0a8e69d7617d68f0843635158684120a3dc""#))
        #expect(appResolved.contains(#""revision" : "8dffa0a8e69d7617d68f0843635158684120a3dc""#))
        #expect(service.contains("import vMLXFlux"))
        #expect(service.contains("await MetalGate.shared.enterImageGeneration()"))
        #expect(service.contains("await MetalGate.shared.exitImageGeneration()"))
        #expect(gate.contains("public func enterImageGeneration() async"))
        #expect(gate.contains("public func exitImageGeneration()"))
        #expect(handler.contains(#"path == "/images/models""#))
        #expect(handler.contains(#"path == "/images/generations""#))
        #expect(handler.contains(#"path == "/images/edits""#))
        #expect(handler.contains(#"path == "/images/upscale""#))
        #expect(handler.contains(#"path == "/images/cancel""#))
    }
}
