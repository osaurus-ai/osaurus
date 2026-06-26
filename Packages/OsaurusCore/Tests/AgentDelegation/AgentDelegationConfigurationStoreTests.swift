//
//  AgentDelegationConfigurationStoreTests.swift
//  osaurusTests
//
//  Persistence coverage for the local delegate/image-job settings store.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent delegation configuration store", .serialized)
struct AgentDelegationConfigurationStoreTests {
    @Test("missing file snapshots to defaults")
    func missingFileSnapshotsToDefaults() throws {
        let sandbox = try makeSandbox()
        defer {
            AgentDelegationConfigurationStore.setOverrideDirectory(nil)
            try? FileManager.default.removeItem(at: sandbox)
        }

        AgentDelegationConfigurationStore.setOverrideDirectory(sandbox)
        #expect(AgentDelegationConfigurationStore.load() == nil)
        #expect(AgentDelegationConfigurationStore.snapshot() == .default)
    }

    @Test("save writes immediately and invalidated snapshot reloads")
    func saveWritesAndReloads() throws {
        let sandbox = try makeSandbox()
        defer {
            AgentDelegationConfigurationStore.setOverrideDirectory(nil)
            try? FileManager.default.removeItem(at: sandbox)
        }

        AgentDelegationConfigurationStore.setOverrideDirectory(sandbox)
        let config = AgentDelegationConfiguration(
            agentDelegationEnabled: true,
            cloudTextDelegationEnabled: true,
            imageDelegationEnabled: true,
            defaultLocalTextDelegateModelId: "  local-chat  ",
            defaultImageGenerationModelId: "flux",
            defaultImageEditModelId: "qwen-edit",
            textDelegateLoadPolicy: .keepWarmWhenSafe,
            imageJobLoadPolicy: .unloadImageAfterAgentJob,
            sharingPolicy: .askBeforeExpandedSharing,
            permissionDefaults: AgentDelegationPermissionDefaults(
                localTextDelegate: .alwaysAllow,
                localTextDelegateToolUse: .deny,
                imageGenerate: .alwaysAllow,
                imageEdit: .ask
            ),
            budgets: AgentDelegationBudgets(
                maxDelegateTokens: 100_000,
                maxDelegateTurns: 99,
                maxToolCalls: 99,
                maxElapsedSeconds: 99_999
            )
        )

        AgentDelegationConfigurationStore.save(config)

        let file = sandbox.appendingPathComponent("agent-delegation.json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        AgentDelegationConfigurationStore.invalidateSnapshot()
        let reloaded = AgentDelegationConfigurationStore.snapshot()
        #expect(reloaded.agentDelegationEnabled == true)
        #expect(reloaded.cloudTextDelegationEnabled == true)
        #expect(reloaded.imageDelegationEnabled == true)
        #expect(reloaded.localTextDelegationActive == true)
        #expect(reloaded.imageDelegationActive == true)
        #expect(reloaded.defaultLocalTextDelegateModelId == "local-chat")
        #expect(reloaded.budgets.maxDelegateTokens == 32_768)
        #expect(reloaded.budgets.maxDelegateTurns == 8)
        #expect(reloaded.budgets.maxToolCalls == 32)
        #expect(reloaded.budgets.maxElapsedSeconds == 1_800)
    }

    @Test("legacy files decode with safe delegation defaults")
    func legacyFilesDecodeWithSafeDefaults() throws {
        let data = Data(
            """
            {
              "cloudTextDelegationEnabled": true,
              "defaultImageGenerationModelId": "flux"
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(AgentDelegationConfiguration.self, from: data)

        #expect(decoded.agentDelegationEnabled == false)
        #expect(decoded.cloudTextDelegationEnabled == true)
        #expect(decoded.imageDelegationEnabled == false)
        #expect(decoded.localTextDelegationActive == false)
        #expect(decoded.imageDelegationActive == false)
        #expect(decoded.defaultImageGenerationModelId == "flux")
    }

    @Test("override directory swaps between sandboxes")
    func overrideDirectorySwapsBetweenSandboxes() throws {
        let first = try makeSandbox()
        let second = try makeSandbox()
        defer {
            AgentDelegationConfigurationStore.setOverrideDirectory(nil)
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        AgentDelegationConfigurationStore.setOverrideDirectory(first)
        AgentDelegationConfigurationStore.save(
            AgentDelegationConfiguration(defaultLocalTextDelegateModelId: "first")
        )

        AgentDelegationConfigurationStore.setOverrideDirectory(second)
        AgentDelegationConfigurationStore.save(
            AgentDelegationConfiguration(defaultLocalTextDelegateModelId: "second")
        )

        let firstData = try Data(contentsOf: first.appendingPathComponent("agent-delegation.json"))
        let secondData = try Data(contentsOf: second.appendingPathComponent("agent-delegation.json"))
        let firstDecoded = try JSONDecoder().decode(AgentDelegationConfiguration.self, from: firstData)
        let secondDecoded = try JSONDecoder().decode(AgentDelegationConfiguration.self, from: secondData)

        #expect(firstDecoded.defaultLocalTextDelegateModelId == "first")
        #expect(secondDecoded.defaultLocalTextDelegateModelId == "second")
    }

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-agent-delegation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
