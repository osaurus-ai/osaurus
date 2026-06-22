//
//  LocalAgentBridge.swift
//  osaurus
//
//  In-process implementation of `AgentRuntimeBridge`. Holds direct
//  references to `AgentDatabaseStore` (per-agent SQLite), `SchedulerDatabase`
//  (next-run + run history + pause), and `NotificationService` (delivery).
//
//  Concurrency model (spec §1.4, §16 Q1):
//
//  Each agent gets its own serial `DispatchQueue` (`actorQueues[agentId]`),
//  built lazily on first use. All mutation-style methods route through
//  that queue, so:
//
//   - The agent's inference loop, a UI cell edit, and a scheduled
//     view-refresh for the same agent serialize into a single timeline.
//     `_changelog` is correctly ordered with no extra plumbing.
//   - Different agents don't block each other — each has its own queue.
//
//  Reads (`schema`, `query`, `schemaSnapshot`) skip the bridge queue —
//  they go straight to the per-agent `AgentDatabase`, which has its own
//  serial queue inside. We pay one queue hop per write, two queue hops
//  per write (bridge queue then DB queue); the DB queue's job is to
//  serialize SQLite, while the bridge queue's job is to serialize the
//  bridge's higher-level steps (migration file + schema dump + actor
//  stamping).
//

import Foundation

public final class LocalAgentBridge: @unchecked Sendable, AgentRuntimeBridge {
    public static let shared = LocalAgentBridge()

    private let lock = NSLock()
    private var actorQueues: [UUID: DispatchQueue] = [:]

    init() {}

    // MARK: - Public lifecycle

    /// Ensure the per-agent serial queue + DB exist. Called by the
    /// toggle in agent settings when the user first turns the feature
    /// on, and at app launch for every agent already opted-in.
    public func bootstrap(agentId: UUID) throws {
        _ = serialQueue(for: agentId)
        try AgentDatabaseStore.shared.ensureOpen(for: agentId)
    }

    /// Drop the per-agent queue from the cache. Called when an agent
    /// is deleted or its DB is dropped. The `AgentDatabaseStore` will
    /// also close + remove its connection separately.
    public func forget(agentId: UUID) {
        lock.lock()
        actorQueues.removeValue(forKey: agentId)
        lock.unlock()
    }

    // MARK: - AgentRuntimeBridge (reads)

    public func schema(agentId: UUID) throws -> AgentRuntimeSchema {
        try AgentDatabaseStore.shared.database(for: agentId).schema()
    }

    public func query(
        agentId: UUID,
        sql: String,
        params: [AgentSQLValue]
    ) throws -> AgentQueryResult {
        try AgentDatabaseStore.shared.database(for: agentId).query(sql: sql, params: params)
    }

    /// Paged read: `limit` caps the returned rows (up to the engine's hard
    /// max) and `offset` skips rows so a caller can walk a large result set
    /// across calls. Overload of `query(agentId:sql:params:)`.
    public func query(
        agentId: UUID,
        sql: String,
        params: [AgentSQLValue],
        limit: Int?,
        offset: Int?
    ) throws -> AgentQueryResult {
        try AgentDatabaseStore.shared.database(for: agentId)
            .query(sql: sql, params: params, limit: limit, offset: offset)
    }

    public func schemaSnapshot(agentId: UUID) throws -> String {
        let schema = try AgentDatabaseStore.shared.database(for: agentId).schema()
        return SchemaSnapshot.render(schema)
    }

    // MARK: - AgentRuntimeBridge (writes)

    @discardableResult
    public func createTable(
        agentId: UUID,
        name: String,
        purpose: String,
        columns: [AgentColumnSpec],
        indexes: [AgentIndexSpec]
    ) throws -> AgentCreateTableResult {
        try serialized(agentId) {
            let actor = self.currentActor()
            let runId = ChatExecutionContext.currentRunId
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let appliedSQL = try database.createTable(
                name: name,
                purpose: purpose,
                columns: columns,
                indexes: indexes,
                actor: actor,
                runId: runId
            )
            let downSQL = "DROP TABLE \(name);"
            let migration = MigrationGenerator.writePair(
                for: agentId,
                slug: "create-\(name)",
                upSQL: appliedSQL + ";",
                downSQL: downSQL
            )
            self.refreshSchemaArtifacts(agentId: agentId, database: database)
            return AgentCreateTableResult(
                migrationIndex: migration?.index ?? 0,
                appliedSQL: appliedSQL
            )
        }
    }

