//
//  ToolConfigurationStore.swift
//  osaurus
//
//  Persistence for ToolConfiguration
//

import Foundation

@MainActor
enum ToolConfigurationStore {
    /// When set, configuration reads/writes use this directory instead of the default path.
    static var overrideDirectory: URL?

    static func load() -> ToolConfiguration {
        let url = configurationFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                return try JSONDecoder().decode(ToolConfiguration.self, from: Data(contentsOf: url))
            } catch {
                print("[Osaurus] Failed to load ToolConfiguration: \(error)")
            }
        }
        // CRITICAL: see RemoteProviderConfigurationStore.load — never
        // auto-save an empty default on missing-file. The 2026-04
        // storage-migration recovery race showed this pattern can
        // permanently destroy user data.
        return ToolConfiguration()
    }

    /// Persist the configuration without blocking the caller.
    ///
    /// The registry mutates its in-memory `ToolConfiguration` synchronously, so
    /// a tool toggle / policy change reflects in the UI instantly. The encode +
    /// atomic write are handed off to a background serial queue here, so the
    /// main thread never stalls on `tools.json` I/O (which previously fired on
    /// *every* enable/disable, policy change, and auto-grant backfill). Rapid
    /// bursts coalesce to a single last-writer-wins write.
    static func save(_ configuration: ToolConfiguration) {
        // Resolve the destination on the main actor (reads `overrideDirectory`)
        // and capture it, so a later override change can't redirect this write.
        let url = configurationFileURL()
        writeCoordinator.enqueue(configuration, to: url)
    }

    /// Synchronously drain any pending background write. Call from
    /// `applicationWillTerminate` before `_exit` so a toggle made moments before
    /// quitting still lands on disk (mirrors `flushGreetingPoolSync`).
    static func flushPendingWrites(timeout: TimeInterval = 1.5) {
        writeCoordinator.flushSync(timeout: timeout)
    }

    private static func configurationFileURL() -> URL {
        if let dir = overrideDirectory {
            return dir.appendingPathComponent("tools.json")
        }
        return OsaurusPaths.resolvePath(new: OsaurusPaths.toolConfigFile(), legacy: "ToolConfiguration.json")
    }

    /// Serial, coalescing background writer for `tools.json`.
    private static let writeCoordinator = WriteCoordinator()

    private final class WriteCoordinator: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.osaurus.toolconfig.write", qos: .utility)
        private let lock = NSLock()
        /// Most recent snapshot awaiting persistence (last-writer-wins).
        private var pending: (config: ToolConfiguration, url: URL)?
        private var isDraining = false

        func enqueue(_ config: ToolConfiguration, to url: URL) {
            lock.lock()
            pending = (config, url)
            let shouldSchedule = !isDraining
            if shouldSchedule { isDraining = true }
            lock.unlock()
            guard shouldSchedule else { return }
            queue.async { [self] in drain() }
        }

        func flushSync(timeout: TimeInterval) {
            let done = DispatchSemaphore(value: 0)
            queue.async { [self] in
                drain()
                done.signal()
            }
            _ = done.wait(timeout: .now() + timeout)
        }

        /// Writes the freshest pending snapshot, looping to absorb writes that
        /// arrive mid-flush so nothing is dropped.
        private func drain() {
            while true {
                lock.lock()
                guard let job = pending else {
                    isDraining = false
                    lock.unlock()
                    return
                }
                pending = nil
                lock.unlock()
                Self.writeToDisk(job.config, to: job.url)
            }
        }

        private static func writeToDisk(_ config: ToolConfiguration, to url: URL) {
            OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(config).write(to: url, options: [.atomic])
            } catch {
                print("[Osaurus] Failed to save ToolConfiguration: \(error)")
            }
        }
    }
}
