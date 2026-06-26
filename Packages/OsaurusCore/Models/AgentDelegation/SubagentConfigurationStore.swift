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
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(normalized)
            try data.write(to: url, options: [.atomic])
            snapshotLock.lock()
            cachedSnapshot = normalized
            snapshotLock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .subagentConfigurationChanged,
                    object: normalized
                )
            }
        } catch {
            print("[Osaurus] Failed to save SubagentConfiguration: \(error)")
        }
    }

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
