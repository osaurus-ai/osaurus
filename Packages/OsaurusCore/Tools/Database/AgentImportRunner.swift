//
//  AgentImportRunner.swift
//  osaurus
//
//  Shared host-side bulk-import pipeline used by BOTH `db_import` (the agent
//  tool, actor=agent) and the Data tab's Import button / drag-drop (actor=
//  user). Schema resolution, table creation, and the bulk load live here so
//  the two surfaces can't drift apart. Reading + parsing is intentionally a
//  separate step so each caller supplies its own file source: the agent tool
//  resolves a path under the bound working folder, while the UI hands over a
//  user-picked `URL`.
//
//  `_changelog` actor stamping is the caller's responsibility via
//  `ChatExecutionContext.$currentRunActor` (the UI wraps `run` in
//  `actor=user`, matching the inline-edit path; the agent tool runs inside
//  the loop where the actor is already `agent`).
//

import Foundation

enum AgentImportRunner {

    /// Summary of a completed import. Mirrors the fields `db_import` reports
    /// back to the model and the Data tab shows the user.
    struct Outcome: Sendable {
        var table: String
        var rowsImported: Int
        var rowsSkipped: Int
        var createdTable: Bool
        var columns: [String]
        var droppedColumns: [String]
        var truncated: Bool
        var sampleErrors: [String]
    }

    /// Insert every parsed row, or upsert on a conflict key set.
    enum Mode: Sendable, Equatable {
        case insert
        case upsert(keyColumns: [String])
    }

    /// Schema-resolution failures that callers translate into their own
    /// surface error (a typed tool envelope, or a UI banner string).
    enum RunError: LocalizedError, Equatable {
        case noMatchingColumns(fileColumns: [String], table: String)
        case tableMissingNoCreate(table: String)
        case missingUpsertKey(key: String)

        var errorDescription: String? {
            switch self {
            case let .noMatchingColumns(fileColumns, table):
                return
                    "None of the file's columns (\(fileColumns.joined(separator: ", "))) "
                    + "match table `\(table)`."
            case let .tableMissingNoCreate(table):
                return "Table `\(table)` does not exist and table creation is disabled."
            case let .missingUpsertKey(key):
                return "Upsert key column `\(key)` is not present in the imported data."
            }
        }
    }

    /// Audit/soft-delete bookkeeping columns the importer never maps to.
    private static let reservedColumns: Set<String> = [
        "_created_at", "_updated_at", "_deleted_at",
    ]

    /// Read + parse a file URL into typed rows. Enforces the import size
    /// guard (`DatabaseImport.maxBytes`) and auto-detects the format from the
    /// extension/content unless `explicitFormat` is given.
    static func parse(
        url: URL,
        explicitFormat: String? = nil,
        hasHeader: Bool = true,
        explicitColumns: [String]? = nil,
        maxRows: Int? = nil
    ) throws -> DatabaseImport.Parsed {
        let data = try Data(contentsOf: url)
        let sample = String(data: data.prefix(8192), encoding: .utf8) ?? ""
        let format = DatabaseImport.detectFormat(
            explicit: explicitFormat,
            path: url.lastPathComponent,
            sample: sample
        )
        return try DatabaseImport.parse(
            data: data,
            format: format,
            hasHeader: hasHeader,
            explicitColumns: explicitColumns,
            maxRows: maxRows
        )
    }

    /// Resolve the destination schema — filter to an existing table's columns,
    /// or create the table from the file's columns — then bulk-load `parsed`.
    static func run(
        agentId: UUID,
        table: String,
        parsed: DatabaseImport.Parsed,
        mode: Mode = .insert,
        createTable: Bool = true,
        typeOverrides: [String: String] = [:],
        sourceLabel: String
    ) throws -> Outcome {
        let schema = try LocalAgentBridge.shared.schema(agentId: agentId)
        let existing = schema.tables.first { $0.name == table }

        let keyColumns: [String]
        if case let .upsert(keys) = mode { keyColumns = keys } else { keyColumns = [] }

        var targetColumns = parsed.columns
        var rows = parsed.rows
        var droppedColumns: [String] = []
        var createdTable = false

        if let existing {
            let allowed = Set(existing.columns.map { $0.name }).subtracting(reservedColumns)
            droppedColumns = parsed.columns.filter { !allowed.contains($0) }
            targetColumns = parsed.columns.filter { allowed.contains($0) }
            guard !targetColumns.isEmpty else {
                throw RunError.noMatchingColumns(fileColumns: parsed.columns, table: table)
            }
            if !droppedColumns.isEmpty {
                rows = parsed.rows.map { row in row.filter { allowed.contains($0.key) } }
            }
        } else {
            guard createTable else {
                throw RunError.tableMissingNoCreate(table: table)
            }
            var specs: [AgentColumnSpec] = []
            for column in parsed.columns {
                let affinity = typeOverrides[column] ?? parsed.inferredTypes[column] ?? "TEXT"
                specs.append(AgentColumnSpec(name: column, type: affinity, nullable: true))
            }
            var indexes: [AgentIndexSpec] = []
            if !keyColumns.isEmpty {
                indexes.append(
                    AgentIndexSpec(name: "\(table)__import_key", columns: keyColumns, unique: true)
                )
            }
            _ = try LocalAgentBridge.shared.createTable(
                agentId: agentId,
                name: table,
                purpose: "Imported from \(sourceLabel)",
                columns: specs,
                indexes: indexes
            )
            createdTable = true
        }

        for key in keyColumns where !targetColumns.contains(key) {
            throw RunError.missingUpsertKey(key: key)
        }

        let result = try LocalAgentBridge.shared.importRows(
            agentId: agentId,
            table: table,
            rows: rows,
            keyColumns: keyColumns,
            columns: targetColumns
        )

        return Outcome(
            table: table,
            rowsImported: result.rowsImported,
            rowsSkipped: parsed.rowsSkipped,
            createdTable: createdTable,
            columns: targetColumns,
            droppedColumns: droppedColumns,
            truncated: parsed.truncated,
            sampleErrors: Array(parsed.errors.prefix(5))
        )
    }
}
