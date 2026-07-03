//
//  DatabaseTools.swift
//  osaurus
//
//  The `db_*` tools the agent calls when `Agent.settings.dbEnabled == true`
//  (spec §6.1, §6.2). One tool per typed operation plus the raw `db_execute`
//  escape hatch. All tools delegate to `LocalAgentBridge.shared` so per-agent
//  serialisation, `_changelog` stamping, and migration-file generation happen
//  in one place.
//
//  The agent ID is resolved from `ChatExecutionContext.currentAgentId`. Tool
//  calls outside a chat session (no agent id in context) return an
//  `unavailable` envelope — these tools are gated to opt-in agents only.
//
//  Naming: tool names use underscores (`db_schema`, `db_create_table`) to
//  conform to `ToolRegistry.sanitizeToolName` (which strips `.`). The
//  onboarding prompt block (`OnboardingPrompt.block`) keeps the names in
//  sync with what's registered here.
//

import Foundation

// MARK: - Shared helpers

/// Common helpers for `db_*` tools. Resolves the active agent, parses
/// `AgentSQLValue` arg payloads, and turns thrown `AgentDatabaseError`
/// values into structured failure envelopes.
enum DatabaseToolHelpers {
    /// Resolve the agent id we should operate on, falling back to a
    /// failure envelope when there's no active agent context.
    static func requireAgentId(tool: String) -> ArgumentRequirement<UUID> {
        guard let id = ChatExecutionContext.currentAgentId else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .unavailable,
                    message:
                        "Agent DB tools require an active agent context. "
                        + "This usually means the agent hasn't enabled the database "
                        + "feature, or the call originated outside a chat session.",
                    tool: tool,
                    retryable: false
                )
            )
        }
        return .value(id)
    }

    /// Coerce an arbitrary JSON object dict into a `[column: AgentSQLValue]`
    /// map. Strings, numbers, booleans, nil all round-trip. `NSNumber` is
    /// classified using `objCType` so a JSON integer doesn't become a
    /// double accidentally.
    static func toSQLValues(_ raw: [String: Any]) -> [String: AgentSQLValue] {
        var out: [String: AgentSQLValue] = [:]
        out.reserveCapacity(raw.count)
        for (k, v) in raw {
            out[k] = toSQLValue(v)
        }
        return out
    }

    static func toSQLValue(_ value: Any) -> AgentSQLValue {
        if value is NSNull { return .null }
        if let n = value as? NSNumber {
            // CFBoolean is also NSNumber — disambiguate by ObjC type.
            let type = String(cString: n.objCType)
            if type == "c" || type == "B" { return .bool(n.boolValue) }
            if Double(n.int64Value) == n.doubleValue {
                return .integer(n.int64Value)
            }
            return .double(n.doubleValue)
        }
        if let s = value as? String { return .text(s) }
        if let b = value as? Bool { return .bool(b) }
        if let i = value as? Int { return .integer(Int64(i)) }
        if let d = value as? Double { return .double(d) }
        if let data = value as? Data { return .blob(data) }
        return .text(String(describing: value))
    }

    static func toSQLValueArray(_ value: Any) -> [AgentSQLValue] {
        if let arr = value as? [Any] { return arr.map { toSQLValue($0) } }
        return []
    }

    /// Render an `AgentSQLValue` back into a JSON-serialisable `Any` so
    /// query results survive `ToolEnvelope.success(result:)`.
    static func toJSONAny(_ value: AgentSQLValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .integer(let n): return NSNumber(value: n)
        case .double(let d): return NSNumber(value: d)
        case .text(let s): return s
        case .bool(let b): return NSNumber(value: b)
        case .blob(let data): return data.base64EncodedString()
        }
    }

    /// Map a thrown `AgentDatabaseError` (or anything else) into a
    /// structured failure envelope. `forbidden` / `invalidArgument` /
    /// `tableExists` / `tableNotFound` carry their own envelopes so the
    /// model can self-correct without parsing prose.
    static func envelope(for error: Error, tool: String) -> String {
        if let dbErr = error as? AgentDatabaseError {
            switch dbErr {
            case .forbidden(let m):
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: m,
                    tool: tool,
                    retryable: false
                )
            case .invalidArgument(let m):
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: m,
                    tool: tool
                )
            case .tableExists(let name):
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Table `\(name)` already exists. Call `db_schema` first to "
                        + "decide whether to evolve it via `db_alter_table` instead.",
                    tool: tool,
                    retryable: false
                )
            case .tableNotFound(let name):
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Table `\(name)` does not exist.",
                    tool: tool,
                    retryable: false
                )
            case .notOpen:
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: "Agent database is not open.",
                    tool: tool,
                    retryable: true
                )
            default:
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: dbErr.localizedDescription,
                    tool: tool
                )
            }
        }
        return ToolEnvelope.failure(
            kind: .executionError,
            message: error.localizedDescription,
            tool: tool
        )
    }
}

// MARK: - db_schema