    @discardableResult
    public func alterTableAddColumns(
        agentId: UUID,
        name: String,
        additions: [AgentColumnSpec]
    ) throws -> AgentCreateTableResult {
        try serialized(agentId) {
            let actor = self.currentActor()
            let runId = ChatExecutionContext.currentRunId
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let applied = try database.alterTableAddColumns(
                name: name,
                additions: additions,
                actor: actor,
                runId: runId
            )
            let up = applied.map { $0 + ";" }.joined(separator: "\n")
            // Down: drop the added columns. SQLite supports DROP COLUMN
            // from 3.35+, which the vendored SQLCipher includes.
            let down =
                additions
                .map { "ALTER TABLE \(name) DROP COLUMN \($0.name);" }
                .joined(separator: "\n")
            let migration = MigrationGenerator.writePair(
                for: agentId,
                slug: "alter-\(name)-add-columns",
                upSQL: up,
                downSQL: down
            )
            self.refreshSchemaArtifacts(agentId: agentId, database: database)
            return AgentCreateTableResult(
                migrationIndex: migration?.index ?? 0,
                appliedSQL: up
            )
        }
    }

    @discardableResult
    public func runMigration(
        agentId: UUID,
        upSQL: String,
        downSQL: String,
        description: String
    ) throws -> AgentCreateTableResult {
        try serialized(agentId) {
            let actor = self.currentActor()
            let runId = ChatExecutionContext.currentRunId
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            try database.runMigration(
                upSQL: upSQL,
                downSQL: downSQL,
                description: description,
                actor: actor,
                runId: runId
            )
            let migration = MigrationGenerator.writePair(
                for: agentId,
                slug: description.isEmpty ? "migrate" : description,
                upSQL: upSQL,
                downSQL: downSQL
            )
            self.refreshSchemaArtifacts(agentId: agentId, database: database)
            return AgentCreateTableResult(
                migrationIndex: migration?.index ?? 0,
                appliedSQL: upSQL
            )
        }
    }

    @discardableResult
    public func insert(
        agentId: UUID,
        table: String,
        row: [String: AgentSQLValue]
    ) throws -> AgentInsertResult {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let rowID = try database.insert(
                table: table,
                row: row,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
            return AgentInsertResult(rowID: rowID)
        }
    }

    @discardableResult
    public func upsert(
        agentId: UUID,
        table: String,
        keyColumns: [String],
        row: [String: AgentSQLValue]
    ) throws -> AgentInsertResult {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let rowID = try database.upsert(
                table: table,
                keyColumns: keyColumns,
                row: row,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
            return AgentInsertResult(rowID: rowID)
        }
    }

    @discardableResult
    public func insertMany(
        agentId: UUID,
        table: String,
        rows: [[String: AgentSQLValue]]
    ) throws -> AgentBulkInsertResult {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let rowIDs = try database.insertMany(
                table: table,
                rows: rows,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
            return AgentBulkInsertResult(rowIDs: rowIDs, count: rowIDs.count)
        }
    }

    @discardableResult
    public func upsertMany(
        agentId: UUID,
        table: String,
        keyColumns: [String],
        rows: [[String: AgentSQLValue]]
    ) throws -> AgentMutationResult {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let count = try database.upsertMany(
                table: table,
                keyColumns: keyColumns,
                rows: rows,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
            return AgentMutationResult(rowsAffected: count)
        }
    }

