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

    private init() {}

    private func baseDirectoryURL() -> URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.runtime(), legacy: "SharedConfiguration")
    }

    private func instanceDirectoryURL() -> URL {
        baseDirectoryURL().appendingPathComponent(instanceId, isDirectory: true)
    }

    private func ensureDirectories() -> URL? {
        let instance = instanceDirectoryURL()
        do {
            try OsaurusPaths.ensureExists(baseDirectoryURL())
            try OsaurusPaths.ensureExists(instance)
            return instance
        } catch {
            print("[Osaurus] SharedConfigurationService: failed to create directories: \(error)")
            return nil
        }
    }

    /// Update or remove the shared configuration based on server health
    func update(health: ServerHealth, configuration: ServerConfiguration, localAddress: String) {
        guard let instanceDir = ensureDirectories() else { return }

        let fileURL = instanceDir.appendingPathComponent("configuration.json")

        switch health {
        case .running:
            let values: [String: Any] = [
                "instanceId": instanceId,
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "port": configuration.port,
                "address": localAddress,
                "url": "http://\(localAddress):\(configuration.port)",
                "exposeToNetwork": configuration.exposeToNetwork,
                "health": "running",
            ]
            do {
                let jsonData = try JSONSerialization.data(
                    withJSONObject: values,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try jsonData.write(to: fileURL, options: [.atomic])
                // Touch base directory mtime for discoverability of latest instance
                _ = try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: instanceDir.path
                )
            } catch {
                print("[Osaurus] SharedConfigurationService: failed to write configuration: \(error)")
            }
        case .starting:
            // Publish minimal metadata while starting
            let values: [String: Any] = [
                "instanceId": instanceId,
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "health": "starting",
            ]
            do {
                let jsonData = try JSONSerialization.data(
                    withJSONObject: values,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try jsonData.write(to: fileURL, options: [.atomic])
            } catch {
                print(
                    "[Osaurus] SharedConfigurationService: failed to write starting configuration: \(error)"
                )
            }
        case .restarting:
            // Publish minimal metadata while restarting
            let values: [String: Any] = [
                "instanceId": instanceId,
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "health": "restarting",
            ]
            do {
                let jsonData = try JSONSerialization.data(
                    withJSONObject: values,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try jsonData.write(to: fileURL, options: [.atomic])
            } catch {
                print(
                    "[Osaurus] SharedConfigurationService: failed to write restarting configuration: \(error)"
                )
            }
        case .stopped, .stopping, .error:
            // Remove the file to indicate this instance is not serving
            remove()
        }
    }

    /// Remove this instance's shared files
    func remove() {
        let instance = instanceDirectoryURL()
        do {
            if FileManager.default.fileExists(atPath: instance.path) {
                try FileManager.default.removeItem(at: instance)
                print(
                    "[Osaurus] SharedConfigurationService: removed instance directory at \(instance.path)"
                )
            }
        } catch {
            print("[Osaurus] SharedConfigurationService: failed to remove instance directory: \(error)")
        }
    }
}
