//
//  MigrationGenerator.swift
//  osaurus
//
//  Writes numbered up/down migration files (spec §3, §7.3) under
//  `~/.osaurus/agents/<id>/migrations/`. Each `db.create_table`,
//  `db.alter_table`, and `db.migrate` call produces one pair:
//
//      0007-add-water-log.sql        -- the applied SQL ("up")
//      0007-add-water-log.down.sql   -- the reversal ("down")
//
//  The agent does NOT see these files; they exist for the user and
//  for any future "rollback to migration N" tooling. We never re-apply
//  them from disk (the SQLite file is canonical).
//

import Foundation

public enum MigrationGenerator {
    /// Persist a migration pair for `agentId`. Returns the assigned
    /// migration index and the URLs of the up/down files. Best-effort:
    /// on filesystem failure we log + continue — the migration was
    /// applied to the canonical SQLite file already, and the agent's
    /// view of "what changed" is reflected in `_changelog`.
    @discardableResult
    public static func writePair(
        for agentId: UUID,
        slug: String,
        upSQL: String,
        downSQL: String
    ) -> (index: Int, upURL: URL, downURL: URL)? {
        let dir = OsaurusPaths.agentMigrationsDirectory(for: agentId)
        OsaurusPaths.ensureExistsSilent(dir)
        let index = nextMigrationIndex(in: dir)
        let safeSlug = sanitizeSlug(slug)
        let base = String(format: "%04d-%@", index, safeSlug as CVarArg)
        let upURL = dir.appendingPathComponent("\(base).sql")
        let downURL = dir.appendingPathComponent("\(base).down.sql")

        do {
            try upSQL.write(to: upURL, atomically: true, encoding: .utf8)
            try downSQL.write(to: downURL, atomically: true, encoding: .utf8)
            return (index, upURL, downURL)
        } catch {
            print("[Osaurus] MigrationGenerator: write failed: \(error)")
            return nil
        }
    }

    /// Scan the migrations directory and return the next 4-digit index.
    /// Linear scan is fine — at user-scale agents these directories
    /// won't grow beyond a few hundred files for the lifetime of the
    /// agent.
    static func nextMigrationIndex(in dir: URL) -> Int {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            )
        else { return 1 }
        var max = 0
        for entry in entries {
            let name = entry.lastPathComponent
            // First 4 characters should be digits when the file is one of ours.
            let prefix = name.prefix(4)
            guard let n = Int(prefix) else { continue }
            if n > max { max = n }
        }
        return max + 1
    }

    /// Normalize a free-form description into a filesystem-safe slug.
    /// Lowercase, ASCII letters/digits/dashes; collapse runs of
    /// disallowed chars into a single dash; truncate to 48 chars.
    static func sanitizeSlug(_ raw: String) -> String {
        var out = ""
        var lastWasDash = false
        for ch in raw.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if out.isEmpty { out = "migration" }
        if out.count > 48 { out = String(out.prefix(48)) }
        return out
    }
}
