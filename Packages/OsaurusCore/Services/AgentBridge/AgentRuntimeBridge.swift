//
//  AgentRuntimeBridge.swift
//  osaurus
//
//  Protocol that the agent's `db.*` tools (and the scheduling /
//  notification tools in Phase 3) call into. We deliberately split
//  protocol from implementation (`LocalAgentBridge`) so:
//
//   - Tools depend on a narrow surface rather than the storage
//     layer's full vocabulary.
//   - A future `RemoteAgentBridge` (when an agent itself runs in a
//     sandbox) can serialize the same protocol over IPC without the
//     tool layer noticing — the shape here is wire-ready (every
//     argument / return type is `Codable & Sendable`).
//

import Foundation

/// Read-only schema info returned by `bridge.schema(agentId:)`.
public typealias AgentRuntimeSchema = AgentDatabaseSchema

/// Result envelope returned by `bridge.createTable(...)`. The migration
/// `index` is the integer assigned by `MigrationGenerator`; `appliedSQL`
/// is the canonical CREATE TABLE statement that hit SQLite.
public struct AgentCreateTableResult: Codable, Sendable {
    public var migrationIndex: Int
    public var appliedSQL: String

    public init(migrationIndex: Int, appliedSQL: String) {
        self.migrationIndex = migrationIndex
        self.appliedSQL = appliedSQL
    }
}

/// Result envelope from `bridge.insert(...)`.
public struct AgentInsertResult: Codable, Sendable {
    public var rowID: Int64

    public init(rowID: Int64) {
        self.rowID = rowID
    }
}

/// Result envelope from `bridge.update/softDelete/restore(...)`.
public struct AgentMutationResult: Codable, Sendable {
    public var rowsAffected: Int

    public init(rowsAffected: Int) {
        self.rowsAffected = rowsAffected
    }
}

/// Result envelope from `bridge.insertMany(...)`. `rowIDs` are returned in
/// input order; `count` is `rowIDs.count` for inserts.
public struct AgentBulkInsertResult: Codable, Sendable {
    public var rowIDs: [Int64]
    public var count: Int

    public init(rowIDs: [Int64], count: Int) {
        self.rowIDs = rowIDs
        self.count = count
    }
}

/// Result envelope from `bridge.importRows(...)`. `columns` echoes the
/// resolved target column order so the tool can report what landed without
/// re-reading the data.
public struct AgentImportResult: Codable, Sendable {
    public var table: String
    public var rowsImported: Int
    public var columns: [String]

    public init(table: String, rowsImported: Int, columns: [String]) {
        self.table = table
        self.rowsImported = rowsImported
        self.columns = columns
    }
}

/// Request passed to `bridge.scheduleNextRun(...)`. The bridge resolves the
/// owning agent's `AgentScheduleSettings` and applies the clamp ladder; the
/// `scheduledBy` field distinguishes a self-scheduled run (`.agent`) from
/// a user edit in the Next Run panel (`.user`) so the audit trail in
/// `_changelog` + `agent_next_run.scheduled_by` reads correctly (spec §9.5).
public struct AgentScheduleRequest: Codable, Sendable {
    public var scheduledAt: Date
    public var instructions: String
    public var contextViews: [String]
    public var priority: NextRunPriority
    public var onMiss: NextRunOnMiss
    public var scheduledBy: NextRunScheduledBy

    public init(
        scheduledAt: Date,
        instructions: String,
        contextViews: [String] = [],
        priority: NextRunPriority = .normal,
        onMiss: NextRunOnMiss = .skip,
        scheduledBy: NextRunScheduledBy = .agent
    ) {
        self.scheduledAt = scheduledAt
        self.instructions = instructions
        self.contextViews = contextViews
        self.priority = priority
        self.onMiss = onMiss
        self.scheduledBy = scheduledBy
    }
}

