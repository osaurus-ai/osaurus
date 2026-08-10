//
//  PluginSupersededSkipTests.swift
//  osaurus
//
//  Superseded plugins (native features replaced them) must be skipped at the
//  scan stage — their dylibs are never dlopen'd, so they can't reach the tool
//  registry, the skill manager, or the ABI probe / config-push crash surface.
//  `excludeSupersededPlugins` is the pure function `performPluginScan` applies
//  to every scan result; these tests pin its contract without real dylibs.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct PluginSupersededSkipTests {

    /// Builds the canonical install-layout dylib URL for a plugin id
    /// (`.../Tools/{pluginId}/{version}/plugin.dylib`) — the shape
    /// `extractPluginId` derives the id from.
    private func dylibURL(for pluginId: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent(pluginId, isDirectory: true)
            .appendingPathComponent("1.0.0", isDirectory: true)
            .appendingPathComponent("plugin.dylib", isDirectory: false)
    }

    @Test func supersededDylibsAreDroppedFromTheLoadList() {
        let regular = dylibURL(for: "osaurus.telegram")
        let urls =
            PluginManager.supersededPluginIds.map { dylibURL(for: $0) } + [regular]

        let result = PluginManager.excludeSupersededPlugins(urls: urls, failures: [:])

        // Nothing superseded survives to dlopen; everything else does.
        #expect(result.urls == [regular])
    }

    @Test func supersededVerificationFailuresAreDropped() {
        // A superseded plugin with (say) a missing consent marker must show
        // the "Built into Osaurus" banner, not a load error — its failure
        // entry is dropped while other plugins' failures are preserved.
        let failures = [
            "osaurus.browser": "consent_required: Plugin has not been approved",
            "osaurus.search": "Checksum verification failed",
            "osaurus.telegram": "Missing receipt.json - plugin cannot be verified",
        ]

        let result = PluginManager.excludeSupersededPlugins(urls: [], failures: failures)

        #expect(
            result.failures == [
                "osaurus.telegram": "Missing receipt.json - plugin cannot be verified"
            ]
        )
    }

    @Test func supersededListCoversBothNativeReplacements() {
        // Both migrated plugins must stay covered by the scan skip, and each
        // must keep a native settings tab for the banner's deep link.
        for pluginId in ["osaurus.search", "osaurus.browser"] {
            #expect(PluginManager.supersededPluginIds.contains(pluginId))
            #expect(PluginManager.nativeSettingsTab(forSupersededPlugin: pluginId) != nil)
        }
    }
}