    @discardableResult
    public func importRows(
        agentId: UUID,
        table: String,
        rows: [[String: AgentSQLValue]],
        keyColumns: [String],
        columns: [String]
    ) throws -> AgentImportResult {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let imported = try database.importRows(
                table: table,
                rows: rows,
                keyColumns: keyColumns,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
            return AgentImportResult(
                table: table,
                rowsImported: imported,
                columns: columns
            )
        }
    }

    @discardableResult
    public func update(
        agentId: UUID,
        table: String,
        set: [String: AgentSQLValue],
        whereClause: [String: AgentSQLValue],
        includeDeleted: Bool
    ) throws -> AgentMutationResult {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let affected = try database.update(
                table: table,
                set: set,
                whereClause: whereClause,
                includeDeleted: includeDeleted,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
            return AgentMutationResult(rowsAffected: affected)
        }
    }

    @discardableResult
    public func softDelete(
        agentId: UUID,
        table: String,
        whereClause: [String: AgentSQLValue]
    ) throws -> AgentMutationResult {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let affected = try database.softDelete(
                table: table,
                whereClause: whereClause,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
            return AgentMutationResult(rowsAffected: affected)
        }
    }

    @discardableResult
    public func restore(
        agentId: UUID,
        table: String,
        whereClause: [String: AgentSQLValue]
    ) throws -> AgentMutationResult {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let affected = try database.restore(
                table: table,
                whereClause: whereClause,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
            return AgentMutationResult(rowsAffected: affected)
        }
    }

    @discardableResult
    public func execute(
        agentId: UUID,
        sql: String,
        params: [AgentSQLValue]
    ) throws -> AgentExecuteResult {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let result = try database.execute(
                sql: sql,
                params: params,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
            // Raw SQL might mutate schema; opportunistically refresh
            // the artifacts so the user-facing files don't drift.
            // Cheap when schema is unchanged because the dump is
            // idempotent.
            self.refreshSchemaArtifacts(agentId: agentId, database: database)
            return result
        }
    }

    // MARK: - AgentRuntimeBridge (saved views, spec §6.3)

    @discardableResult
    public func defineView(
        agentId: UUID,
        name: String,
        sql: String,
        renderHint: String,
        refresh: String,
        description: String?
    ) throws -> AgentSavedView {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let view = try database.defineView(
                name: name,
                sql: sql,
                renderHint: renderHint,
                refresh: refresh,
                description: description,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
            // A new view shifts the schema snapshot; keep the disk
            // artifact in sync so the file the user sees in their
            // agent directory matches the live DB.
            self.refreshSchemaArtifacts(agentId: agentId, database: database)
            return view
        }
    }

    @discardableResult
    public func dropView(agentId: UUID, name: String) throws -> Bool {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            let existed = try database.dropView(
                name: name,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
            self.refreshSchemaArtifacts(agentId: agentId, database: database)
            return existed
        }
    }

    public func setViewPinned(
        agentId: UUID,
        name: String,
        pinned: Bool
    ) throws {
        try serialized(agentId) {
            let database = try AgentDatabaseStore.shared.database(for: agentId)
            try database.setViewPinned(
                name: name,
                pinned: pinned,
                actor: self.currentActor(),
                runId: ChatExecutionContext.currentRunId
            )
        }
    }

    public func listViews(agentId: UUID) throws -> [AgentSavedView] {
        try AgentDatabaseStore.shared.database(for: agentId).savedViews()
    }

    public func runView(
        agentId: UUID,
        name: String
    ) throws -> AgentQueryResult {
        try AgentDatabaseStore.shared.database(for: agentId).runView(name: name)
    }

    // MARK: - AgentRuntimeBridge (scheduling, spec §9)

