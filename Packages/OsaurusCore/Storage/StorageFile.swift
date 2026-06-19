//
//  StorageFile.swift
//  osaurus
//
//  Small filesystem helpers shared by the storage layer for handling a
//  SQLite database together with its WAL/SHM sidecars: cleaning them up
//  (so a stale `-wal` never re-attaches to a freshly swapped file) and
//  quarantining an unrecoverable database instead of deleting it.
//

import Foundation
import os

public enum StorageFile {
    private static let log = Logger(subsystem: "ai.osaurus", category: "storage.file")

    /// The sidecar paths SQLite can create alongside `path`. Osaurus databases
    /// run in WAL mode (`-wal`/`-shm`); the `-journal` rollback sidecar is
    /// included defensively so a stale journal from a non-WAL/older file (or a
    /// mode change) can't re-attach to a freshly swapped database.
    public static func sidecarPaths(for path: String) -> [String] {
        ["\(path)-wal", "\(path)-shm", "\(path)-journal"]
    }

    /// Best-effort removal of the `-wal`/`-shm` sidecars for `path`.
    /// Call after swapping/replacing the main file so a stale WAL from the
    /// previous (differently-keyed) file can't corrupt the new one.
    public static func removeSidecars(for path: String) {
        let fm = FileManager.default
        for sidecar in sidecarPaths(for: path) where fm.fileExists(atPath: sidecar) {
            try? fm.removeItem(atPath: sidecar)
        }
    }

    /// Remove the database file *and* its sidecars.
    public static func remove(path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        removeSidecars(for: path)
    }

    /// Directory where unrecoverable artifacts are parked instead of deleted.
    public static func quarantineDirectory() -> URL {
        OsaurusPaths.root().appendingPathComponent("quarantine", isDirectory: true)
    }

    /// Move `path` (and its sidecars) into `~/.osaurus/quarantine/` under a
    /// timestamped name so the user keeps a chance to recover it manually.
    /// Returns the destination of the main file when the move succeeded.
    @discardableResult
    public static func quarantine(path: String, reason: String) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        let dir = quarantineDirectory()
        OsaurusPaths.ensureExistsSilent(dir)

        let stamp = Self.timestamp()
        let base = URL(fileURLWithPath: path).lastPathComponent
        let dest = dir.appendingPathComponent("\(stamp)-\(base)")
        do {
            try fm.moveItem(atPath: path, toPath: dest.path)
        } catch {
            log.error(
                "quarantine: failed to move \(base, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        // Move sidecars next to the quarantined main file (best effort).
        for sidecar in sidecarPaths(for: path) where fm.fileExists(atPath: sidecar) {
            let sidecarName = URL(fileURLWithPath: sidecar).lastPathComponent
            try? fm.moveItem(atPath: sidecar, toPath: dir.appendingPathComponent("\(stamp)-\(sidecarName)").path)
        }
        log.error(
            "quarantined \(base, privacy: .public) (\(reason, privacy: .public)) -> \(dest.lastPathComponent, privacy: .public)"
        )
        return dest
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
