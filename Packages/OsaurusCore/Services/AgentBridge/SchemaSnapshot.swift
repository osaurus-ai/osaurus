//
//  SchemaSnapshot.swift
//  osaurus
//
//  Renders the compact text snapshot of an agent's DB schema that gets
//  injected into the system prompt every run (spec §5.5.5). Kept off
//  the hot inference path: each render runs once per run, before the
//  inference loop begins.
//
//  Discipline (spec §5.5.5):
//   - Hard cap of ~2000 tokens; we approximate "tokens = chars / 4".
//   - When over cap, truncate in this order:
//       1. drop view SQL bodies (keep names + render hints);
//       2. truncate column lists to first 10 + "... N more";
//       3. drop oldest-touched tables last.
//   - Always include all table names + purposes.
//   - Append a trailer when truncated: "Schema is large. Call
//     `db.schema()` for full details on specific tables."
//   - Never include sample data — privacy: cloud models would see
//     row values in every request.
//

import Foundation

public enum SchemaSnapshot {
    /// Approximate character budget. Roughly equivalent to ~2000 tokens
    /// at the 4-chars-per-token rule-of-thumb used elsewhere in the
    /// codebase.
    public static let charBudget: Int = 8000

    /// Render the schema snapshot for `schema`. `now` is plumbed in so
    /// tests can pin the "last write Xh ago" strings.
    public static func render(
        _ schema: AgentDatabaseSchema,
        now: Date = Date()
    ) -> String {
        if schema.tables.isEmpty && schema.views.isEmpty {
            return emptyStateBlock
        }

        // Sort tables most-recently-written first so the "drop oldest"
        // truncation pass strips the right end of the list.
        let orderedTables = schema.tables.sorted { lhs, rhs in
            let lt = lhs.lastWriteAt ?? .distantPast
            let rt = rhs.lastWriteAt ?? .distantPast
            return lt > rt
        }

        // Pass 1 — full detail.
        var truncated = false
        var output = renderFull(tables: orderedTables, views: schema.views, now: now)
        if output.count > charBudget {
            // Pass 2 — drop view SQL.
            output = renderFull(
                tables: orderedTables,
                views: schema.views,
                now: now,
                includeViewSQL: false
            )
            truncated = true
        }
        if output.count > charBudget {
            // Pass 3 — truncate column lists.
            output = renderFull(
                tables: orderedTables,
                views: schema.views,
                now: now,
                includeViewSQL: false,
                maxColumnsPerTable: 10
            )
        }
        if output.count > charBudget {
            // Pass 4 — drop oldest-touched tables.
            var kept = orderedTables
            while output.count > charBudget && kept.count > 1 {
                kept = Array(kept.dropLast())
                output = renderFull(
                    tables: kept,
                    views: schema.views,
                    now: now,
                    includeViewSQL: false,
                    maxColumnsPerTable: 10
                )
            }
        }

        if truncated || output.count > charBudget {
            output += "\n\nSchema is large. Call `db.schema()` for full details on specific tables."
        }
        return output
    }

    /// Block emitted when there are no user tables or views (spec §5.5.5).
    public static let emptyStateBlock: String = """
        ## Current database state

        No tables yet. When the user asks you to track or organize something, propose a schema in chat first, get their confirmation, then call db.create_table().
        """

    // MARK: - Renderer

    private static func renderFull(
        tables: [AgentTableSchema],
        views: [AgentSavedView],
        now: Date,
        includeViewSQL: Bool = true,
        maxColumnsPerTable: Int? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("## Current database state")

        if !tables.isEmpty {
            lines.append("")
            lines.append("Tables:")
            lines.append("")
            for table in tables {
                lines.append("- \(table.name) (purpose: \"\(escapeQuotes(table.purpose))\")")
                let columns =
                    maxColumnsPerTable.map { Array(table.columns.prefix($0)) } ?? table.columns
                for col in columns {
                    var line =
                        "    \(col.name.padding(toLength: max(12, col.name.count + 2), withPad: " ", startingAt: 0))\(col.type)"
                    if col.primaryKey { line += " PRIMARY KEY" }
                    if !col.nullable && !col.primaryKey { line += " NOT NULL" }
                    lines.append(line)
                }
                if let cap = maxColumnsPerTable, table.columns.count > cap {
                    lines.append("    ... \(table.columns.count - cap) more")
                }
                let count = "\(table.rowCount) row\(table.rowCount == 1 ? "" : "s")"
                let touched =
                    table.lastWriteAt.map { "last write \(relative(from: $0, to: now))" }
                    ?? "never written"
                lines.append("  \(count) · \(touched)")
                lines.append("")
            }
        }

        if !views.isEmpty {
            lines.append("Views:")
            lines.append("")
            for view in views {
                lines.append("- \(view.name) (\(view.renderHint), refreshes \(view.refresh))")
                if includeViewSQL {
                    lines.append("    SQL: \(view.sql)")
                }
                lines.append("")
            }
        }

        lines.append("System columns on every user table: _created_at, _updated_at, _deleted_at.")
        lines.append(
            "Queries via db.query() auto-filter `_deleted_at IS NULL` unless you pass include_deleted=true."
        )
        return lines.joined(separator: "\n")
    }

    private static func escapeQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Compact "Xs/Xm/Xh/Xd ago" style relative formatter. Avoids
    /// pulling in `RelativeDateTimeFormatter` so deterministic output
    /// is easy in tests.
    static func relative(from past: Date, to now: Date) -> String {
        let delta = max(0, Int(now.timeIntervalSince(past)))
        if delta < 60 { return "\(delta)s ago" }
        if delta < 3600 { return "\(delta / 60)m ago" }
        if delta < 86400 { return "\(delta / 3600)h ago" }
        return "\(delta / 86400)d ago"
    }
}