    @discardableResult
    public func scheduleNextRun(
        agentId: UUID,
        request: AgentScheduleRequest,
        bounds: AgentScheduleSettings
    ) throws -> AgentScheduleResult {
        try serialized(agentId) {
            try SchedulerDatabase.shared.open()

            // Daily cap: in manual mode the cap is 0 — every self-schedule
            // attempt is rejected. We still want user-driven edits through
            // the Next Run panel to land regardless of the cap (the user is
            // the safety valve, not the dispatcher), so this guard only
            // fires for `.agent` writes (spec §13).
            let isAgentWrite = request.scheduledBy == .agent
            let runWindow: TimeInterval = 24 * 3600
            let usedToday =
                (try? SchedulerDatabase.shared.successfulOrErroredRunCount(
                    agentId: agentId,
                    triggerKind: .schedule,
                    in: runWindow
                )) ?? 0
            let remainingBudget = max(0, bounds.dailyRunCap - usedToday)

            if isAgentWrite && bounds.mode == .manual {
                return AgentScheduleResult(
                    entry: nil,
                    clamped: true,
                    clampReasons: [.modeManual],
                    remainingBudgetToday: 0
                )
            }
            if isAgentWrite && bounds.dailyRunCap > 0 && usedToday >= bounds.dailyRunCap {
                return AgentScheduleResult(
                    entry: nil,
                    clamped: true,
                    clampReasons: [.dailyCap],
                    remainingBudgetToday: 0
                )
            }
            if isAgentWrite,
                let pauseRecord = (try? SchedulerDatabase.shared.pauseInfo(for: agentId)),
                pauseRecord.pausedUntil > Date()
            {
                return AgentScheduleResult(
                    entry: nil,
                    clamped: true,
                    clampReasons: [.paused],
                    remainingBudgetToday: remainingBudget
                )
            }

            let now = Date()
            var scheduled = max(request.scheduledAt, now)
            var reasons: [AgentScheduleClampReason] = []

            // Clamp order matches spec §16 Q3: min_interval → max_horizon
            // → quiet_hours / allowed-days → daily_cap (already enforced
            // above). The ladder is intentionally one-shot per dimension;
            // we don't keep retrying because quiet_hours expansion can
            // shove us past max_horizon, which is fine for the agent to
            // see in the clamp reasons.

            if isAgentWrite && bounds.minIntervalSeconds > 0 {
                let earliest = now.addingTimeInterval(TimeInterval(bounds.minIntervalSeconds))
                if scheduled < earliest {
                    scheduled = earliest
                    reasons.append(.minInterval)
                }
            }
            if bounds.maxHorizonSeconds > 0 {
                let latest = now.addingTimeInterval(TimeInterval(bounds.maxHorizonSeconds))
                if scheduled > latest {
                    scheduled = latest
                    reasons.append(.maxHorizon)
                }
            }
            if isAgentWrite,
                let quietStart = bounds.quietHoursStart,
                let quietEnd = bounds.quietHoursEnd,
                quietStart != quietEnd
            {
                if let bumped = Self.escapeQuietHours(
                    scheduled,
                    quietStartMinute: quietStart,
                    quietEndMinute: quietEnd
                ) {
                    if bumped != scheduled {
                        scheduled = bumped
                        reasons.append(.quietHours)
                    }
                }
            }
            if isAgentWrite, bounds.allowedDaysMask != 127 {
                if let bumped = Self.advanceToAllowedDay(
                    scheduled,
                    mask: bounds.allowedDaysMask
                ) {
                    if bumped != scheduled {
                        scheduled = bumped
                        reasons.append(.dayNotAllowed)
                    }
                } else if bounds.allowedDaysMask == 0 {
                    // mask=0 means no days are allowed; refuse outright.
                    return AgentScheduleResult(
                        entry: nil,
                        clamped: true,
                        clampReasons: [.dayNotAllowed],
                        remainingBudgetToday: remainingBudget
                    )
                }
            }

            let entry = NextRunEntry(
                agentId: agentId,
                scheduledAt: scheduled,
                instructions: request.instructions,
                contextViews: request.contextViews,
                priority: request.priority,
                onMiss: request.onMiss,
                scheduledBy: request.scheduledBy,
                scheduledAtWall: Date()
            )
            let stored = try SchedulerDatabase.shared.upsertNextRun(entry)
            // Poke the scheduler so it doesn't wait out its 60s idle
            // sleep to notice a freshly inserted near-term row.
            Task { @MainActor in NextRunScheduler.shared.notifyRowChanged() }
            return AgentScheduleResult(
                entry: stored,
                clamped: !reasons.isEmpty,
                clampReasons: reasons,
                remainingBudgetToday: remainingBudget
            )
        }
    }

