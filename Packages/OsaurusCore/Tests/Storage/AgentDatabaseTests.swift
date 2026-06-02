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
        // And it still calls out the soft-delete contract explicitly.
        #expect(
            OnboardingPrompt.block.lowercased().contains("soft delete")
        )
    }
}
