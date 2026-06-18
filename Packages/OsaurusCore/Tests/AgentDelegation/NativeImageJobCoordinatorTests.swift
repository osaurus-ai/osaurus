//
//  NativeImageJobCoordinatorTests.swift
//  osaurus
//

import Foundation
import Testing

@testable import OsaurusCore

struct NativeImageJobCoordinatorTests {
    @Test func resolverPrefersExplicitRequestedModel() throws {
        let available = [
            imageModel(id: "default-model", ready: true, textToImage: true)
        ]

        let resolved = try NativeImageJobModelResolver.resolve(
            requested: " explicit-model ",
            configured: "default-model",
            available: available,
            kind: .imageGeneration
        )

        #expect(resolved == "explicit-model")
    }

    @Test func resolverUsesConfiguredDefaultBeforeScanningAvailableModels() throws {
        let available = [
            imageModel(id: "first-ready", ready: true, textToImage: true)
        ]

        let resolved = try NativeImageJobModelResolver.resolve(
            requested: nil,
            configured: "configured-model",
            available: available,
            kind: .imageGeneration
        )

        #expect(resolved == "configured-model")
    }

    @Test func resolverSkipsIncompleteAndWrongCapabilityModels() throws {
        let available = [
            imageModel(id: "incomplete", ready: false, textToImage: true),
            imageModel(id: "edit-only", ready: true, textToImage: false, imageEdit: true),
            imageModel(id: "ready-gen", ready: true, textToImage: true),
        ]

        let resolved = try NativeImageJobModelResolver.resolve(
            requested: " ",
            configured: nil,
            available: available,
            kind: .imageGeneration
        )

        #expect(resolved == "ready-gen")
    }

    @Test func resolverThrowsWhenNoReadyGenerationModelExists() {
        let available = [
            imageModel(id: "edit-only", ready: true, textToImage: false, imageEdit: true)
        ]

        #expect(throws: NativeImageJobCoordinatorError.self) {
            _ = try NativeImageJobModelResolver.resolve(
                requested: nil,
                configured: nil,
                available: available,
                kind: .imageGeneration
            )
        }
    }

    @Test func resolverSelectsReadyEditModelForImageEditJobs() throws {
        let available = [
            imageModel(id: "gen-only", ready: true, textToImage: true),
            imageModel(id: "ready-edit", ready: true, textToImage: false, imageEdit: true),
        ]

        let resolved = try NativeImageJobModelResolver.resolve(
            requested: nil,
            configured: nil,
            available: available,
            kind: .imageEdit
        )

        #expect(resolved == "ready-edit")
    }

    private func imageModel(
        id: String,
        ready: Bool,
        textToImage: Bool,
        imageEdit: Bool = false
    ) -> ImageModelInfo {
        ImageModelInfo(
            id: id,
            canonicalName: nil,
            displayName: id,
            kind: imageEdit ? "imageEdit" : "imageGen",
            ready: ready,
            quantizationBits: nil,
            defaultSteps: nil,
            defaultGuidance: nil,
            capabilities: ImageModelCapabilities(textToImage: textToImage, imageEdit: imageEdit),
            blockedReasons: ready ? [] : ["missing weights"],
            totalBytes: 0
        )
    }
}
