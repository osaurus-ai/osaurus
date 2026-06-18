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
}
