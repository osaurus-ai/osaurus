//
//  PalaceConfiguration.swift
//  osaurus
//
//  User-configurable settings for the Palace verbatim-memory subsystem.
//  Palace is OFF by default: `enabled == false` must produce zero behavior
//  change anywhere in the app (tools stripped from the schema, no DB file
//  created, no launch-time work).
//

import Foundation
import os

public struct PalaceConfiguration: Codable, Equatable, Sendable {
    /// Master toggle. Default FALSE — Palace is opt-in.
    public var enabled: Bool

    /// Embedding backend ("mlx" or "none"). When "none" (or when the
    /// embedding model is unavailable), search falls back to FTS5.
    public var embeddingBackend: String

    /// Wing used when a tool call omits `wing`.
    public var defaultWing: String

    /// Default LIMIT for `palace_search`.
    public var searchDefaultLimit: Int

    /// Maximum cosine distance (1 - similarity) for a vector hit to be
    /// returned. 2.0 disables the filter.
    public var maxDistance: Double

    // MARK: - Internal constants (not user-configurable in Phase 0)

    /// Maximum allowed content length for a single drawer. Larger payloads
    /// are rejected with a clear tool error; blob-file spillover is a later
    /// phase (`blob_ref` column already exists in the schema).
    public static let maxContentLength = 100_000

    public init(
        enabled: Bool = false,
        embeddingBackend: String = "mlx",
        defaultWing: String = "default",
        searchDefaultLimit: Int = 5,
        maxDistance: Double = 1.5
    ) {
        self.enabled = enabled
        self.embeddingBackend = embeddingBackend
        self.defaultWing = defaultWing
        self.searchDefaultLimit = searchDefaultLimit
        self.maxDistance = maxDistance
    }

    /// Returns a copy with all values clamped to valid ranges.
    public func validated() -> PalaceConfiguration {
        var c = self
        c.searchDefaultLimit = max(1, min(c.searchDefaultLimit, 50))
        c.maxDistance = max(0.0, min(c.maxDistance, 2.0))
        if c.defaultWing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            c.defaultWing = "default"
        }
        return c
    }

    public init(from decoder: Decoder) throws {
        let defaults = PalaceConfiguration()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        embeddingBackend =
            try c.decodeIfPresent(String.self, forKey: .embeddingBackend) ?? defaults.embeddingBackend
        defaultWing = try c.decodeIfPresent(String.self, forKey: .defaultWing) ?? defaults.defaultWing
        searchDefaultLimit =
            try c.decodeIfPresent(Int.self, forKey: .searchDefaultLimit) ?? defaults.searchDefaultLimit
        maxDistance = try c.decodeIfPresent(Double.self, forKey: .maxDistance) ?? defaults.maxDistance
    }

    public static var `default`: PalaceConfiguration { PalaceConfiguration() }
}

// MARK: - Store

public enum PalaceConfigurationStore: Sendable {
    private static let logger = Logger(subsystem: "ai.osaurus", category: "palace.config")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Cache entry keyed on the file's modification date so hand-edits to
    /// palace.json — the only enable/disable mechanism until a Settings UI
    /// ships — take effect on the next load() instead of requiring an app
    /// restart. `pendingWrite` marks a value cached by save() whose async
    /// disk write may not have landed yet; the next load adopts the file's
    /// mtime once it's visible.
    private struct Cached {
        let config: PalaceConfiguration
        let fileModificationDate: Date?
        let pendingWrite: Bool
    }

    private static let lock = OSAllocatedUnfairLock<Cached?>(initialState: nil)

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public static func load() -> PalaceConfiguration {
        let url = OsaurusPaths.palaceConfigFile()
        let onDisk = modificationDate(of: url)

        if let cached = lock.withLock({ $0 }) {
            if cached.pendingWrite {
                // Adopt the file's mtime once the async save has landed so
                // later hand-edits are detected as a change.
                lock.withLock {
                    $0 = Cached(
                        config: cached.config,
                        fileModificationDate: onDisk,
                        pendingWrite: onDisk == nil
                    )
                }
                return cached.config
            }
            if let onDisk, cached.fileModificationDate == onDisk {
                return cached.config
            }
        }

        // CRITICAL: see RemoteProviderConfigurationStore.load — never
        // auto-save an empty default on missing-file. The 2026-04
        // storage-migration recovery race showed this pattern can
        // permanently destroy user data.
        guard onDisk != nil else {
            lock.withLock { $0 = nil }
            return PalaceConfiguration()
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(PalaceConfiguration.self, from: data)
            let validated = config.validated()
            lock.withLock {
                $0 = Cached(config: validated, fileModificationDate: onDisk, pendingWrite: false)
            }
            return validated
        } catch {
            logger.error("Failed to load palace config: \(error)")
            return .default
        }
    }

    public static func save(_ config: PalaceConfiguration) {
        let validated = config.validated()
        let url = OsaurusPaths.palaceConfigFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let data = try encoder.encode(validated)
            // Update the cache before the write so in-process reads see the
            // new value immediately; the disk write then lands off the main
            // thread. Tests run against an override root and write
            // synchronously.
            lock.withLock {
                $0 = Cached(config: validated, fileModificationDate: nil, pendingWrite: true)
            }
            ConfigDiskWriter.write(
                data,
                to: url,
                synchronous: OsaurusPaths.overrideRoot != nil,
                onError: { logger.error("Failed to save palace config: \($0.localizedDescription)") }
            )
        } catch {
            logger.error("Failed to save palace config: \(error)")
        }
    }

    public static func invalidateCache() {
        lock.withLock { $0 = nil }
    }
}
