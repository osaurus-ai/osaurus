//
//  LegacySessionImporter.swift
//  osaurus
//
//  One-time migration of per-session JSON files at `~/.osaurus/sessions/*.json`
//  into the SQLite-backed `ChatHistoryDatabase`. After a successful import
//  each file is moved (not deleted) into `~/.osaurus/sessions.archive/`
//  so users always have a recoverable snapshot of their original history.
//

import Foundation

@MainActor
enum LegacySessionImporter {
    /// Tracks completion in-memory so subsequent calls within the same app
    /// run no-op even if the legacy directory becomes non-empty again.
    private static var didRun = false

    static func runIfNeeded() {
        guard !didRun else { return }
        didRun = true

        let legacyDir = OsaurusPaths.resolvePath(
            new: OsaurusPaths.sessions(),
            legacy: "ChatSessions"
        )

        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyDir.path),
            let files = try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil)
        else { return }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        guard !jsonFiles.isEmpty else { return }

        let archiveDir = OsaurusPaths.sessionsArchive()
        OsaurusPaths.ensureExistsSilent(archiveDir)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var imported = 0
        var failed = 0
        for file in jsonFiles {
            do {
                let data = try Data(contentsOf: file)
                let session = try decoder.decode(ChatSessionData.self, from: data)
                try ChatHistoryDatabase.shared.saveSession(session)
                let target = archiveDir.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    try? fm.removeItem(at: target)
                }
                try fm.moveItem(at: file, to: target)
                imported += 1
            } catch {
                failed += 1
                print(
                    "[LegacySessionImporter] Failed to import \(file.lastPathComponent): \(error)"
                )
            }
        }

        print(
            "[LegacySessionImporter] Migrated \(imported) JSON session(s) to SQLite (\(failed) failed). Originals archived under \(archiveDir.path)."
        )
    }
}
