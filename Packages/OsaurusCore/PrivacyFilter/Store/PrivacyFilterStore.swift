//
//  PrivacyFilterStore.swift
//  osaurus / PrivacyFilter
//
//  JSON-on-disk persistence for `PrivacyFilterConfiguration`, modeled
//  on `ServerRuntimeSettingsStore`. Provides a nonisolated `snapshot()`
//  so the request pipeline (running on a non-MainActor `RemoteProviderService`
//  actor) can read the policy without hopping back to the main actor.
//

import Foundation

public enum PrivacyFilterStore {
    /// Test-only override for the config directory. Reading callers
    /// must go through `directoryURL()`; writing callers must hold
    /// `snapshotLock` (use `setOverrideDirectory(_:)`) so a parallel
    /// `snapshot()` in another suite can't observe a half-set URL.
    private nonisolated(unsafe) static var _overrideDirectory: URL?

    /// In-memory snapshot. Updated on every save so the pipeline never
    /// pays a disk read on the per-request hot path.
    private nonisolated(unsafe) static var cachedSnapshot: PrivacyFilterConfiguration?
    /// `NSLock` is `Sendable`, so the `let` doesn't need
    /// `nonisolated(unsafe)`. The mutable state above DOES — that's
    /// why we still need the lock at all.
    private static let snapshotLock = NSLock()

    private static let fileName = "privacy-filter.json"

    /// Atomically set the override directory and drop the in-memory
    /// cache so the next `snapshot()` re-reads from the new location.
    /// Pass `nil` in tearDown to restore the real config path.
    public nonisolated static func setOverrideDirectory(_ url: URL?) {
        snapshotLock.lock()
        _overrideDirectory = url
        cachedSnapshot = nil
        snapshotLock.unlock()
    }

    // MARK: - Load / Save

    /// Load from disk, returning `nil` when no file exists. Callers
    /// that need a non-optional should use `snapshot()`.
    public nonisolated static func load() -> PrivacyFilterConfiguration? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(PrivacyFilterConfiguration.self, from: data)
            snapshotLock.lock()
            cachedSnapshot = decoded
            snapshotLock.unlock()
            return decoded
        } catch {
            print("[Osaurus] Failed to load PrivacyFilterConfiguration: \(error)")
            return nil
        }
    }

    /// Persist and update the snapshot. Posts
    /// `.privacyFilterConfigurationChanged` so UI observers re-read.
    public nonisolated static func save(_ configuration: PrivacyFilterConfiguration) {
        let url = fileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: [.atomic])
            snapshotLock.lock()
            cachedSnapshot = configuration
            snapshotLock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .privacyFilterConfigurationChanged,
                    object: configuration
                )
            }
        } catch {
            print("[Osaurus] Failed to save PrivacyFilterConfiguration: \(error)")
        }
    }

    // MARK: - Snapshot

    /// Latest configuration. Returns the default value when nothing
    /// has been persisted yet. Safe to call from any actor context.
    public nonisolated static func snapshot() -> PrivacyFilterConfiguration {
        snapshotLock.lock()
        if let cached = cachedSnapshot {
            snapshotLock.unlock()
            return cached
        }
        snapshotLock.unlock()
        return load() ?? .default
    }

    /// Drop the in-memory cache. Tests use this so the next snapshot()
    /// re-reads from disk.
    public nonisolated static func invalidateSnapshot() {
        snapshotLock.lock()
        cachedSnapshot = nil
        snapshotLock.unlock()
    }

    // MARK: - Paths

    private nonisolated static func directoryURL() -> URL {
        snapshotLock.lock()
        let override = _overrideDirectory
        snapshotLock.unlock()
        if let override { return override }
        return OsaurusPaths.config()
    }

    private nonisolated static func fileURL() -> URL {
        directoryURL().appendingPathComponent(fileName)
    }
}
