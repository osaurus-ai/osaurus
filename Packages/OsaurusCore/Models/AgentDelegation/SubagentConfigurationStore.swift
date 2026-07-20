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
    private static let snapshotLock = NSLock()
    private static let persistenceQueue = DispatchQueue(
        label: "ai.osaurus.subagent-configuration.persistence",
        qos: .utility
    )
    private static let fileName = "agent-delegation.json"

    nonisolated static func setOverrideDirectory(_ url: URL?) {
        snapshotLock.lock()
        overrideDirectory = url
        cachedSnapshot = nil
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
            snapshotLock.unlock()
            return normalized
        } catch {
            print("[Osaurus] Failed to load SubagentConfiguration: \(error)")
            return nil
        }
    }

    nonisolated static func save(_ configuration: SubagentConfiguration) {
        let normalized = configuration.normalized
        let url = fileURL()
        persistenceQueue.sync {
            persist(normalized, to: url)
        }
        publish(normalized)
    }

    /// UI-facing save path. Snapshot publication is immediate so a toggle
    /// affects subsequent agent resolution in the same run-loop turn, while
    /// the atomic filesystem rename runs on one ordered utility queue instead
    /// of beachballing SwiftUI (Sentry APPLE-MACOS-150). Serial ordering keeps
    /// rapid edits last-write-wins on disk.
    nonisolated static func saveAsync(_ configuration: SubagentConfiguration) {
        let normalized = configuration.normalized
        let url = fileURL()
        publish(normalized)
        persistenceQueue.async {
            persist(normalized, to: url)
        }
    }

    private nonisolated static func persist(
        _ normalized: SubagentConfiguration,
        to url: URL
    ) {
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(normalized)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save SubagentConfiguration: \(error)")
        }
    }

    private nonisolated static func publish(_ normalized: SubagentConfiguration) {
        snapshotLock.lock()
        cachedSnapshot = normalized
        snapshotLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .subagentConfigurationChanged,
                object: normalized
            )
        }
    }

    /// Bounded drain for the hard-exit path. UI saves are deliberately
    /// asynchronous, so a toggle followed immediately by Quit must wait for
    /// the ordered atomic write before AppDelegate calls `_exit`.
    nonisolated static func flushPendingWrites(timeout: TimeInterval = 1.5) {
        let done = DispatchSemaphore(value: 0)
        persistenceQueue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    #if DEBUG
        nonisolated static func flushPendingWritesForTests() {
            flushPendingWrites()
        }
    #endif

    nonisolated static func snapshot() -> SubagentConfiguration {
        snapshotLock.lock()
        if let cached = cachedSnapshot {
            snapshotLock.unlock()
            return cached
        }
        snapshotLock.unlock()
        return load() ?? .default
    }

    nonisolated static func invalidateSnapshot() {
        snapshotLock.lock()
        cachedSnapshot = nil
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
