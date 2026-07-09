//
//  KnowledgeDatabase.swift
//  osaurus
//
//  SQLite index for the knowledge feature.
//  WAL mode, serial queue, versioned migrations.
//
//  Tables:
//    documents  — one row per indexed markdown file (frontmatter facets)
//    chunks     — heading-aware chunks of each document
//    chunks_fts — FTS5 contentless mirror of chunks for BM25 search
//
//  The markdown files in each collection folder are the source of truth;
//  every row here is a derived, rebuildable artifact. Chunk deletes are
//  explicit (no FK cascade) so the FTS triggers always fire.
//

import Foundation
import OsaurusSQLCipher

public enum KnowledgeDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case databaseFromNewerVersion(found: Int, expected: Int)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let msg): return "Failed to open knowledge database: \(msg)"
        case .failedToExecute(let msg): return "Failed to execute query: \(msg)"
        case .failedToPrepare(let msg): return "Failed to prepare statement: \(msg)"
        case .migrationFailed(let msg): return "Knowledge migration failed: \(msg)"
        case .databaseFromNewerVersion(let found, let expected):
            return
                "Knowledge database is schema v\(found) but this build supports up to v\(expected). Refusing to open to avoid forward-version corruption."
        case .notOpen: return "Knowledge database is not open"
        }
    }
}

public final class KnowledgeDatabase: @unchecked Sendable {
    public static let shared = KnowledgeDatabase()

    /// Highest schema version this build knows how to produce.
    private static let latestSchemaVersion = 2

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.knowledge.database")