final class DBSchemaTool: OsaurusTool, @unchecked Sendable {
    let name = "db_schema"
    let description =
        "Return the current schema (tables, columns, indexes, views) of your "
        + "private database. The schema snapshot is also auto-injected into "
        + "your system prompt at run-start; call this when you need to "
        + "confirm schema changes you just made."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }
        do {
            let schema = try LocalAgentBridge.shared.schema(agentId: agentId)
            // Canonical encoder: the schema becomes the tool-result content
            // the model sees on its next turn, so byte-stable output
            // protects prompt-prefix caches (see `JSONDeterminism.swift`).
            let data = try JSONEncoder.osaurusCanonical().encode(schema)
            // `ToolEnvelope.success(result:)` accepts `Any` and re-encodes,
            // so route the Codable schema through a plain Foundation object.
            let json = try JSONSerialization.jsonObject(with: data)
            return ToolEnvelope.success(tool: name, result: json)
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_create_table

final class DBCreateTableTool: OsaurusTool, @unchecked Sendable {
    let name = "db_create_table"
    let description =
        "Create a new table in your private database. `purpose` is required "
        + "and surfaced to the user — make it a clear, single-sentence "
        + "description of what the table is for. Host-managed columns "
        + "(`_created_at`, `_updated_at`, `_deleted_at`) are added "
        + "automatically; do not redeclare them. An `id INTEGER PRIMARY KEY` "
        + "is added too unless you declare your own `id` column or mark a "
        + "column `primary_key` — a declared `id` becomes the primary key "
        + "with the type you give it. Call `db_schema` first to confirm "
        + "there isn't already a table with this name."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("Table name. ASCII letters/digits/_, ≤ 128 chars."),
            ]),
            "purpose": .object([
                "type": .string("string"),
                "description": .string(
                    "Why this table exists, in one sentence. Surfaced to the user."
                ),
            ]),
            "columns": .object([
                "type": .string("array"),
                "description": .string(
                    "Column definitions. Each item: `{name, type, nullable?, "
                        + "default?, primary_key?}`."
                ),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "type": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Column type affinity. One of TEXT, INTEGER, REAL, BLOB, NUMERIC."
                            ),
                        ]),
                        "nullable": .object([
                            "type": .string("boolean"),
                            "description": .string("Default true."),
                        ]),
                        "default": .object([
                            "type": .string("string"),
                            "description": .string(
                                "SQL literal used as the default, e.g. `0`, `''`, `current_timestamp`."
                            ),
                        ]),
                        "primary_key": .object([
                            "type": .string("boolean"),
                            "description": .string("Default false."),
                        ]),
                    ]),
                    "required": .array([.string("name"), .string("type")]),
                ]),
            ]),
            "indexes": .object([
                "type": .string("array"),
                "description": .string("Optional. Indexes to create alongside the table."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "columns": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                        ]),
                        "unique": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("name"), .string("columns")]),
                ]),
            ]),
        ]),
        "required": .array([.string("name"), .string("purpose"), .string("columns")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let nameReq = requireString(args, "name", expected: "table name", tool: name)
        guard case .value(let tableName) = nameReq else { return nameReq.failureEnvelope ?? "" }
        let purposeReq = requireString(
            args,
            "purpose",
            expected: "single-sentence description of what this table is for",
            tool: name
        )
        guard case .value(let purpose) = purposeReq else { return purposeReq.failureEnvelope ?? "" }

        guard let columnsRaw = args["columns"] as? [[String: Any]] else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Missing required argument `columns` (array of column specs).",
                field: "columns",
                expected: "array of {name, type, nullable?, default?, primary_key?}",
                tool: name
            )
        }
        var columns: [AgentColumnSpec] = []
        for col in columnsRaw {
            guard let cName = col["name"] as? String, let cType = col["type"] as? String else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Each column needs `name` and `type`.",
                    tool: name
                )
            }
            columns.append(
                AgentColumnSpec(
                    name: cName,
                    type: cType,
                    nullable: (col["nullable"] as? Bool) ?? true,
                    defaultValue: col["default"] as? String,
                    primaryKey: (col["primary_key"] as? Bool) ?? false
                )
            )
        }

        var indexes: [AgentIndexSpec] = []
        if let idxRaw = args["indexes"] as? [[String: Any]] {
            for idx in idxRaw {
                guard let iName = idx["name"] as? String,
                    let iCols = idx["columns"] as? [String]
                else { continue }
                indexes.append(
                    AgentIndexSpec(
                        name: iName,
                        columns: iCols,
                        unique: (idx["unique"] as? Bool) ?? false
                    )
                )
            }
        }

        do {
            let result = try LocalAgentBridge.shared.createTable(
                agentId: agentId,
                name: tableName,
                purpose: purpose,
                columns: columns,
                indexes: indexes
            )
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "success": true,
                    "migration_id": result.migrationIndex,
                    "applied_sql": result.appliedSQL,
                ]
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_alter_table

