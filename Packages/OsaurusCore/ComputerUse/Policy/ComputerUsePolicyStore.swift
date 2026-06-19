//
//  ComputerUsePolicyStore.swift
//  OsaurusCore — Computer Use
//
//  Persistence for the user's `AutonomyPolicy`, stored at
//  `~/.osaurus/config/computer-use.json`. Mirrors `ToolConfigurationStore`:
//  synchronous in-memory reads, a coalescing background writer so a policy
//  toggle never stalls the main thread, and a flush hook for app teardown.
//

import Foundation

@MainActor
public enum ComputerUsePolicyStore {
    /// When set, reads/writes use this directory instead of the default path
    /// (used by tests to avoid touching the real config).
    public static var overrideDirectory: URL?

    /// In-memory cache so the gate and UI read the same instance without
    /// re-decoding on every access.
    private static var cached: AutonomyPolicy?

    /// Load the persisted policy, or the shipped default when none exists.
    public static func load() -> AutonomyPolicy {
        if let cached { return cached }
        let url = configurationFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let policy = try JSONDecoder().decode(AutonomyPolicy.self, from: Data(contentsOf: url))
                cached = policy
                return policy
            } catch {
                print("[Osaurus] Failed to load AutonomyPolicy: \(error)")
            }
        }
        // Never auto-write a default on missing-file (see ToolConfigurationStore).
        let fallback = AutonomyPolicy.defaultPolicy
        cached = fallback
        return fallback
    }

    /// Persist the policy without blocking the caller. The in-memory cache is
    /// updated synchronously so the UI reflects the change instantly; the
    /// encode + atomic write are coalesced onto a background queue.
    public static func save(_ policy: AutonomyPolicy) {
        cached = policy
        let url = configurationFileURL()
        writeCoordinator.enqueue(policy, to: url)
    }

    /// Synchronously drain any pending write (call from `applicationWillTerminate`).
    public static func flushPendingWrites(timeout: TimeInterval = 1.5) {
        writeCoordinator.flushSync(timeout: timeout)
    }

    private static func configurationFileURL() -> URL {
        if let dir = overrideDirectory {
            return dir.appendingPathComponent("computer-use.json")
        }
        return OsaurusPaths.computerUseConfigFile()
    }

    private static let writeCoordinator = WriteCoordinator()

    private final class WriteCoordinator: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.osaurus.computeruse.write", qos: .utility)
        private let lock = NSLock()
        private var pending: (policy: AutonomyPolicy, url: URL)?
        private var isDraining = false

        func enqueue(_ policy: AutonomyPolicy, to url: URL) {
            lock.lock()
            pending = (policy, url)
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
                Self.writeToDisk(job.policy, to: job.url)
            }
        }

        private static func writeToDisk(_ policy: AutonomyPolicy, to url: URL) {
            OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(policy).write(to: url, options: [.atomic])
            } catch {
                print("[Osaurus] Failed to save AutonomyPolicy: \(error)")
            }
        }
    }
}
