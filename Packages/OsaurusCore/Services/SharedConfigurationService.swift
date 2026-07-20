//
//  SharedConfigurationService.swift
//  osaurus
//
//  Publishes runtime server configuration for discovery by other processes
//

import Foundation

@MainActor
final class SharedConfigurationService {
    static let shared = SharedConfigurationService()
    private let instanceId = UUID().uuidString

    /// Serial queue so writes and removals apply in call order without blocking the main thread
    private static let ioQueue = DispatchQueue(
        label: "com.dinoki.osaurus.shared-configuration", qos: .utility)

    private init() {}

    private func baseDirectoryURL() -> URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.runtime(), legacy: "SharedConfiguration")
    }

    private func instanceDirectoryURL() -> URL {
        baseDirectoryURL().appendingPathComponent(instanceId, isDirectory: true)
    }

    private nonisolated static func ensureDirectories(base: URL, instance: URL) -> Bool {
        do {
            try OsaurusPaths.ensureExists(base)
            try OsaurusPaths.ensureExists(instance)
            return true
        } catch {
            print("[Osaurus] SharedConfigurationService: failed to create directories: \(error)")
            return false
        }
    }

    /// Update or remove the shared configuration based on server health
    func update(health: ServerHealth, configuration: ServerConfiguration, localAddress: String) {
        let base = baseDirectoryURL()
        let instanceDir = instanceDirectoryURL()

        let values: [String: Any]
        switch health {
        case .running:
            values = [
                "instanceId": instanceId,
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "port": configuration.port,
                "address": localAddress,
                "url": "http://\(localAddress):\(configuration.port)",
                "exposeToNetwork": configuration.exposeToNetwork,
                "health": "running",
            ]
        case .starting:
            // Publish minimal metadata while starting
            values = [
                "instanceId": instanceId,
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "health": "starting",
            ]
        case .restarting:
            // Publish minimal metadata while restarting
            values = [
                "instanceId": instanceId,
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "health": "restarting",
            ]
        case .stopped, .stopping, .error:
            // Remove the file to indicate this instance is not serving
            remove()
            return
        }

        let touchDirectory = health == .running
        Self.ioQueue.async {
            guard Self.ensureDirectories(base: base, instance: instanceDir) else { return }
            let fileURL = instanceDir.appendingPathComponent("configuration.json")
            do {
                let jsonData = try JSONSerialization.data(
                    withJSONObject: values,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try jsonData.write(to: fileURL, options: [.atomic])
                if touchDirectory {
                    // Touch base directory mtime for discoverability of latest instance
                    _ = try? FileManager.default.setAttributes(
                        [.modificationDate: Date()],
                        ofItemAtPath: instanceDir.path
                    )
                }
            } catch {
                print("[Osaurus] SharedConfigurationService: failed to write configuration: \(error)")
            }
        }
    }

    /// Drain the I/O queue so pending writes/removals land before process exit
    func flushPendingWork() {
        Self.ioQueue.sync {}
    }

    /// Remove this instance's shared files
    func remove() {
        let instance = instanceDirectoryURL()
        Self.ioQueue.async {
            do {
                if FileManager.default.fileExists(atPath: instance.path) {
                    try FileManager.default.removeItem(at: instance)
                    print(
                        "[Osaurus] SharedConfigurationService: removed instance directory at \(instance.path)"
                    )
                }
            } catch {
                print(
                    "[Osaurus] SharedConfigurationService: failed to remove instance directory: \(error)")
            }
        }
    }
}