    @discardableResult
    public func cancelNextRun(agentId: UUID) throws -> Bool {
        try serialized(agentId) {
            try SchedulerDatabase.shared.open()
            let existed = (try? SchedulerDatabase.shared.nextRun(for: agentId)) != nil
            try SchedulerDatabase.shared.clearNextRun(for: agentId)
            Task { @MainActor in NextRunScheduler.shared.notifyRowChanged() }
            return existed
        }
    }

    public func nextRun(agentId: UUID) throws -> NextRunEntry? {
        try SchedulerDatabase.shared.open()
        return try SchedulerDatabase.shared.nextRun(for: agentId)
    }

    public func pauseAgent(
        agentId: UUID,
        until: Date,
        reason: String?
    ) throws {
        try serialized(agentId) {
            try SchedulerDatabase.shared.open()
            try SchedulerDatabase.shared.pause(agentId: agentId, until: until, reason: reason)
            // No row change, but the scheduler's pause check fires at
            // tick time — waking early lets the next iteration skip a
            // just-paused agent immediately.
            Task { @MainActor in NextRunScheduler.shared.notifyRowChanged() }
        }
    }

    public func unpauseAgent(agentId: UUID) throws {
        try serialized(agentId) {
            try SchedulerDatabase.shared.open()
            try SchedulerDatabase.shared.unpause(agentId: agentId)
            Task { @MainActor in NextRunScheduler.shared.notifyRowChanged() }
        }
    }

    public func pauseInfo(agentId: UUID) throws -> AgentPauseRecord? {
        try SchedulerDatabase.shared.open()
        return try SchedulerDatabase.shared.pauseInfo(for: agentId)
    }

    public func notify(
        agentId: UUID,
        agentName: String,
        title: String,
        body: String,
        viewRef: String?
    ) throws {
        // `UNUserNotificationCenter.current()` (created on first access
        // of `NotificationService.shared`) raises an Objective-C
        // exception in processes without an app bundle — e.g. the
        // `osaurus-evals` CLI. Log instead of crashing the headless run;
        // the bundled app path is unaffected.
        guard Bundle.main.bundleIdentifier != nil else {
            print("[Osaurus] notify (headless, suppressed): \(agentName) · \(title) — \(body)")
            return
        }
        // `postAgentEvent` is `nonisolated` (it dispatches the actual
        // `UNNotificationCenter.add` into a `Task @MainActor`), but
        // `NotificationService.shared` itself is MainActor-isolated.
        // Hop briefly to the main actor to obtain a reference, then let
        // the rest of the call run nonisolated.
        Task { @MainActor in
            NotificationService.shared.postAgentEvent(
                agentId: agentId,
                agentName: agentName,
                title: title,
                body: body,
                viewRef: viewRef
            )
        }
    }

    // MARK: - Internals

    /// Resolve the current `_changelog.actor` from the task-local
    /// context. Defaults to `.agent` because the most common path
    /// (a tool firing during inference) doesn't set the local
    /// explicitly — it's the assumed default.
    private func currentActor() -> AgentDatabaseActor {
        guard let raw = ChatExecutionContext.currentRunActor,
            let actor = AgentDatabaseActor(rawValue: raw)
        else { return .agent }
        return actor
    }

    /// Run `body` on the per-agent serial queue. Brackets the call
    /// with `AgentMutationActivity.begin/end` so the UI's
    /// "mutations-in-flight" spinner (spec §16 Q1) tracks live work
    /// even if `body` throws or the queue is contended. The
    /// bracket dispatches to MainActor without awaiting completion
    /// — the spinner is cosmetic, so a tiny lag is fine and keeps
    /// the calling thread off MainActor.
    private func serialized<T>(_ agentId: UUID, body: () throws -> T) throws -> T {
        Task { @MainActor in AgentMutationActivity.shared.begin(agentId) }
        defer {
            Task { @MainActor in AgentMutationActivity.shared.end(agentId) }
        }
        return try serialQueue(for: agentId).sync(execute: body)
    }

