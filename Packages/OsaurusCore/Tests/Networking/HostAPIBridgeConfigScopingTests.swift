//
//  HostAPIBridgeConfigScopingTests.swift
//  osaurusTests
//
//  Pins the per-agent plugin-config scoping contract used by
//  `GET/POST /api/config/{key}` on the host bridge: configuration is
//  namespaced by the TOKEN-BOUND agent plus the plugin, writes only
//  ever land in the agent-scoped file, and reads fall back to the
//  legacy shared `config.json` (written before scoping existed)
//  without ever writing to it.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct HostAPIBridgeConfigScopingTests {

    private func withCleanPluginDir(
        _ plugin: String,
        _ body: @Sendable () async throws -> Void
    ) async rethrows {
        try await StoragePathsTestLock.shared.run {
            let dir = OsaurusPaths.pluginDataDirectory(for: plugin)
            try? FileManager.default.removeItem(at: dir)
            defer { try? FileManager.default.removeItem(at: dir) }
            try await body()
        }
    }

    @Test
    func filesAreNamespacedByAgentAndPlugin() {
        let agentA = UUID()
        let agentB = UUID()
        let a = HostAPIBridgeConfigStore.files(pluginName: "weather", agentId: agentA)
        let b = HostAPIBridgeConfigStore.files(pluginName: "weather", agentId: agentB)
        let c = HostAPIBridgeConfigStore.files(pluginName: "other", agentId: agentA)

        #expect(a.scoped != b.scoped)  // same plugin, different agents
        #expect(a.scoped != c.scoped)  // same agent, different plugins
        #expect(a.legacy == b.legacy)  // shared legacy file per plugin
        #expect(a.scoped.lastPathComponent == "config-\(agentA.uuidString).json")
    }

    @Test
    func twoAgentsCannotReadOrOverwriteEachOther() async {
        await withCleanPluginDir("scoping-probe") {
            let agentA = UUID()
            let agentB = UUID()
            let filesA = HostAPIBridgeConfigStore.files(
                pluginName: "scoping-probe", agentId: agentA)
            let filesB = HostAPIBridgeConfigStore.files(
                pluginName: "scoping-probe", agentId: agentB)

            HostAPIBridgeConfigStore.write(key: "city", value: "Tokyo", files: filesA)
            HostAPIBridgeConfigStore.write(key: "city", value: "Lisbon", files: filesB)

            #expect(HostAPIBridgeConfigStore.value(key: "city", files: filesA) == "Tokyo")
            #expect(HostAPIBridgeConfigStore.value(key: "city", files: filesB) == "Lisbon")
        }
    }

    @Test
    func legacySharedConfigFillsGapsButScopedWins() async throws {
        try await withCleanPluginDir("legacy-probe") {
            let agent = UUID()
            let files = HostAPIBridgeConfigStore.files(
                pluginName: "legacy-probe", agentId: agent)

            // Simulate a pre-scoping install: values in the shared file.
            try OsaurusPaths.ensureExists(files.legacy.deletingLastPathComponent())
            let legacy = ["city": "Berlin", "units": "metric"]
            try JSONSerialization.data(withJSONObject: legacy).write(to: files.legacy)

            // Unwritten key resolves through the legacy fallback.
            #expect(HostAPIBridgeConfigStore.value(key: "units", files: files) == "metric")

            // A scoped write shadows the legacy value for this agent only,
            // and never mutates the shared file.
            HostAPIBridgeConfigStore.write(key: "city", value: "Osaka", files: files)
            #expect(HostAPIBridgeConfigStore.value(key: "city", files: files) == "Osaka")
            let untouched =
                (try? JSONSerialization.jsonObject(with: Data(contentsOf: files.legacy)))
                as? [String: String]
            #expect(untouched?["city"] == "Berlin")
        }
    }
}
