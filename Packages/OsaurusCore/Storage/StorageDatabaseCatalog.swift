//
//  StorageDatabaseCatalog.swift
//  osaurus
//
//  Enumerates everything the opt-in at-rest encryption covers under
//  `~/.osaurus/`: every database opened through `OsaurusStorageOpener`
//  (the core stores, one per installed plugin, one per agent with an
//  Agent DB) and the directories holding policy-aware `.osec` files.
//  Posture convergence, key rotation, plaintext export and the storage
//  key's fail-closed guard all read this one list, so a store missing
//  here is silently left out of all four (`StorageDatabaseCatalogTests`
//  guards that).
//

import Foundation

public enum StorageDatabaseCatalog {
    /// One unified target description so callers stay flat. The
    /// `label` is only used for human-readable logging; rekey and
    /// export operate on `path`. Core databases use short labels
    /// ("chat history", "memory", ...); plugin databases use the
    /// "plugin <id>" format via `plugin(id:path:)`.
    public struct DatabaseTarget: Sendable {
        public let label: String
        public let path: String

        public init(label: String, path: String) {
            self.label = label
            self.path = path
        }

        /// Convenience constructor for plugin targets — keeps the
        /// label format ("plugin <id>") in one place.
        public static func plugin(id: String, path: String) -> DatabaseTarget {
            DatabaseTarget(label: "plugin " + id, path: path)
        }
    }

    public static func databaseTargets() -> [DatabaseTarget] {
        var targets: [DatabaseTarget] = [
            .init(label: "chat history", path: OsaurusPaths.chatHistoryDatabaseFile().path),
            .init(label: "agent channels", path: OsaurusPaths.agentChannelMessagesDatabaseFile().path),
            .init(label: "memory", path: OsaurusPaths.memoryDatabaseFile().path),
            .init(label: "methods", path: OsaurusPaths.methodsDatabaseFile().path),
            .init(label: "tool index", path: OsaurusPaths.toolIndexDatabaseFile().path),
            // Cross-agent next-run and pause slots for the Agent DB feature.
            .init(label: "scheduler", path: OsaurusPaths.schedulerDatabaseFile().path),
            // The knowledge index holds document text, and the write log
            // holds the prior content of every agent edit (its undo history).
            .init(label: "knowledge", path: OsaurusPaths.knowledgeDatabaseFile().path),
            .init(label: "knowledge write log", path: OsaurusPaths.knowledgeWriteLogDatabaseFile().path),
            // On-device Osaurus Router billing ledger. Encrypted with the
            // shared storage key, so it must be rekeyed alongside the core
            // databases on rotation and included in plaintext export.
            .init(label: "router billing", path: OsaurusPaths.billingLedgerDatabaseFile().path),
            // Insights activity / audit log. Opened through the shared
            // opener, so it must follow the key on rotation and be part of
            // plaintext export like the other core stores.
            .init(label: "activity log", path: OsaurusPaths.activityLogDatabaseFile().path),
        ]
        // Plugin DBs — one per installed plugin. We can discover them
        // by walking `Tools/<pluginId>/data/data.db`.
        let toolsDir = OsaurusPaths.tools()
        if let plugins = try? FileManager.default.contentsOfDirectory(at: toolsDir, includingPropertiesForKeys: nil) {
            for plugin in plugins {
                let pluginId = plugin.lastPathComponent
                // Production safety net: any `com.test.*` plugin ID
                // can only exist on disk because a developer ran the
                // OsaurusCore test suite without isolating
                // `OsaurusPaths.overrideRoot`. End users will never
                // have one, so filter them out.
                if Self.isLeakedTestPluginId(pluginId) { continue }
                let dbPath = OsaurusPaths.pluginDatabaseFile(for: pluginId).path
                if FileManager.default.fileExists(atPath: dbPath) {
                    targets.append(.plugin(id: pluginId, path: dbPath))
                }
            }
        }
        // Per-agent `db.sqlite` files — one per agent that has opted
        // in to the Agent DB feature. Discovered by walking
        // `agents/<UUID>/db.sqlite`. `AgentStore` writes agent
        // metadata as `agents/<UUID>.json` (siblings of the dirs), so
        // the directory walk here naturally skips them.
        let agentsDir = OsaurusPaths.agents()
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: agentsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for entry in entries {
                let isDir =
                    (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                // Only consider UUID-named subdirectories — `avatars/`
                // and any future side-folders should be ignored.
                guard let agentId = UUID(uuidString: entry.lastPathComponent) else { continue }
                let dbPath = OsaurusPaths.agentDatabaseFile(for: agentId).path
                if FileManager.default.fileExists(atPath: dbPath) {
                    targets.append(
                        .init(label: "agent db \(entry.lastPathComponent)", path: dbPath)
                    )
                }
            }
        }
        return targets
    }

    // MARK: - Policy-aware files

    /// A directory whose files are written with
    /// `EncryptedFileStore.writePolicyAware`: each logical file is a
    /// plaintext twin or an AES-GCM `.osec` twin, following the posture.
    public struct PolicyAwareDirectory: Sendable {
        public let label: String
        public let url: URL
        /// Files in `url` that are always written raw and must never be
        /// wrapped, because their readers don't go through the twin API.
        public let rawFileNames: Set<String>
    }

    /// Directories convergence brings in line with the posture, along with
    /// the databases.
    public static func policyAwareDirectories() -> [PolicyAwareDirectory] {
        [PolicyAwareDirectory(label: "attachments", url: AttachmentBlobStore.blobsDir(), rawFileNames: [])]
    }

    /// Every directory that can hold `.osec` files under the storage key: the
    /// policy-aware directories plus the config trees the earlier always-on
    /// encryption wrapped. Used by export, rotation and the key guard.
    public static func encryptedFileRoots() -> [URL] {
        policyAwareDirectories().map(\.url) + [
            OsaurusPaths.agents(),
            OsaurusPaths.themes(),
            OsaurusPaths.schedules(),
            OsaurusPaths.watchers(),
            OsaurusPaths.providers(),
            OsaurusPaths.config(),
            OsaurusPaths.sessionsArchive(),
            OsaurusPaths.sandboxPluginLibrary(),
            OsaurusPaths.toolSpecs(),
        ]
    }

    /// True for plugin IDs that could only have been created by a
    /// leaked test run (anything with a `com.test.` prefix).
    public static func isLeakedTestPluginId(_ pluginId: String) -> Bool {
        pluginId.hasPrefix("com.test.")
    }
}
