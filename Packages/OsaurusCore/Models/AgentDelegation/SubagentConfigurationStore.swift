//
//  SubagentConfigurationStore.swift
//  osaurus
//
//  JSON-on-disk persistence for local delegate/image-job policy.
//

import Foundation

enum SubagentConfigurationStore {
    private nonisolated(unsafe) static var overrideDirectory: URL?
    private nonisolated(unsafe) static var cachedSnapshot: SubagentConfiguration?
    private nonisolated(unsafe) static var snapshotRevision: UInt64 = 0
    private static let snapshotLock = NSLock()
    private static let fileName = "agent-delegation.json"

    nonisolated static func setOverrideDirectory(_ url: URL?) {
        snapshotLock.lock()
        overrideDirectory = url
        cachedSnapshot = nil
        snapshotRevision &+= 1
        snapshotLock.unlock()
    }

    nonisolated static func load() -> SubagentConfiguration? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)
            let normalized = decoded.normalized
            snapshotLock.lock()
            cachedSnapshot = normalized
            snapshotRevision &+= 1
            snapshotLock.unlock()
            return normalized
        } catch {
            print("[Osaurus] Failed to load SubagentConfiguration: \(error)")
            return nil
        }
    }

    /// Persist without blocking the caller. The snapshot cache updates and the
    /// change notification posts immediately; the encode + atomic write happen
    /// on a background serial queue (mirrors `ToolConfigurationStore`), so a
    /// save from the main actor never stalls the UI on file I/O.
    nonisolated static func save(_ configuration: SubagentConfiguration) {
        let normalized = configuration.normalized
        let url = fileURL()
        snapshotLock.lock()
        cachedSnapshot = normalized
        snapshotRevision &+= 1
        // Enqueue while the snapshot lock still owns commit order. If two
        // writers update the cache back-to-back, their notification and disk
        // writes must be queued in that same order rather than allowing the
        // older writer to enqueue after the newer one.
        publishAndPersist(normalized, to: url)
        snapshotLock.unlock()
    }

    /// Atomically reconcile a long-lived editor against the latest shared
    /// snapshot. Unchanged editor fields adopt the live value, while fields the
    /// user actually changed since `loadedBaseline` win. The returned value is
    /// the new canonical editor baseline.
    @discardableResult
    nonisolated static func saveEditorSnapshot(
        _ editor: SubagentConfiguration,
        loadedBaseline: SubagentConfiguration
    ) -> SubagentConfiguration {
        mutateCurrent { live in
            SubagentConfiguration.mergingEditorSnapshot(
                editor,
                loadedBaseline: loadedBaseline,
                live: live
            )
        }
    }

    /// Atomically update one scoped part of the shared document. Runtime
    /// writers such as an Always Allow decision use this instead of a
    /// snapshot-then-replace sequence that can race another editor.
    @discardableResult
    nonisolated static func mutate(
        _ update: (inout SubagentConfiguration) -> Void
    ) -> SubagentConfiguration {
        mutateCurrent { live in
            var updated = live
            update(&updated)
            return updated
        }
    }

    private nonisolated static func mutateCurrent(
        _ update: (SubagentConfiguration) -> SubagentConfiguration
    ) -> SubagentConfiguration {
        // Materialize a cold store before entering the mutation lock. `load()`
        // owns that IO and installs the decoded snapshot under the same lock.
        let materialized = snapshot()
        let url = fileURL()
        snapshotLock.lock()
        let live = cachedSnapshot ?? materialized
        let normalized = update(live).normalized
        guard normalized != live else {
            snapshotLock.unlock()
            return live
        }
        cachedSnapshot = normalized
        snapshotRevision &+= 1
        publishAndPersist(normalized, to: url)
        snapshotLock.unlock()
        return normalized
    }

    private nonisolated static func publishAndPersist(
        _ configuration: SubagentConfiguration,
        to url: URL
    ) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .subagentConfigurationChanged,
                object: configuration
            )
        }
        writeQueue.async {
            OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(configuration)
                try data.write(to: url, options: [.atomic])
            } catch {
                print("[Osaurus] Failed to save SubagentConfiguration: \(error)")
            }
        }
    }

    /// Synchronously drain any pending background write. Call before process
    /// exit (and in tests before reading the file back from disk).
    nonisolated static func flushPendingWrites(timeout: TimeInterval = 1.5) {
        let done = DispatchSemaphore(value: 0)
        writeQueue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private static let writeQueue = DispatchQueue(
        label: "com.osaurus.subagentconfig.write", qos: .utility)

    nonisolated static func snapshot() -> SubagentConfiguration {
        snapshotLock.lock()
        if let cached = cachedSnapshot {
            snapshotLock.unlock()
            return cached
        }
        snapshotLock.unlock()
        return load() ?? .default
    }

    /// Monotonic ABA-safe generation for execution-time authorization.
    ///
    /// A batch captures this after its single approval and checks it again
    /// immediately before admission. Even if settings are changed and then
    /// restored to byte-identical values while targets are being prepared,
    /// the generation changes and stale prepared authority is rejected.
    nonisolated static func revision() -> UInt64 {
        snapshotLock.lock()
        let value = snapshotRevision
        snapshotLock.unlock()
        return value
    }

    /// Complete the legacy display-name migration once the live agent catalog
    /// is available. Ambiguous or missing names are dropped by the
    /// configuration's fail-closed migration policy.
    @discardableResult
    nonisolated static func migrateLegacyAgentNames(
        using agents: [Agent]
    ) -> SubagentConfiguration {
        mutate { current in
            guard !current.legacySpawnableAgentNames.isEmpty else { return }
            current = current.migratingLegacyAgentNames(using: agents)
        }
    }

    nonisolated static func invalidateSnapshot() {
        snapshotLock.lock()
        cachedSnapshot = nil
        snapshotRevision &+= 1
        snapshotLock.unlock()
    }

    private nonisolated static func directoryURL() -> URL {
        snapshotLock.lock()
        let override = overrideDirectory
        snapshotLock.unlock()
        if let override { return override }
        return OsaurusPaths.config()
    }

    private nonisolated static func fileURL() -> URL {
        directoryURL().appendingPathComponent(fileName)
    }
}

extension Notification.Name {
    static let subagentConfigurationChanged = Foundation.Notification.Name(
        "subagentConfigurationChanged"
    )
}
