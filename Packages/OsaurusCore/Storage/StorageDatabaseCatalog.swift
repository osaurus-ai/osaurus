//
//  StorageDatabaseCatalog.swift
//  osaurus
//
//  Enumerates every at-rest SQLCipher database under `~/.osaurus/`:
//  the core databases, one per installed plugin, and one per agent
//  that opted in to the Agent DB feature. It's a standalone catalog
//  because key rotation (`StorageExportService.rotateStorageKey`)
//  and plaintext export (`StorageExportService.exportPlaintextBackup`)
//  both need the same discovery logic.
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
            // Both Agent DB stores are created encrypted on first open
            // via `EncryptedSQLiteOpener`; they're listed here so
            // `StorageExportService.rotate(...)` rekeys them along with
            // the core databases and `StorageMaintenance` PRAGMA passes
            // can find them when the handles register themselves.
            .init(label: "scheduler", path: OsaurusPaths.schedulerDatabaseFile().path),
            // On-device Osaurus Router billing ledger. Encrypted with the
            // shared storage key, so it must be rekeyed alongside the core
            // databases on rotation and included in plaintext export.
            .init(label: "router billing", path: OsaurusPaths.billingLedgerDatabaseFile().path),
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
                guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
                let dbPath = entry.appendingPathComponent("db.sqlite").path
                if FileManager.default.fileExists(atPath: dbPath) {
                    targets.append(
                        .init(label: "agent db \(entry.lastPathComponent)", path: dbPath)
                    )
                }
            }
        }
        return targets
    }

    /// True for plugin IDs that could only have been created by a
    /// leaked test run (anything with a `com.test.` prefix).
    public static func isLeakedTestPluginId(_ pluginId: String) -> Bool {
        pluginId.hasPrefix("com.test.")
    }
}
