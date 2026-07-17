//
//  AgentDataBrowserModel.swift
//  osaurus
//
//  Paging state machine behind the Database workspace's row browser.
//  The old Data tab issued a single `SELECT … LIMIT 500` and rendered
//  everything eagerly; this model loads pages incrementally (keyset
//  cursor on `_updated_at, id` for managed tables, offset fallback for
//  raw-SQL tables), tracks the true filtered row count, and discards
//  stale async results after the table/filter changes.
//
//  The query runner is injected so tests can drive the model against an
//  in-memory `AgentDatabase` without the bridge singleton.
//

import Foundation

// MARK: - Filter Mode

/// Soft-delete filter modes for the row browser. The spec calls out a
/// "soft-delete view" (§7) — the browser shows live rows by default and
/// an audit-style read-only view of `_deleted_at IS NOT NULL` rows on
/// demand.
enum DataFilterMode: String, CaseIterable, Identifiable {
    case live
    case deleted
    case all

    var id: String { rawValue }

    /// User-facing label. `.live` reads as "Active" since users don't
    /// think of un-deleted rows as "live" — the term came from the
    /// soft-delete SQL pattern and was confusing in the UI.
    var label: String {
        switch self {
        case .live: return L("Active")
        case .deleted: return L("Deleted")
        case .all: return L("All")
        }
    }

    /// One-line description shown in the filter help popover.
    var helpDescription: String {
        switch self {
        case .live: return L("Rows the agent is currently using.")
        case .deleted: return L("Deleted rows the agent can still restore.")
        case .all: return L("Everything in the table, including deleted rows.")
        }
    }
}

// MARK: - Browser Model

@MainActor
final class AgentDataBrowserModel: ObservableObject {

    /// Abstract query runner. Mirrors
    /// `LocalAgentBridge.query(agentId:sql:params:limit:offset:)` so the
    /// live backend is a one-line closure and tests can substitute an
    /// in-memory `AgentDatabase`.
    struct Backend: Sendable {
        var runQuery:
            @Sendable (_ sql: String, _ params: [AgentSQLValue], _ limit: Int?, _ offset: Int?)
                throws -> AgentQueryResult
    }

    static func liveBackend(agentId: UUID) -> Backend {
        Backend { sql, params, limit, offset in
            try LocalAgentBridge.shared.query(
                agentId: agentId,
                sql: sql,
                params: params,
                limit: limit,
                offset: offset
            )
        }
    }

    // MARK: State

    @Published private(set) var columns: [AgentColumnInfo] = []
    @Published private(set) var columnNames: [String] = []
    @Published private(set) var rows: [[AgentSQLValue]] = []
    /// Filtered total from `SELECT COUNT(*)`; `nil` until the count query
    /// lands (or when it failed).
    @Published private(set) var totalCount: Int?
    @Published private(set) var isLoadingFirstPage = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var loadError: String?

    private(set) var tableName: String?
    private(set) var filterMode: DataFilterMode = .live

    var idColumnIndex: Int? { columnNames.firstIndex(of: "id") }
    var deletedColumnIndex: Int? { columnNames.firstIndex(of: "_deleted_at") }

    let pageSize: Int
    private let backend: Backend
    /// Monotonic token bumped on every reset; async page/count results
    /// carry the generation they were issued under and are dropped when
    /// it no longer matches (table/filter changed mid-flight).
    private var generation = 0

    init(backend: Backend, pageSize: Int = 200) {
        self.backend = backend
        self.pageSize = pageSize
    }

    // MARK: Loading

    /// Reset to the given table + filter and load the first page and the
    /// filtered count. `schemaColumns` come from the schema snapshot so
    /// paging can key off `_updated_at` / `id` availability without a
    /// PRAGMA round-trip.
    func load(table: String, schemaColumns: [AgentColumnInfo], filter: DataFilterMode) {
        generation += 1
        tableName = table
        filterMode = filter
        columns = schemaColumns
        columnNames = schemaColumns.map(\.name)
        rows = []
        totalCount = nil
        hasMore = false
        loadError = nil
        isLoadingFirstPage = true
        isLoadingMore = false
        fetchPage(reset: true)
        fetchCount()
    }

    /// Clear all state (no table selected).
    func clear() {
        generation += 1
        tableName = nil
        columns = []
        columnNames = []
        rows = []
        totalCount = nil
        hasMore = false
        loadError = nil
        isLoadingFirstPage = false
        isLoadingMore = false
    }

