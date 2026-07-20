//
//  SharedConfigurationService.swift
//  osaurus
//
//  Publishes runtime server configuration for discovery by other processes
//

import Foundation

final class SharedConfigurationService: @unchecked Sendable {
    static let shared = SharedConfigurationService()
    private let instanceId: String
    private let baseDirectoryOverride: URL?
    private let ioQueue = DispatchQueue(
        label: "com.osaurus.shared-configuration",
        qos: .utility
    )

    private enum Publication: Sendable {
        case running(port: Int, address: String, exposeToNetwork: Bool)
        case status(String)
        case remove
    }

    init(
        instanceId: String = UUID().uuidString,
        baseDirectoryOverride: URL? = nil
    ) {
        self.instanceId = instanceId
        self.baseDirectoryOverride = baseDirectoryOverride
    }

    private func baseDirectoryURL() -> URL {
        if let baseDirectoryOverride { return baseDirectoryOverride }
        return OsaurusPaths.resolvePath(
            new: OsaurusPaths.runtime(),
            legacy: "SharedConfiguration"
        )
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
        let publication: Publication = switch health {
        case .running:
            .running(
                port: configuration.port,
                address: localAddress,
                exposeToNetwork: configuration.exposeToNetwork
            )
        case .starting:
            .status("starting")
        case .restarting:
            .status("restarting")
        case .stopped, .stopping, .error:
            .remove
        }

        // Server state is published by a main-thread Combine sink. Keep the
        // filesystem work ordered, but never make that sink wait on mkdir,
        // atomic rename, or recursive removal.
        ioQueue.async { [self] in
            perform(publication)
        }
    }

    private func perform(_ publication: Publication) {
        if case .remove = publication {
            performRemove()
            return
        }

        guard let instanceDir = ensureDirectories() else { return }
        let fileURL = instanceDir.appendingPathComponent("configuration.json")
        let values: [String: Any]

        switch publication {
        case .running(let port, let address, let exposeToNetwork):
            values = [
                "instanceId": instanceId,
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "port": port,
                "address": address,
                "url": "http://\(address):\(port)",
                "exposeToNetwork": exposeToNetwork,
                "health": "running",
            ]
        case .status(let status):
            values = [
                "instanceId": instanceId,
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "health": status,
            ]
        case .remove:
            return
        }

        do {
            let jsonData = try JSONSerialization.data(
                withJSONObject: values,
                options: [.prettyPrinted, .sortedKeys]
            )
            try jsonData.write(to: fileURL, options: [.atomic])
            // Touch the instance directory mtime for discovery ordering.
            _ = try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: instanceDir.path
            )
        } catch {
            print("[Osaurus] SharedConfigurationService: failed to write configuration: \(error)")
        }
    }

    /// Remove this instance's shared files
    func remove() {
        ioQueue.async { [self] in
            performRemove()
        }
    }

    /// Drain preceding publications and remove synchronously before `_exit`.
    func removeSynchronously() {
        ioQueue.sync { [self] in
            performRemove()
        }
    }

    #if DEBUG
        func flushPendingIOForTests() {
            ioQueue.sync {}
        }
    #endif

    private func performRemove() {
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
