//
//  KnowledgeSchemaForwardCompatTests.swift
//  OsaurusCoreTests — Knowledge
//
//  A knowledge database stamped by a NEWER build must still open.
//
//  Refusing one is indistinguishable from data loss to the user: every
//  collection renders empty and every `search_knowledge` returns nothing.
//  That is the same failure that produced the "all my chat history is gone
//  after updating" reports one database over, and it is exactly the symptom
//  osaurus#2439 opened with, so it must not be reachable by bouncing between
//  release channels.
//

import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct KnowledgeSchemaForwardCompatTests {

    /// Migrations must stay additive for the forward-open to be sound. If a
    /// future migration drops, renames, or re-types anything, this constant
    /// has to go false and be replaced by an explicit minimum-version gate.
    @Test func migrationsAreDeclaredAdditiveOnly() {
        #expect(KnowledgeDatabase.migrationsAreAdditiveOnly)
    }

    /// A file stamped several versions ahead opens, and its rows stay
    /// readable through this build's queries.
    @Test func schemaAheadDatabaseOpensAndStaysReadable() async throws {
        try await withTempRoot {
            try seedKnowledgeDB([
                // A future build's schema: everything this build knows, plus
                // an additive column it has never heard of.
                """
                CREATE TABLE documents (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    collection_id TEXT NOT NULL,
                    rel_path TEXT NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    doc_type TEXT NOT NULL DEFAULT '',
                    inferred_type TEXT NOT NULL DEFAULT '',
                    summary TEXT NOT NULL DEFAULT '',
                    tags_csv TEXT NOT NULL DEFAULT '',
                    content_hash TEXT NOT NULL DEFAULT '',
                    size_bytes INTEGER NOT NULL DEFAULT 0,
                    modified_at TEXT NOT NULL DEFAULT '',
                    indexed_at TEXT NOT NULL DEFAULT '',
                    a_column_from_the_future TEXT NOT NULL DEFAULT ''
                )
                """,
                """
                INSERT INTO documents
                    (collection_id, rel_path, title, doc_type, summary, tags_csv,
                     content_hash, size_bytes, modified_at, indexed_at)
                VALUES ('c1', 'kept.md', 'Kept', 'guide', '', '', 'h', 1, '', '')
                """,
                "PRAGMA user_version = 999",
            ])

            let db = KnowledgeDatabase()
            // The load-bearing assertion: this must not throw.
            try db.open()
            defer { db.close() }

            // And the pre-existing row must still be visible, since "opens but
            // reads nothing" would look identical to the refusal we removed.
            let documents = try db.listDocuments(collectionIds: ["c1"])
            #expect(documents.map(\.relPath) == ["kept.md"])

            // `user_version` is left untouched so the newer build still
            // recognizes its own schema and re-runs its own migrations.
            #expect(diskUserVersion() == 999)
        }
    }

    /// The ordinary path is unaffected: a fresh database migrates up to this
    /// build's version.
    @Test func freshDatabaseMigratesToCurrentVersion() async throws {
        try await withTempRoot {
            let db = KnowledgeDatabase()
            try db.open()
            defer { db.close() }
            #expect(diskUserVersion() == 4)
            // v4 is the write log; prove the table actually exists rather
            // than trusting the version stamp.
            #expect(try db.listWriteRecords(collectionId: "c1").isEmpty)
        }
    }

    /// An older-but-valid file still migrates forward rather than being
    /// mistaken for a schema-ahead one.
    @Test func olderDatabaseStillMigratesForward() async throws {
        try await withTempRoot {
            try seedKnowledgeDB(["PRAGMA user_version = 0"])
            let db = KnowledgeDatabase()
            try db.open()
            defer { db.close() }
            #expect(diskUserVersion() == 4)
        }
    }

    // MARK: - Harness

    private func withTempRoot(_ body: @Sendable () throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-knowledge-schema-tests-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
                try? FileManager.default.removeItem(at: root)
            }
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            StorageKeyManager.shared.wipeCache()
            try body()
        }
    }

    private func seedKnowledgeDB(_ statements: [String]) throws {
        let path = OsaurusPaths.knowledgeDatabaseFile().path
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let conn = try EncryptedSQLiteOpener.open(path: path, key: nil)
        defer { sqlite3_close(conn) }
        for sql in statements {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(conn, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? "?"
                sqlite3_free(err)
                throw NSError(
                    domain: "KnowledgeSchemaForwardCompatTests",
                    code: Int(rc),
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        }
    }

    private func diskUserVersion() -> Int {
        guard
            let conn = try? EncryptedSQLiteOpener.open(
                path: OsaurusPaths.knowledgeDatabaseFile().path,
                key: nil,
                applyPerfPragmas: false
            )
        else { return -1 }
        defer { sqlite3_close(conn) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
    }
}
