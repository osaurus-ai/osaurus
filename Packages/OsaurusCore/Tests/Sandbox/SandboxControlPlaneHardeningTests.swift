//
//  SandboxControlPlaneHardeningTests.swift
//  osaurusTests
//
//  The host-side gates around what sandboxed code and the model can reach:
//  bridge inference and dispatch, the control-plane tool policies, the
//  scope requirement for the private sandbox adapters, and the boot-asset
//  digest records.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Sandbox control plane hardening")
struct SandboxControlPlaneHardeningTests {

    // MARK: - Code Can Use Osaurus

    @Test("Host services are off by default and when absent from saved config")
    func hostServicesDefaultOff() throws {
        #expect(AutonomousExecConfig.default.hostServicesEnabled == false)
        #expect(AutonomousExecConfig(enabled: true).hostServicesEnabled == false)

        let legacy = #"{"enabled":true,"maxCommandsPerTurn":10,"pluginCreate":true}"#
        let decoded = try JSONDecoder().decode(AutonomousExecConfig.self, from: Data(legacy.utf8))
        #expect(decoded.hostServicesEnabled == false)
    }

    @Test("Host services survive an encode and decode")
    func hostServicesRoundTrip() throws {
        let config = AutonomousExecConfig(enabled: true, hostServicesEnabled: true)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AutonomousExecConfig.self, from: data)
        #expect(decoded.hostServicesEnabled == true)
    }

    // MARK: - Bridge dispatch

    @Test("A task started from the sandbox runs external with no folder")
    func bridgeDispatchIsExternal() {
        let identity = SandboxBridgeTokenStore.Identity(agentId: UUID(), linuxName: "agent-x")
        let request = HostBridgeRequests.dispatchRequest(
            task: "do it", identity: identity, externalSessionKey: "k")

        #expect(request.externalSurface)
        #expect(BackgroundTaskManager.resolvedExternalSurface(for: request))
        #expect(!BackgroundTaskManager.isUnattended(request, externalSurface: true))
        #expect(request.folderPath == nil)
        #expect(request.folderBookmark == nil)
        #expect(request.source == .plugin)
        #expect(request.agentId == identity.agentId)
    }

    // MARK: - Control-plane tool policies

    @Test("Storing a model-supplied secret asks; the secure prompt does not")
    func secretSetAsksOnlyWithValue() async {
        let tool = SandboxSecretSetTool(agentId: UUID().uuidString)
        #expect(tool.defaultPermissionPolicy == .auto)

        let prompt = #"{"key":"K","description":"d","instructions":"i"}"#
        let empty = #"{"key":"K","description":"d","instructions":"i","value":""}"#
        let supplied = #"{"key":"K","description":"d","instructions":"i","value":"sk-123456"}"#
        #expect(await tool.resolveContextualPermissionPolicy(argumentsJSON: prompt) == .auto)
        #expect(await tool.resolveContextualPermissionPolicy(argumentsJSON: empty) == .auto)
        #expect(await tool.resolveContextualPermissionPolicy(argumentsJSON: supplied) == .ask)
    }

    @Test("Registering a plugin asks by default")
    func pluginRegisterAsks() {
        let tool = SandboxPluginRegisterTool(agentId: UUID().uuidString, agentName: "a")
        #expect(tool.defaultPermissionPolicy == .ask)
    }

    // MARK: - Adapter scope

    @Test("Sandbox adapters are refused when no request scope is published", arguments: [
        "sandbox_exec", "sandbox_read_file", "sandbox_write_file", "sandbox_search_files",
    ])
    @MainActor
    func adaptersRequireScope(name: String) async throws {
        let output = try await ToolRegistry.shared.execute(name: name, argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(output))
        #expect(output.contains("is not available here"))
    }

    // MARK: - Boot assets

    @Test("A staged asset matches only the digest recorded for it")
    func stagedAssetDigestRecord() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-boot-asset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = dir.appendingPathComponent("initfs.ext4")
        let record = SandboxManager.initFSDigestFile(for: asset)
        try Data("initfs".utf8).write(to: asset)

        #expect(await !SandboxManager.stagedAssetMatchesRecord(asset, record: record))

        try await SandboxManager.recordAssetDigest(of: asset, to: record)
        #expect(await SandboxManager.stagedAssetMatchesRecord(asset, record: record))

        try Data("tampered".utf8).write(to: asset)
        #expect(await !SandboxManager.stagedAssetMatchesRecord(asset, record: record))
    }
}
