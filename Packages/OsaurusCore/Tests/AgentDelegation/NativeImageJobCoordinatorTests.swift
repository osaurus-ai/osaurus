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
            imageModel(id: "default-model", ready: true, textToImage: true),
            imageModel(id: "explicit-model", ready: true, textToImage: true),
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
            imageModel(id: "first-ready", ready: true, textToImage: true),
            imageModel(id: "configured-model", ready: true, textToImage: true),
        ]

        let resolved = try NativeImageJobModelResolver.resolve(
            requested: nil,
            configured: "configured-model",
            available: available,
            kind: .imageGeneration
        )

        #expect(resolved == "configured-model")
    }

    @Test func resolverRejectsUnavailableRequestedModel() {
        let available = [
            imageModel(id: "default-model", ready: true, textToImage: true)
        ]

        #expect(throws: NativeImageJobCoordinatorError.self) {
            _ = try NativeImageJobModelResolver.resolve(
                requested: "missing-model",
                configured: "default-model",
                available: available,
                kind: .imageGeneration
            )
        }
    }

    @Test func resolverRejectsIncompleteConfiguredModel() {
        let available = [
            imageModel(id: "configured-model", ready: false, textToImage: true),
            imageModel(id: "fallback-ready", ready: true, textToImage: true),
        ]

        #expect(throws: NativeImageJobCoordinatorError.self) {
            _ = try NativeImageJobModelResolver.resolve(
                requested: nil,
                configured: "configured-model",
                available: available,
                kind: .imageGeneration
            )
        }
    }

    @Test func resolverRejectsWrongKindConfiguredModel() {
        let available = [
            imageModel(id: "configured-edit", ready: true, textToImage: false, imageEdit: true),
            imageModel(id: "fallback-ready", ready: true, textToImage: true),
        ]

        #expect(throws: NativeImageJobCoordinatorError.self) {
            _ = try NativeImageJobModelResolver.resolve(
                requested: nil,
                configured: "configured-edit",
                available: available,
                kind: .imageGeneration
            )
        }
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

    @Test func chatResidencyPolicyOnlyEvictsForAgentSingleResidency() {
        // The image-job residency decision now lives on the config as the single
        // source consumed by the shared `ChatResidencyHandoff` dedup.
        #expect(
            SubagentConfiguration(imageJobLoadPolicy: .agentSingleResidency)
                .imageJobUnloadsChatModels
        )
        #expect(
            !SubagentConfiguration(imageJobLoadPolicy: .unloadImageAfterAgentJob)
                .imageJobUnloadsChatModels
        )
        #expect(
            !SubagentConfiguration(imageJobLoadPolicy: .manualPanelKeepsImageLoaded)
                .imageJobUnloadsChatModels
        )
    }

    @Test("post-job chat restore is best-effort so a produced image is never lost")
    func restoreWiringIsBestEffort() throws {
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AgentDelegation/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
        let coordinator = try String(
            contentsOf: coreRoot.appendingPathComponent(
                "Services/AgentDelegation/NativeImageJobCoordinator.swift"
            ),
            encoding: .utf8
        )
        // The image is generated and written to disk BEFORE the chat-model
        // restore runs, so a reload hiccup must not throw and discard the user's
        // image. Pin the best-effort wiring (and the absence of the throwing
        // variant) so a future refactor can't silently reintroduce the loss.
        #expect(coordinator.contains("await ChatResidencyHandoff.restoreBestEffort(lease)"))
        #expect(!coordinator.contains("try await ChatResidencyHandoff.restore(lease)"))
    }

    @Test func progressDictionaryIncludesChatToolContext() throws {
        let turnID = UUID()
        let progress = NativeImageJobProgress(
            jobID: "job-1",
            phase: .generating,
            model: "image-model",
            step: 2,
            total: 4,
            context: NativeImageJobContext(
                sessionID: "session-1",
                assistantTurnID: turnID,
                toolCallID: "tool-call-1"
            )
        ).dictionary

        #expect(progress["session_id"] as? String == "session-1")
        #expect(progress["assistant_turn_id"] as? String == turnID.uuidString)
        #expect(progress["tool_call_id"] as? String == "tool-call-1")
    }

    @Test func qwenImageRequestsUseAtLeastTwoDenoiseSteps() {
        #expect(
            ImageGenerationService.safeDenoiseSteps(
                for: "qwen-image-mflux-4bit",
                requested: 1
            ) == 2
        )
        #expect(
            ImageGenerationService.safeDenoiseSteps(
                for: "Qwen-Image-Edit-mflux-q4",
                requested: 1
            ) == 2
        )
        #expect(
            ImageGenerationService.safeDenoiseSteps(
                for: "FLUX.1-schnell-mflux-4bit",
                requested: 1
            ) == 1
        )
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
