//
//  MemoryManagementConsoleService.swift
//  osaurus
//
//  SQL-backed inspection, mutation, and diagnostics for the Memory console.
//  This deliberately bypasses the runtime search APIs because the console
//  must be able to show disabled rows while runtime recall must not.
//

import Foundation
import OsaurusSQLCipher

public enum MemoryPrivacyRedactor {
    private struct Pattern {
        let name: String
        let replacement: String
        let regex: NSRegularExpression
    }

    private static func compile(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid memory redaction regex: \(pattern)")
        }
    }

    private static let patterns: [Pattern] = [
        Pattern(
            name: "email",
            replacement: "[redacted email]",
            regex: compile(
                #"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#,
                options: [.caseInsensitive]
            )
        ),
        Pattern(
            name: "url",
            replacement: "[redacted url]",
            regex: compile(
                #"\bhttps?://[^\s<>()]+"#,
                options: [.caseInsensitive]
            )
        ),
        Pattern(
            name: "secret",
            replacement: "[redacted secret]",
            regex: compile(
                #"\b(?:sk|pk|rk|ghp|gho|ghu|ghs|github_pat|hf|xoxb|xoxp)[A-Za-z0-9_\-]{16,}\b|\b[A-Fa-f0-9]{32,}\b"#,
                options: []
            )
        ),
        Pattern(
            name: "ssn",
            replacement: "[redacted ssn]",
            regex: compile(#"\b\d{3}-\d{2}-\d{4}\b"#)
        ),
        Pattern(
            name: "account",
            replacement: "[redacted account]",
            regex: compile(#"\b(?:\d[ -]?){13,19}\b"#)
        ),
        Pattern(
            name: "phone",
            replacement: "[redacted phone]",
            regex: compile(#"\b(?:\+?1[\s.\-]?)?(?:\(?\d{3}\)?[\s.\-]?)\d{3}[\s.\-]?\d{4}\b"#)
        ),
    ]

    public static func redact(_ text: String, maxCharacters: Int = 600) -> MemoryRedactionResult {
        let originalCount = text.count
        var redacted = text
        var counts: [String: Int] = [:]

        for pattern in patterns {
            let nsRange = NSRange(redacted.startIndex..., in: redacted)
            let matches = pattern.regex.matches(in: redacted, range: nsRange)
            guard !matches.isEmpty else { continue }
            counts[pattern.name, default: 0] += matches.count
            redacted = pattern.regex.stringByReplacingMatches(
                in: redacted,
                range: nsRange,
                withTemplate: pattern.replacement
            )
        }

        let boundedLimit = max(0, maxCharacters)
        let wasTruncated = redacted.count > boundedLimit
        if wasTruncated {
            let suffix = "..."
            if boundedLimit <= suffix.count {
                redacted = String(suffix.prefix(boundedLimit))
            } else {
                redacted = String(redacted.prefix(boundedLimit - suffix.count)) + suffix
            }
        }

        return MemoryRedactionResult(
            text: redacted,
            redactionCounts: counts,
            originalCharacterCount: originalCount,
            displayedCharacterCount: redacted.count,
            wasTruncated: wasTruncated
        )
    }
}

public struct MemoryManagementConsoleService: Sendable {
    public init() {}

    public func snapshot(
        query: MemoryConsoleQuery,
        db: MemoryDatabase = .shared,
        includeVectorState: Bool = true
    ) async throws -> MemoryConsoleSnapshot {
        // The Memory tab opens the shared database lazily from its own load
        // task, and the console can race ahead of it (e.g. when the Memories
        // tab is the first thing rendered). `open()` is idempotent and
        // serialized, so opening here is safe and avoids surfacing a
        // "database is not open" error for what is really a startup ordering
        // issue. A genuine open failure still flows through `diagnoseStorage`
        // as an `unavailable` health state rather than a thrown error.
        if !db.isOpen {
            try? db.open()
        }
        let items = try search(query: query, db: db)
        let health = await diagnoseStorage(db: db, includeVectorState: includeVectorState)
        return MemoryConsoleSnapshot(query: query, items: items, health: health)
    }

    public func search(
        query: MemoryConsoleQuery,
        db: MemoryDatabase = .shared
    ) throws -> [MemoryConsoleItem] {
        let normalized = MemoryConsoleQuery(
            text: query.text,
            scope: query.scope,
            agentId: query.agentId,
            includeDisabled: query.includeDisabled,
            limit: query.limit
        )
        let terms = Self.searchTerms(normalized.trimmedText)
        var items: [MemoryConsoleItem] = []

        if normalized.scope == .all || normalized.scope == .pinned {
            items.append(contentsOf: try loadPinnedItems(query: normalized, terms: terms, db: db))
        }
        if normalized.scope == .all || normalized.scope == .episodes {
            items.append(contentsOf: try loadEpisodeItems(query: normalized, terms: terms, db: db))
        }
        if normalized.scope == .all || normalized.scope == .transcript {
            items.append(contentsOf: try loadTranscriptItems(query: normalized, terms: terms, db: db))
        }

        return Array(
            items.sorted(by: Self.sortConsoleItems).prefix(normalized.limit)
        )
    }

    public func disable(
        itemId: String,
        db: MemoryDatabase = .shared
    ) async throws -> MemoryConsoleMutationResult {
        let parsed = try Self.parseItemId(itemId)
        switch parsed.kind {
        case .pinnedFact:
            let agentId = try agentIdForPinnedFact(id: parsed.storageId, db: db)
            let changed = try updateStatus(
                table: "pinned_facts",
                idColumn: "id",
                id: parsed.storageId,
                status: "disabled",
                db: db
            )
            if changed {
                await MemorySearchService.shared.removeDocument(id: parsed.storageId, agentId: agentId)
                await MemoryContextAssembler.shared.invalidateCache(agentId: agentId)
            }
            return MemoryConsoleMutationResult(
                itemId: itemId,
                mutation: .disable,
                changed: changed,
                message: changed ? L("Pinned fact disabled.") : L("Pinned fact was not found.")
            )

        case .episode:
            guard let episodeId = Int(parsed.storageId) else {
                throw MemoryDatabaseError.failedToExecute("Invalid episode id: \(parsed.storageId)")
            }
            let agentId = try agentIdForEpisode(id: episodeId, db: db)
            let changed = try updateStatus(
                table: "episodes",
                idColumn: "id",
                id: parsed.storageId,
                status: "disabled",
                db: db
            )
            if changed {
                let vectorId = TextSimilarity.deterministicUUID(from: "episode:\(episodeId)").uuidString
                await MemorySearchService.shared.removeDocument(id: vectorId, agentId: agentId)
                await MemoryContextAssembler.shared.invalidateCache(agentId: agentId)
            }
            return MemoryConsoleMutationResult(
                itemId: itemId,
                mutation: .disable,
                changed: changed,
                message: changed ? L("Episode disabled.") : L("Episode was not found.")
            )

        case .transcriptTurn:
            return MemoryConsoleMutationResult(
                itemId: itemId,
                mutation: .disable,
                changed: false,
                message: L("Transcript turns do not have a disabled state. Use Forget to remove the row.")
            )
        }
    }

    public func forget(
        itemId: String,
        db: MemoryDatabase = .shared
    ) async throws -> MemoryConsoleMutationResult {
        let parsed = try Self.parseItemId(itemId)
        switch parsed.kind {
        case .pinnedFact:
            let agentId = try agentIdForPinnedFact(id: parsed.storageId, db: db)
            guard agentId != nil else {
                return MemoryConsoleMutationResult(
                    itemId: itemId,
                    mutation: .forget,
                    changed: false,
                    message: L("Pinned fact was not found.")
                )
            }
            try db.deletePinnedFact(id: parsed.storageId)
            await MemorySearchService.shared.removeDocument(id: parsed.storageId, agentId: agentId)
            await MemoryContextAssembler.shared.invalidateCache(agentId: agentId)
            return MemoryConsoleMutationResult(
                itemId: itemId,
                mutation: .forget,
                changed: true,
                message: L("Pinned fact forgotten.")
            )

        case .episode:
            guard let episodeId = Int(parsed.storageId) else {
                throw MemoryDatabaseError.failedToExecute("Invalid episode id: \(parsed.storageId)")
            }
            let agentId = try agentIdForEpisode(id: episodeId, db: db)
            guard agentId != nil else {
                return MemoryConsoleMutationResult(
                    itemId: itemId,
                    mutation: .forget,
                    changed: false,
                    message: L("Episode was not found.")
                )
            }
            try db.deleteEpisode(id: episodeId)
            let vectorId = TextSimilarity.deterministicUUID(from: "episode:\(episodeId)").uuidString
            await MemorySearchService.shared.removeDocument(id: vectorId, agentId: agentId)
            await MemoryContextAssembler.shared.invalidateCache(agentId: agentId)
            return MemoryConsoleMutationResult(
                itemId: itemId,
                mutation: .forget,
                changed: true,
                message: L("Episode forgotten.")
            )

        case .transcriptTurn:
            guard let transcriptId = Int(parsed.storageId) else {
                throw MemoryDatabaseError.failedToExecute("Invalid transcript id: \(parsed.storageId)")
            }
            let row = try transcriptVectorKey(id: transcriptId, db: db)
            let changed = try deleteTranscriptTurn(id: transcriptId, db: db)
            if let row, changed {
                let vectorId =
                    TextSimilarity
                    .deterministicUUID(from: "transcript:\(row.conversationId):\(row.chunkIndex)")
                    .uuidString
                await MemorySearchService.shared.removeDocument(id: vectorId, agentId: row.agentId)
                await MemoryContextAssembler.shared.invalidateCache(agentId: row.agentId)
            }
            return MemoryConsoleMutationResult(
                itemId: itemId,
                mutation: .forget,
                changed: changed,
                message: changed ? L("Transcript turn forgotten.") : L("Transcript turn was not found.")
            )
        }
    }

    public func contextPreview(
        agentId: String,
        query: String,
        maxTokens: Int,
        config: MemoryConfiguration = MemoryConfigurationStore.load()
    ) async -> MemoryContextPreview {
        var previewConfig = config.validated()
        previewConfig.memoryBudgetTokens = max(100, min(maxTokens, 4000))
        let assembled = await MemoryContextAssembler.assembleContext(
            agentId: agentId,
            config: previewConfig,
            query: query
        )
        let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxChars = max(1, maxTokens) * MemoryConfiguration.charsPerToken
        let redacted = MemoryPrivacyRedactor.redact(
            trimmed.isEmpty ? "(No memory context assembled.)" : trimmed,
            maxCharacters: maxChars
        )
        return MemoryContextPreview(
            agentId: agentId,
            query: query,
            maxTokens: maxTokens,
            estimatedTokens: max(1, redacted.text.count / MemoryConfiguration.charsPerToken),
            redactedContext: redacted,
            wasEmpty: trimmed.isEmpty
        )
    }

    public func diagnoseStorage(
        db: MemoryDatabase = .shared,
        includeVectorState: Bool = true
    ) async -> MemoryStorageHealth {
        let databaseOpen = db.isOpen
        let schemaVersion = db.schemaUserVersion()
        let expectedSchemaVersion = MemoryDatabase.expectedSchemaVersion
        let activePinned = (try? statusCount(table: "pinned_facts", status: "active", db: db)) ?? 0
        let disabledPinned = (try? statusCount(table: "pinned_facts", status: "disabled", db: db)) ?? 0
        let activeEpisodes = (try? statusCount(table: "episodes", status: "active", db: db)) ?? 0
        let disabledEpisodes = (try? statusCount(table: "episodes", status: "disabled", db: db)) ?? 0
        let transcriptCount = (try? countRows(table: "transcript", db: db)) ?? 0
        let pendingSignals = (try? db.pendingSignalsSummary()) ?? PendingSignalsSummary()
        let processingStats = (try? db.processingStats()) ?? ProcessingStats()
        let ftsReady = (try? ftsTablesReady(db: db)) ?? false
        let vectorAvailable = includeVectorState ? await MemorySearchService.shared.isVecturaAvailable : false
        let vectorFailures = includeVectorState ? await MemorySearchService.shared.indexFailures() : 0

        var diagnostics: [String] = []
        if !databaseOpen {
            diagnostics.append("Memory database is not open.")
        }
        if schemaVersion != expectedSchemaVersion {
            let actual = schemaVersion.map(String.init) ?? "unknown"
            diagnostics.append("Schema version is \(actual), expected \(expectedSchemaVersion).")
        }
        if !ftsReady {
            diagnostics.append("FTS mirrors are missing or unavailable; text search may fall back to LIKE scans.")
        }
        if vectorFailures > 0 {
            diagnostics.append("Vector index recorded \(vectorFailures) write failure(s); rebuild may be needed.")
        }
        if let lastOpenError = db.lastOpenErrorDescription, !lastOpenError.isEmpty {
            diagnostics.append("Last open error: \(lastOpenError)")
        }
        if pendingSignals.totalSignals > 0 && processingStats.totalCalls == 0 {
            diagnostics.append("Pending signals exist but no processing log rows were written.")
        }

        let level: MemoryStorageHealth.Level
        if !databaseOpen {
            level = .unavailable
        } else if diagnostics.isEmpty {
            level = .healthy
        } else {
            level = .degraded
        }

        return MemoryStorageHealth(
            level: level,
            databaseOpen: databaseOpen,
            schemaVersion: schemaVersion,
            expectedSchemaVersion: expectedSchemaVersion,
            databaseSizeBytes: db.databaseSizeBytes(),
            activePinnedCount: activePinned,
            disabledPinnedCount: disabledPinned,
            activeEpisodeCount: activeEpisodes,
            disabledEpisodeCount: disabledEpisodes,
            transcriptCount: transcriptCount,
            pendingSignals: pendingSignals,
            processingStats: processingStats,
            ftsTablesReady: ftsReady,
            vectorSearchAvailable: vectorAvailable,
            vectorIndexFailures: vectorFailures,
            lastOpenError: db.lastOpenErrorDescription,
            diagnostics: diagnostics
        )
    }

    // MARK: - Loading

    private func loadPinnedItems(
        query: MemoryConsoleQuery,
        terms: [String],
        db: MemoryDatabase
    ) throws -> [MemoryConsoleItem] {
        var sql = """
            SELECT id, agent_id, content, salience, source_count, source_episode_id,
                   last_used, use_count, status, created_at, tags_csv
            FROM pinned_facts
            WHERE 1 = 1
            """
        let (agentClause, agentBindIndex) = Self.agentClause(query.agentId, nextIndex: 1)
        sql += agentClause
        var nextIndex = agentBindIndex
        let statusIndex = nextIndex
        nextIndex += 1
        sql += " AND (?\(statusIndex) = 1 OR status = 'active')"
        let search = Self.searchClause(
            columns: ["content", "tags_csv"],
            terms: terms,
            startingAt: nextIndex
        )
        sql += search.sql
        nextIndex = search.nextIndex
        let limitIndex = nextIndex
        sql += " ORDER BY salience DESC, created_at DESC LIMIT ?\(limitIndex)"

        var items: [MemoryConsoleItem] = []
        try db.prepareAndExecute(
            sql,
            bind: { stmt in
                if let agentId = query.agentId {
                    MemoryDatabase.bindText(stmt, index: 1, value: agentId)
                }
                sqlite3_bind_int(stmt, Int32(statusIndex), query.includeDisabled ? 1 : 0)
                Self.bindTerms(stmt, terms: terms, bindings: search.bindings)
                sqlite3_bind_int(stmt, Int32(limitIndex), Int32(query.limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    items.append(Self.pinnedItem(stmt: stmt, terms: terms))
                }
            }
        )
        return items
    }

    private func loadEpisodeItems(
        query: MemoryConsoleQuery,
        terms: [String],
        db: MemoryDatabase
    ) throws -> [MemoryConsoleItem] {
        var sql = """
            SELECT id, agent_id, conversation_id, summary, topics_csv, entities_csv,
                   decisions, action_items, salience, token_count, model,
                   conversation_at, status, created_at
            FROM episodes
            WHERE 1 = 1
            """
        let (agentClause, agentBindIndex) = Self.agentClause(query.agentId, nextIndex: 1)
        sql += agentClause
        var nextIndex = agentBindIndex
        let statusIndex = nextIndex
        nextIndex += 1
        sql += " AND (?\(statusIndex) = 1 OR status = 'active')"
        let search = Self.searchClause(
            columns: ["summary", "topics_csv", "entities_csv", "decisions", "action_items"],
            terms: terms,
            startingAt: nextIndex
        )
        sql += search.sql
        nextIndex = search.nextIndex
        let limitIndex = nextIndex
        sql += " ORDER BY conversation_at DESC, salience DESC LIMIT ?\(limitIndex)"

        var items: [MemoryConsoleItem] = []
        try db.prepareAndExecute(
            sql,
            bind: { stmt in
                if let agentId = query.agentId {
                    MemoryDatabase.bindText(stmt, index: 1, value: agentId)
                }
                sqlite3_bind_int(stmt, Int32(statusIndex), query.includeDisabled ? 1 : 0)
                Self.bindTerms(stmt, terms: terms, bindings: search.bindings)
                sqlite3_bind_int(stmt, Int32(limitIndex), Int32(query.limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    items.append(Self.episodeItem(stmt: stmt, terms: terms))
                }
            }
        )
        return items
    }

    private func loadTranscriptItems(
        query: MemoryConsoleQuery,
        terms: [String],
        db: MemoryDatabase
    ) throws -> [MemoryConsoleItem] {
        var sql = """
            SELECT id, agent_id, conversation_id, chunk_index, role, content,
                   token_count, title, created_at
            FROM transcript
            WHERE 1 = 1
            """
        let (agentClause, agentBindIndex) = Self.agentClause(query.agentId, nextIndex: 1)
        sql += agentClause
        var nextIndex = agentBindIndex
        let search = Self.searchClause(columns: ["content", "title"], terms: terms, startingAt: nextIndex)
        sql += search.sql
        nextIndex = search.nextIndex
        let limitIndex = nextIndex
        sql += " ORDER BY created_at DESC, chunk_index DESC LIMIT ?\(limitIndex)"

        var items: [MemoryConsoleItem] = []
        try db.prepareAndExecute(
            sql,
            bind: { stmt in
                if let agentId = query.agentId {
                    MemoryDatabase.bindText(stmt, index: 1, value: agentId)
                }
                Self.bindTerms(stmt, terms: terms, bindings: search.bindings)
                sqlite3_bind_int(stmt, Int32(limitIndex), Int32(query.limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    items.append(Self.transcriptItem(stmt: stmt, terms: terms))
                }
            }
        )
        return items
    }

    // MARK: - Row Mapping

    private static func pinnedItem(stmt: OpaquePointer, terms: [String]) -> MemoryConsoleItem {
        let id = columnText(stmt, 0)
        let agentId = columnText(stmt, 1)
        let content = columnText(stmt, 2)
        let tags = splitCSV(columnText(stmt, 10))
        let detail = MemoryPrivacyRedactor.redact(content, maxCharacters: 2_000)
        let preview = MemoryPrivacyRedactor.redact(content, maxCharacters: 260)
        let matched = matchedTerms(terms, in: [content] + tags)
        let salience = sqlite3_column_double(stmt, 3)
        return MemoryConsoleItem(
            id: "pinned:\(id)",
            kind: .pinnedFact,
            storageId: id,
            agentId: agentId,
            title: "Pinned fact",
            preview: preview,
            detail: detail,
            relevanceExplanation: explanation(
                kind: "pinned fact",
                matchedTerms: matched,
                fallback: "Sorted by salience \(Int(salience * 100))% and last use."
            ),
            metadata: MemoryConsoleMetadata(
                salience: salience,
                sourceCount: Int(sqlite3_column_int(stmt, 4)),
                sourceEpisodeId: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5)),
                lastUsed: columnText(stmt, 6),
                useCount: Int(sqlite3_column_int(stmt, 7)),
                status: columnText(stmt, 8),
                createdAt: columnText(stmt, 9),
                tags: tags
            ),
            canDisable: columnText(stmt, 8) == "active"
        )
    }

    private static func episodeItem(stmt: OpaquePointer, terms: [String]) -> MemoryConsoleItem {
        let id = Int(sqlite3_column_int(stmt, 0))
        let agentId = columnText(stmt, 1)
        let summary = columnText(stmt, 3)
        let topics = splitCSV(columnText(stmt, 4))
        let entities = splitCSV(columnText(stmt, 5))
        let decisions = columnText(stmt, 6)
        let actionItems = columnText(stmt, 7)
        let status = columnText(stmt, 12)
        let searchable = [summary, decisions, actionItems] + topics + entities
        let matched = matchedTerms(terms, in: searchable)
        let fullText = [summary, decisions, actionItems].filter { !$0.isEmpty }.joined(separator: "\n")
        let detail = MemoryPrivacyRedactor.redact(fullText, maxCharacters: 2_000)
        let preview = MemoryPrivacyRedactor.redact(summary, maxCharacters: 300)
        return MemoryConsoleItem(
            id: "episode:\(id)",
            kind: .episode,
            storageId: "\(id)",
            agentId: agentId,
            title: episodeTitle(date: columnText(stmt, 11), topics: topics),
            preview: preview,
            detail: detail,
            relevanceExplanation: explanation(
                kind: "episode",
                matchedTerms: matched,
                fallback: "Sorted by conversation date and salience."
            ),
            metadata: MemoryConsoleMetadata(
                salience: sqlite3_column_double(stmt, 8),
                status: status,
                createdAt: columnText(stmt, 13),
                tokenCount: Int(sqlite3_column_int(stmt, 9)),
                conversationAt: columnText(stmt, 11),
                conversationId: columnText(stmt, 2),
                model: columnText(stmt, 10),
                topics: topics,
                entities: entities
            ),
            canDisable: status == "active"
        )
    }

    private static func transcriptItem(stmt: OpaquePointer, terms: [String]) -> MemoryConsoleItem {
        let id = Int(sqlite3_column_int(stmt, 0))
        let agentId = columnText(stmt, 1)
        let conversationId = columnText(stmt, 2)
        let chunkIndex = Int(sqlite3_column_int(stmt, 3))
        let role = columnText(stmt, 4)
        let content = columnText(stmt, 5)
        let title = columnText(stmt, 7)
        let createdAt = columnText(stmt, 8)
        let matched = matchedTerms(terms, in: [content, title])
        let detail = MemoryPrivacyRedactor.redact(content, maxCharacters: 2_000)
        let preview = MemoryPrivacyRedactor.redact(content, maxCharacters: 300)
        return MemoryConsoleItem(
            id: "transcript:\(id)",
            kind: .transcriptTurn,
            storageId: "\(id)",
            agentId: agentId,
            title: title.isEmpty ? "\(role.capitalized) turn" : title,
            preview: preview,
            detail: detail,
            relevanceExplanation: explanation(
                kind: "transcript turn",
                matchedTerms: matched,
                fallback: "Sorted by latest transcript activity."
            ),
            metadata: MemoryConsoleMetadata(
                createdAt: createdAt,
                tokenCount: Int(sqlite3_column_int(stmt, 6)),
                conversationId: conversationId,
                conversationTitle: title.isEmpty ? nil : title,
                chunkIndex: chunkIndex,
                role: role
            ),
            canDisable: false
        )
    }

    // MARK: - Mutations

    private func updateStatus(
        table: String,
        idColumn: String,
        id: String,
        status: String,
        db: MemoryDatabase
    ) throws -> Bool {
        var changed = false
        try db.prepareAndExecute(
            "UPDATE \(table) SET status = ?1 WHERE \(idColumn) = ?2 AND status != ?1",
            bind: { stmt in
                MemoryDatabase.bindText(stmt, index: 1, value: status)
                if let intId = Int(id) {
                    sqlite3_bind_int(stmt, 2, Int32(intId))
                } else {
                    MemoryDatabase.bindText(stmt, index: 2, value: id)
                }
            },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw MemoryDatabaseError.failedToExecute("UPDATE \(table) failed with code \(step)")
                }
                changed = sqlite3_changes(sqlite3_db_handle(stmt)) > 0
            }
        )
        return changed
    }

    private func deleteTranscriptTurn(id: Int, db: MemoryDatabase) throws -> Bool {
        var changed = false
        try db.prepareAndExecute(
            "DELETE FROM transcript WHERE id = ?1",
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(id)) },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw MemoryDatabaseError.failedToExecute("DELETE transcript failed with code \(step)")
                }
                changed = sqlite3_changes(sqlite3_db_handle(stmt)) > 0
            }
        )
        return changed
    }

    private func agentIdForPinnedFact(id: String, db: MemoryDatabase) throws -> String? {
        try singleText(
            "SELECT agent_id FROM pinned_facts WHERE id = ?1",
            db: db,
            bind: { stmt in MemoryDatabase.bindText(stmt, index: 1, value: id) }
        )
    }

    private func agentIdForEpisode(id: Int, db: MemoryDatabase) throws -> String? {
        try singleText(
            "SELECT agent_id FROM episodes WHERE id = ?1",
            db: db,
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(id)) }
        )
    }

    private func transcriptVectorKey(
        id: Int,
        db: MemoryDatabase
    ) throws -> (agentId: String, conversationId: String, chunkIndex: Int)? {
        var row: (agentId: String, conversationId: String, chunkIndex: Int)?
        try db.prepareAndExecute(
            "SELECT agent_id, conversation_id, chunk_index FROM transcript WHERE id = ?1",
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(id)) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    row = (
                        agentId: Self.columnText(stmt, 0),
                        conversationId: Self.columnText(stmt, 1),
                        chunkIndex: Int(sqlite3_column_int(stmt, 2))
                    )
                }
            }
        )
        return row
    }

    // MARK: - Diagnostics

    private func statusCount(table: String, status: String, db: MemoryDatabase) throws -> Int {
        try singleInt(
            "SELECT COUNT(*) FROM \(table) WHERE status = ?1",
            db: db,
            bind: { stmt in MemoryDatabase.bindText(stmt, index: 1, value: status) }
        )
    }

    private func countRows(table: String, db: MemoryDatabase) throws -> Int {
        try singleInt("SELECT COUNT(*) FROM \(table)", db: db, bind: { _ in })
    }

    private func ftsTablesReady(db: MemoryDatabase) throws -> Bool {
        let found = try singleInt(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name IN ('fts_pinned', 'fts_episodes', 'fts_transcript')
            """,
            db: db,
            bind: { _ in }
        )
        return found == 3
    }

    private func singleInt(
        _ sql: String,
        db: MemoryDatabase,
        bind: (OpaquePointer) -> Void
    ) throws -> Int {
        var value = 0
        try db.prepareAndExecute(
            sql,
            bind: bind,
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    value = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return value
    }

    private func singleText(
        _ sql: String,
        db: MemoryDatabase,
        bind: (OpaquePointer) -> Void
    ) throws -> String? {
        var value: String?
        try db.prepareAndExecute(
            sql,
            bind: bind,
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    value = Self.columnText(stmt, 0)
                }
            }
        )
        return value
    }

    // MARK: - Query Helpers

    private static func searchTerms(_ query: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalized = String(
            query.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        )
        let terms =
            normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
        return Array(NSOrderedSet(array: terms).compactMap { $0 as? String })
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
        "i", "in", "is", "it", "me", "my", "of", "on", "or", "the", "to",
        "we", "you", "your",
    ]

    private static func agentClause(_ agentId: String?, nextIndex: Int) -> (String, Int) {
        guard agentId != nil else { return ("", nextIndex) }
        return (" AND agent_id = ?\(nextIndex)", nextIndex + 1)
    }

    private static func searchClause(
        columns: [String],
        terms: [String],
        startingAt: Int
    ) -> (sql: String, bindings: [(index: Int, term: String)], nextIndex: Int) {
        guard !terms.isEmpty else { return ("", [], startingAt) }
        var next = startingAt
        var bindings: [(Int, String)] = []
        let clauses = terms.map { term -> String in
            let termClauses = columns.map { column -> String in
                let index = next
                next += 1
                bindings.append((index, term))
                return "COALESCE(\(column), '') LIKE '%' || ?\(index) || '%'"
            }
            return "(" + termClauses.joined(separator: " OR ") + ")"
        }
        return (" AND " + clauses.joined(separator: " AND "), bindings, next)
    }

    private static func bindTerms(
        _ stmt: OpaquePointer,
        terms: [String],
        bindings: [(index: Int, term: String)]
    ) {
        guard !terms.isEmpty else { return }
        for binding in bindings {
            MemoryDatabase.bindText(stmt, index: Int32(binding.index), value: binding.term)
        }
    }

    private static func matchedTerms(_ terms: [String], in fields: [String]) -> [String] {
        guard !terms.isEmpty else { return [] }
        let searchable = fields.joined(separator: " ").lowercased()
        return terms.filter { searchable.contains($0) }
    }

    private static func explanation(
        kind: String,
        matchedTerms: [String],
        fallback: String
    ) -> String {
        if matchedTerms.isEmpty {
            return "Shown as a recent \(kind). \(fallback)"
        }
        let terms = matchedTerms.prefix(5).joined(separator: ", ")
        return "Matched \(kind) text for: \(terms)."
    }

    private static func sortConsoleItems(_ lhs: MemoryConsoleItem, _ rhs: MemoryConsoleItem) -> Bool {
        let lhsDate = lhs.metadata.conversationAt ?? lhs.metadata.createdAt ?? lhs.metadata.lastUsed ?? ""
        let rhsDate = rhs.metadata.conversationAt ?? rhs.metadata.createdAt ?? rhs.metadata.lastUsed ?? ""
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        let lhsSalience = lhs.metadata.salience ?? 0
        let rhsSalience = rhs.metadata.salience ?? 0
        if lhsSalience != rhsSalience {
            return lhsSalience > rhsSalience
        }
        return lhs.id < rhs.id
    }

    private static func splitCSV(_ csv: String) -> [String] {
        csv.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func episodeTitle(date: String, topics: [String]) -> String {
        let day = date.isEmpty ? "Episode" : String(date.prefix(10))
        guard let topic = topics.first, !topic.isEmpty else { return day }
        return "\(day) - \(topic)"
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: pointer)
    }

    private static func parseItemId(_ itemId: String) throws -> (kind: MemoryConsoleItemKind, storageId: String) {
        let parts = itemId.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else {
            throw MemoryDatabaseError.failedToExecute("Invalid memory console item id: \(itemId)")
        }
        switch parts[0] {
        case "pinned": return (.pinnedFact, parts[1])
        case "episode": return (.episode, parts[1])
        case "transcript": return (.transcriptTurn, parts[1])
        default:
            throw MemoryDatabaseError.failedToExecute("Unknown memory console item kind: \(parts[0])")
        }
    }
}
