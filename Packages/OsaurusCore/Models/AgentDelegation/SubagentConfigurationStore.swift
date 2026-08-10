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
    private nonisolated(unsafe) static var cachedSpawnSharedAuthority:
        SpawnSharedConfigurationAuthority?
    private nonisolated(unsafe) static var cachedSpawnDefaultAuthority:
        SpawnDefaultConfigurationAuthority?
    private nonisolated(unsafe) static var spawnSharedAuthorityRevision: UInt64 = 0
    private nonisolated(unsafe) static var spawnDefaultAuthorityRevision: UInt64 = 0
    private static let snapshotLock = NSLock()
    /// Serializes the one cold disk materialization without holding
    /// `snapshotLock` across I/O. A save may still proceed while the read is in
    /// flight; the commit path below rechecks the revision/cache and never
    /// overwrites that newer value.
    private static let snapshotMaterializationLock = NSLock()
    private static let fileName = "agent-delegation.json"

    nonisolated static func setOverrideDirectory(_ url: URL?) {
        snapshotLock.lock()
        overrideDirectory = url
        cachedSnapshot = nil
        snapshotRevision &+= 1
        cachedSpawnSharedAuthority = nil
        cachedSpawnDefaultAuthority = nil
        spawnSharedAuthorityRevision &+= 1
        spawnDefaultAuthorityRevision &+= 1
        snapshotLock.unlock()
    }

    nonisolated static func load() -> SubagentConfiguration? {
        snapshotMaterializationLock.lock()
        defer { snapshotMaterializationLock.unlock() }

        while true {
            snapshotLock.lock()
            let revisionBeforeRead = snapshotRevision
            let url = fileURLWhileLocked()
            snapshotLock.unlock()

            let decoded = readConfiguration(at: url)

            snapshotLock.lock()
            // A concurrent save installed newer authority while disk I/O was
            // open. Return that live value rather than overwriting it with the
            // stale read.
            if snapshotRevision != revisionBeforeRead,
                let live = cachedSnapshot
            {
                snapshotLock.unlock()
                return live
            }
            // An override-directory swap or explicit invalidation changed the
            // generation but left no cached value. Retry against the current
            // location instead of installing bytes from the old one.
            guard snapshotRevision == revisionBeforeRead else {
                snapshotLock.unlock()
                continue
            }
            guard let decoded else {
                snapshotLock.unlock()
                return nil
            }
            installSpawnAuthorityWhileLocked(decoded, recordingChange: false)
            cachedSnapshot = decoded
            snapshotRevision &+= 1
            snapshotLock.unlock()
            return decoded
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
        installSpawnAuthorityWhileLocked(normalized, recordingChange: true)
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
        installSpawnAuthorityWhileLocked(normalized, recordingChange: true)
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
        snapshotWithRevision().configuration
    }

    /// One linearizable authority read. Callers that compare configuration
    /// generations must never obtain the configuration and revision in two
    /// separate lock acquisitions: a concurrent save between those reads
    /// would produce a torn pair.
    nonisolated static func snapshotWithRevision() -> (
        configuration: SubagentConfiguration,
        revision: UInt64
    ) {
        let snapshot = snapshotWithSpawnAuthorityRevisions()
        return (snapshot.configuration, snapshot.revision)
    }

    /// One linearizable Spawn-authority read. The two scoped generations
    /// advance only for fields that can affect Spawn execution:
    ///
    /// - `spawnSharedRevision`: residency handoff / RAM-safety settings and the
    ///   parallel fan-out limit shared by every launcher;
    /// - `spawnDefaultRevision`: the Default launcher's target/model pools,
    ///   Spawn permission, budgets, model override, and child-tool grant.
    ///
    /// This keeps ABA protection for relevant changes without rejecting a
    /// pending Spawn merely because an Image or AppleScript editor saved the
    /// same shared configuration document.
    nonisolated static func snapshotWithSpawnAuthorityRevisions() -> (
        configuration: SubagentConfiguration,
        revision: UInt64,
        spawnSharedRevision: UInt64,
        spawnDefaultRevision: UInt64
    ) {
        snapshotLock.lock()
        if let cached = cachedSnapshot {
            let revision = snapshotRevision
            let sharedRevision = spawnSharedAuthorityRevision
            let defaultRevision = spawnDefaultAuthorityRevision
            snapshotLock.unlock()
            return (cached, revision, sharedRevision, defaultRevision)
        }
        snapshotLock.unlock()

        snapshotMaterializationLock.lock()
        defer { snapshotMaterializationLock.unlock() }

        while true {
            snapshotLock.lock()
            if let cached = cachedSnapshot {
                let revision = snapshotRevision
                let sharedRevision = spawnSharedAuthorityRevision
                let defaultRevision = spawnDefaultAuthorityRevision
                snapshotLock.unlock()
                return (cached, revision, sharedRevision, defaultRevision)
            }
            let revisionBeforeRead = snapshotRevision
            let url = fileURLWhileLocked()
            snapshotLock.unlock()

            let decoded = readConfiguration(at: url)

            snapshotLock.lock()
            // A save that won during the read is authoritative.
            if let cached = cachedSnapshot {
                let revision = snapshotRevision
                let sharedRevision = spawnSharedAuthorityRevision
                let defaultRevision = spawnDefaultAuthorityRevision
                snapshotLock.unlock()
                return (cached, revision, sharedRevision, defaultRevision)
            }
            // The active directory or invalidation generation changed while
            // reading. Discard stale bytes and retry from the current source.
            guard snapshotRevision == revisionBeforeRead else {
                snapshotLock.unlock()
                continue
            }
            let configuration = decoded ?? .default
            if decoded != nil {
                cachedSnapshot = configuration
                snapshotRevision &+= 1
            }
            // Even an absent file has a real `.default` authority baseline.
            // Recording it here ensures the first relevant save after an
            // approval advances the scoped generation.
            installSpawnAuthorityWhileLocked(
                configuration,
                recordingChange: false
            )
            let revision = snapshotRevision
            let sharedRevision = spawnSharedAuthorityRevision
            let defaultRevision = spawnDefaultAuthorityRevision
            snapshotLock.unlock()
            return (
                configuration,
                revision,
                sharedRevision,
                defaultRevision
            )
        }
    }

    /// `snapshotLock` must be held.
    private nonisolated static func installSpawnAuthorityWhileLocked(
        _ configuration: SubagentConfiguration,
        recordingChange: Bool
    ) {
        let shared = configuration.spawnSharedAuthority
        let defaultAuthority = configuration.spawnDefaultAuthority

        if let previous = cachedSpawnSharedAuthority,
            previous != shared,
            recordingChange
        {
            spawnSharedAuthorityRevision &+= 1
        }
        if let previous = cachedSpawnDefaultAuthority,
            previous != defaultAuthority,
            recordingChange
        {
            spawnDefaultAuthorityRevision &+= 1
        }
        cachedSpawnSharedAuthority = shared
        cachedSpawnDefaultAuthority = defaultAuthority
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
        cachedSpawnSharedAuthority = nil
        cachedSpawnDefaultAuthority = nil
        spawnSharedAuthorityRevision &+= 1
        spawnDefaultAuthorityRevision &+= 1
        snapshotLock.unlock()
    }

    private nonisolated static func directoryURL() -> URL {
        snapshotLock.lock()
        let override = overrideDirectory
        snapshotLock.unlock()
        if let override { return override }
        return OsaurusPaths.config()
    }

    /// `snapshotLock` must be held.
    private nonisolated static func fileURLWhileLocked() -> URL {
        (overrideDirectory ?? OsaurusPaths.config())
            .appendingPathComponent(fileName)
    }

    private nonisolated static func fileURL() -> URL {
        directoryURL().appendingPathComponent(fileName)
    }

    private nonisolated static func readConfiguration(
        at url: URL
    ) -> SubagentConfiguration? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder()
                .decode(SubagentConfiguration.self, from: data)
                .normalized
        } catch {
            print("[Osaurus] Failed to load SubagentConfiguration: \(error)")
            return nil
        }
    }
}

extension Notification.Name {
    static let subagentConfigurationChanged = Foundation.Notification.Name(
        "subagentConfigurationChanged"
    )
}