    private func serialQueue(for agentId: UUID) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let q = actorQueues[agentId] { return q }
        let q = DispatchQueue(label: "ai.osaurus.bridge.\(agentId.uuidString)")
        actorQueues[agentId] = q
        return q
    }

    /// Re-render `schema.sql` after a schema mutation. Best-effort.
    ///
    /// Atomicity caveat (spec §337): the SQLite transaction commits
    /// inside `database.<mutation>` before this re-render runs, so a
    /// crash or process kill between commit and dump can leave the
    /// on-disk `schema.sql` lagging behind the database by one
    /// migration. SQLite is the canonical source of truth — the
    /// next successful schema mutation will rewrite `schema.sql`
    /// from the live snapshot, so the lag self-heals on the next
    /// write. We accept the (rare) window over wrapping the dump
    /// inside the transaction, because the dump's failure modes
    /// (disk full, perms) would otherwise roll back the user's
    /// schema change too.
    private func refreshSchemaArtifacts(agentId: UUID, database: AgentDatabase) {
        guard let schema = try? database.schema() else { return }
        SchemaDumper.dump(schema, for: agentId)
    }

    /// If `date` falls inside the quiet-hours window, push it forward to
    /// the next minute that's outside the window. Window is [start, end);
    /// `start > end` is treated as wrapping past midnight (e.g. 22:00 →
    /// 07:00). Returns the bumped date, or the input if it was already
    /// safe.
    static func escapeQuietHours(
        _ date: Date,
        quietStartMinute startM: Int,
        quietEndMinute endM: Int,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date? {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let hour = comps.hour, let minute = comps.minute else { return date }
        let mod = hour * 60 + minute

        let inQuiet: Bool
        if startM == endM {
            return date  // degenerate window — no quiet hours
        } else if startM < endM {
            inQuiet = mod >= startM && mod < endM
        } else {
            inQuiet = mod >= startM || mod < endM
        }
        guard inQuiet else { return date }

        // Reset to start of day and add `endM` minutes; if `start > end`
        // (wrap-around) and we're past midnight, end is on the same day,
        // otherwise it's on the next day.
        var dayComps = calendar.dateComponents([.year, .month, .day], from: date)
        dayComps.hour = 0
        dayComps.minute = 0
        dayComps.second = 0
        guard let dayStart = calendar.date(from: dayComps) else { return date }

        if startM < endM {
            return calendar.date(byAdding: .minute, value: endM, to: dayStart) ?? date
        }
        // Wrap-around. If `mod >= startM`, we're in the evening half — end
        // is tomorrow at `endM`; otherwise we're in the early morning half
        // and end is today at `endM`.
        if mod >= startM {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return date }
            return calendar.date(byAdding: .minute, value: endM, to: nextDay) ?? date
        }
        return calendar.date(byAdding: .minute, value: endM, to: dayStart) ?? date
    }

    /// If `date`'s weekday isn't allowed by `mask`, advance day-by-day
    /// (preserving time of day) until it is. Sun=1, Mon=2, ... Sat=64.
    /// Returns nil iff `mask == 0` (no day will ever be allowed).
    static func advanceToAllowedDay(
        _ date: Date,
        mask: Int,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date? {
        guard mask != 0 else { return nil }
        if mask == 127 { return date }
        var probe = date
        for _ in 0 ..< 7 {
            let weekday = calendar.component(.weekday, from: probe)
            // Calendar.weekday is 1=Sun..7=Sat → bit = 1 << (weekday-1).
            let bit = 1 << (weekday - 1)
            if mask & bit != 0 { return probe }
            guard let next = calendar.date(byAdding: .day, value: 1, to: probe) else { return probe }
            probe = next
        }
        return probe
    }
}
