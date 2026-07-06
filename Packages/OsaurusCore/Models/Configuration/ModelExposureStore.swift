//
//  ModelExposureStore.swift
//  osaurus
//
//  Per-model API exposure settings: which models the server lists on
//  /models, /tags, and the plugin list_models surface.
//

import Foundation

/// The kind of model being resolved for exposure. Determines the default
/// when the user has not explicitly toggled the model.
public enum ModelExposureKind: Sendable {
    /// Installed local MLX models and the Apple Foundation model.
    /// Exposed by default.
    case local
    /// Remote provider models (Osaurus Router and BYOK providers),
    /// identified by their prefixed id (e.g. "osaurus/openai/gpt-5.2").
    /// Hidden by default.
    case remote

    public var defaultExposed: Bool {
        switch self {
        case .local: return true
        case .remote: return false
        }
    }
}

/// Persisted exposure settings. Only explicit user toggles are stored;
/// everything else resolves to the kind's default. This means existing
/// users automatically get "local on, remote off" without migration,
/// and newly installed/discovered models pick up the right default.
public struct ModelExposureSettings: Codable, Equatable, Sendable {
    /// Model id -> exposed. Keys match the ids the API returns: the repo
    /// slug for local models (e.g. "qwen3-4b-4bit"), "foundation", and
    /// the provider-prefixed id for remote models.
    public var overrides: [String: Bool]

    public init(overrides: [String: Bool] = [:]) {
        self.overrides = overrides
    }

    public func isExposed(id: String, kind: ModelExposureKind) -> Bool {
        overrides[id] ?? kind.defaultExposed
    }
}

/// Thread-safe store for `ModelExposureSettings`. HTTP handlers run off the
/// MainActor, so reads go through an in-memory snapshot behind a lock
/// (loaded once from disk, updated on save) instead of per-request disk I/O.
public final class ModelExposureStore: @unchecked Sendable {
    public static let shared = ModelExposureStore()

    /// When set, reads/writes use this directory instead of the default
    /// config path. Tests set this before any access.
    public var overrideDirectory: URL? {
        didSet {
            lock.lock()
            cached = nil
            lock.unlock()
        }
    }

    private let lock = NSLock()
    private var cached: ModelExposureSettings?

    /// Internal so tests can create isolated instances pointed at a temp
    /// directory. Production code uses `shared`.
    init(overrideDirectory: URL? = nil) {
        self.overrideDirectory = overrideDirectory
    }

    // MARK: - Reads

    public func isExposed(id: String, kind: ModelExposureKind) -> Bool {
        settings().isExposed(id: id, kind: kind)
    }

    public func settings() -> ModelExposureSettings {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = loadFromDisk() ?? ModelExposureSettings()
        cached = loaded
        return loaded
    }

    // MARK: - Writes

    public func setExposed(_ exposed: Bool, id: String, kind: ModelExposureKind) {
        mutate { settings in
            if exposed == kind.defaultExposed {
                settings.overrides.removeValue(forKey: id)
            } else {
                settings.overrides[id] = exposed
            }
        }
    }

    /// Bulk toggle used by per-provider "Expose all / Hide all" actions.
    public func setExposed(_ exposed: Bool, ids: [String], kind: ModelExposureKind) {
        mutate { settings in
            for id in ids {
                if exposed == kind.defaultExposed {
                    settings.overrides.removeValue(forKey: id)
                } else {
                    settings.overrides[id] = exposed
                }
            }
        }
    }

    private func mutate(_ change: (inout ModelExposureSettings) -> Void) {
        lock.lock()
        var settings = cached ?? loadFromDisk() ?? ModelExposureSettings()
        change(&settings)
        cached = settings
        lock.unlock()
        persist(settings)
    }

    // MARK: - Persistence

    private func fileURL() -> URL {
        if let dir = overrideDirectory {
            return dir.appendingPathComponent("model-exposure.json")
        }
        return OsaurusPaths.config().appendingPathComponent("model-exposure.json")
    }

    private func loadFromDisk() -> ModelExposureSettings? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(ModelExposureSettings.self, from: Data(contentsOf: url))
        } catch {
            print("[Osaurus] Failed to load ModelExposureSettings: \(error)")
            return nil
        }
    }

    private func persist(_ settings: ModelExposureSettings) {
        let url = fileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            ConfigDiskWriter.write(
                data,
                to: url,
                synchronous: overrideDirectory != nil || OsaurusPaths.overrideRoot != nil,
                onError: { print("[Osaurus] Failed to save ModelExposureSettings: \($0)") }
            )
        } catch {
            print("[Osaurus] Failed to save ModelExposureSettings: \(error)")
        }
    }
}