/// Which clamp rule the bridge applied to `scheduledAt` before persisting,
/// if any. Reported back to the caller so the agent's tool result can
/// surface "your 30-second self-wake was clamped to 5 minutes because
/// min_interval applies."
public enum AgentScheduleClampReason: String, Codable, Sendable, CaseIterable {
    case minInterval = "min_interval"
    case maxHorizon = "max_horizon"
    case quietHours = "quiet_hours"
    case dailyCap = "daily_cap"
    case dayNotAllowed = "day_not_allowed"
    case modeManual = "mode_manual"
    case paused
}

/// Returned by `bridge.scheduleNextRun(...)`.
public struct AgentScheduleResult: Codable, Sendable {
    /// What we actually persisted into `agent_next_run`. `nil` when the
    /// schedule was rejected outright (e.g. `daily_cap` exhausted).
    public var entry: NextRunEntry?
    /// True iff the bridge moved `scheduledAt` to satisfy a clamp.
    public var clamped: Bool
    /// Ordered list of clamps applied, in the order applied. Empty when
    /// the request was accepted verbatim.
    public var clampReasons: [AgentScheduleClampReason]
    /// `daily_run_cap - used` in the current rolling window. Useful for
    /// agents that want to reason about their own budget.
    public var remainingBudgetToday: Int

    public init(
        entry: NextRunEntry?,
        clamped: Bool,
        clampReasons: [AgentScheduleClampReason],
        remainingBudgetToday: Int
    ) {
        self.entry = entry
        self.clamped = clamped
        self.clampReasons = clampReasons
        self.remainingBudgetToday = remainingBudgetToday
    }
}

/// Protocol the tool layer talks to. The current implementation
/// (`LocalAgentBridge`) holds direct references to `AgentDatabase`,
/// `SchedulerDatabase`, and `NotificationService`. A future
/// `RemoteAgentBridge` would serialize each method over a transport.
///
/// All methods are blocking from the caller's perspective; the
/// implementation may serialize through internal queues. Tools call
/// these from `OsaurusTool.execute(argumentsJSON:)` which already runs
/// off the main actor inside the `ToolRegistry.execute` pipeline.
public protocol AgentRuntimeBridge: Sendable {
    // MARK: Schema

    func schema(agentId: UUID) throws -> AgentRuntimeSchema

    @discardableResult
    func createTable(
        agentId: UUID,
        name: String,
        purpose: String,
        columns: [AgentColumnSpec],
        indexes: [AgentIndexSpec]
    ) throws -> AgentCreateTableResult

    @discardableResult
    func alterTableAddColumns(
        agentId: UUID,
        name: String,
        additions: [AgentColumnSpec]
    ) throws -> AgentCreateTableResult

    @discardableResult
    func runMigration(
        agentId: UUID,
        upSQL: String,
        downSQL: String,
        description: String
    ) throws -> AgentCreateTableResult

    // MARK: CRUD

    @discardableResult
    func insert(
        agentId: UUID,
        table: String,
        row: [String: AgentSQLValue]
    ) throws -> AgentInsertResult

    @discardableResult
    func upsert(
        agentId: UUID,
        table: String,
        keyColumns: [String],
        row: [String: AgentSQLValue]
    ) throws -> AgentInsertResult

    /// Insert many in-context rows in one (chunked) batch. Back-compat
    /// sibling of `insert(...)` for the `rows[]` form of `db_insert`.
    @discardableResult
    func insertMany(
        agentId: UUID,
        table: String,
        rows: [[String: AgentSQLValue]]
    ) throws -> AgentBulkInsertResult

    /// Upsert many in-context rows in one (chunked) batch.
    @discardableResult
    func upsertMany(
        agentId: UUID,
        table: String,
        keyColumns: [String],
        rows: [[String: AgentSQLValue]]
    ) throws -> AgentMutationResult

    /// Host-mediated bulk import. `rows` are parsed on the host (no model
    /// tokens spent per row). `keyColumns` empty ⇒ insert; non-empty ⇒
    /// upsert. `columns` is the resolved target column order, echoed back
    /// in the result.
    @discardableResult
    func importRows(
        agentId: UUID,
        table: String,
        rows: [[String: AgentSQLValue]],
        keyColumns: [String],
        columns: [String]
    ) throws -> AgentImportResult

