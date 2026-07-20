//
//  DatabaseToolsTests.swift
//  osaurusTests
//
//  Path resolution, export, and tool-surface tests for Agent DB file tools.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct DatabaseToolsTests {

    @MainActor
    private func withHostFolder<T>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-db-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Folder ownership is per chat session now: the resolver reads the
        // executing scope's root from the TaskLocal, so bind it here the way
        // the send path does instead of registering a global folder.
        return try await ChatExecutionContext.$currentFolderRoot.withValue(root) {
            try await body(root)
        }
    }

    @Test
    @MainActor
    func pathResolverReadsFromHostWorkingFolder() async throws {
        try await withHostFolder { root in
            let file = root.appendingPathComponent("data.csv")
            try "a,b\n1,2\n".write(to: file, atomically: true, encoding: .utf8)

            let agentId = UUID()
            let result = await ChatExecutionContext.$currentAgentId.withValue(agentId) {
                await DatabaseFilePathResolver.resolveForRead(path: "data.csv", tool: "db_import")
            }
            guard case .resolved(let resolved) = result else {
                Issue.record("expected success, got \(result)")
                return
            }
            #expect(resolved.scope == .hostFolder)
            #expect(resolved.url.path == file.path)
        }
    }

    @Test
    func pathResolverReadsFromSandboxAgentDir() async throws {
        let agentName = "test-agent-\(UUID().uuidString.prefix(8))"
        let agentDir = OsaurusPaths.containerAgentDir(agentName)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: agentDir) }

        let file = agentDir.appendingPathComponent("output.csv")
        try "x\n1\n".write(to: file, atomically: true, encoding: .utf8)

        let agentId = UUID()
        let result = await ChatExecutionContext.$sandboxAgentName.withValue(agentName) {
            await ChatExecutionContext.$currentAgentId.withValue(agentId) {
                await DatabaseFilePathResolver.resolveForRead(path: "output.csv", tool: "db_import")
            }
        }
        guard case .resolved(let resolved) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resolved.scope == .sandbox)
        #expect(resolved.url.path == file.path)
    }

    @Test
    func pathResolverUnavailableWhenNoRoot() async {
        // The whole test bundle runs suites in parallel, and sibling suites
        // may leave a folder context registered in the process-global
        // `FolderToolManager` (or an active sandbox agent context). The
        // durable invariant is that resolution FAILS when the file exists
        // nowhere — the exact envelope ("unavailable" vs "No file at")
        // depends on whether a root happened to be visible.
        let result = await DatabaseFilePathResolver.resolveForRead(
            path: "missing.csv",
            tool: "db_import"
        )
        guard case .failed(let envelope) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(
            envelope.contains("unavailable") || envelope.contains("db_insert")
                || envelope.contains("missing.csv")
        )
    }

    @Test
    @MainActor
    func dbExecutePathModeRunsSqlScript() async throws {
        try await withHostFolder { root in
            let script = root.appendingPathComponent("seed.sql")
            try """
            CREATE TABLE IF NOT EXISTS seed_test (label TEXT);
            INSERT INTO seed_test (label) VALUES ('from-file');
            """.write(to: script, atomically: true, encoding: .utf8)

            let agentId = UUID()
            let db = AgentDatabase(agentId: agentId)
            try db.openInMemory()
            defer { db.close() }

            let read = await DatabaseFilePathResolver.loadTextScript(path: "seed.sql", tool: "db_execute")
            guard case .text(let sql) = read else {
                Issue.record("path resolve/read failed")
                return
            }
            _ = try db.execute(sql: sql, actor: .agent, runId: nil)
            let count = try db.query(sql: "SELECT COUNT(*) FROM seed_test")
            #expect(count.rows[0][0] == .integer(1))
        }
    }

    @Test
    @MainActor
    func dbExecutePathModeRejectsForbiddenScript() async throws {
        try await withHostFolder { root in
            let script = root.appendingPathComponent("evil.sql")
            try "DROP TABLE notes;".write(to: script, atomically: true, encoding: .utf8)

            let load = await DatabaseFilePathResolver.loadTextScript(path: "evil.sql", tool: "db_execute")
            guard case .text(let sql) = load else {
                Issue.record("expected script load")
                return
            }
            let db = AgentDatabase(agentId: UUID())
            try db.openInMemory()
            defer { db.close() }
            #expect(throws: AgentDatabaseError.self) {
                _ = try db.execute(sql: sql, actor: .agent, runId: nil)
            }
        }
    }

    @Test
    func exportImportCsvRoundTrip() throws {
        let db = AgentDatabase(agentId: UUID())
        try db.openInMemory()
        defer { db.close() }

        try db.createTable(
            name: "items",
            purpose: "export test",
            columns: [AgentColumnSpec(name: "name", type: "TEXT", nullable: false)],
            indexes: [],
            actor: .agent,
            runId: nil
        )
        _ = try db.insert(table: "items", row: ["name": .text("alpha")], actor: .agent, runId: nil)
        _ = try db.insert(table: "items", row: ["name": .text("beta")], actor: .agent, runId: nil)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let probe = try db.query(sql: "SELECT name FROM items ORDER BY id")
        let exported = try DatabaseExport.streamWrite(
            url: tempURL,
            format: .csv,
            maxBytes: DatabaseImport.maxBytes,
            headerColumns: probe.columns
        ) { emit in
            _ = try db.forEachQueryRow(sql: "SELECT name FROM items ORDER BY id") { columns, row in
                try emit(columns, row)
            }
        }
        #expect(exported.rowsExported == 2)
        #expect(!exported.truncated)

        let parsed = try AgentImportRunner.parse(
            url: tempURL,
            explicitFormat: "csv",
            hasHeader: true,
            explicitColumns: nil,
            maxRows: nil
        )
        #expect(parsed.rows.count == 2)
    }

    @Test
    func validateReadOnlyQueryRejectsInsert() {
        #expect(throws: AgentDatabaseError.self) {
            try AgentDatabase.validateReadOnlyQuery("INSERT INTO t VALUES (1)")
        }
    }

    // MARK: - Tool contract pins (import mode + saved-view routing)

    @Test
    func dbImportModeSchemaPinsEnum() {
        // The published JSON schema must constrain `mode` so schema-strict
        // models can't invent values like `append` in the first place.
        let tool = DBImportTool()
        guard case .object(let root)? = tool.parameters,
            case .object(let props) = root["properties"],
            case .object(let mode) = props["mode"],
            case .array(let allowed) = mode["enum"]
        else {
            Issue.record("db_import.mode is missing an enum in its schema")
            return
        }
        #expect(allowed == [.string("insert"), .string("upsert")])
    }

    @Test
    func dbImportRejectsAppendModeAtRuntime() async throws {
        // Regression for the transcript failure: `mode: "append"` must be
        // rejected as invalid_args (with the canonical values named) before
        // any file I/O happens. `insert` is the append.
        let tool = DBImportTool()
        let envelope = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await tool.execute(
                argumentsJSON: #"{"table": "t", "path": "data.csv", "mode": "append"}"#
            )
        }
        #expect(envelope.contains("invalid_args"))
        #expect(envelope.contains("insert | upsert"))
    }

    @Test
    func savedViewRoutingIsPinnedInToolDescriptions() {
        // Saved views are stored definitions, not SQL tables. The strict
        // contract lives in the tool descriptions the model reads: db_query
        // must point at db_run_view, and db_run_view must state it is the
        // only execution path.
        #expect(DBQueryTool().description.contains("db_run_view"))
        let runView = DBRunViewTool().description
        #expect(runView.contains("stored definitions"))
        #expect(runView.contains("db_query"))
    }

    @Test
    func exportOverwriteGuard() async throws {
        // Pin the resolver to a sandbox root via the TaskLocal (checked
        // before any process-global state), so parallel sibling suites
        // can't redirect the write candidate mid-test.
        let agentName = "test-agent-\(UUID().uuidString.prefix(8))"
        let agentDir = OsaurusPaths.containerAgentDir(agentName)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: agentDir) }

        let dest = agentDir.appendingPathComponent("out.csv")
        try "old\n".write(to: dest, atomically: true, encoding: .utf8)

        let result = await ChatExecutionContext.$sandboxAgentName.withValue(agentName) {
            await DatabaseFilePathResolver.resolveForWrite(
                path: "out.csv",
                tool: "db_export",
                overwrite: false
            )
        }
        guard case .failed(let envelope) = result else {
            Issue.record("expected overwrite failure")
            return
        }
        #expect(envelope.contains("overwrite"))

        // Same path with overwrite: true must resolve to the sandbox file.
        let allowed = await ChatExecutionContext.$sandboxAgentName.withValue(agentName) {
            await DatabaseFilePathResolver.resolveForWrite(
                path: "out.csv",
                tool: "db_export",
                overwrite: true
            )
        }
        guard case .resolved(let resolved) = allowed else {
            Issue.record("expected overwrite:true to resolve")
            return
        }
        #expect(resolved.scope == .sandbox)
        #expect(resolved.url.path == dest.path)
    }
}
