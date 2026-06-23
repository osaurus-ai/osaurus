//
//  OsaurusPaths.swift
//  osaurus
//
//  Centralized path management for all Osaurus app data.
//  Provides consistent directory structure across all components.
//

import AppKit
import Foundation

/// Centralized path management for all Osaurus app data.
/// All stores and services should use this module for path resolution.
public enum OsaurusPaths {
    /// Optional root directory override for tests
    /// Note: nonisolated(unsafe) since this is only set during test setup before any concurrent access
    nonisolated(unsafe) public static var overrideRoot: URL?

    // MARK: - Root Directory

    private static let defaultRoot: URL = {
        let fm = FileManager.default
        let newRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".osaurus", isDirectory: true)
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldRoot = supportDir.appendingPathComponent("com.dinoki.osaurus", isDirectory: true)

        _ = migrateLegacyApplicationSupportRootIfNeeded(
            fileManager: fm,
            legacyRoot: oldRoot,
            activeRoot: newRoot
        )

        return newRoot
    }()

    /// Marker written after the legacy Application Support root has been
    /// copied/merged into `~/.osaurus`. The legacy root is intentionally never
    /// deleted, so this marker prevents every future launch from re-merging it.
    public static let legacyApplicationSupportMergeMarkerName =
        ".legacy-application-support-merge.done"

    enum LegacyApplicationSupportMigrationResult: Equatable {
        case legacyRootAbsent
        case alreadyMarked(URL)
        case copied(URL)
        case merged(URL)
    }

    /// The root data directory for Osaurus: `~/.osaurus/`
    public static func root() -> URL {
        if let override = overrideRoot {
            return override
        }
        if let envRoot = ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"],
            !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: envRoot, isDirectory: true)
        }
        return defaultRoot
    }

    /// Returns the marker path for a resolved root without triggering another
    /// root lookup when the caller already has one.
    public static func legacyApplicationSupportMergeMarker(for root: URL) -> URL {
        root.appendingPathComponent(legacyApplicationSupportMergeMarkerName)
    }

    // MARK: - Directory Paths

    /// Configuration files directory
    public static func config() -> URL {
        root().appendingPathComponent("config", isDirectory: true)
    }

    /// Voice-related configuration directory
    public static func voiceConfig() -> URL {
        config().appendingPathComponent("voice", isDirectory: true)
    }

    /// Provider configurations directory
    public static func providers() -> URL {
        root().appendingPathComponent("providers", isDirectory: true)
    }

    /// Agents directory
    public static func agents() -> URL {
        root().appendingPathComponent("agents", isDirectory: true)
    }

    /// Per-agent invite ledger directory (one JSON file per agent).
    /// Sibling of `agents()` so `AgentStore` doesn't try to decode the
    /// ledger files as agent records.
    public static func agentInvites() -> URL {
        root().appendingPathComponent("agent-invites", isDirectory: true)
    }

    /// Remote (paired) agents that the receiver has added from someone else's
    /// share link. Distinct from `agents()` — those are the local agents
    /// this device owns and signs for.
    public static func remoteAgents() -> URL {
        root().appendingPathComponent("remote-agents", isDirectory: true)
    }

    /// Themes directory
    public static func themes() -> URL {
        root().appendingPathComponent("themes", isDirectory: true)
    }

    /// Chat sessions directory (legacy JSON files, archived after migration)
    public static func sessions() -> URL {
        root().appendingPathComponent("sessions", isDirectory: true)
    }

    /// Archive directory used by the chat-history SQLite migration to retain
    /// the original per-session JSON files (never deleted).
    public static func sessionsArchive() -> URL {
        root().appendingPathComponent("sessions.archive", isDirectory: true)
    }

    /// Chat history database directory
    public static func chatHistory() -> URL {
        root().appendingPathComponent("chat-history", isDirectory: true)
    }

    /// Provider-neutral Agent Channel message state.
    public static func agentChannels() -> URL {
        root().appendingPathComponent("agent-channels", isDirectory: true)
    }

    /// Schedules directory
    public static func schedules() -> URL {
        root().appendingPathComponent("schedules", isDirectory: true)
    }

    /// Watchers directory
    public static func watchers() -> URL {
        root().appendingPathComponent("watchers", isDirectory: true)
    }

    /// Runtime state directory
    public static func runtime() -> URL {
        root().appendingPathComponent("runtime", isDirectory: true)
    }

    /// Cache directory
    public static func cache() -> URL {
        root().appendingPathComponent("cache", isDirectory: true)
    }

    /// Output directory for locally generated images (vMLXFlux). The image
    /// engine writes the final PNG here and returns the URL; the chat layer
    /// copies the bytes into its attachment store and HTTP `response_format:url`
    /// callers receive a `file://` path under this directory.
    public static func generatedImages() -> URL {
        root().appendingPathComponent("generated-images", isDirectory: true)
    }

    /// Disk KV cache directory used by vmlx-swift's `DiskCache` (L2 tier).
    /// Stores SQLite index + safetensors blocks keyed by model + token hash.
    public static func diskKVCache() -> URL {
        cache().appendingPathComponent("kv_v2", isDirectory: true)
    }

    /// Current size of the disk KV cache in bytes. Returns 0 when the
    /// directory doesn't exist yet.
    public static func diskKVCacheUsageBytes() -> Int {
        let url = diskKVCache()
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return directorySize(at: url)
    }

    // MARK: - Volume free-space query
    //
    // Prefer the cheap POSIX filesystem query. On some external/APFS volumes
    // `.volumeAvailableCapacityForImportantUsageKey` enters CacheDelete and can
    // block model load for minutes before any weights are mapped. The URL-keyed
    // query remains a fallback for volumes where legacy `.systemFreeSize` is
    // missing or reports zero under sandbox/container pressure.

    /// Returns the free byte count on the volume that hosts `path`. Uses the
    /// legacy filesystem attribute first to avoid CacheDelete stalls, then falls
    /// back to `.volumeAvailableCapacityForImportantUsageKey` when needed.
    /// Returns `nil` if both queries fail — callers should treat `nil` as
    /// "unknown, render 'unknown'" rather than coercing to zero.
    public static func volumeFreeBytes(forPath path: String) -> Int64? {
        var legacyFree: Int64?
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
            let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
        {
            legacyFree = free
        }
        if let legacyFree, legacyFree > 0 {
            return legacyFree
        }

        let url = URL(fileURLWithPath: path)
        var importantCapacity: Int64?
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        if let values = try? url.resourceValues(forKeys: keys),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        {
            importantCapacity = capacity
        }
        return resolvedVolumeFreeBytes(
            importantCapacity: importantCapacity,
            legacyFree: legacyFree
        )
    }

    static func resolvedVolumeFreeBytes(
        importantCapacity: Int64?,
        legacyFree: Int64?
    ) -> Int64? {
        if let legacyFree, legacyFree > 0 {
            return legacyFree
        }
        if let importantCapacity, importantCapacity > 0 {
            return importantCapacity
        }
        return importantCapacity ?? legacyFree
    }

    /// Returns total volume capacity in bytes for the volume that hosts
    /// `path`. Uses `.volumeTotalCapacityKey` first, legacy `.systemSize`
    /// as fallback. Returns `nil` on full failure.
    public static func volumeTotalBytes(forPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey]
        if let values = try? url.resourceValues(forKeys: keys),
            let capacity = values.volumeTotalCapacity
        {
            return Int64(capacity)
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
            let total = (attrs[.systemSize] as? NSNumber)?.int64Value
        {
            return total
        }
        return nil
    }

    /// Deletes every file under the disk KV cache directory. The directory
    /// itself is left in place (re-created on next model load via
    /// `ensureExistsSilent`). Safe to call while models are loaded — the
    /// package's `DiskCache` will reopen its SQLite handle on the next
    /// `storeAfterGeneration` call, but may log errors for writes that race
    /// the deletion. For a clean clear, call `ModelRuntime.shared.clearAll()`
    /// first to release the coordinators.
    ///
    /// Returns the number of bytes freed.
    @discardableResult
    public static func clearDiskKVCache() -> Int {
        let url = diskKVCache()
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let before = directorySize(at: url)
        if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for entry in contents {
                try? fm.removeItem(at: entry)
            }
        }
        return before
    }

    /// Skills directory
    public static func skills() -> URL {
        root().appendingPathComponent("skills", isDirectory: true)
    }

    /// Artifacts directory
    public static func artifacts() -> URL {
        root().appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Work data directory
    public static func workData() -> URL {
        root().appendingPathComponent("work", isDirectory: true)
    }

    /// Memory system data directory
    public static func memory() -> URL {
        root().appendingPathComponent("memory", isDirectory: true)
    }

    /// Methods system data directory
    public static func methods() -> URL {
        root().appendingPathComponent("methods", isDirectory: true)
    }

    /// On-device Osaurus Router billing ledger directory (`~/.osaurus/billing/`).
    public static func billing() -> URL {
        root().appendingPathComponent("billing", isDirectory: true)
    }

    /// Tool index data directory
    public static func toolIndex() -> URL {
        root().appendingPathComponent("tool-index", isDirectory: true)
    }

    // MARK: - Agent DB + Self-Scheduling (Agent DB feature)

    /// Per-agent feature directory: `~/.osaurus/agents/<uuid>/`.
    /// Sibling to the agent's JSON file (which lives directly under `agents()`).
    public static func agentDirectory(for id: UUID) -> URL {
        agents().appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Per-agent SQLite database file: `~/.osaurus/agents/<uuid>/db.sqlite`.
    /// Encrypted via `EncryptedSQLiteOpener` with the shared storage key.
    public static func agentDatabaseFile(for id: UUID) -> URL {
        agentDirectory(for: id).appendingPathComponent("db.sqlite")
    }

    /// Auto-generated, human-readable schema dump for the agent's DB.
    /// Regenerated by `SchemaDumper` after every schema mutation.
    public static func agentSchemaSQLFile(for id: UUID) -> URL {
        agentDirectory(for: id).appendingPathComponent("schema.sql")
    }

    /// Per-agent migrations directory: `~/.osaurus/agents/<uuid>/migrations/`.
    /// Each `db.create_table`/`db.alter_table`/`db.migrate` call writes a
    /// numbered up + down SQL pair here.
    public static func agentMigrationsDirectory(for id: UUID) -> URL {
        agentDirectory(for: id).appendingPathComponent("migrations", isDirectory: true)
    }

    /// Per-agent saved-views directory: `~/.osaurus/agents/<uuid>/views/`.
    /// Auto-synced with the `_views` system table for portability.
    public static func agentViewsDirectory(for id: UUID) -> URL {
        agentDirectory(for: id).appendingPathComponent("views", isDirectory: true)
    }

    /// Per-agent run-trace directory: `~/.osaurus/agents/<uuid>/runs/`.
    /// One JSON file per run with the full prompt, tool calls, and output.
    public static func agentRunsDirectory(for id: UUID) -> URL {
        agentDirectory(for: id).appendingPathComponent("runs", isDirectory: true)
    }

    /// Per-run trace file under the agent's run directory.
    public static func agentRunTraceFile(agentId: UUID, runId: UUID) -> URL {
        agentRunsDirectory(for: agentId).appendingPathComponent("\(runId.uuidString).json")
    }

    /// Host-side record of which sandbox packages have been installed for
    /// an agent: `~/.osaurus/agents/<uuid>/installed-packages.json`. Seeded
    /// by `SandboxAgentProvisioner` (lazy reconcile) and appended to by
    /// `sandbox_install`; surfaced as a compact line in the system prompt.
    public static func agentPackageManifestFile(for id: UUID) -> URL {
        agentDirectory(for: id).appendingPathComponent("installed-packages.json")
    }

    /// Cross-agent scheduler database: `~/.osaurus/scheduler.sqlite`.
    /// Owns `agent_next_run`, `agent_runs`, `agent_pause`. Encrypted.
    public static func schedulerDatabaseFile() -> URL {
        root().appendingPathComponent("scheduler.sqlite")
    }

    /// Plugin binaries directory (`~/.osaurus/Tools/`)
    public static func tools() -> URL {
        root().appendingPathComponent("Tools", isDirectory: true)
    }

    /// Plugin specifications directory (`~/.osaurus/PluginSpecs/`)
    public static func toolSpecs() -> URL {
        root().appendingPathComponent("PluginSpecs", isDirectory: true)
    }

    /// Central sandbox plugin library (`~/.osaurus/sandbox-plugins/`)
    public static func sandboxPluginLibrary() -> URL {
        root().appendingPathComponent("sandbox-plugins", isDirectory: true)
    }

    // MARK: - Container / Sandbox Paths

    /// Container root: `~/.osaurus/container/`
    public static func container() -> URL {
        root().appendingPathComponent("container", isDirectory: true)
    }

    /// Kernel binary directory: `~/.osaurus/container/kernel/`
    public static func containerKernelDir() -> URL {
        container().appendingPathComponent("kernel", isDirectory: true)
    }

    /// Path to the Linux kernel binary
    public static func containerKernelFile() -> URL {
        containerKernelDir().appendingPathComponent("vmlinux")
    }

    /// Path to the init filesystem image: `~/.osaurus/container/initfs.ext4`
    public static func containerInitFSFile() -> URL {
        container().appendingPathComponent("initfs.ext4")
    }

    /// Mounted as `/workspace` inside the container
    public static func containerWorkspace() -> URL {
        container().appendingPathComponent("workspace", isDirectory: true)
    }

    /// Per-agent workspace directories inside the container workspace
    public static func containerAgentsDir() -> URL {
        containerWorkspace().appendingPathComponent("agents", isDirectory: true)
    }

    /// A specific agent's workspace directory (host-side path)
    public static func containerAgentDir(_ agentName: String) -> URL {
        containerAgentsDir().appendingPathComponent(agentName, isDirectory: true)
    }

    /// Shared workspace readable by all agents
    public static func containerSharedDir() -> URL {
        containerWorkspace().appendingPathComponent("shared", isDirectory: true)
    }

    // MARK: - Shared Artifacts

    /// Root directory for all shared artifacts: `~/.osaurus/artifacts/`
    public static func artifactsDir() -> URL {
        root().appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Per-context artifacts directory: `~/.osaurus/artifacts/{contextId}/`
    public static func contextArtifactsDir(contextId: String) -> URL {
        artifactsDir().appendingPathComponent(contextId, isDirectory: true)
    }

    /// In-container absolute path for an agent's home directory
    public static func inContainerAgentHome(_ agentName: String) -> String {
        "/workspace/agents/\(agentName)"
    }

    /// In-container absolute path for a plugin directory
    public static func inContainerPluginDir(_ agentName: String, _ pluginName: String) -> String {
        "/workspace/agents/\(agentName)/plugins/\(pluginName)"
    }

    // MARK: - Configuration Files

    public static func chatConfigFile() -> URL { config().appendingPathComponent("chat.json") }
    public static func serverConfigFile() -> URL { config().appendingPathComponent("server.json") }
    public static func toolConfigFile() -> URL { config().appendingPathComponent("tools.json") }
    public static func computerUseConfigFile() -> URL {
        config().appendingPathComponent("computer-use.json")
    }
    public static func toastConfigFile() -> URL { config().appendingPathComponent("toast.json") }
    public static func sandboxConfigFile() -> URL { config().appendingPathComponent("sandbox.json") }
    public static func speechConfigFile() -> URL { voiceConfig().appendingPathComponent("speech.json") }
    public static func ttsConfigFile() -> URL { voiceConfig().appendingPathComponent("tts.json") }
    public static func vadConfigFile() -> URL { voiceConfig().appendingPathComponent("vad.json") }
    public static func transcriptionConfigFile() -> URL { voiceConfig().appendingPathComponent("transcription.json") }
    public static func remoteProviderConfigFile() -> URL { providers().appendingPathComponent("remote.json") }
    public static func mcpProviderConfigFile() -> URL { providers().appendingPathComponent("mcp.json") }
    /// On-disk cache for `GenerativeGreetingPool` so app-launches start
    /// with already-warmed greetings instead of a cold inference path.
    /// One JSON file, tiny payload (a handful of strings per agent).
    public static func greetingPoolCacheFile() -> URL {
        cache().appendingPathComponent("greeting-pool.json")
    }
    /// On-disk cache for model download sizes (see `ModelSizeCache`).
    /// Keyed by repo id, persisted so sizes survive relaunch and only
    /// re-fetch when a repo's HF revision changes.
    public static func modelSizeCacheFile() -> URL {
        cache().appendingPathComponent("model-sizes.json")
    }
    /// On-disk manifest of externally-discovered models (HF cache, LM
    /// Studio) so the catalog can surface them on launch before the
    /// background rescan finishes. See `ExternalModelLocator`.
    public static func externalModelsManifestFile() -> URL {
        cache().appendingPathComponent("external-models.json")
    }
    public static func workDatabaseFile() -> URL { workData().appendingPathComponent("work.db") }
    public static func memoryDatabaseFile() -> URL { memory().appendingPathComponent("memory.sqlite") }
    public static func chatHistoryDatabaseFile() -> URL {
        chatHistory().appendingPathComponent("history.sqlite")
    }
    public static func agentChannelMessagesDatabaseFile() -> URL {
        agentChannels().appendingPathComponent("messages.sqlite")
    }
    public static func methodsDatabaseFile() -> URL { methods().appendingPathComponent("methods.sqlite") }
    /// Encrypted on-device Osaurus Router billing ledger: `~/.osaurus/billing/ledger.sqlite`.
    public static func billingLedgerDatabaseFile() -> URL { billing().appendingPathComponent("ledger.sqlite") }
    public static func toolIndexDatabaseFile() -> URL { toolIndex().appendingPathComponent("tool_index.sqlite") }
    public static func memoryConfigFile() -> URL { config().appendingPathComponent("memory.json") }
    public static func relayConfigFile() -> URL { config().appendingPathComponent("relay.json") }

    // MARK: - File Path Helpers

    public static func agentFile(for id: UUID) -> URL {
        agents().appendingPathComponent("\(id.uuidString).json")
    }

    public static func themeFile(for id: UUID) -> URL {
        themes().appendingPathComponent("\(id.uuidString).json")
    }

    public static func sessionFile(for id: UUID) -> URL {
        sessions().appendingPathComponent("\(id.uuidString).json")
    }

    public static func scheduleFile(for id: UUID) -> URL {
        schedules().appendingPathComponent("\(id.uuidString).json")
    }

    public static func watcherFile(for id: UUID) -> URL {
        watchers().appendingPathComponent("\(id.uuidString).json")
    }

    public static func pluginDirectory(for pluginId: String) -> URL {
        tools().appendingPathComponent(pluginId, isDirectory: true)
    }

    /// Per-plugin data directory for sandboxed SQLite storage
    public static func pluginDataDirectory(for pluginId: String) -> URL {
        pluginDirectory(for: pluginId).appendingPathComponent("data", isDirectory: true)
    }

    // MARK: - Claude plugins (imported via GitHub)

    /// Root directory for Claude-plugin metadata and per-plugin storage:
    /// `~/.osaurus/claude-plugins/`.
    public static func claudePluginsRoot() -> URL {
        root().appendingPathComponent("claude-plugins", isDirectory: true)
    }

    /// Per-plugin manifest snapshot directory:
    /// `~/.osaurus/claude-plugins/manifests/`.
    public static func claudePluginsManifestsDir() -> URL {
        claudePluginsRoot().appendingPathComponent("manifests", isDirectory: true)
    }

    /// Per-plugin user-config (non-sensitive) JSON directory:
    /// `~/.osaurus/claude-plugins/userconfig/`.
    public static func claudePluginsUserConfigDir() -> URL {
        claudePluginsRoot().appendingPathComponent("userconfig", isDirectory: true)
    }

    /// Per-plugin data directory parent (`CLAUDE_PLUGIN_DATA` root):
    /// `~/.osaurus/claude-plugins/data/`.
    public static func claudePluginsDataDir() -> URL {
        claudePluginsRoot().appendingPathComponent("data", isDirectory: true)
    }

    /// Per-plugin synthesised source cache (`CLAUDE_PLUGIN_ROOT` target):
    /// `~/.osaurus/claude-plugins/cache/`. Currently a placeholder so the
    /// variable expander can hand out a stable path even though we don't
    /// keep a full plugin checkout.
    public static func claudePluginsCacheDir() -> URL {
        claudePluginsRoot().appendingPathComponent("cache", isDirectory: true)
    }

    /// Per-plugin manifest snapshot file:
    /// `~/.osaurus/claude-plugins/manifests/<safeId>.json`.
    public static func claudePluginManifestFile(for pluginId: String) -> URL {
        claudePluginsManifestsDir()
            .appendingPathComponent("\(claudePluginSafeId(pluginId)).json")
    }

    /// Per-plugin user-config JSON file:
    /// `~/.osaurus/claude-plugins/userconfig/<safeId>.json`.
    public static func claudePluginUserConfigFile(for pluginId: String) -> URL {
        claudePluginsUserConfigDir()
            .appendingPathComponent("\(claudePluginSafeId(pluginId)).json")
    }

    /// Per-plugin data directory:
    /// `~/.osaurus/claude-plugins/data/<safeId>/`. Created lazily on first
    /// reference by `ClaudePluginVariableExpander`.
    public static func claudePluginDataDir(for pluginId: String) -> URL {
        claudePluginsDataDir()
            .appendingPathComponent(claudePluginSafeId(pluginId), isDirectory: true)
    }

    /// Per-plugin synthesised source cache directory:
    /// `~/.osaurus/claude-plugins/cache/<safeId>/`.
    public static func claudePluginCacheDir(for pluginId: String) -> URL {
        claudePluginsCacheDir()
            .appendingPathComponent(claudePluginSafeId(pluginId), isDirectory: true)
    }

    /// Spec-compatible safe-id sanitiser for filesystem paths derived from a
    /// Claude `pluginId`. Replaces anything outside `[A-Za-z0-9_-]` with `-`
    /// so a pluginId like `github:owner/repo/name` becomes
    /// `github-owner-repo-name`.
    public static func claudePluginSafeId(_ pluginId: String) -> String {
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        )
        var out = ""
        out.reserveCapacity(pluginId.count)
        for scalar in pluginId.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("-")
            }
        }
        // Collapse repeated dashes so we don't get unsightly `---` runs.
        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }
        return out
    }

    /// Per-plugin SQLite database file
    public static func pluginDatabaseFile(for pluginId: String) -> URL {
        pluginDataDirectory(for: pluginId).appendingPathComponent("data.db")
    }

    public static func runtimeInstance(_ instanceId: String) -> URL {
        runtime().appendingPathComponent(instanceId, isDirectory: true)
    }

    // MARK: - Legacy Resolution

    /// Resolves a path, preferring the legacy location if it exists and the new location doesn't.
    public static func resolvePath(new newPath: URL, legacy legacyName: String) -> URL {
        let legacyPath = root().appendingPathComponent(legacyName)
        let fm = FileManager.default
        if fm.fileExists(atPath: legacyPath.path) && !fm.fileExists(atPath: newPath.path) {
            return legacyPath
        }
        return newPath
    }

    // MARK: - Directory Creation

    /// Ensures a directory exists, creating it if necessary
    public static func ensureExists(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Ensures a directory exists (non-throwing version)
    public static func ensureExistsSilent(_ url: URL) {
        try? ensureExists(url)
    }

    /// Opens `url` in Finder, creating the directory first if needed.
    /// Centralises the ensure-dir + `NSWorkspace.shared.open` pair so
    /// "Open in Finder" affordances behave identically across the UI
    /// (and don't fail silently when a lazily-provisioned folder
    /// hasn't been created yet).
    @MainActor
    public static func revealInFinder(_ url: URL) {
        ensureExistsSilent(url)
        NSWorkspace.shared.open(url)
    }

    // MARK: - File Utilities

    /// Computes the total size of all files in a directory tree.
    public static func directorySize(at url: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
    }

    // MARK: - Migration

    /// Copies or merges the retired Application Support root into the active
    /// root once, then writes a marker in the active root. The legacy root is
    /// left untouched so users can inspect or delete it manually.
    @discardableResult
    static func migrateLegacyApplicationSupportRootIfNeeded(
        fileManager fm: FileManager = .default,
        legacyRoot oldRoot: URL,
        activeRoot newRoot: URL
    ) -> LegacyApplicationSupportMigrationResult {
        var isLegacyDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: oldRoot.path, isDirectory: &isLegacyDirectory),
            isLegacyDirectory.boolValue
        else {
            return .legacyRootAbsent
        }

        let marker = legacyApplicationSupportMergeMarker(for: newRoot)
        if fm.fileExists(atPath: marker.path) {
            print("[Osaurus] Legacy data migration already marked at \(marker.path); skipping")
            return .alreadyMarked(marker)
        }

        if !fm.fileExists(atPath: newRoot.path) {
            do {
                try fm.copyItem(at: oldRoot, to: newRoot)
                writeLegacyApplicationSupportMergeMarker(
                    marker,
                    legacyRoot: oldRoot,
                    activeRoot: newRoot
                )
                print("[Osaurus] Copied data from \(oldRoot.path) to \(newRoot.path)")
                return .copied(marker)
            } catch {
                print("[Osaurus] Copy failed, falling back to merge: \(error)")
            }
        }

        mergeDirectory(from: oldRoot, into: newRoot)
        writeLegacyApplicationSupportMergeMarker(
            marker,
            legacyRoot: oldRoot,
            activeRoot: newRoot
        )
        print("[Osaurus] Merged data from \(oldRoot.path) into \(newRoot.path)")
        return .merged(marker)
    }

    private static func writeLegacyApplicationSupportMergeMarker(
        _ marker: URL,
        legacyRoot: URL,
        activeRoot: URL
    ) {
        let payload = """
            legacy_application_support_migrated=1
            legacy_root=\(legacyRoot.path)
            active_root=\(activeRoot.path)

            """
        do {
            try ensureExists(marker.deletingLastPathComponent())
            try Data(payload.utf8).write(to: marker, options: .atomic)
        } catch {
            print("[Osaurus] Failed to write legacy data migration marker \(marker.path): \(error)")
        }
    }

    /// Recursively copy the contents of `src` into `dest` (never deletes from `src`).
    /// When both source and destination files exist, the newer one wins.
    private static func mergeDirectory(from src: URL, into dest: URL) {
        let fm = FileManager.default
        ensureExistsSilent(dest)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let contents = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: Array(keys)) else {
            return
        }
        for item in contents {
            let target = dest.appendingPathComponent(item.lastPathComponent)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if fm.fileExists(atPath: target.path) {
                if isDir {
                    mergeDirectory(from: item, into: target)
                } else {
                    let srcDate =
                        (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast
                    let destDate =
                        (try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast
                    if srcDate > destDate {
                        try? fm.removeItem(at: target)
                        try? fm.copyItem(at: item, to: target)
                    }
                }
            } else {
                try? fm.copyItem(at: item, to: target)
            }
        }
    }

    // MARK: - Legacy Personas -> agents migration

    /// Result of the one-time legacy `Personas` -> `agents` agent-JSON
    /// consolidation. Surfaced for tests; callers can ignore it.
    public enum LegacyPersonasMigrationResult: Equatable {
        case legacyDirectoryAbsent
        case migrated(moved: Int, conflicts: Int)
    }

    /// Consolidates stranded agent records from the legacy `Personas/`
    /// directory into the canonical `agents/` directory.
    ///
    /// Agent JSON historically resolved through
    /// `resolvePath(new: agents(), legacy: "Personas")`, which only reads the
    /// legacy directory while `agents/` does **not** exist. The first time any
    /// feature creates `agents/` (a per-agent Database directory
    /// `agents/<uuid>/`, or the `agents/avatars` folder), resolution flips to
    /// `agents/` and every record still under `Personas/` silently disappears
    /// from the list. This moves those records so the flip can never strand
    /// them again.
    ///
    /// Idempotent and conflict-safe: a `<uuid>.json` that already exists in
    /// `agents/` is left untouched and the legacy copy is preserved beside it
    /// as a `.bak` file (ignored by `AgentStore.loadAll`'s `.json` filter).
    /// The legacy directory is removed only once it is empty, so unexpected
    /// non-JSON contents are never discarded.
    @discardableResult
    public static func migrateLegacyPersonasIfNeeded(
        fileManager fm: FileManager = .default
    ) -> LegacyPersonasMigrationResult {
        let rootURL = root()
        // The legacy directory shipped as "Personas". On case-insensitive
        // volumes (the macOS default) "personas" resolves to the same path;
        // probe both so a case-sensitive volume is also handled.
        let legacyDirectory: URL? = ["Personas", "personas"].lazy
            .map { rootURL.appendingPathComponent($0, isDirectory: true) }
            .first { candidate in
                var isDir = ObjCBool(false)
                return fm.fileExists(atPath: candidate.path, isDirectory: &isDir) && isDir.boolValue
            }
        guard let legacy = legacyDirectory else { return .legacyDirectoryAbsent }

        let agentsDir = agents()
        // Never operate on the canonical directory itself.
        guard legacy.standardizedFileURL != agentsDir.standardizedFileURL else {
            return .legacyDirectoryAbsent
        }
        ensureExistsSilent(agentsDir)

        var moved = 0
        var conflicts = 0
        if let entries = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
            for entry in entries where entry.pathExtension.lowercased() == "json" {
                let target = agentsDir.appendingPathComponent(entry.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    // Keep the canonical copy; preserve the legacy one as a
                    // non-decodable backup so nothing is lost on a conflict.
                    let backup = uniqueBackupURL(for: target, fileManager: fm)
                    do {
                        try fm.moveItem(at: entry, to: backup)
                        conflicts += 1
                    } catch {
                        print(
                            "[Osaurus] Personas migration: failed to back up "
                                + "\(entry.lastPathComponent): \(error)"
                        )
                    }
                } else {
                    do {
                        try fm.moveItem(at: entry, to: target)
                        moved += 1
                    } catch {
                        print(
                            "[Osaurus] Personas migration: failed to move "
                                + "\(entry.lastPathComponent): \(error)"
                        )
                    }
                }
            }
        }

        // Best-effort cleanup: only remove the legacy directory once empty so
        // we never discard unexpected non-JSON contents.
        if let remaining = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil),
            remaining.isEmpty
        {
            try? fm.removeItem(at: legacy)
        }

        if moved > 0 || conflicts > 0 {
            print(
                "[Osaurus] Migrated \(moved) agent file(s) from \(legacy.path) into "
                    + "\(agentsDir.path) (\(conflicts) conflict backup(s) kept)"
            )
        }
        return .migrated(moved: moved, conflicts: conflicts)
    }

    /// Returns a non-colliding `<name>.bak` URL beside `target`.
    private static func uniqueBackupURL(for target: URL, fileManager fm: FileManager) -> URL {
        let directory = target.deletingLastPathComponent()
        let base = target.lastPathComponent
        var candidate = directory.appendingPathComponent("\(base).bak")
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base).\(counter).bak")
            counter += 1
        }
        return candidate
    }

}
