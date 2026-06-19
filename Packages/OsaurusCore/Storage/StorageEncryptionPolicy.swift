//
//  StorageEncryptionPolicy.swift
//  osaurus
//
//  The user-selected at-rest encryption posture for `~/.osaurus/`.
//
//  As of the SQLCipher walk-back, Osaurus stores local data **plaintext by
//  default** and relies on macOS FileVault for at-rest protection. Users who
//  want file-level encryption can opt back in to SQLCipher (see
//  `StorageSettingsView`), which re-introduces the Keychain-key dependency.
//
//  The posture is persisted as a small NON-encrypted JSON marker next to the
//  data ( `~/.osaurus/.storage-encryption.json` ). It MUST stay plaintext:
//  it's read at the very start of launch to decide whether the encryption key
//  is even needed, so it cannot itself depend on that key (chicken/egg).
//

import Foundation

public enum StorageEncryptionMode: String, Codable, Sendable {
    /// SQLite databases + `.osec` files are written plaintext; FileVault is
    /// the at-rest protection. No Keychain key is required to open anything.
    case plaintext
    /// SQLite databases are SQLCipher-encrypted and `.osec` files are
    /// AES-GCM wrapped with the Keychain-held data-encryption key.
    case encrypted
}

/// Source of truth for the desired at-rest encryption mode. Thread-safe;
/// the resolved mode is cached after the first read.
public final class StorageEncryptionPolicy: @unchecked Sendable {
    public static let shared = StorageEncryptionPolicy()

    /// The default posture for installs with no marker yet. Plaintext is the
    /// deliberate post-walk-back default: reliability first, FileVault at rest.
    public static let defaultMode: StorageEncryptionMode = .plaintext

    private static let markerFilename = ".storage-encryption.json"
    private static let markerVersion = 1

    private struct Marker: Codable {
        var mode: StorageEncryptionMode
        var version: Int
    }

    private let lock = NSLock()
    private var cached: StorageEncryptionMode?

    private init() {}

    private func markerURL() -> URL {
        OsaurusPaths.root().appendingPathComponent(Self.markerFilename)
    }

    /// The desired at-rest mode. Defaults to `defaultMode` when no marker
    /// exists (fresh install, or existing install upgrading into the
    /// walk-back — its encrypted files are then converged to plaintext).
    public func desiredMode() -> StorageEncryptionMode {
        // Under tests the data root is swapped between cases via
        // `OsaurusPaths.overrideRoot`, so a process-global cache would leak a
        // prior case's posture. Always re-read from the active root there.
        let cachingEnabled = !RuntimeEnvironment.isUnderTests
        if cachingEnabled {
            lock.lock()
            if let cached {
                lock.unlock()
                return cached
            }
            lock.unlock()
        }

        let resolved = persistedMode() ?? Self.defaultMode

        if cachingEnabled {
            lock.lock()
            cached = resolved
            lock.unlock()
        }
        return resolved
    }

    /// The mode recorded in the on-disk marker, or `nil` when no marker exists
    /// yet. Unlike `desiredMode()` this never substitutes `defaultMode`, so the
    /// launch resolver can tell a never-decided install (no marker) apart from
    /// one that explicitly chose plaintext. Always reads the file directly
    /// (bypassing the cache) so a marker written earlier this launch is seen.
    public func persistedMode() -> StorageEncryptionMode? {
        guard let data = try? Data(contentsOf: markerURL()),
            let marker = try? JSONDecoder().decode(Marker.self, from: data)
        else { return nil }
        return marker.mode
    }

    /// True when the user has opted in to SQLCipher encryption.
    public var isEncryptionEnabled: Bool { desiredMode() == .encrypted }

    /// Persist a new desired mode. Callers are responsible for actually
    /// converting on-disk artifacts to match (see `StorageMigrationCoordinator`).
    public func setDesiredMode(_ mode: StorageEncryptionMode) throws {
        let marker = Marker(mode: mode, version: Self.markerVersion)
        let data = try JSONEncoder().encode(marker)
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.root())
        try data.write(to: markerURL(), options: [.atomic])
        lock.lock()
        cached = mode
        lock.unlock()
    }

    /// Test seam: drop the cached value so a fresh marker read happens.
    public func invalidateCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