final class DBAlterTableTool: OsaurusTool, @unchecked Sendable {
    let name = "db_alter_table"
    let description =
        "Evolve an existing table. Phase 1 supports `add_column` only — to "
        + "rename or drop columns, use `db_migrate` with the explicit "
        + "rebuild SQL. Every change writes a reversible migration to the "
        + "agent's migrations directory."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("Existing table name."),
            ]),
            "add_columns": .object([
                "type": .string("array"),
                "description": .string("Columns to add. Same shape as `db_create_table.columns`."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "type": .object(["type": .string("string")]),
                        "nullable": .object(["type": .string("boolean")]),
                        "default": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("name"), .string("type")]),
                ]),
            ]),
        ]),
        "required": .array([.string("name"), .string("add_columns")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let nameReq = requireString(args, "name", expected: "existing table name", tool: name)
        guard case .value(let tableName) = nameReq else { return nameReq.failureEnvelope ?? "" }

        guard let addRaw = args["add_columns"] as? [[String: Any]], !addRaw.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`add_columns` must be a non-empty array.",
                tool: name
            )
        }
        var additions: [AgentColumnSpec] = []
        for col in addRaw {
            guard let cName = col["name"] as? String, let cType = col["type"] as? String else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Each add_column entry needs `name` and `type`.",
                    tool: name
                )
            }
            additions.append(
                AgentColumnSpec(
                    name: cName,
                    type: cType,
                    nullable: (col["nullable"] as? Bool) ?? true,
                    defaultValue: col["default"] as? String,
                    primaryKey: false
                )
            )
        }

        do {
            let result = try LocalAgentBridge.shared.alterTableAddColumns(
                agentId: agentId,
                name: tableName,
                additions: additions
            )
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "success": true,
                    "migration_id": result.migrationIndex,
                    "applied_sql": result.appliedSQL,
                ]
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_migrate

