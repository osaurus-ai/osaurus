//
//  AgentDelegationToolAvailabilityTests.swift
//  osaurusTests
//
//  Pins delegation settings as the source of truth for chat tool exposure.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent delegation tool availability", .serialized)
struct AgentDelegationToolAvailabilityTests {
    private static let localDelegateCatalog: [MLXModel] = [
        MLXModel(
            id: "JANGQ-AI/Laguna-M.1-JANG_2L",
            name: "Laguna M.1 JANG 2L",
            description: "fixture",
            downloadURL: "https://example.invalid/laguna"
        ),
        MLXModel(
            id: "OsaurusAI/VibeThinker-3B-MXFP4",
            name: "VibeThinker 3B MXFP4",
            description: "fixture",
            downloadURL: "https://example.invalid/vibethinker"
        ),
    ]

    @Test
    func imageToolsAreAbsentFromDefaultAlwaysLoadedSchema() async throws {
        try await withDelegationSandboxAsync(configuration: .default) {
            let names = await MainActor.run {
                Set(ToolRegistry.shared.alwaysLoadedSpecs(mode: .none).map(\.function.name))
            }
            #expect(!names.contains("image_generate"))
            #expect(!names.contains("image_edit"))
        }
    }

    @Test
    func imageToolsEnterSchemaWhenMasterAndImageDelegationAreEnabled() async throws {
        try await withDelegationSandboxAsync(
            configuration: AgentDelegationConfiguration(
                agentDelegationEnabled: true,
                imageDelegationEnabled: true
            )
        ) {
            let names = await MainActor.run {
                Set(ToolRegistry.shared.alwaysLoadedSpecs(mode: .none).map(\.function.name))
            }
            #expect(names.contains("image_generate"))
            #expect(names.contains("image_edit"))
        }
    }

    @Test
    func disabledImageDelegationBlocksDirectSpecLoading() async throws {
        try await withDelegationSandboxAsync(
            configuration: AgentDelegationConfiguration(
                agentDelegationEnabled: true,
                imageDelegationEnabled: false
            )
        ) {
            let (specs, availability) = await MainActor.run {
                (
                    ToolRegistry.shared.specs(forTools: ["image_generate", "image_edit"]),
                    ToolRegistry.shared.availability(forTool: "image_generate")
                )
            }

            #expect(specs.isEmpty)
            #expect(availability.reasonCodes.contains(.disabled))
            #expect(availability.detail.contains("agent delegation is disabled"))
        }
    }

    @Test
    func disabledImageDelegationRejectsStaleToolExecution() async throws {
        try await withDelegationSandboxAsync(configuration: .default) {
            let result = try await NativeImageGenerateTool().execute(
                argumentsJSON: #"{"prompt":"green apple"}"#
            )

            #expect(ToolEnvelope.isError(result))
            #expect(ToolEnvelope.failureMessage(result).contains("disabled in Agent Delegation settings"))
        }
    }

    @Test
    func localDelegateIsAbsentFromDefaultAlwaysLoadedSchema() async throws {
        try await withDelegationSandboxAsync(configuration: .default) {
            let names = await MainActor.run {
                Set(ToolRegistry.shared.alwaysLoadedSpecs(mode: .none).map(\.function.name))
            }
            #expect(!names.contains("local_delegate"))
        }
    }

    @Test
    func localDelegateEntersSchemaWhenMasterAndCloudTextDelegationAreEnabled() async throws {
        try await withDelegationSandboxAsync(
            configuration: AgentDelegationConfiguration(
                agentDelegationEnabled: true,
                cloudTextDelegationEnabled: true,
                defaultLocalTextDelegateModelId: "Laguna-M.1-JANG_2L"
            )
        ) {
            let names = await MainActor.run {
                Set(ToolRegistry.shared.alwaysLoadedSpecs(mode: .none).map(\.function.name))
            }
            #expect(names.contains("local_delegate"))
        }
    }

    @Test
    func disabledLocalDelegateBlocksDirectSpecLoading() async throws {
        try await withDelegationSandboxAsync(
            configuration: AgentDelegationConfiguration(
                agentDelegationEnabled: true,
                cloudTextDelegationEnabled: false
            )
        ) {
            let (specs, availability) = await MainActor.run {
                (
                    ToolRegistry.shared.specs(forTools: ["local_delegate"]),
                    ToolRegistry.shared.availability(forTool: "local_delegate")
                )
            }

            #expect(specs.isEmpty)
            #expect(availability.reasonCodes.contains(.disabled))
            #expect(availability.detail.contains("agent delegation is disabled"))
        }
    }

    @Test
    func disabledLocalDelegateRejectsStaleToolExecution() async throws {
        try await withDelegationSandboxAsync(configuration: .default) {
            let result = try await LocalTextDelegateTool().execute(
                argumentsJSON: #"{"task":"Summarize this small function."}"#
            )

            #expect(ToolEnvelope.isError(result))
            #expect(ToolEnvelope.failureMessage(result).contains("disabled in Agent Delegation settings"))
        }
    }

    @Test
    func localDelegateRejectsMissingConfiguredLocalModel() async throws {
        try await withLocalModelCatalog(Self.localDelegateCatalog) {
            try await withDelegationSandboxAsync(
                configuration: AgentDelegationConfiguration(
                    agentDelegationEnabled: true,
                    cloudTextDelegationEnabled: true,
                    defaultLocalTextDelegateModelId: "missing-model",
                    permissionDefaults: AgentDelegationPermissionDefaults(localTextDelegate: .alwaysAllow)
                )
            ) {
                let result = try await LocalTextDelegateTool().execute(
                    argumentsJSON: #"{"task":"Summarize this small function."}"#
                )

                #expect(ToolEnvelope.isError(result))
                #expect(ToolEnvelope.failureMessage(result).contains("not installed"))
            }
        }
    }

    private func withDelegationSandboxAsync(
        configuration: AgentDelegationConfiguration,
        body: () async throws -> Void
    ) async throws {
        let sandbox = try makeSandbox()
        defer {
            AgentDelegationConfigurationStore.setOverrideDirectory(nil)
            try? FileManager.default.removeItem(at: sandbox)
        }
        AgentDelegationConfigurationStore.setOverrideDirectory(sandbox)
        AgentDelegationConfigurationStore.save(configuration)
        try await body()
    }

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-agent-delegation-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func withLocalModelCatalog(
        _ models: [MLXModel],
        body: () async throws -> Void
    ) async throws {
        let prevScan = ModelManager.scanLocalModelsOverrideForTests
        let prevWait = ModelManager.localModelsScanWaitLimitOverrideForTests
        let prevExternal = ExternalModelLocator.testRootsOverride

        ExternalModelLocator.testRootsOverride = []
        ExternalModelLocator.invalidateInMemory()
        _ = ExternalModelLocator.rescan()
        ModelManager.localModelsScanWaitLimitOverrideForTests = 2.0
        ModelManager.scanLocalModelsOverrideForTests = { _ in models }
        ModelManager.invalidateLocalModelsCache()
        _ = ModelManager.discoverLocalModels()

        defer {
            ModelManager.scanLocalModelsOverrideForTests = prevScan
            ModelManager.localModelsScanWaitLimitOverrideForTests = prevWait
            ExternalModelLocator.testRootsOverride = prevExternal
            ExternalModelLocator.invalidateInMemory()
            ModelManager.invalidateLocalModelsCache()
        }

        try await body()
    }
}
