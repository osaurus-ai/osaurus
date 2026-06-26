//
//  SubagentConfigurationStoreTests.swift
//  osaurusTests
//
//  Persistence coverage for the local delegate/image-job settings store.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent delegation configuration store", .serialized)
struct SubagentConfigurationStoreTests {
    @Test("missing file snapshots to defaults")
    func missingFileSnapshotsToDefaults() async throws {
        let lease = await acquireSubagentStoreSandbox("agent-delegation-store")
        defer { lease.release() }

        #expect(SubagentConfigurationStore.load() == nil)
        #expect(SubagentConfigurationStore.snapshot() == .default)
    }

    @Test("save writes immediately and invalidated snapshot reloads")
    func saveWritesAndReloads() async throws {
        let lease = await acquireSubagentStoreSandbox("agent-delegation-store")
        defer { lease.release() }
        let sandbox = lease.sandbox

        let config = SubagentConfiguration(
            localTextDelegationEnabled: true,
            imageDelegationEnabled: true,
            defaultImageGenerationModelId: "  flux  ",
            defaultImageEditModelId: "qwen-edit",
            imageJobLoadPolicy: .unloadImageAfterAgentJob,
            permissionDefaults: SubagentPermissionDefaults(
                policies: ["spawn": .alwaysAllow, "image": .deny]
            ),
            budgets: SubagentBudgets(
                maxDelegateTokens: 100_000,
                maxDelegateTurns: 99,
                maxToolCalls: 99,
                maxElapsedSeconds: 99_999
            )
        )

        SubagentConfigurationStore.save(config)

        let file = sandbox.appendingPathComponent("agent-delegation.json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        SubagentConfigurationStore.invalidateSnapshot()
        let reloaded = SubagentConfigurationStore.snapshot()
        #expect(reloaded.localTextDelegationEnabled == true)
        #expect(reloaded.imageDelegationEnabled == true)
        #expect(reloaded.localOrchestratorTextHandoffActive == true)
        #expect(reloaded.imageDelegationActive == true)
        #expect(reloaded.defaultImageGenerationModelId == "flux")
        #expect(reloaded.imageJobLoadPolicy == .unloadImageAfterAgentJob)
        #expect(reloaded.permissionDefaults.policy(for: "spawn") == .alwaysAllow)
        #expect(reloaded.permissionDefaults.policy(for: "image") == .deny)
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
              "localTextDelegationEnabled": true,
              "defaultImageGenerationModelId": "flux"
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)

        #expect(decoded.localTextDelegationEnabled == true)
        #expect(decoded.imageDelegationEnabled == false)
        // No master switch: the handoff is active whenever its own toggle is on.
        #expect(decoded.localOrchestratorTextHandoffActive == true)
        // The main chat's image switch is off here, so image stays inactive.
        #expect(decoded.imageDelegationActive == false)
        #expect(decoded.defaultImageGenerationModelId == "flux")
    }

    @Test("override directory swaps between sandboxes")
    func overrideDirectorySwapsBetweenSandboxes() async throws {
        // `lease.sandbox` is the first override; `lease.release()` resets
        // the global override to nil and removes it. The second dir is
        // managed locally.
        let lease = await acquireSubagentStoreSandbox("agent-delegation-store-first")
        let first = lease.sandbox
        let second = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: second)
            lease.release()
        }

        SubagentConfigurationStore.save(
            SubagentConfiguration(defaultImageGenerationModelId: "first")
        )

        SubagentConfigurationStore.setOverrideDirectory(second)
        SubagentConfigurationStore.save(
            SubagentConfiguration(defaultImageGenerationModelId: "second")
        )

        let firstData = try Data(contentsOf: first.appendingPathComponent("agent-delegation.json"))
        let secondData = try Data(contentsOf: second.appendingPathComponent("agent-delegation.json"))
        let firstDecoded = try JSONDecoder().decode(SubagentConfiguration.self, from: firstData)
        let secondDecoded = try JSONDecoder().decode(SubagentConfiguration.self, from: secondData)

        #expect(firstDecoded.defaultImageGenerationModelId == "first")
        #expect(secondDecoded.defaultImageGenerationModelId == "second")
    }

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-agent-delegation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