final class DBMigrateTool: OsaurusTool, @unchecked Sendable {
    let name = "db_migrate"
    let description =
        "Run a raw SQL migration as a reversible pair. Use only for cases "
        + "the typed surface (`db_create_table`, `db_alter_table`) can't "
        + "express, like composite indexes, triggers, or virtual tables. "
        + "Provide both `up_sql` and `down_sql`; both run inside a "
        + "transaction (down is NOT executed here — it's persisted for a "
        + "future rollback). DROP TABLE, TRUNCATE, and unconstrained "
        + "DELETE are rejected."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "up_sql": .object([
                "type": .string("string"),
                "description": .string("SQL to apply now."),
            ]),
            "down_sql": .object([
                "type": .string("string"),
                "description": .string("SQL that reverses `up_sql`. Use `-- no-op` if not invertible."),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("Short description used for the migration filename."),
            ]),
        ]),
        "required": .array([.string("up_sql"), .string("down_sql"), .string("description")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let upReq = requireString(args, "up_sql", expected: "SQL to apply", tool: name)
        guard case .value(let upSQL) = upReq else { return upReq.failureEnvelope ?? "" }
        let downReq = requireString(args, "down_sql", expected: "SQL that reverses up_sql", tool: name)
        guard case .value(let downSQL) = downReq else { return downReq.failureEnvelope ?? "" }
        let descReq = requireString(args, "description", expected: "short description", tool: name)
        guard case .value(let desc) = descReq else { return descReq.failureEnvelope ?? "" }

        do {
            let result = try LocalAgentBridge.shared.runMigration(
                agentId: agentId,
                upSQL: upSQL,
                downSQL: downSQL,
                description: desc
            )
            return ToolEnvelope.success(
                tool: name,
                result: ["success": true, "migration_id": result.migrationIndex]
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_insert

final class DBInsertTool: OsaurusTool, @unchecked Sendable {
    let name = "db_insert"
    let description =
        "Insert row(s) into a table. Pass `row` for a single row, or `rows` "
        + "(an array of objects) to insert many in one call — prefer `rows` "
        + "for batches so you don't spend a tool call per row. For data that "
        + "already lives in a file, use `db_import` instead. Host-managed "
        + "columns (`_created_at`, `_updated_at`, `_deleted_at`) are filled "
        + "in automatically — do not include them. An auto-added integer "
        + "`id` fills itself too; include `id` only when the table declares "
        + "its own `id` column."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "table": .object(["type": .string("string")]),
            "row": .object([
                "type": .string("object"),
                "description": .string(
                    "A single row: column → value map. Strings / numbers / "
                        + "booleans / null only."
                ),
                "additionalProperties": .bool(true),
            ]),
            "rows": .object([
                "type": .string("array"),
                "description": .string(
                    "Many rows in one call. Each item is a column → value map. "
                        + "Use this instead of repeated `db_insert` for batches."
                ),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(true),
                ]),
            ]),
        ]),
        "required": .array([.string("table")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let tableReq = requireString(args, "table", expected: "table name", tool: name)
        guard case .value(let table) = tableReq else { return tableReq.failureEnvelope ?? "" }

        do {
            if let rowsAny = args["rows"] {
                guard let rowsRaw = rowsAny as? [[String: Any]], !rowsRaw.isEmpty else {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "`rows` must be a non-empty array of objects.",
                        field: "rows",
                        tool: name
                    )
                }
                let mapped = rowsRaw.map { DatabaseToolHelpers.toSQLValues($0) }
                let result = try LocalAgentBridge.shared.insertMany(
                    agentId: agentId,
                    table: table,
                    rows: mapped
                )
                return ToolEnvelope.success(
                    tool: name,
                    result: [
                        "ids": result.rowIDs.map { NSNumber(value: $0) },
                        "count": result.count,
                    ]
                )
            }

            guard let rowRaw = args["row"] as? [String: Any] else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Provide `row` (a single object) or `rows` (an array of objects).",
                    field: "row",
                    tool: name
                )
            }
            let result = try LocalAgentBridge.shared.insert(
                agentId: agentId,
                table: table,
                row: DatabaseToolHelpers.toSQLValues(rowRaw)
            )
            return ToolEnvelope.success(
                tool: name,
                result: ["id": NSNumber(value: result.rowID)]
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_upsert

final class DBUpsertTool: OsaurusTool, @unchecked Sendable {
    let name = "db_upsert"
    let description =
        "Insert row(s), or update the existing row when one conflicts on "
        + "`key_columns`. Pass `row` for a single row or `rows` for a batch. "
        + "The conflict columns must have a UNIQUE or PRIMARY KEY constraint. "
        + "For file-backed data, use `db_import` with `mode=upsert` instead."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "table": .object(["type": .string("string")]),
            "key_columns": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Columns to conflict on. Must be UNIQUE or PRIMARY KEY."),
            ]),
            "row": .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
            ]),
            "rows": .object([
                "type": .string("array"),
                "description": .string("Many rows in one call. Each item is a column → value map."),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(true),
                ]),
            ]),
        ]),
        "required": .array([.string("table"), .string("key_columns")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let tableReq = requireString(args, "table", expected: "table name", tool: name)
        guard case .value(let table) = tableReq else { return tableReq.failureEnvelope ?? "" }

        let keyReq = requireStringArray(
            args,
            "key_columns",
            expected: "non-empty array of column names",
            tool: name
        )
        guard case .value(let keyColumns) = keyReq else { return keyReq.failureEnvelope ?? "" }

        do {
            if let rowsAny = args["rows"] {
                guard let rowsRaw = rowsAny as? [[String: Any]], !rowsRaw.isEmpty else {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "`rows` must be a non-empty array of objects.",
                        field: "rows",
                        tool: name
                    )
                }
                let mapped = rowsRaw.map { DatabaseToolHelpers.toSQLValues($0) }
                let result = try LocalAgentBridge.shared.upsertMany(
                    agentId: agentId,
                    table: table,
                    keyColumns: keyColumns,
                    rows: mapped
                )
                return ToolEnvelope.success(
                    tool: name,
                    result: ["count": result.rowsAffected]
                )
            }

            guard let rowRaw = args["row"] as? [String: Any] else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Provide `row` (a single object) or `rows` (an array of objects).",
                    field: "row",
                    tool: name
                )
            }
            let result = try LocalAgentBridge.shared.upsert(
                agentId: agentId,
                table: table,
                keyColumns: keyColumns,
                row: DatabaseToolHelpers.toSQLValues(rowRaw)
            )
            return ToolEnvelope.success(
                tool: name,
                result: ["id": NSNumber(value: result.rowID)]
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_update

final class DBUpdateTool: OsaurusTool, @unchecked Sendable {
    let name = "db_update"
    let description =
        "Update rows matched by `where`. `_updated_at` is refreshed "
        + "automatically. By default soft-deleted rows are skipped — pass "
        + "`include_deleted=true` to update them too (rare)."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "table": .object(["type": .string("string")]),
            "set": .object([
                "type": .string("object"),
                "description": .string("Column → new value map."),
                "additionalProperties": .bool(true),
            ]),
            "where": .object([
                "type": .string("object"),
                "description": .string("Column → value equality predicate. ANDed together."),
                "additionalProperties": .bool(true),
            ]),
            "include_deleted": .object([
                "type": .string("boolean"),
                "description": .string("Default false."),
            ]),
        ]),
        "required": .array([.string("table"), .string("set"), .string("where")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let tableReq = requireString(args, "table", expected: "table name", tool: name)
        guard case .value(let table) = tableReq else { return tableReq.failureEnvelope ?? "" }

        guard let setRaw = args["set"] as? [String: Any], !setRaw.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`set` must be a non-empty JSON object.",
                tool: name
            )
        }
        guard let whereRaw = args["where"] as? [String: Any] else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`where` must be a JSON object.",
                tool: name
            )
        }

        let includeDeleted = (args["include_deleted"] as? Bool) ?? false
        do {
            let result = try LocalAgentBridge.shared.update(
                agentId: agentId,
                table: table,
                set: DatabaseToolHelpers.toSQLValues(setRaw),
                whereClause: DatabaseToolHelpers.toSQLValues(whereRaw),
                includeDeleted: includeDeleted
            )
            return ToolEnvelope.success(
                tool: name,
                result: ["rows_affected": result.rowsAffected]
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_delete (soft)

final class DBDeleteTool: OsaurusTool, @unchecked Sendable {
    let name = "db_delete"
    let description =
        "Soft-delete rows matched by `where`. Sets `_deleted_at` to now. "
        + "Recoverable via `db_restore`. Do not hard-delete from agent "
        + "code — if the user explicitly asks to wipe data, use "
        + "`db_execute` so the audit trail flags it."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "table": .object(["type": .string("string")]),
            "where": .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
            ]),
        ]),
        "required": .array([.string("table"), .string("where")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let tableReq = requireString(args, "table", expected: "table name", tool: name)
        guard case .value(let table) = tableReq else { return tableReq.failureEnvelope ?? "" }
        guard let whereRaw = args["where"] as? [String: Any], !whereRaw.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`where` must be a non-empty JSON object. Soft-deleting every "
                    + "row of a table is rarely intended — pass an explicit predicate.",
                tool: name
            )
        }

        do {
            let result = try LocalAgentBridge.shared.softDelete(
                agentId: agentId,
                table: table,
                whereClause: DatabaseToolHelpers.toSQLValues(whereRaw)
            )
            return ToolEnvelope.success(
                tool: name,
                result: ["rows_affected": result.rowsAffected]
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_restore

final class DBRestoreTool: OsaurusTool, @unchecked Sendable {
    let name = "db_restore"
    let description =
        "Un-soft-delete rows matched by `where` (sets `_deleted_at = NULL`)."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "table": .object(["type": .string("string")]),
            "where": .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
            ]),
        ]),
        "required": .array([.string("table"), .string("where")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let tableReq = requireString(args, "table", expected: "table name", tool: name)
        guard case .value(let table) = tableReq else { return tableReq.failureEnvelope ?? "" }
        guard let whereRaw = args["where"] as? [String: Any], !whereRaw.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`where` must be a non-empty JSON object.",
                tool: name
            )
        }

        do {
            let result = try LocalAgentBridge.shared.restore(
                agentId: agentId,
                table: table,
                whereClause: DatabaseToolHelpers.toSQLValues(whereRaw)
            )
            return ToolEnvelope.success(
                tool: name,
                result: ["rows_affected": result.rowsAffected]
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_query

final class DBQueryTool: OsaurusTool, @unchecked Sendable {
    let name = "db_query"
    let description =
        "Run a read-only SQL query. Returns up to `limit` rows (default "
        + "1000, hard cap 5000); page through larger results with "
        + "`limit`/`offset`. `truncated` is true when more rows existed. For "
        + "big tables, prefer aggregating in SQL (COUNT/SUM/GROUP BY) over "
        + "returning raw rows. Queries auto-filter `_deleted_at IS NULL` on "
        + "user tables unless you pass `include_deleted=true` in the WHERE."

    /// Soft ceiling on the encoded row payload (chars), kept under the
    /// universal 100K tool-result cap so the model gets a clean
    /// `truncated` + paging hint instead of a hard string cut.
    private static let maxEncodedRowBytes = 80_000

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "sql": .object([
                "type": .string("string"),
                "description": .string(
                    "SELECT statement. May reference `?1`, `?2`, … bound from `params`."
                ),
            ]),
            "params": .object([
                "type": .string("array"),
                "description": .string("Positional bind parameters (optional)."),
                "items": .object(["type": .string("string")]),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string(
                    "Max rows to return (default 1000, hard cap 5000). Pair with `offset` to page."
                ),
            ]),
            "offset": .object([
                "type": .string("integer"),
                "description": .string("Rows to skip before returning (default 0)."),
            ]),
        ]),
        "required": .array([.string("sql")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let sqlReq = requireString(args, "sql", expected: "SELECT statement", tool: name)
        guard case .value(let sql) = sqlReq else { return sqlReq.failureEnvelope ?? "" }

        let params: [AgentSQLValue]
        if let raw = args["params"] {
            params = DatabaseToolHelpers.toSQLValueArray(raw)
        } else {
            params = []
        }
        let limit = coerceInt(args["limit"])
        let offset = coerceInt(args["offset"])

        do {
            let result = try LocalAgentBridge.shared.query(
                agentId: agentId,
                sql: sql,
                params: params,
                limit: limit,
                offset: offset
            )
            var rows: [[Any]] = result.rows.map { row in
                row.map { DatabaseToolHelpers.toJSONAny($0) }
            }

            // Encoded-size guard: trim trailing rows so the payload stays
            // under the soft cap, surfacing a paging hint rather than a hard
            // truncation of the JSON string downstream.
            var sizeTruncated = false
            if let data = try? JSONSerialization.data(withJSONObject: rows),
                data.count > Self.maxEncodedRowBytes, !rows.isEmpty
            {
                let avg = max(1, data.count / rows.count)
                let keep = max(1, (Self.maxEncodedRowBytes * 9 / 10) / avg)
                if keep < rows.count {
                    rows = Array(rows.prefix(keep))
                    sizeTruncated = true
                }
            }

            let truncated = result.truncated || sizeTruncated
            var warnings: [String] = []
            if truncated {
                let nextOffset = (offset ?? 0) + rows.count
                warnings.append(
                    "Result truncated at \(rows.count) rows. Page with `offset: \(nextOffset)`, "
                        + "or aggregate in SQL (COUNT/SUM/GROUP BY) instead of returning raw rows."
                )
            }
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "columns": result.columns,
                    "rows": rows,
                    "truncated": truncated,
                ],
                warnings: warnings.isEmpty ? nil : warnings
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_execute

final class DBExecuteTool: OsaurusTool, @unchecked Sendable {
    let name = "db_execute"
    let description =
        "Run first-class SQL the typed tools can't express — including "
        + "multi-statement transform scripts (`INSERT … SELECT`, CTEs, "
        + "window functions, index/trigger DDL) which run inside one "
        + "transaction. Prefer this over pulling rows into context to "
        + "compute by hand, and use `db_import` for file ingestion. Logged "
        + "with `op='raw'`. Rejected: DROP TABLE, TRUNCATE, DROP DATABASE, "
        + "unconstrained DELETE, ATTACH/DETACH, PRAGMA writes, "
        + "load_extension, and writes to system tables."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "sql": .object([
                "type": .string("string"),
                "description": .string("Statement to execute."),
            ]),
            "params": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
            ]),
        ]),
        "required": .array([.string("sql")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let sqlReq = requireString(args, "sql", expected: "SQL statement", tool: name)
        guard case .value(let sql) = sqlReq else { return sqlReq.failureEnvelope ?? "" }

        let params: [AgentSQLValue]
        if let raw = args["params"] {
            params = DatabaseToolHelpers.toSQLValueArray(raw)
        } else {
            params = []
        }

        do {
            let result = try LocalAgentBridge.shared.execute(
                agentId: agentId,
                sql: sql,
                params: params
            )
            var resultDict: [String: Any] = ["rows_affected": result.rowsAffected]
            if let warning = result.warning {
                resultDict["warning"] = warning
            }
            return ToolEnvelope.success(
                tool: name,
                result: resultDict,
                warnings: result.warning.map { [$0] }
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_import

/// Host-mediated bulk loader. The model points at a file in the working
/// folder; the host resolves the path (same symlink-safe guard as
/// `file_read`), parses CSV/TSV/JSON/JSONL, optionally infers + creates the
/// table, and bulk-inserts via `LocalAgentBridge.importRows` — so a large
/// load costs zero per-row tokens and doesn't burn the tool-call budget.
final class DBImportTool: OsaurusTool, @unchecked Sendable {
    let name = "db_import"
    let description =
        "Bulk-load a file from your working folder straight into a table. "
        + "The host reads and parses it, so no row data passes through your "
        + "tokens and you don't spend a tool call per row — use this instead "
        + "of looping `db_insert` whenever the data already lives in a file. "
        + "Supports CSV, TSV, JSON (array or object), and JSONL/NDJSON; the "
        + "format is auto-detected from the extension/content. Creates the "
        + "table from the file's columns when it doesn't exist (set "
        + "`create_table` false to require an existing one). Returns a small "
        + "summary (counts + columns), never the row data."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "table": .object([
                "type": .string("string"),
                "description": .string("Destination table name."),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Path to the data file, relative to your working folder "
                        + "(e.g. `data/today.csv`)."
                ),
            ]),
            "format": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional override: `csv`, `tsv`, `json`, `jsonl`/`ndjson`. "
                        + "Auto-detected from the extension/content when omitted."
                ),
            ]),
            "mode": .object([
                "type": .string("string"),
                "description": .string(
                    "`insert` (default) or `upsert`. Upsert requires `key_columns`."
                ),
            ]),
            "key_columns": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "For `upsert`: the conflict columns. A UNIQUE index on them "
                        + "is created automatically when this call creates the table."
                ),
            ]),
            "create_table": .object([
                "type": .string("boolean"),
                "description": .string(
                    "Create the table from the file's columns if it's missing. Default true."
                ),
            ]),
            "has_header": .object([
                "type": .string("boolean"),
                "description": .string("CSV/TSV only: first row is a header. Default true."),
            ]),
            "columns": .object([
                "type": .string("array"),
                "description": .string(
                    "Optional ordered column names — each item is a string or "
                        + "`{name, type}`. Required for headerless CSV; the `type` "
                        + "overrides inferred affinity when a table is created."
                ),
                "items": .object(["type": .string("object")]),
            ]),
            "max_rows": .object([
                "type": .string("integer"),
                "description": .string("Optional cap on the number of rows imported."),
            ]),
        ]),
        "required": .array([.string("table"), .string("path")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let tableReq = requireString(args, "table", expected: "destination table name", tool: name)
        guard case .value(let table) = tableReq else { return tableReq.failureEnvelope ?? "" }
        let pathReq = requireString(
            args,
            "path",
            expected: "path under your working folder",
            tool: name
        )
        guard case .value(let path) = pathReq else { return pathReq.failureEnvelope ?? "" }

        let modeRaw = (args["mode"] as? String)?.lowercased() ?? "insert"
        guard modeRaw == "insert" || modeRaw == "upsert" else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`mode` must be `insert` or `upsert`.",
                field: "mode",
                expected: "insert | upsert",
                tool: name
            )
        }
        var keyColumns: [String] = []
        if modeRaw == "upsert" {
            let keyReq = requireStringArray(
                args,
                "key_columns",
                expected: "conflict columns for upsert",
                tool: name
            )
            guard case .value(let keys) = keyReq else { return keyReq.failureEnvelope ?? "" }
            keyColumns = keys
        }

        let createTable = coerceBool(args["create_table"]) ?? true
        let hasHeader = coerceBool(args["has_header"]) ?? true
        let maxRows = coerceInt(args["max_rows"])

        // `columns` override accepts a [String] of names or [{name, type?}].
        var explicitColumnNames: [String]?
        var typeOverrides: [String: String] = [:]
        if let colsAny = args["columns"] {
            if let names = colsAny as? [String], !names.isEmpty {
                explicitColumnNames = names
            } else if let objects = colsAny as? [[String: Any]], !objects.isEmpty {
                var names: [String] = []
                for object in objects {
                    guard let columnName = object["name"] as? String, !columnName.isEmpty else {
                        continue
                    }
                    names.append(columnName)
                    if let type = object["type"] as? String, !type.isEmpty {
                        typeOverrides[columnName] = type
                    }
                }
                if !names.isEmpty { explicitColumnNames = names }
            }
        }

        // Resolve the working-folder root the same way `file_read` does.
        let root: URL? = await MainActor.run {
            FolderToolManager.shared.registeredContext?.rootPath
        }
        guard let rootPath = root else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "db_import reads from your working folder, but no folder is bound to "
                    + "this session. Ask the user to pick a working folder, then retry.",
                tool: name,
                retryable: false
            )
        }

        let fileURL: URL
        do {
            fileURL = try FolderToolHelpers.resolvePath(path, rootPath: rootPath)
        } catch {
            return ToolEnvelope.fromError(error, tool: name)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No file at `\(path)` in the working folder.",
                field: "path",
                tool: name,
                retryable: false
            )
        }
        let parsed: DatabaseImport.Parsed
        do {
            parsed = try AgentImportRunner.parse(
                url: fileURL,
                explicitFormat: args["format"] as? String,
                hasHeader: hasHeader,
                explicitColumns: explicitColumnNames,
                maxRows: maxRows
            )
        } catch {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                tool: name,
                retryable: false
            )
        }

        let mode: AgentImportRunner.Mode =
            (modeRaw == "upsert") ? .upsert(keyColumns: keyColumns) : .insert
        do {
            let outcome = try AgentImportRunner.run(
                agentId: agentId,
                table: table,
                parsed: parsed,
                mode: mode,
                createTable: createTable,
                typeOverrides: typeOverrides,
                sourceLabel: (path as NSString).lastPathComponent
            )

            var resultDict: [String: Any] = [
                "table": outcome.table,
                "rows_imported": outcome.rowsImported,
                "rows_skipped": outcome.rowsSkipped,
                "created_table": outcome.createdTable,
                "columns": outcome.columns,
                "truncated": outcome.truncated,
            ]
            if !outcome.droppedColumns.isEmpty {
                resultDict["dropped_columns"] = outcome.droppedColumns
            }
            if !outcome.sampleErrors.isEmpty { resultDict["sample_errors"] = outcome.sampleErrors }

            var warnings: [String] = []
            if outcome.truncated {
                warnings.append("Import stopped at max_rows; not all rows were loaded.")
            }
            if !outcome.droppedColumns.isEmpty {
                warnings.append(
                    "Ignored columns not on `\(table)`: "
                        + outcome.droppedColumns.joined(separator: ", ") + "."
                )
            }
            return ToolEnvelope.success(
                tool: name,
                result: resultDict,
                warnings: warnings.isEmpty ? nil : warnings
            )
        } catch let error as AgentImportRunner.RunError {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: error.errorDescription ?? "Import failed.",
                tool: name,
                retryable: false
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_define_view

/// Phase 2 saved-view tools (spec §6.3). A saved view is a named
/// SELECT/CTE the agent reuses across runs and the UI surfaces on
/// the Views and Home tabs. Definitions go through
/// `LocalAgentBridge.defineView` so the `_changelog` audit entry is
/// stamped the same way as any other write.
final class DBDefineViewTool: OsaurusTool, @unchecked Sendable {
    let name = "db_define_view"
    let description =
        "Save (or redefine) a named SQL view the user and you can re-run "
        + "later. View bodies must be SELECT or WITH ... SELECT only — "
        + "if you need to write data, use `db_insert` / `db_update`. "
        + "`render_hint` controls how the UI plots the result; use one "
        + "of `table`, `bar`, `line`, `pie`, `number`."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("View name. ASCII letters/digits/_."),
            ]),
            "sql": .object([
                "type": .string("string"),
                "description": .string(
                    "SELECT or WITH-CTE statement. Re-runnable; bind params "
                        + "are not supported on views (Phase 2 limitation)."
                ),
            ]),
            "render_hint": .object([
                "type": .string("string"),
                "description": .string(
                    "Suggested visualization: `table`, `bar`, `line`, `pie`, `number`."
                ),
            ]),
            "refresh": .object([
                "type": .string("string"),
                "description": .string(
                    "Refresh policy: `manual`, `on_run`, or a duration like `5m`."
                ),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("Optional one-liner describing what the view shows."),
            ]),
        ]),
        "required": .array([
            .string("name"), .string("sql"),
            .string("render_hint"), .string("refresh"),
        ]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let viewNameReq = requireString(args, "name", expected: "view name", tool: name)
        guard case .value(let viewName) = viewNameReq else { return viewNameReq.failureEnvelope ?? "" }
        let sqlReq = requireString(args, "sql", expected: "view SQL", tool: name)
        guard case .value(let sql) = sqlReq else { return sqlReq.failureEnvelope ?? "" }
        let hintReq = requireString(args, "render_hint", expected: "render hint", tool: name)
        guard case .value(let hint) = hintReq else { return hintReq.failureEnvelope ?? "" }
        let refreshReq = requireString(args, "refresh", expected: "refresh policy", tool: name)
        guard case .value(let refresh) = refreshReq else { return refreshReq.failureEnvelope ?? "" }
        let descriptionReq = optionalString(
            args,
            "description",
            expected: "view description"
        )
        guard case .value(let description) = descriptionReq else {
            return descriptionReq.failureEnvelope ?? ""
        }

        do {
            let view = try LocalAgentBridge.shared.defineView(
                agentId: agentId,
                name: viewName,
                sql: sql,
                renderHint: hint,
                refresh: refresh,
                description: description
            )
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "name": view.name,
                    "render_hint": view.renderHint,
                    "refresh": view.refresh,
                    "pinned": view.pinned,
                ]
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_run_view

final class DBRunViewTool: OsaurusTool, @unchecked Sendable {
    let name = "db_run_view"
    let description =
        "Run a previously saved view by name. Returns the same shape as "
        + "`db_query`: `{columns, rows, truncated}`. Use `db_list_views` "
        + "to see what's defined."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "name": .object(["type": .string("string")])
        ]),
        "required": .array([.string("name")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let viewNameReq = requireString(args, "name", expected: "view name", tool: name)
        guard case .value(let viewName) = viewNameReq else { return viewNameReq.failureEnvelope ?? "" }

        do {
            let result = try LocalAgentBridge.shared.runView(
                agentId: agentId,
                name: viewName
            )
            let rows: [[Any]] = result.rows.map { row in
                row.map { DatabaseToolHelpers.toJSONAny($0) }
            }
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "columns": result.columns,
                    "rows": rows,
                    "truncated": result.truncated,
                ]
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_list_views

final class DBListViewsTool: OsaurusTool, @unchecked Sendable {
    let name = "db_list_views"
    let description =
        "List every saved view by name with its render hint, refresh "
        + "policy, and pinned state. Use this when you need to decide "
        + "whether a view already exists before defining a new one."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }
        do {
            let views = try LocalAgentBridge.shared.listViews(agentId: agentId)
            let payload: [[String: Any]] = views.map { v in
                var dict: [String: Any] = [
                    "name": v.name,
                    "render_hint": v.renderHint,
                    "refresh": v.refresh,
                    "pinned": v.pinned,
                ]
                if let desc = v.description { dict["description"] = desc }
                return dict
            }
            return ToolEnvelope.success(tool: name, result: ["views": payload])
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - db_drop_view

final class DBDropViewTool: OsaurusTool, @unchecked Sendable {
    let name = "db_drop_view"
    let description =
        "Permanently delete a saved view. The view's audit entry is "
        + "still kept in `_changelog`. Underlying table data is "
        + "untouched."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "name": .object(["type": .string("string")])
        ]),
        "required": .array([.string("name")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let viewNameReq = requireString(args, "name", expected: "view name", tool: name)
        guard case .value(let viewName) = viewNameReq else { return viewNameReq.failureEnvelope ?? "" }

        do {
            let existed = try LocalAgentBridge.shared.dropView(agentId: agentId, name: viewName)
            return ToolEnvelope.success(
                tool: name,
                result: ["dropped": existed, "name": viewName]
            )
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}
