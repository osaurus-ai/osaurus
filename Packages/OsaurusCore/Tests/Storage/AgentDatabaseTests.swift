//
//  AgentDatabaseTests.swift
//  osaurusTests
//
//  Spec §1.4 + §5.5.2 + §5.5.5 round-trip tests for the agent DB
//  layer. These run against an in-memory SQLCipher database so they
//  don't need to coordinate with `StorageMutationGate`.
//
//  Coverage:
//   - `SchemaSnapshot.render` truncates view SQL, then column lists,
//     then drops oldest-touched tables.
//   - `AgentDatabase` auto-stamps `_created_at`, `_updated_at` on
//     insert and switches them on update; `softDelete` populates
//     `_deleted_at` without removing the row.
//   - `_changelog` rows pick up the actor + run id the call site
//     passes, and `OnboardingPrompt` text doesn't drift silently
//     (snapshot-style assertion the spec calls out in §5.5.3).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct AgentDatabaseTests {

    private func makeDB() throws -> AgentDatabase {
        let db = AgentDatabase(agentId: UUID())
        try db.openInMemory()
        return db
    }

    // MARK: - Soft delete defaults

    @Test
    func insertStampsCreatedAndUpdated() throws {
        let db = try makeDB()
        try db.createTable(
            name: "notes",
            purpose: "test rows",
            columns: [
                AgentColumnSpec(name: "title", type: "TEXT", nullable: false)
            ],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        let rowid = try db.insert(
            table: "notes",
            row: ["title": .text("hello")],
            actor: .agent,
            runId: nil
        )
        let result = try db.query(
            sql: "SELECT _created_at, _updated_at, _deleted_at FROM notes WHERE id = ?1",
            params: [.integer(rowid)]
        )
        #expect(result.rows.count == 1)
        let row = result.rows[0]
        if case .integer = row[0] {} else { Issue.record("created_at should be integer") }
        if case .integer = row[1] {} else { Issue.record("updated_at should be integer") }
        if case .null = row[2] {} else { Issue.record("deleted_at should be null on insert") }
    }

    @Test
    func softDeleteStampsDeletedAtButPreservesRow() throws {
        let db = try makeDB()
        try db.createTable(
            name: "notes",
            purpose: "test rows",
            columns: [
                AgentColumnSpec(name: "title", type: "TEXT", nullable: false)
            ],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        let rowid = try db.insert(
            table: "notes",
            row: ["title": .text("delete me")],
            actor: .agent,
            runId: nil
        )
        _ = try db.softDelete(
            table: "notes",
            whereClause: ["id": .integer(rowid)],
            actor: .agent,
            runId: nil
        )
        let live = try db.query(
            sql: "SELECT COUNT(*) FROM notes WHERE _deleted_at IS NULL",
            params: []
        )
        #expect(live.rows[0][0] == .integer(0))
        let tombstoned = try db.query(
            sql: "SELECT COUNT(*) FROM notes WHERE _deleted_at IS NOT NULL",
            params: []
        )
        #expect(tombstoned.rows[0][0] == .integer(1))
    }

    // MARK: - Changelog stamping

    @Test
    func changelogCapturesActorAndRunId() throws {
        let db = try makeDB()
        try db.createTable(
            name: "notes",
            purpose: "test rows",
            columns: [
                AgentColumnSpec(name: "title", type: "TEXT", nullable: false)
            ],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        let runId = UUID()
        _ = try db.insert(
            table: "notes",
            row: ["title": .text("first")],
            actor: .user,
            runId: runId
        )
        let log = try db.query(
            sql:
                "SELECT actor, op, table_name, run_id FROM _changelog "
                + "ORDER BY id DESC LIMIT 1",
            params: []
        )
        #expect(log.rows.count == 1)
        let row = log.rows[0]
        #expect(row[0] == .text("user"))
        #expect(row[1] == .text("insert"))
        #expect(row[2] == .text("notes"))
        #expect(row[3] == .text(runId.uuidString))
    }

    // MARK: - Schema snapshot truncation

    @Test
    func snapshotEmptyStateBlockUsedWhenNoTables() {
        let schema = AgentDatabaseSchema(tables: [], views: [])
        let rendered = SchemaSnapshot.render(schema)
        #expect(rendered == SchemaSnapshot.emptyStateBlock)
    }

    @Test
    func snapshotTruncatesViewSQLFirst() {
        // Big SQL bodies should disappear before column lists do.
        let columns = (0 ..< 3).map { i in
            AgentColumnInfo(
                name: "col_\(i)",
                type: "TEXT",
                nullable: true,
                defaultValue: nil,
                primaryKey: false
            )
        }
        let table = AgentTableSchema(
            name: "t1",
            purpose: "test",
            columns: columns,
            indexes: [],
            rowCount: 0,
            lastWriteAt: nil
        )
        let bigSQL = String(repeating: "SELECT * FROM t1 UNION ALL ", count: 800)
        let view = AgentSavedView(
            name: "v1",
            sql: bigSQL,
            renderHint: "table",
            refresh: "manual",
            description: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let schema = AgentDatabaseSchema(tables: [table], views: [view])
        let rendered = SchemaSnapshot.render(schema)
        // The view name is always kept.
        #expect(rendered.contains("v1"))
        // But the giant SQL body should have been dropped.
        #expect(rendered.contains(bigSQL) == false)
        // Truncation footer appears (or at least the rendered body
        // is within budget). Either signals truncation worked.
        #expect(rendered.count <= SchemaSnapshot.charBudget + 200)
    }

    @Test
    func snapshotDropsOldestTablesWhenStillTooLarge() {
        // Build many tables with lots of columns so even after view
        // SQL drop + column-list truncation we're still over budget.
        func bigColumns() -> [AgentColumnInfo] {
            (0 ..< 40).map { i in
                AgentColumnInfo(
                    name: "really_long_column_name_to_eat_chars_\(i)",
                    type: "TEXT",
                    nullable: true,
                    defaultValue: nil,
                    primaryKey: false
                )
            }
        }
        let now = Date()
        let tables: [AgentTableSchema] = (0 ..< 40).map { i in
            AgentTableSchema(
                name: "table_\(i)",
                purpose: "table purpose \(i)",
                columns: bigColumns(),
                indexes: [],
                rowCount: 10,
                lastWriteAt: now.addingTimeInterval(TimeInterval(-i * 3600))
            )
        }
        let schema = AgentDatabaseSchema(tables: tables, views: [])
        let rendered = SchemaSnapshot.render(schema, now: now)
        // Most recently written table must still be present.
        #expect(rendered.contains("table_0"))
        // Some of the oldest tables must have been dropped.
        let droppedCount = (0 ..< 40).filter { i in
            !rendered.contains("table_\(i)")
        }.count
        #expect(droppedCount > 0)
        #expect(rendered.contains("Schema is large"))
    }

    // MARK: - OnboardingPrompt drift guard

    @Test
    func onboardingPromptVersionIsPositive() {
        #expect(OnboardingPrompt.version >= 1)
        // Block stays anchored to the documented tool names so the
        // prompt and the registered tool ids never drift apart.
        #expect(OnboardingPrompt.block.contains("db_create_table"))
        #expect(OnboardingPrompt.block.contains("db_insert"))
        #expect(OnboardingPrompt.block.contains("db_query"))
        #expect(OnboardingPrompt.block.contains("db_delete"))
        // The bulk-ingestion guidance must be present so the model reaches
        // for db_import instead of looping single-row writes.
        #expect(OnboardingPrompt.block.contains("db_import"))
        // And it still calls out the soft-delete contract explicitly.
        #expect(
            OnboardingPrompt.block.lowercased().contains("soft delete")
        )
    }

    // MARK: - Bulk ingest (importRows / insertMany)

    @Test
    func importRowsInsertModeLoadsEveryRow() throws {
        let db = try makeDB()
        try db.createTable(
            name: "commits",
            purpose: "ingest test",
            columns: [
                AgentColumnSpec(name: "sha", type: "TEXT", nullable: false),
                AgentColumnSpec(name: "additions", type: "INTEGER", nullable: false),
            ],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        let rows: [[String: AgentSQLValue]] = (1 ... 250).map { i in
            ["sha": .text("sha-\(i)"), "additions": .integer(Int64(i))]
        }
        // No keyColumns => append/insert semantics, one host call for 250 rows.
        let written = try db.importRows(table: "commits", rows: rows, actor: .user, runId: nil)
        #expect(written == 250)
        let count = try db.query(sql: "SELECT COUNT(*) FROM commits")
        #expect(count.rows[0][0] == .integer(250))
        let sum = try db.query(sql: "SELECT SUM(additions) FROM commits")
        #expect(sum.rows[0][0] == .integer(Int64((1 ... 250).reduce(0, +))))
    }

    @Test
    func importRowsUpsertModeDedupesOnKeyColumns() throws {
        let db = try makeDB()
        // A unique index on the key column is what makes ON CONFLICT(slug)
        // resolve to an update instead of erroring.
        try db.createTable(
            name: "repos",
            purpose: "upsert test",
            columns: [
                AgentColumnSpec(name: "slug", type: "TEXT", nullable: false),
                AgentColumnSpec(name: "stars", type: "INTEGER", nullable: false),
            ],
            indexes: [AgentIndexSpec(name: "repos_slug_uq", columns: ["slug"], unique: true)],
            actor: .agent,
            runId: nil
        )
        _ = try db.importRows(
            table: "repos",
            rows: [
                ["slug": .text("a"), "stars": .integer(1)],
                ["slug": .text("b"), "stars": .integer(2)],
            ],
            keyColumns: ["slug"],
            actor: .user,
            runId: nil
        )
        _ = try db.importRows(
            table: "repos",
            rows: [
                ["slug": .text("a"), "stars": .integer(10)],  // conflict -> update
                ["slug": .text("c"), "stars": .integer(3)],  // new -> insert
            ],
            keyColumns: ["slug"],
            actor: .user,
            runId: nil
        )
        let count = try db.query(sql: "SELECT COUNT(*) FROM repos")
        #expect(count.rows[0][0] == .integer(3))  // a, b, c — not 4
        let a = try db.query(
            sql: "SELECT stars FROM repos WHERE slug = ?1",
            params: [.text("a")]
        )
        #expect(a.rows[0][0] == .integer(10))  // updated, not duplicated
    }

    @Test
    func insertManyReturnsARowidForEveryRow() throws {
        let db = try makeDB()
        try db.createTable(
            name: "scores",
            purpose: "bulk insert test",
            columns: [
                AgentColumnSpec(name: "player", type: "TEXT", nullable: false),
                AgentColumnSpec(name: "points", type: "INTEGER", nullable: false),
            ],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        let ids = try db.insertMany(
            table: "scores",
            rows: [
                ["player": .text("p1"), "points": .integer(10)],
                ["player": .text("p2"), "points": .integer(20)],
                ["player": .text("p3"), "points": .integer(30)],
            ],
            actor: .agent,
            runId: nil
        )
        #expect(ids.count == 3)
        #expect(Set(ids).count == 3)  // distinct rowids
        let total = try db.query(sql: "SELECT SUM(points) FROM scores")
        #expect(total.rows[0][0] == .integer(60))
    }

    // MARK: - Multi-statement db_execute

    @Test
    func executeRunsEveryStatementInAScript() throws {
        let db = try makeDB()
        let result = try db.execute(
            sql: "CREATE TABLE t (a INTEGER); INSERT INTO t (a) VALUES (1); INSERT INTO t (a) VALUES (2);",
            actor: .agent,
            runId: nil
        )
        // CREATE doesn't move total_changes; two single-row inserts do.
        #expect(result.rowsAffected == 2)
        let count = try db.query(sql: "SELECT COUNT(*) FROM t")
        #expect(count.rows[0][0] == .integer(2))
    }

    @Test
    func executeMultiStatementTransformAggregatesInOneCall() throws {
        let db = try makeDB()
        _ = try db.execute(
            sql: """
                CREATE TABLE raw (day TEXT, amount INTEGER);
                INSERT INTO raw (day, amount) VALUES ('d1', 10), ('d1', 20), ('d2', 5);
                CREATE TABLE totals (day TEXT, total INTEGER);
                INSERT INTO totals (day, total) SELECT day, SUM(amount) FROM raw GROUP BY day;
                """,
            actor: .agent,
            runId: nil
        )
        let top = try db.query(sql: "SELECT day, total FROM totals ORDER BY total DESC")
        #expect(top.rows.count == 2)
        #expect(top.rows[0][0] == .text("d1"))
        #expect(top.rows[0][1] == .integer(30))
    }

    // MARK: - Forbidden SQL guardrails

    @Test
    func forbiddenReasonBlocksDangerousStatements() {
        // Legacy destructive set.
        #expect(AgentDatabase.forbiddenReason(in: "DROP TABLE notes") != nil)
        #expect(AgentDatabase.forbiddenReason(in: "TRUNCATE notes") != nil)
        #expect(AgentDatabase.forbiddenReason(in: "DELETE FROM notes") != nil)  // no WHERE
        // Sandbox escapes.
        #expect(AgentDatabase.forbiddenReason(in: "ATTACH DATABASE 'x.db' AS y") != nil)
        #expect(AgentDatabase.forbiddenReason(in: "DETACH DATABASE y") != nil)
        #expect(AgentDatabase.forbiddenReason(in: "SELECT load_extension('evil')") != nil)
        // Privileged PRAGMA write (flips journal mode / FK enforcement).
        #expect(AgentDatabase.forbiddenReason(in: "PRAGMA journal_mode = WAL") != nil)
        // Tampering with the audit / system tables bypasses the contract.
        #expect(AgentDatabase.forbiddenReason(in: "DELETE FROM _changelog WHERE id = 1") != nil)
        #expect(AgentDatabase.forbiddenReason(in: "INSERT INTO _views (name) VALUES ('x')") != nil)
    }

    @Test
    func forbiddenReasonAllowsReadOnlyAndScopedWrites() {
        #expect(AgentDatabase.forbiddenReason(in: "SELECT 1") == nil)
        #expect(AgentDatabase.forbiddenReason(in: "SELECT * FROM notes WHERE id = 1") == nil)
        // Read-only PRAGMAs (no `=`) stay allowed.
        #expect(AgentDatabase.forbiddenReason(in: "PRAGMA table_info(notes)") == nil)
        // A DELETE *with* a WHERE on a user table is allowed.
        #expect(AgentDatabase.forbiddenReason(in: "DELETE FROM notes WHERE id = 1") == nil)
    }

    @Test
    func executeRejectsForbiddenStatementAndDataSurvives() throws {
        let db = try makeDB()
        try db.createTable(
            name: "keepme",
            purpose: "guardrail test",
            columns: [AgentColumnSpec(name: "label", type: "TEXT", nullable: false)],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        _ = try db.insert(table: "keepme", row: ["label": .text("one")], actor: .agent, runId: nil)
        #expect(throws: AgentDatabaseError.self) {
            _ = try db.execute(sql: "DROP TABLE keepme", actor: .agent, runId: nil)
        }
        let count = try db.query(sql: "SELECT COUNT(*) FROM keepme")
        #expect(count.rows[0][0] == .integer(1))
    }

    // MARK: - Query paging (limit / offset / truncated)

    @Test
    func queryHonorsLimitAndOffsetAndTruncationFlag() throws {
        let db = try makeDB()
        try db.createTable(
            name: "nums",
            purpose: "paging test",
            columns: [AgentColumnSpec(name: "n", type: "INTEGER", nullable: false)],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        let rows: [[String: AgentSQLValue]] = (1 ... 25).map { ["n": .integer(Int64($0))] }
        _ = try db.importRows(table: "nums", rows: rows, actor: .agent, runId: nil)

        // Page 1: rows 1..10, more remain -> truncated.
        let page1 = try db.query(sql: "SELECT n FROM nums ORDER BY n", limit: 10, offset: 0)
        #expect(page1.rows.count == 10)
        #expect(page1.rows.first?[0] == .integer(1))
        #expect(page1.rows.last?[0] == .integer(10))
        #expect(page1.truncated)

        // Last page: offset 20 leaves only 5 rows -> not truncated.
        let page3 = try db.query(sql: "SELECT n FROM nums ORDER BY n", limit: 10, offset: 20)
        #expect(page3.rows.count == 5)
        #expect(page3.rows.first?[0] == .integer(21))
        #expect(page3.rows.last?[0] == .integer(25))
        #expect(page3.truncated == false)
    }

    // MARK: - Typed tools on raw-SQL tables (no host-managed columns)

    // Regression (E4B loop): tables created via `db_execute` CREATE TABLE
    // (or fixture seed SQL) have no `_deleted_at`, and the typed tools used
    // to hard-fail with SQLite's bare "no such column: _deleted_at" on
    // every update/delete/select against them.

    @Test
    func updateWorksOnRawSqlTableWithoutSoftDeleteColumn() throws {
        let db = try makeDB()
        _ = try db.execute(
            sql:
                "CREATE TABLE expenses (id INTEGER PRIMARY KEY, note TEXT, amount INTEGER); "
                + "INSERT INTO expenses (note, amount) VALUES ('lunch', 12);",
            actor: .agent,
            runId: nil
        )
        let changed = try db.update(
            table: "expenses",
            set: ["amount": .integer(15)],
            whereClause: ["note": .text("lunch")],
            actor: .agent,
            runId: nil
        )
        #expect(changed == 1)
        let amount = try db.query(sql: "SELECT amount FROM expenses WHERE note = 'lunch'")
        #expect(amount.rows[0][0] == .integer(15))
    }

    @Test
    func softDeleteOnRawSqlTableThrowsActionableError() throws {
        let db = try makeDB()
        _ = try db.execute(
            sql:
                "CREATE TABLE expenses (id INTEGER PRIMARY KEY, note TEXT); "
                + "INSERT INTO expenses (note) VALUES ('stale');",
            actor: .agent,
            runId: nil
        )
        do {
            _ = try db.softDelete(
                table: "expenses",
                whereClause: ["note": .text("stale")],
                actor: .agent,
                runId: nil
            )
            Issue.record("softDelete should throw on a table without _deleted_at")
        } catch let AgentDatabaseError.invalidArgument(message) {
            // The error must steer the model to the working alternative,
            // not just repeat SQLite's "no such column".
            #expect(message.contains("_deleted_at"))
            #expect(message.contains("db_execute"))
        }
        // The row is untouched.
        let count = try db.query(sql: "SELECT COUNT(*) FROM expenses")
        #expect(count.rows[0][0] == .integer(1))
    }

    @Test
    func restoreOnRawSqlTableThrowsActionableError() throws {
        let db = try makeDB()
        _ = try db.execute(
            sql: "CREATE TABLE plain (id INTEGER PRIMARY KEY, note TEXT);",
            actor: .agent,
            runId: nil
        )
        do {
            _ = try db.restore(
                table: "plain",
                whereClause: ["note": .text("x")],
                actor: .agent,
                runId: nil
            )
            Issue.record("restore should throw on a table without _deleted_at")
        } catch let AgentDatabaseError.invalidArgument(message) {
            #expect(message.contains("_deleted_at"))
        }
    }

    // MARK: - createTable with a model-declared `id` column

    // Regression (E4B loop): declaring an explicit `id` column without
    // `primary_key` used to collide with the auto-added
    // `id INTEGER PRIMARY KEY AUTOINCREMENT` -> "duplicate column name: id".

    @Test
    func createTableWithDeclaredIdColumnPromotesItToPrimaryKey() throws {
        let db = try makeDB()
        try db.createTable(
            name: "tickets",
            purpose: "declared-id regression",
            columns: [
                AgentColumnSpec(name: "id", type: "TEXT", nullable: false),
                AgentColumnSpec(name: "title", type: "TEXT", nullable: false),
            ],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        // Insert with an explicit TEXT id — the declared column, not the
        // auto-added integer one, must be the primary key.
        _ = try db.insert(
            table: "tickets",
            row: ["id": .text("T-1"), "title": .text("first")],
            actor: .agent,
            runId: nil
        )
        let info = try db.query(sql: "PRAGMA table_info(tickets)")
        // Columns: id TEXT pk, title, _created_at, _updated_at, _deleted_at —
        // exactly ONE column named id.
        let idRows = info.rows.filter { $0[1] == .text("id") }
        #expect(idRows.count == 1)
        #expect(idRows.first?[2] == .text("TEXT"))
        // pk flag is the 6th column of table_info output.
        #expect(idRows.first?[5] == .integer(1))
        let row = try db.query(sql: "SELECT title FROM tickets WHERE id = 'T-1'")
        #expect(row.rows.count == 1)
    }

    @Test
    func createTableWithExplicitPrimaryKeyStillWins() throws {
        let db = try makeDB()
        // A non-id primary key declared by the model: no id column is
        // auto-added on top of it, and the declared PK is honored.
        try db.createTable(
            name: "slugs",
            purpose: "explicit pk regression",
            columns: [
                AgentColumnSpec(name: "slug", type: "TEXT", nullable: false, primaryKey: true),
                AgentColumnSpec(name: "label", type: "TEXT", nullable: true),
            ],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        let info = try db.query(sql: "PRAGMA table_info(slugs)")
        let pkRows = info.rows.filter { $0[5] == .integer(1) }
        #expect(pkRows.count == 1)
        #expect(pkRows.first?[1] == .text("slug"))
        #expect(info.rows.contains { $0[1] == .text("id") } == false)
    }
}
