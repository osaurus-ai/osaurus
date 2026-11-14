//
//  DatabaseToolOutputSchemas.swift
//  osaurus
//
//  The `result` shape of each `db_*` and scheduling tool.
//

import Foundation

enum DatabaseToolOutputSchemas {
    private typealias S = ToolOutputSchema

    static let schema = S.object(
        [
            "tables": S.array(S.anyObject("A table: name, purpose, columns, indexes."), "The agent's tables."),
            "views": S.array(S.anyObject("A saved view."), "Saved views."),
        ], required: ["tables"])

    static let migration = S.object(
        [
            "success": S.boolean("True."),
            "migration_id": S.integer("The migration's index."),
            "applied_sql": S.value("The SQL that ran."),
        ])

    static let insert = S.object(
        [
            "id": S.integer("With `row`: the new row's id."),
            "ids": S.array(S.integer("Row id."), "With `rows`: the new rows' ids, in order."),
            "count": S.integer("With `rows`: rows written."),
        ])

    static let rowsAffected = S.object(
        ["rows_affected": S.integer("Rows changed.")], required: ["rows_affected"])

    static let query = S.object(
        [
            "columns": S.array(S.string("Column name."), "Column names, in row order."),
            "rows": S.array(
                S.array(S.value("A cell."), "One row, aligned with `columns`."),
                "Rows as arrays: `rows[i][j]` is the value of `columns[j]`."),
            "truncated": S.boolean("True when more rows exist (page with `offset`)."),
        ], required: ["columns", "rows"])

    static let execute = S.object(
        [
            "rows_affected": S.integer("Rows changed."),
            "warning": S.string("A note about the statement."),
            "select_rows_drained": S.integer("Rows a SELECT produced and dropped."),
        ], required: ["rows_affected"])

    static let `import` = S.object(
        [
            "table": S.string("The table loaded."),
            "rows_imported": S.integer("Rows written."),
            "rows_skipped": S.integer("Rows not written."),
            "created_table": S.boolean("True when the table was created."),
            "columns": S.array(S.string("Column."), "Columns loaded."),
            "truncated": S.boolean("True when `max_rows` stopped it."),
            "source_scope": S.string("Where the file came from."),
            "dropped_columns": S.array(S.string("Column."), "File columns the table lacks."),
            "sample_errors": S.array(S.value("An error."), "Some rows that failed."),
        ], required: ["table", "rows_imported"])

    static let export = S.object(
        [
            "path": S.string("The file written."),
            "format": S.string("`csv`, `json`, …"),
            "rows_exported": S.integer("Rows written."),
            "bytes": S.integer("File size."),
            "truncated": S.boolean("True when the size cap stopped it."),
            "columns": S.array(S.string("Column."), "Columns written."),
            "destination_scope": S.string("Where the file went."),
        ], required: ["path", "rows_exported"])

    private static let viewFields: [String: JSONValue] = [
        "name": S.string("View name."),
        "render_hint": S.string("How the UI plots it."),
        "refresh": S.string("When it refreshes."),
        "pinned": S.boolean("Pinned in the UI."),
        "description": S.string("What it shows."),
    ]

    static let defineView = S.object(viewFields, required: ["name"])

    static let listViews = S.object(
        ["views": S.array(S.object(viewFields, required: ["name"]), "Saved views.")], required: ["views"])

    static let dropView = S.object(
        ["dropped": S.boolean("False when no such view existed."), "name": S.string("View name.")],
        required: ["name"])

    static let scheduleNextRun = S.object(
        [
            "clamped": S.boolean("True when the time was moved."),
            "clamp_reasons": S.array(S.string("Reason."), "Why it moved."),
            "remaining_budget_today": S.integer("Runs left today."),
            "scheduled_at": S.string("When it runs (ISO 8601)."),
            "instructions": S.string("What the run will do."),
            "priority": S.string("Priority."),
            "on_miss": S.string("What happens when the Mac is asleep."),
            "scheduled_by": S.string("Who scheduled it."),
            "context_views": S.array(S.string("View."), "Views the run starts with."),
            "rejected": S.boolean("True when nothing was scheduled."),
        ])

    static let cancelNextRun = S.object(["cancelled": S.value("Whether a run was removed.")])

    static let notify = S.object(["posted": S.boolean("True.")], required: ["posted"])
}

extension DBSchemaTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.schema } }
extension DBCreateTableTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.migration } }
extension DBAlterTableTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.migration } }
extension DBMigrateTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.migration } }
extension DBInsertTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.insert } }
extension DBUpsertTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.insert } }
extension DBUpdateTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.rowsAffected } }
extension DBDeleteTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.rowsAffected } }
extension DBRestoreTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.rowsAffected } }
extension DBQueryTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.query } }
extension DBExecuteTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.execute } }
extension DBImportTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.import } }
extension DBExportTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.export } }
extension DBDefineViewTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.defineView } }
extension DBRunViewTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.query } }
extension DBListViewsTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.listViews } }
extension DBDropViewTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.dropView } }
extension ScheduleNextRunTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.scheduleNextRun } }
extension CancelNextRunTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.cancelNextRun } }
extension NotifyTool { var outputSchema: JSONValue? { DatabaseToolOutputSchemas.notify } }