    /// Reload the first page + count for the current table/filter.
    func refresh() {
        guard let table = tableName else { return }
        load(table: table, schemaColumns: columns, filter: filterMode)
    }

    /// Fetch the next page when the user nears the end of the loaded
    /// window. Single-flight: no-op while any request is running.
    func loadMoreIfNeeded() {
        guard hasMore, !isLoadingMore, !isLoadingFirstPage, tableName != nil else { return }
        isLoadingMore = true
        fetchPage(reset: false)
    }

    // MARK: SQL construction

    /// Whether the current table supports stable keyset paging on
    /// `(_updated_at, id)`. Raw-SQL tables can miss either column.
    private var supportsKeysetPaging: Bool {
        columnNames.contains("_updated_at") && columnNames.contains("id")
    }

    /// Filter clause; empty for tables without a `_deleted_at` marker
    /// (raw-SQL and system tables have nothing to filter on).
    private func filterConditions() -> [String] {
        guard columnNames.contains("_deleted_at") else { return [] }
        switch filterMode {
        case .live: return ["_deleted_at IS NULL"]
        case .deleted: return ["_deleted_at IS NOT NULL"]
        case .all: return []
        }
    }

    /// Page query for the current cursor position. Returns SQL + params +
    /// whether the engine `offset` parameter should be used (fallback
    /// paging only).
    private func pageQuery(afterRow lastRow: [AgentSQLValue]?) -> (
        sql: String, params: [AgentSQLValue], offset: Int?
    ) {
        guard let table = tableName else { return ("", [], nil) }
        var conditions = filterConditions()
        var params: [AgentSQLValue] = []
        let orderSQL: String
        var offset: Int? = nil

        if supportsKeysetPaging {
            orderSQL = "ORDER BY _updated_at DESC, id DESC"
            if let lastRow,
                let updatedIdx = columnNames.firstIndex(of: "_updated_at"),
                let idIdx = columnNames.firstIndex(of: "id"),
                updatedIdx < lastRow.count, idIdx < lastRow.count
            {
                conditions.append("(_updated_at < ?1 OR (_updated_at = ?1 AND id < ?2))")
                params = [lastRow[updatedIdx], lastRow[idIdx]]
            }
        } else {
            // No stable managed columns — page by rowid order + offset.
            orderSQL = "ORDER BY _rowid_ DESC"
            if lastRow != nil { offset = rows.count }
        }

        let whereSQL = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = "SELECT * FROM \"\(table)\" \(whereSQL) \(orderSQL)"
        return (sql, params, offset)
    }

    private func countQuery() -> (sql: String, params: [AgentSQLValue])? {
        guard let table = tableName else { return nil }
        let conditions = filterConditions()
        let whereSQL = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return ("SELECT COUNT(*) FROM \"\(table)\" \(whereSQL)", [])
    }

    // MARK: Fetch plumbing

    private func fetchPage(reset: Bool) {
        let gen = generation
        let lastRow = reset ? nil : rows.last
        let (sql, params, offset) = pageQuery(afterRow: lastRow)
        guard !sql.isEmpty else { return }
        let backend = backend
        let limit = pageSize
        Task.detached(priority: .userInitiated) {
            let outcome: Result<AgentQueryResult, Error> = Result {
                try backend.runQuery(sql, params, limit, offset)
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.isLoadingFirstPage = false
                self.isLoadingMore = false
                switch outcome {
                case .success(let result):
                    // Grids key on the SELECT's column order, which for
                    // `SELECT *` matches the schema columns; trust the
                    // result's columns in case they diverge (e.g. after
                    // an ALTER the snapshot missed).
                    if !result.columns.isEmpty, result.columns != self.columnNames {
                        self.columnNames = result.columns
                    }
                    if reset {
                        self.rows = result.rows
                    } else {
                        self.rows.append(contentsOf: result.rows)
                    }
                    self.hasMore = result.truncated
                    self.loadError = nil
                case .failure(let error):
                    self.loadError = error.localizedDescription
                    if reset { self.rows = [] }
                    self.hasMore = false
                }
            }
        }
    }

    private func fetchCount() {
        guard let (sql, params) = countQuery() else { return }
        let gen = generation
        let backend = backend
        Task.detached(priority: .utility) {
            let count: Int? = {
                guard let result = try? backend.runQuery(sql, params, nil, nil),
                    let first = result.rows.first?.first,
                    case .integer(let n) = first
                else { return nil }
                return Int(n)
            }()
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.totalCount = count
            }
        }
    }
}
