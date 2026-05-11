//
//  PluginCrashLoopGuardTests.swift
//  osaurusTests
//
//  Pins the contract of the host's plugin crash-loop guard:
//
//  - A `.currently_loading` marker left behind by a crash inside the
//    first-delivery window (`runFirstDeliverySweep` → ABI handshake
//    probe / `on_config_changed`) promotes to a `.quarantine` entry
//    on the NEXT scan, so the host stops re-loading the same broken
//    plugin on every launch.
//  - `removeFromQuarantine(_:)` clears a single plugin id WITHOUT
//    unhiding the rest, and also wipes the loading marker so the
//    plugin isn't re-quarantined on the next scan.
//  - `FailedPlugin.lastKnownManifest` flows from `PluginLoadError`
//    through `_loadAll` so `AgentDetailView`'s failed-plugin tab can
//    apply the same `pluginAppearsInAgentDetailTabs` filter that loaded
//    plugins use.
//
//  We can't actually `abort()` the test process to validate the
//  marker mechanically. Instead we exercise the path the marker
//  enables: write the marker (the same way `runFirstDeliverySweep`
//  does just before the probe), then drive the production scan
//  helper that promotes stale markers to quarantine entries.
//

import Foundation
import OsaurusRepository
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct PluginCrashLoopGuardTests {

    // MARK: - Test scaffolding

    /// Redirects both path roots at a fresh temp directory for the
    /// duration of `body`. `PluginManager.toolsRootDirectory()` reads
    /// through `ToolsPaths.toolsRootDirectory()` (which lives in
    /// `OsaurusRepository`, NOT `OsaurusPaths`) so the override has to
    /// hit `ToolsPaths.overrideRoot` for marker / quarantine files to
    /// land inside the temp dir. `OsaurusPaths.overrideRoot` is set
    /// too so any sibling helper that reads via `OsaurusPaths.tools()`
    /// stays in lock-step.
    private func withTempToolsRoot<T: Sendable>(
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await StoragePathsTestLock.shared.run {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-crashloop-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let toolsRoot = tmp.appendingPathComponent("Tools", isDirectory: true)
            try FileManager.default.createDirectory(at: toolsRoot, withIntermediateDirectories: true)
            let previousOsaurus = OsaurusPaths.overrideRoot
            let previousTools = ToolsPaths.overrideRoot
            OsaurusPaths.overrideRoot = tmp
            ToolsPaths.overrideRoot = tmp
            defer {
                OsaurusPaths.overrideRoot = previousOsaurus
                ToolsPaths.overrideRoot = previousTools
                try? FileManager.default.removeItem(at: tmp)
            }
            return try await body(toolsRoot)
        }
    }

    private func writeMarker(pluginId: String, in toolsRoot: URL) throws {
        let url = toolsRoot.appendingPathComponent(".currently_loading", isDirectory: false)
        try pluginId.data(using: .utf8)!.write(to: url)
    }

    private func markerExists(in toolsRoot: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: toolsRoot.appendingPathComponent(".currently_loading").path
        )
    }

    /// Pre-seeds the quarantine file directly so the test can assert
    /// that `removeFromQuarantine(_:)` operates on the right bucket
    /// without depending on a real plugin scan.
    private func writeQuarantine(_ ids: [String], in toolsRoot: URL) throws {
        let data = try JSONEncoder().encode(ids)
        try data.write(to: toolsRoot.appendingPathComponent(".quarantine"))
    }

    // MARK: - Marker promotion

    /// `toolsDirectoryURLsWithFailures` runs `promoteStaleLoadingMarker`
    /// at the top of every scan. If the previous run left a marker
    /// behind (i.e. `runFirstDeliverySweep` wrote it for the probe and
    /// the plugin's `on_config_changed` aborted the host before
    /// `clearLoadingMarker()`), the next scan moves the id into
    /// `.quarantine` and the marker is wiped. This is the mechanism
    /// that breaks the "host crashes on every launch" loop the user
    /// hit with the misaligned-mirror Telegram plugin.
    @Test
    func staleMarkerPromotesToQuarantineOnNextScan() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeMarker(pluginId: "ai.osaurus.guarded-test", in: toolsRoot)
            #expect(markerExists(in: toolsRoot))

            _ = PluginManager.toolsDirectoryURLsWithFailures()

            #expect(!markerExists(in: toolsRoot))
            #expect(PluginManager.quarantinedPluginIds().contains("ai.osaurus.guarded-test"))
        }
    }

    /// Empty / whitespace-only marker contents must NOT poison the
    /// quarantine list. Otherwise a partially-flushed marker write
    /// (host SIGABRTed mid-write) could promote the empty string and
    /// hide the bug.
    @Test
    func emptyMarkerDoesNotPromote() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeMarker(pluginId: "   ", in: toolsRoot)

            _ = PluginManager.toolsDirectoryURLsWithFailures()

            #expect(PluginManager.quarantinedPluginIds().isEmpty)
        }
    }

    /// Re-running the scan after the marker has already been promoted
    /// must NOT re-promote anything (no marker on disk → nothing to
    /// promote). Defends against an off-by-one where the scan reads
    /// the marker file even when it doesn't exist anymore.
    @Test
    func successfulScanDoesNotReQuarantine() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeMarker(pluginId: "ai.osaurus.first", in: toolsRoot)
            _ = PluginManager.toolsDirectoryURLsWithFailures()
            #expect(PluginManager.quarantinedPluginIds() == ["ai.osaurus.first"])

            _ = PluginManager.toolsDirectoryURLsWithFailures()
            _ = PluginManager.toolsDirectoryURLsWithFailures()

            #expect(PluginManager.quarantinedPluginIds() == ["ai.osaurus.first"])
            #expect(!markerExists(in: toolsRoot))
        }
    }

    // MARK: - Per-plugin quarantine removal

    /// The `Retry` button on `AgentDetailView`'s failed-plugin tab calls
    /// `removeFromQuarantine(_:)`. It must clear ONLY the named plugin
    /// — clearing the entire `.quarantine` file would silently re-load
    /// every other broken plugin and risk re-entering the crash loop.
    @Test
    func removeFromQuarantineDropsOnlyTheNamedId() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeQuarantine(
                ["ai.osaurus.alpha", "ai.osaurus.beta", "ai.osaurus.gamma"],
                in: toolsRoot
            )
            #expect(PluginManager.quarantinedPluginIds().count == 3)

            PluginManager.removeFromQuarantine("ai.osaurus.beta")

            let remaining = PluginManager.quarantinedPluginIds()
            #expect(remaining == ["ai.osaurus.alpha", "ai.osaurus.gamma"])
        }
    }

    /// When the LAST id is removed the quarantine file must be deleted
    /// outright (not left as `[]`). `quarantinedPluginIds()` treats
    /// missing-file and empty-list identically so the user behaviour is
    /// the same either way, but leaving an empty file behind would be
    /// surprising during manual inspection of `~/.osaurus/Tools/`.
    @Test
    func removeFromQuarantineDeletesFileWhenEmptied() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeQuarantine(["ai.osaurus.only"], in: toolsRoot)

            PluginManager.removeFromQuarantine("ai.osaurus.only")

            #expect(PluginManager.quarantinedPluginIds().isEmpty)
            #expect(
                !FileManager.default.fileExists(
                    atPath: toolsRoot.appendingPathComponent(".quarantine").path
                )
            )
        }
    }

    /// Removing an id that's NOT in the list is a no-op — does not
    /// truncate the file, does not raise. Matches the contract the
    /// AgentsView retry path relies on (it calls remove unconditionally
    /// before triggering the reload).
    @Test
    func removeFromQuarantineIgnoresUnknownId() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeQuarantine(["ai.osaurus.alpha"], in: toolsRoot)

            PluginManager.removeFromQuarantine("ai.osaurus.unknown")

            #expect(PluginManager.quarantinedPluginIds() == ["ai.osaurus.alpha"])
        }
    }

    /// `removeFromQuarantine` must also wipe the `.currently_loading`
    /// marker if one is sitting on disk — otherwise a Retry would
    /// drop the quarantine entry, then the next scan's
    /// `promoteStaleLoadingMarker` would silently re-add the same id
    /// and the user would see "still failed" with no explanation.
    @Test
    func removeFromQuarantineWipesStaleLoadingMarker() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeQuarantine(["ai.osaurus.target"], in: toolsRoot)
            try writeMarker(pluginId: "ai.osaurus.target", in: toolsRoot)

            PluginManager.removeFromQuarantine("ai.osaurus.target")

            #expect(PluginManager.quarantinedPluginIds().isEmpty)
            #expect(!markerExists(in: toolsRoot))
        }
    }

    // MARK: - FailedPlugin manifest propagation

    /// The new `lastKnownManifest` field on `FailedPlugin` lets the
    /// agent detail view filter failed plugins by the same surface
    /// signals (config / instructions / secrets / routes / web) it
    /// uses for loaded plugins. Pre-API-default tests would have
    /// passed without anyone noticing the field went missing.
    @Test
    func failedPluginCarriesLastKnownManifestWhenProvided() {
        let manifest = PluginManifest(
            plugin_id: "ai.osaurus.test.manifest",
            description: "test",
            capabilities: PluginManifest.Capabilities(
                tools: nil,
                routes: nil,
                config: nil,
                web: nil,
                artifact_handler: nil
            ),
            instructions: nil,
            name: "Manifest Test",
            version: nil,
            license: nil,
            authors: nil,
            min_macos: nil,
            min_osaurus: nil,
            secrets: nil,
            docs: nil
        )

        let failed = PluginManager.FailedPlugin(
            pluginId: "ai.osaurus.test.manifest",
            error: "boom",
            lastKnownManifest: manifest
        )

        #expect(failed.lastKnownManifest?.plugin_id == "ai.osaurus.test.manifest")
        #expect(failed.lastKnownManifest?.name == "Manifest Test")
    }

    /// Default-init path (no manifest provided, e.g. the failure
    /// happened before `get_manifest` returned) leaves the field nil.
    /// `failedPluginAppearsInAgentDetailTabs` treats nil as "show
    /// anyway" — the user still needs to see and recover the failure.
    @Test
    func failedPluginManifestDefaultsToNil() {
        let failed = PluginManager.FailedPlugin(
            pluginId: "ai.osaurus.test.early",
            error: "dlopen failed"
        )

        #expect(failed.lastKnownManifest == nil)
    }

    /// `PluginLoadError` carries the manifest forward to the call site
    /// in `_loadAll` that constructs the `FailedPlugin`. The default
    /// init must keep the field optional so existing call sites
    /// (parse-manifest failure, web/route shadow, dlopen failure)
    /// keep compiling without churn.
    @Test
    func pluginLoadErrorManifestDefaultsToNil() {
        let error = PluginManager.PluginLoadError(message: "test")

        #expect(error.manifest == nil)
        #expect(error.message == "test")
        #expect(error.description == "test")
    }
}