    public var isOpen: Bool {
        queue.sync { db != nil }
    }

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        // Park while a storage key rotation is in flight so we can't open a
        // half-rekeyed file — same gate as every other `*Database.open()`.
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.knowledge())
            do {
                db = try OsaurusStorageOpener.open(path: OsaurusPaths.knowledgeDatabaseFile().path)
            } catch let error as EncryptedSQLiteError {
                throw KnowledgeDatabaseError.failedToOpen(error.localizedDescription)
            }
            do {
                try runMigrations()
            } catch {
                // Close the half-opened connection before rethrowing so a
                // retry of `open()` doesn't no-op against an unmigrated schema.
                if let connection = db {
                    sqlite3_close(connection)
                    db = nil
                }
                throw error
            }
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "knowledge",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    /// Open an in-memory database for testing. **Plaintext**.
    public func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            db = try EncryptedSQLiteOpener.open(
                path: ":memory:",
                key: nil,
                applyPerfPragmas: false
            )
            try runMigrations()
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "knowledge")
        queue.sync {
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    // MARK: - Schema & Migrations

    private func runMigrations() throws {
        let currentVersion = try getSchemaVersion()
        if currentVersion > Self.latestSchemaVersion {
            throw KnowledgeDatabaseError.databaseFromNewerVersion(
                found: currentVersion,
                expected: Self.latestSchemaVersion
            )
        }
        if currentVersion < 1 {
            try runMigrationStep(1, migrateToV1)
        }
        if currentVersion < 2 {
            try runMigrationStep(2, migrateToV2)
        }
    }

    private func runMigrationStep(_ version: Int, _ body: () throws -> Void) throws {
        try executeRaw("BEGIN TRANSACTION")
        do {
            try body()
            try setSchemaVersion(version)
            try executeRaw("COMMIT")
        } catch {
            try? executeRaw("ROLLBACK")
            throw KnowledgeDatabaseError.migrationFailed("v\(version): \(error.localizedDescription)")
        }
    }

    private func getSchemaVersion() throws -> Int {
        var version: Int = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return version
    }

    private func setSchemaVersion(_ version: Int) throws {
        try executeRaw("PRAGMA user_version = \(version)")
    }

    private func migrateToV1() throws {
        KnowledgeLogger.database.info("Running v1 migration (initial knowledge schema)")

        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS documents (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                collection_id TEXT NOT NULL,
                rel_path TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                doc_type TEXT NOT NULL DEFAULT '',
                summary TEXT NOT NULL DEFAULT '',
                tags_csv TEXT NOT NULL DEFAULT '',
                content_hash TEXT NOT NULL,
                size_bytes INTEGER NOT NULL DEFAULT 0,
                modified_at TEXT NOT NULL DEFAULT '',
                indexed_at TEXT NOT NULL,
                UNIQUE(collection_id, rel_path)
            )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_documents_collection ON documents(collection_id)"
        )

        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_id INTEGER NOT NULL,
                chunk_index INTEGER NOT NULL,
                heading_path TEXT NOT NULL DEFAULT '',
                content TEXT NOT NULL,
                UNIQUE(document_id, chunk_index)
            )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_chunks_document ON chunks(document_id)"
        )

        // FTS5 contentless mirror of chunks. SQLCipher transparently
        // encrypts the FTS5 shadow tables; the authoritative text lives in
        // `chunks`.
        try executeRaw(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                content, heading_path,
                content='chunks',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            )
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
                INSERT INTO chunks_fts(rowid, content, heading_path)
                VALUES (new.id, new.content, new.heading_path);
            END
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, content, heading_path)
                VALUES('delete', old.id, old.content, old.heading_path);
            END
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, content, heading_path)
                VALUES('delete', old.id, old.content, old.heading_path);
                INSERT INTO chunks_fts(rowid, content, heading_path)
                VALUES (new.id, new.content, new.heading_path);
            END
            """
        )

        KnowledgeLogger.database.info("v1 migration completed")
    }

    /// V2: curation tables. Tickets are agent-filed staleness reports;
    /// proposals are curator-drafted replacements awaiting human review.
    /// Neither table references the corpus rows — a ticket survives its
    /// document being re-indexed or pruned.
    private func migrateToV2() throws {
        KnowledgeLogger.database.info("Running v2 migration (curation tables)")

        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS tickets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                collection_id TEXT NOT NULL,
                rel_path TEXT NOT NULL,
                reason TEXT NOT NULL,
                evidence TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'open',
                created_by TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status)")

        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS proposals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ticket_id INTEGER,
                collection_id TEXT NOT NULL,
                rel_path TEXT NOT NULL,
                new_content TEXT NOT NULL,
                rationale TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'pending',
                created_by TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_proposals_status ON proposals(status)")

        KnowledgeLogger.database.info("v2 migration completed")
    }

    // MARK: - Documents

    /// Insert or update a document row, returning its row id. Chunks are
    /// replaced separately via `replaceChunks` so the two writes can share
    /// one indexing pass.
    public func upsertDocument(
        collectionId: String,
        relPath: String,
        title: String,
        docType: String,
        summary: String,
        tagsCSV: String,
        contentHash: String,
        sizeBytes: Int,
        modifiedAt: String
    ) throws -> Int {
        var documentId = 0
        try prepareAndExecute(
            """
            INSERT INTO documents
                (collection_id, rel_path, title, doc_type, summary, tags_csv,
                 content_hash, size_bytes, modified_at, indexed_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(collection_id, rel_path) DO UPDATE SET
                title = excluded.title,
                doc_type = excluded.doc_type,
                summary = excluded.summary,
                tags_csv = excluded.tags_csv,
                content_hash = excluded.content_hash,
                size_bytes = excluded.size_bytes,
                modified_at = excluded.modified_at,
                indexed_at = excluded.indexed_at
            RETURNING id
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: collectionId)
                Self.bindText(stmt, index: 2, value: relPath)
                Self.bindText(stmt, index: 3, value: title)
                Self.bindText(stmt, index: 4, value: docType)
                Self.bindText(stmt, index: 5, value: summary)
                Self.bindText(stmt, index: 6, value: tagsCSV)
                Self.bindText(stmt, index: 7, value: contentHash)
                sqlite3_bind_int(stmt, 8, Int32(sizeBytes))
                Self.bindText(stmt, index: 9, value: modifiedAt)
                Self.bindText(stmt, index: 10, value: Self.iso8601Now())
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    documentId = Int(sqlite3_column_int64(stmt, 0))
                }
            }
        )
        guard documentId != 0 else {
            throw KnowledgeDatabaseError.failedToExecute("upsertDocument returned no id")
        }
        return documentId
    }

    /// Replace all chunks of a document in one transaction. Explicit
    /// DELETE + INSERT so the FTS triggers fire for every row. Returns
    /// the count of chunks removed so the caller can drop stale vectors
    /// when a document shrinks.
    @discardableResult
    public func replaceChunks(
        documentId: Int,
        chunks: [(headingPath: String, content: String)]
    ) throws -> Int {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return try queue.sync {
            guard let connection = db else { throw KnowledgeDatabaseError.notOpen }
            var removed = 0
            try Self.execRaw(on: connection, "BEGIN TRANSACTION")
            do {
                try Self.prepareAndExecute(
                    on: connection,
                    "DELETE FROM chunks WHERE document_id = ?1",
                    bind: { stmt in sqlite3_bind_int64(stmt, 1, Int64(documentId)) },
                    process: { stmt in
                        _ = sqlite3_step(stmt)
                        removed = Int(sqlite3_changes(connection))
                    }
                )
                for (index, chunk) in chunks.enumerated() {
                    try Self.prepareAndExecute(
                        on: connection,
                        """
                        INSERT INTO chunks (document_id, chunk_index, heading_path, content)
                        VALUES (?1, ?2, ?3, ?4)
                        """,
                        bind: { stmt in
                            sqlite3_bind_int64(stmt, 1, Int64(documentId))
                            sqlite3_bind_int(stmt, 2, Int32(index))
                            Self.bindText(stmt, index: 3, value: chunk.headingPath)
                            Self.bindText(stmt, index: 4, value: chunk.content)
                        },
                        process: { stmt in
                            guard sqlite3_step(stmt) == SQLITE_DONE else {
                                throw KnowledgeDatabaseError.failedToExecute(
                                    String(cString: sqlite3_errmsg(connection))
                                )
                            }
                        }
                    )
                }
                try Self.execRaw(on: connection, "COMMIT")
            } catch {
                try? Self.execRaw(on: connection, "ROLLBACK")
                throw error
            }
            return removed
        }
    }

    /// Content hashes for every indexed document of a collection, keyed by
    /// relative path. Drives the incremental skip + prune pass.
    public func documentHashes(collectionId: String) throws -> [String: String] {
        var hashes: [String: String] = [:]
        try prepareAndExecute(
            "SELECT rel_path, content_hash FROM documents WHERE collection_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: collectionId) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let relPath = Self.columnText(stmt, 0)
                    hashes[relPath] = Self.columnText(stmt, 1)
                }
            }
        )
        return hashes
    }

    /// Delete a document and its chunks, returning the removed chunk count
    /// so the caller can drop the matching vectors.
    @discardableResult
    public func deleteDocument(collectionId: String, relPath: String) throws -> Int {
        var chunkCount = 0
        try prepareAndExecute(
            """
            SELECT COUNT(*) FROM chunks WHERE document_id IN
                (SELECT id FROM documents WHERE collection_id = ?1 AND rel_path = ?2)
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: collectionId)
                Self.bindText(stmt, index: 2, value: relPath)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    chunkCount = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        try prepareAndExecute(
            """
            DELETE FROM chunks WHERE document_id IN
                (SELECT id FROM documents WHERE collection_id = ?1 AND rel_path = ?2)
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: collectionId)
                Self.bindText(stmt, index: 2, value: relPath)
            },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
        try prepareAndExecute(
            "DELETE FROM documents WHERE collection_id = ?1 AND rel_path = ?2",
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: collectionId)
                Self.bindText(stmt, index: 2, value: relPath)
            },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
        return chunkCount
    }

    /// Delete every row belonging to a collection (registry delete or
    /// full re-index): index rows AND its curation trail — orphaned
    /// tickets/proposals would otherwise resurface in the review UI with
    /// no collection to apply them to.
    public func deleteCollection(collectionId: String) throws {
        try prepareAndExecute(
            """
            DELETE FROM chunks WHERE document_id IN
                (SELECT id FROM documents WHERE collection_id = ?1)
            """,
            bind: { stmt in Self.bindText(stmt, index: 1, value: collectionId) },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
        try prepareAndExecute(
            "DELETE FROM documents WHERE collection_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: collectionId) },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
        try prepareAndExecute(
            "DELETE FROM tickets WHERE collection_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: collectionId) },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
        try prepareAndExecute(
            "DELETE FROM proposals WHERE collection_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: collectionId) },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
    }

    public func getDocument(collectionId: String, relPath: String) throws -> KnowledgeDocument? {
        var document: KnowledgeDocument?
        try prepareAndExecute(
            """
            SELECT \(Self.documentColumns) FROM documents
            WHERE collection_id = ?1 AND rel_path = ?2 LIMIT 1
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: collectionId)
                Self.bindText(stmt, index: 2, value: relPath)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    document = Self.readDocument(stmt)
                }
            }
        )
        return document
    }

    /// List documents across the supplied collections, optionally filtered
    /// by OKF `type` and/or a tag (exact match against the normalized tag
    /// list). Ordered by collection then path for stable browsing.
    public func listDocuments(
        collectionIds: [String],
        docType: String? = nil,
        tag: String? = nil,
        limit: Int = 100
    ) throws -> [KnowledgeDocument] {
        guard !collectionIds.isEmpty else { return [] }
        var documents: [KnowledgeDocument] = []
        let placeholders = Self.inPlaceholders(count: collectionIds.count, startingAt: 1)
        var sql = """
            SELECT \(Self.documentColumns) FROM documents
            WHERE collection_id IN (\(placeholders))
            """
        var nextIndex = collectionIds.count + 1
        var docTypeIndex: Int?
        var tagIndex: Int?
        if docType != nil {
            docTypeIndex = nextIndex
            sql += " AND doc_type = ?\(nextIndex) COLLATE NOCASE"
            nextIndex += 1
        }
        if tag != nil {
            tagIndex = nextIndex
            sql += " AND (',' || tags_csv || ',') LIKE ('%,' || ?\(nextIndex) || ',%')"
            nextIndex += 1
        }
        sql += " ORDER BY collection_id, rel_path LIMIT ?\(nextIndex)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                for (offset, id) in collectionIds.enumerated() {
                    Self.bindText(stmt, index: Int32(offset + 1), value: id)
                }
                if let docTypeIndex, let docType {
                    Self.bindText(stmt, index: Int32(docTypeIndex), value: docType)
                }
                if let tagIndex, let tag {
                    Self.bindText(stmt, index: Int32(tagIndex), value: tag.lowercased())
                }
                sqlite3_bind_int(stmt, Int32(nextIndex), Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    documents.append(Self.readDocument(stmt))
                }
            }
        )
        return documents
    }

    // MARK: - Chunk search

    /// BM25 text search over chunks in the supplied collections. Falls
    /// back to LIKE when the query yields no usable FTS tokens.
    public func searchChunksText(
        query: String,
        collectionIds: [String],
        limit: Int = 20
    ) throws -> [KnowledgeChunkHit] {
        guard !collectionIds.isEmpty else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var hits: [KnowledgeChunkHit] = []
        let placeholders = Self.inPlaceholders(count: collectionIds.count, startingAt: 2)
        let limitIndex = collectionIds.count + 2

        if let ftsQuery = Self.ftsMatchQuery(trimmed) {
            try prepareAndExecute(
                """
                SELECT \(Self.chunkHitColumns)
                FROM chunks c
                JOIN chunks_fts ON chunks_fts.rowid = c.id
                JOIN documents d ON d.id = c.document_id
                WHERE chunks_fts MATCH ?1 AND d.collection_id IN (\(placeholders))
                ORDER BY bm25(chunks_fts) LIMIT ?\(limitIndex)
                """,
                bind: { stmt in
                    Self.bindText(stmt, index: 1, value: ftsQuery)
                    for (offset, id) in collectionIds.enumerated() {
                        Self.bindText(stmt, index: Int32(offset + 2), value: id)
                    }
                    sqlite3_bind_int(stmt, Int32(limitIndex), Int32(limit))
                },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        hits.append(Self.readChunkHit(stmt))
                    }
                }
            )
            return hits
        }

        try prepareAndExecute(
            """
            SELECT \(Self.chunkHitColumns)
            FROM chunks c
            JOIN documents d ON d.id = c.document_id
            WHERE c.content LIKE '%' || ?1 || '%' AND d.collection_id IN (\(placeholders))
            ORDER BY d.collection_id, d.rel_path, c.chunk_index LIMIT ?\(limitIndex)
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: trimmed)
                for (offset, id) in collectionIds.enumerated() {
                    Self.bindText(stmt, index: Int32(offset + 2), value: id)
                }
                sqlite3_bind_int(stmt, Int32(limitIndex), Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    hits.append(Self.readChunkHit(stmt))
                }
            }
        )
        return hits
    }

    /// Load chunks by their (collectionId, relPath, chunkIndex) composite
    /// keys — the vector search result mapping path.
    public func loadChunksByCompositeKeys(
        _ keys: [(collectionId: String, relPath: String, chunkIndex: Int)]
    ) throws -> [KnowledgeChunkHit] {
        guard !keys.isEmpty else { return [] }
        var hits: [KnowledgeChunkHit] = []
        for key in keys {
            try prepareAndExecute(
                """
                SELECT \(Self.chunkHitColumns)
                FROM chunks c
                JOIN documents d ON d.id = c.document_id
                WHERE d.collection_id = ?1 AND d.rel_path = ?2 AND c.chunk_index = ?3
                LIMIT 1
                """,
                bind: { stmt in
                    Self.bindText(stmt, index: 1, value: key.collectionId)
                    Self.bindText(stmt, index: 2, value: key.relPath)
                    sqlite3_bind_int(stmt, 3, Int32(key.chunkIndex))
                },
                process: { stmt in
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        hits.append(Self.readChunkHit(stmt))
                    }
                }
            )
        }
        return hits
    }

    /// Every chunk of a collection (or all collections when nil), for
    /// vector index rebuilds.
    public func allChunks(collectionId: String? = nil, limit: Int = 50000) throws -> [KnowledgeChunkHit] {
        var hits: [KnowledgeChunkHit] = []
        var sql = """
            SELECT \(Self.chunkHitColumns)
            FROM chunks c
            JOIN documents d ON d.id = c.document_id
            """
        if collectionId != nil { sql += " WHERE d.collection_id = ?1" }
        sql += " ORDER BY d.collection_id, d.rel_path, c.chunk_index LIMIT ?\(collectionId != nil ? 2 : 1)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let collectionId { Self.bindText(stmt, index: 1, value: collectionId) }
                sqlite3_bind_int(stmt, Int32(collectionId != nil ? 2 : 1), Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    hits.append(Self.readChunkHit(stmt))
                }
            }
        )
        return hits
    }

    // MARK: - Curation: tickets

    /// File a staleness ticket. Returns the new row id.
    public func createTicket(
        collectionId: String,
        relPath: String,
        reason: String,
        evidence: String,
        createdBy: String
    ) throws -> Int {
        var ticketId = 0
        let now = Self.iso8601Now()
        try prepareAndExecute(
            """
            INSERT INTO tickets (collection_id, rel_path, reason, evidence, status, created_by, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, 'open', ?5, ?6, ?6)
            RETURNING id
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: collectionId)
                Self.bindText(stmt, index: 2, value: relPath)
                Self.bindText(stmt, index: 3, value: reason)
                Self.bindText(stmt, index: 4, value: evidence)
                Self.bindText(stmt, index: 5, value: createdBy)
                Self.bindText(stmt, index: 6, value: now)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    ticketId = Int(sqlite3_column_int64(stmt, 0))
                }
            }
        )
        guard ticketId != 0 else {
            throw KnowledgeDatabaseError.failedToExecute("createTicket returned no id")
        }
        return ticketId
    }

    /// The open ticket for a document, if any — used to dedupe repeat flags.
    public func openTicket(collectionId: String, relPath: String) throws -> KnowledgeTicket? {
        var ticket: KnowledgeTicket?
        try prepareAndExecute(
            """
            SELECT \(Self.ticketColumns) FROM tickets
            WHERE collection_id = ?1 AND rel_path = ?2 AND status = 'open'
            ORDER BY id DESC LIMIT 1
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: collectionId)
                Self.bindText(stmt, index: 2, value: relPath)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    ticket = Self.readTicket(stmt)
                }
            }
        )
        return ticket
    }

    public func getTicket(id: Int) throws -> KnowledgeTicket? {
        var ticket: KnowledgeTicket?
        try prepareAndExecute(
            "SELECT \(Self.ticketColumns) FROM tickets WHERE id = ?1 LIMIT 1",
            bind: { stmt in sqlite3_bind_int64(stmt, 1, Int64(id)) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    ticket = Self.readTicket(stmt)
                }
            }
        )
        return ticket
    }

    /// List tickets in the supplied collections, optionally by status.
    /// Newest first. Empty `collectionIds` returns nothing (scoped callers)
    /// — pass nil for the unscoped UI listing.
    public func listTickets(
        collectionIds: [String]?,
        status: KnowledgeTicketStatus? = nil,
        limit: Int = 100
    ) throws -> [KnowledgeTicket] {
        if let collectionIds, collectionIds.isEmpty { return [] }
        var tickets: [KnowledgeTicket] = []
        var sql = "SELECT \(Self.ticketColumns) FROM tickets"
        var clauses: [String] = []
        var nextIndex = 1
        var idsRange: Range<Int>?
        var statusIndex: Int?
        if let collectionIds {
            clauses.append(
                "collection_id IN (\(Self.inPlaceholders(count: collectionIds.count, startingAt: nextIndex)))"
            )
            idsRange = nextIndex ..< (nextIndex + collectionIds.count)
            nextIndex += collectionIds.count
        }
        if status != nil {
            clauses.append("status = ?\(nextIndex)")
            statusIndex = nextIndex
            nextIndex += 1
        }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY id DESC LIMIT ?\(nextIndex)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let collectionIds, let idsRange {
                    for (offset, id) in collectionIds.enumerated() {
                        Self.bindText(stmt, index: Int32(idsRange.lowerBound + offset), value: id)
                    }
                }
                if let statusIndex, let status {
                    Self.bindText(stmt, index: Int32(statusIndex), value: status.rawValue)
                }
                sqlite3_bind_int(stmt, Int32(nextIndex), Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    tickets.append(Self.readTicket(stmt))
                }
            }
        )
        return tickets
    }

    public func updateTicketStatus(id: Int, status: KnowledgeTicketStatus) throws {
        try prepareAndExecute(
            "UPDATE tickets SET status = ?1, updated_at = ?2 WHERE id = ?3",
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: status.rawValue)
                Self.bindText(stmt, index: 2, value: Self.iso8601Now())
                sqlite3_bind_int64(stmt, 3, Int64(id))
            },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
    }

    // MARK: - Curation: proposals

    /// Store a curator-drafted replacement. Returns the new row id.
    public func createProposal(
        ticketId: Int?,
        collectionId: String,
        relPath: String,
        newContent: String,
        rationale: String,
        createdBy: String
    ) throws -> Int {
        var proposalId = 0
        let now = Self.iso8601Now()
        try prepareAndExecute(
            """
            INSERT INTO proposals (ticket_id, collection_id, rel_path, new_content, rationale, status, created_by, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, 'pending', ?6, ?7, ?7)
            RETURNING id
            """,
            bind: { stmt in
                if let ticketId {
                    sqlite3_bind_int64(stmt, 1, Int64(ticketId))
                } else {
                    sqlite3_bind_null(stmt, 1)
                }
                Self.bindText(stmt, index: 2, value: collectionId)
                Self.bindText(stmt, index: 3, value: relPath)
                Self.bindText(stmt, index: 4, value: newContent)
                Self.bindText(stmt, index: 5, value: rationale)
                Self.bindText(stmt, index: 6, value: createdBy)
                Self.bindText(stmt, index: 7, value: now)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    proposalId = Int(sqlite3_column_int64(stmt, 0))
                }
            }
        )
        guard proposalId != 0 else {
            throw KnowledgeDatabaseError.failedToExecute("createProposal returned no id")
        }
        return proposalId
    }

    public func getProposal(id: Int) throws -> KnowledgeProposal? {
        var proposal: KnowledgeProposal?
        try prepareAndExecute(
            "SELECT \(Self.proposalColumns) FROM proposals WHERE id = ?1 LIMIT 1",
            bind: { stmt in sqlite3_bind_int64(stmt, 1, Int64(id)) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    proposal = Self.readProposal(stmt)
                }
            }
        )
        return proposal
    }

    /// List proposals (all collections — review is a human, unscoped
    /// surface), optionally by status. Newest first.
    public func listProposals(
        status: KnowledgeProposalStatus? = nil,
        limit: Int = 100
    ) throws -> [KnowledgeProposal] {
        var proposals: [KnowledgeProposal] = []
        var sql = "SELECT \(Self.proposalColumns) FROM proposals"
        if status != nil { sql += " WHERE status = ?1" }
        sql += " ORDER BY id DESC LIMIT ?\(status != nil ? 2 : 1)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let status { Self.bindText(stmt, index: 1, value: status.rawValue) }
                sqlite3_bind_int(stmt, Int32(status != nil ? 2 : 1), Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    proposals.append(Self.readProposal(stmt))
                }
            }
        )
        return proposals
    }

    /// Cheap pending-proposal count for the sidebar badge (avoids
    /// loading full proposal contents via `listProposals`).
    public func pendingProposalCount() throws -> Int {
        var count = 0
        try prepareAndExecute(
            "SELECT COUNT(*) FROM proposals WHERE status = 'pending'",
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return count
    }

    public func updateProposalStatus(id: Int, status: KnowledgeProposalStatus) throws {
        try prepareAndExecute(
            "UPDATE proposals SET status = ?1, updated_at = ?2 WHERE id = ?3",
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: status.rawValue)
                Self.bindText(stmt, index: 2, value: Self.iso8601Now())
                sqlite3_bind_int64(stmt, 3, Int64(id))
            },
            process: { stmt in _ = sqlite3_step(stmt) }
        )
    }

    // MARK: - Row readers

    private static let documentColumns =
        "id, collection_id, rel_path, title, doc_type, summary, tags_csv, content_hash, size_bytes, modified_at, indexed_at"

    private static func readDocument(_ stmt: OpaquePointer) -> KnowledgeDocument {
        KnowledgeDocument(
            id: Int(sqlite3_column_int64(stmt, 0)),
            collectionId: columnText(stmt, 1),
            relPath: columnText(stmt, 2),
            title: columnText(stmt, 3),
            docType: columnText(stmt, 4),
            summary: columnText(stmt, 5),
            tagsCSV: columnText(stmt, 6),
            contentHash: columnText(stmt, 7),
            sizeBytes: Int(sqlite3_column_int(stmt, 8)),
            modifiedAt: columnText(stmt, 9),
            indexedAt: columnText(stmt, 10)
        )
    }

    private static let ticketColumns =
        "id, collection_id, rel_path, reason, evidence, status, created_by, created_at, updated_at"

    private static func readTicket(_ stmt: OpaquePointer) -> KnowledgeTicket {
        KnowledgeTicket(
            id: Int(sqlite3_column_int64(stmt, 0)),
            collectionId: columnText(stmt, 1),
            relPath: columnText(stmt, 2),
            reason: columnText(stmt, 3),
            evidence: columnText(stmt, 4),
            status: KnowledgeTicketStatus(rawValue: columnText(stmt, 5)) ?? .open,
            createdBy: columnText(stmt, 6),
            createdAt: columnText(stmt, 7),
            updatedAt: columnText(stmt, 8)
        )
    }

    private static let proposalColumns =
        "id, ticket_id, collection_id, rel_path, new_content, rationale, status, created_by, created_at, updated_at"

    private static func readProposal(_ stmt: OpaquePointer) -> KnowledgeProposal {
        KnowledgeProposal(
            id: Int(sqlite3_column_int64(stmt, 0)),
            ticketId: sqlite3_column_type(stmt, 1) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(stmt, 1)),
            collectionId: columnText(stmt, 2),
            relPath: columnText(stmt, 3),
            newContent: columnText(stmt, 4),
            rationale: columnText(stmt, 5),
            status: KnowledgeProposalStatus(rawValue: columnText(stmt, 6)) ?? .pending,
            createdBy: columnText(stmt, 7),
            createdAt: columnText(stmt, 8),
            updatedAt: columnText(stmt, 9)
        )
    }

    private static let chunkHitColumns =
        "c.document_id, c.chunk_index, c.heading_path, c.content, d.collection_id, d.rel_path, d.title, d.doc_type, d.tags_csv"

    private static func readChunkHit(_ stmt: OpaquePointer) -> KnowledgeChunkHit {
        KnowledgeChunkHit(
            documentId: Int(sqlite3_column_int64(stmt, 0)),
            chunkIndex: Int(sqlite3_column_int(stmt, 1)),
            headingPath: columnText(stmt, 2),
            content: columnText(stmt, 3),
            collectionId: columnText(stmt, 4),
            relPath: columnText(stmt, 5),
            title: columnText(stmt, 6),
            docType: columnText(stmt, 7),
            tagsCSV: columnText(stmt, 8)
        )
    }

    // MARK: - Query execution

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw KnowledgeDatabaseError.notOpen }
        try Self.execRaw(on: connection, sql)
    }

    private static func execRaw(on connection: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw KnowledgeDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw KnowledgeDatabaseError.notOpen }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            throw KnowledgeDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        try handler(statement)
    }

    private func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        try queue.sync {
            guard let connection = db else { throw KnowledgeDatabaseError.notOpen }
            try Self.prepareAndExecute(on: connection, sql, bind: bind, process: process)
        }
    }

    private static func prepareAndExecute(
        on connection: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            throw KnowledgeDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        try process(statement)
    }

    /// `?N` placeholder list for an IN clause, e.g. `?2, ?3, ?4`.
    private static func inPlaceholders(count: Int, startingAt first: Int) -> String {
        (0 ..< count).map { "?\(first + $0)" }.joined(separator: ", ")
    }

    /// Sanitize a free-text query for FTS5 MATCH: strip everything that
    /// isn't alphanumeric, then quote each term so embedded SQL operators
    /// are treated as literal tokens.
    ///
    /// Terms are combined with `OR` and prefix-matched (`"term"*`), not
    /// joined by whitespace. Whitespace in FTS5 is an implicit AND, which
    /// forces every word of a natural-language query into a single chunk —
    /// so a multi-word question almost never matches heading-split docs.
    /// OR keeps recall (BM25 still ranks chunks matching more terms first),
    /// and the prefix aligns singular/plural forms under the non-stemming
    /// `unicode61` tokenizer (`customer` matches `customers`).
    static func ftsMatchQuery(_ raw: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let scrubbed = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        let words =
            scrubbed
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }
}

// MARK: - SQLite Helpers

/// SQLITE_TRANSIENT tells SQLite to make its own copy of the string data immediately.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension KnowledgeDatabase {
    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}