    @discardableResult
    func update(
        agentId: UUID,
        table: String,
        set: [String: AgentSQLValue],
        whereClause: [String: AgentSQLValue],
        includeDeleted: Bool
    ) throws -> AgentMutationResult

    @discardableResult
    func softDelete(
        agentId: UUID,
        table: String,
        whereClause: [String: AgentSQLValue]
    ) throws -> AgentMutationResult

    @discardableResult
    func restore(
        agentId: UUID,
        table: String,
        whereClause: [String: AgentSQLValue]
    ) throws -> AgentMutationResult

    func query(
        agentId: UUID,
        sql: String,
        params: [AgentSQLValue]
    ) throws -> AgentQueryResult

    @discardableResult
    func execute(
        agentId: UUID,
        sql: String,
        params: [AgentSQLValue]
    ) throws -> AgentExecuteResult

    // MARK: Scheduling (spec §9 — phase 3)

    /// Schedule the agent's next self-wake. Implementations apply the
    /// clamp ladder defined in spec §16 Q3 (min_interval, max_horizon,
    /// quiet_hours, daily_cap) against the supplied bounds and persist
    /// the result.
    ///
    /// `bounds` is passed in (rather than read inside the bridge) because
    /// `AgentManager` is `@MainActor` isolated and the bridge runs on a
    /// background serial queue — the tool layer resolves the bounds on
    /// MainActor before crossing into the bridge.
    @discardableResult
    func scheduleNextRun(
        agentId: UUID,
        request: AgentScheduleRequest,
        bounds: AgentScheduleSettings
    ) throws -> AgentScheduleResult

    /// Clear the agent's next-run slot, if any. Returns whether a row
    /// was actually deleted. Idempotent.
    @discardableResult
    func cancelNextRun(agentId: UUID) throws -> Bool

    /// Read the current next-run slot, if any.
    func nextRun(agentId: UUID) throws -> NextRunEntry?

    /// Pause / unpause the agent — short-circuits the scheduler.
    func pauseAgent(
        agentId: UUID,
        until: Date,
        reason: String?
    ) throws

    func unpauseAgent(agentId: UUID) throws

    func pauseInfo(agentId: UUID) throws -> AgentPauseRecord?

    /// Surface a notification to the user (spec §10). `agentName` is
    /// passed in (rather than resolved inside the bridge) for the same
    /// MainActor-isolation reason as `scheduleNextRun(...)`.
    func notify(
        agentId: UUID,
        agentName: String,
        title: String,
        body: String,
        viewRef: String?
    ) throws

    // MARK: Saved views (spec §6.3)

    /// Define or redefine a saved view by name. SELECT/CTE-only.
    @discardableResult
    func defineView(
        agentId: UUID,
        name: String,
        sql: String,
        renderHint: String,
        refresh: String,
        description: String?
    ) throws -> AgentSavedView

    /// Drop a saved view. No-op + `false` if it wasn't defined.
    @discardableResult
    func dropView(
        agentId: UUID,
        name: String
    ) throws -> Bool

    /// Toggle the pinned bit so the Home tab surfaces this view.
    func setViewPinned(
        agentId: UUID,
        name: String,
        pinned: Bool
    ) throws

    /// All saved views for this agent, ordered by name.
    func listViews(agentId: UUID) throws -> [AgentSavedView]

    /// Run a saved view's SELECT and return its rows.
    func runView(
        agentId: UUID,
        name: String
    ) throws -> AgentQueryResult

    // MARK: Snapshot generation

    /// Produce the compact text snapshot of the agent's DB schema.
    /// Injected into the system prompt by `SystemPromptComposer`
    /// when `Agent.settings.dbEnabled == true`.
    func schemaSnapshot(agentId: UUID) throws -> String
}
