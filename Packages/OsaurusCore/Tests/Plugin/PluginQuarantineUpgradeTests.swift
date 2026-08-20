import Foundation
import OsaurusRepository
import Testing

@testable import OsaurusCore

/// A quarantine row used to be a bare plugin id, which made the quarantine
/// permanent: a plugin that aborted once during load stayed skipped forever —
/// across plugin upgrades AND across app rebuilds — until the user found the
/// per-plugin Retry button. Seen on a live install, where `osaurus.calendar`
/// had been quarantined by an old crash and loaded cleanly (registering its
/// four tools) the instant the row was dropped.
///
/// Rows now carry the plugin version and host build that crashed, and a row is
/// released for exactly ONE fresh attempt when either no longer matches. These
/// pin that contract, including the part that keeps the crash-loop guard
/// intact: releasing *consumes* the row, so a plugin that crashes again is
/// re-quarantined with the new stamp rather than retried every launch.
@Suite(.serialized)
struct PluginQuarantineUpgradeTests {

    private func withTempToolsRoot<T: Sendable>(
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try await StoragePathsTestLock.shared.run {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-quarantine-\(UUID().uuidString)")
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

    private func writeEntries(
        _ entries: [PluginManager.QuarantineEntry], in toolsRoot: URL
    ) throws {
        try JSONEncoder().encode(entries)
            .write(to: toolsRoot.appendingPathComponent(".quarantine"))
    }

    /// The pre-stamp on-disk shape: a JSON array of bare ids.
    private func writeLegacyQuarantine(_ ids: [String], in toolsRoot: URL) throws {
        try JSONEncoder().encode(ids)
            .write(to: toolsRoot.appendingPathComponent(".quarantine"))
    }

    // MARK: - Backward compatibility

    @Test("a legacy bare-id file still reports its ids")
    func legacyFileDecodes() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeLegacyQuarantine(["ai.osaurus.alpha", "ai.osaurus.beta"], in: toolsRoot)

            #expect(
                PluginManager.quarantinedPluginIds() == ["ai.osaurus.alpha", "ai.osaurus.beta"])
            // Decoded with no stamps — nothing to compare, so nothing is claimed
            // about what crashed.
            let entries = PluginManager.quarantineEntries()
            #expect(entries.count == 2)
            #expect(entries.allSatisfy { $0.version == nil && $0.build == nil })
        }
    }

    /// A legacy row cannot be released automatically: it records nothing about
    /// what crashed, so "has it changed?" is unanswerable. It stays for Retry.
    @Test("a legacy row is never auto-released")
    func legacyRowIsNotReleased() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeLegacyQuarantine(["ai.osaurus.alpha"], in: toolsRoot)

            let released = PluginManager.releaseQuarantineIfUpgraded(
                pluginId: "ai.osaurus.alpha",
                installedVersion: "9.9.9",
                hostBuild: "999"
            )

            #expect(released == false)
            #expect(PluginManager.quarantinedPluginIds() == ["ai.osaurus.alpha"])
        }
    }

    // MARK: - Release conditions

    @Test("upgrading the plugin releases the row for one attempt")
    func pluginUpgradeReleasesRow() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeEntries(
                [.init(id: "ai.osaurus.alpha", version: "1.0.10", build: "42")], in: toolsRoot)

            #expect(
                PluginManager.releaseQuarantineIfUpgraded(
                    pluginId: "ai.osaurus.alpha", installedVersion: "1.0.11", hostBuild: "42"))
            // Consumed, not merely ignored — otherwise every launch would retry.
            #expect(PluginManager.quarantinedPluginIds().isEmpty)
        }
    }

    @Test("upgrading the host releases the row for one attempt")
    func hostUpgradeReleasesRow() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeEntries(
                [.init(id: "ai.osaurus.alpha", version: "1.0.10", build: "42")], in: toolsRoot)

            #expect(
                PluginManager.releaseQuarantineIfUpgraded(
                    pluginId: "ai.osaurus.alpha", installedVersion: "1.0.10", hostBuild: "43"))
            #expect(PluginManager.quarantinedPluginIds().isEmpty)
        }
    }

    /// The whole point of the guard: same plugin, same host, still quarantined.
    @Test("an unchanged pair stays quarantined")
    func unchangedPairStaysQuarantined() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeEntries(
                [.init(id: "ai.osaurus.alpha", version: "1.0.10", build: "42")], in: toolsRoot)

            #expect(
                PluginManager.releaseQuarantineIfUpgraded(
                    pluginId: "ai.osaurus.alpha", installedVersion: "1.0.10", hostBuild: "42")
                    == false)
            #expect(PluginManager.quarantinedPluginIds() == ["ai.osaurus.alpha"])
        }
    }

    /// Releasing must not disturb anyone else's row — the same reason
    /// `removeFromQuarantine` exists instead of `clearQuarantine`.
    @Test("releasing one row leaves the others intact")
    func releaseTouchesOnlyTheNamedRow() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeEntries(
                [
                    .init(id: "ai.osaurus.alpha", version: "1.0.10", build: "42"),
                    .init(id: "ai.osaurus.beta", version: "2.0.0", build: "42"),
                ], in: toolsRoot)

            #expect(
                PluginManager.releaseQuarantineIfUpgraded(
                    pluginId: "ai.osaurus.alpha", installedVersion: "1.0.11", hostBuild: "42"))

            #expect(PluginManager.quarantinedPluginIds() == ["ai.osaurus.beta"])
        }
    }

    /// A plugin with no row at all is loadable; the caller must not treat a
    /// missing row as "quarantined".
    @Test("an absent row reports releasable")
    func absentRowIsReleasable() async throws {
        try await withTempToolsRoot { _ in
            #expect(
                PluginManager.releaseQuarantineIfUpgraded(
                    pluginId: "ai.osaurus.unknown", installedVersion: "1.0.0", hostBuild: "42"))
        }
    }

    /// A plugin whose install has been removed resolves to no version. That is
    /// a change from the recorded one, so the row releases and the scan then
    /// fails it with the honest "no valid version directory" reason instead of
    /// the misleading crash message.
    @Test("a vanished install releases the row")
    func vanishedInstallReleasesRow() async throws {
        try await withTempToolsRoot { toolsRoot in
            try writeEntries(
                [.init(id: "ai.osaurus.alpha", version: "1.0.10", build: "42")], in: toolsRoot)

            #expect(
                PluginManager.releaseQuarantineIfUpgraded(
                    pluginId: "ai.osaurus.alpha", installedVersion: nil, hostBuild: "42"))
            #expect(PluginManager.quarantinedPluginIds().isEmpty)
        }
    }

    // MARK: - Crash-loop guard still holds

    /// Release consumes the row, so a plugin that aborts on the retry is
    /// re-quarantined by the marker path — this time stamped with the new pair,
    /// which then compares equal and keeps it out.
    @Test("a re-crash after release quarantines with the new stamp")
    func reCrashAfterReleaseReQuarantines() async throws {
        try await withTempToolsRoot { toolsRoot in
            let pluginDir = toolsRoot.appendingPathComponent("ai.osaurus.alpha", isDirectory: true)
            let versionDir = pluginDir.appendingPathComponent("1.0.11", isDirectory: true)
            try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

            try writeEntries(
                [.init(id: "ai.osaurus.alpha", version: "1.0.10", build: "42")], in: toolsRoot)
            #expect(
                PluginManager.releaseQuarantineIfUpgraded(
                    pluginId: "ai.osaurus.alpha", installedVersion: "1.0.11", hostBuild: "42"))

            // The retry aborts: a stale loading marker is what survives.
            try Data("ai.osaurus.alpha".utf8)
                .write(to: toolsRoot.appendingPathComponent(".currently_loading"))
            _ = PluginManager.toolsDirectoryURLsWithFailures()

            let entries = PluginManager.quarantineEntries()
            #expect(entries.count == 1)
            // Stamped with what is installed NOW, so the same pair is not
            // retried again on the next launch.
            #expect(entries.first?.version == "1.0.11")
        }
    }

    // MARK: - Version resolution

    @Test("the highest SemVer directory is what a row is compared against")
    func versionResolutionPicksHighestSemVer() async throws {
        try await withTempToolsRoot { toolsRoot in
            let pluginDir = toolsRoot.appendingPathComponent("ai.osaurus.alpha", isDirectory: true)
            for v in ["1.0.9", "1.0.10", "1.0.2"] {
                try FileManager.default.createDirectory(
                    at: pluginDir.appendingPathComponent(v, isDirectory: true),
                    withIntermediateDirectories: true)
            }

            #expect(PluginManager.resolveVersionDirectory(pluginDir)?.lastPathComponent == "1.0.10")
        }
    }
}
