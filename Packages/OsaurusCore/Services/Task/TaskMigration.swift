//
//  TaskMigration.swift
//  osaurus
//
//  Import of the legacy agent run history (`agent_runs` in scheduler.sqlite)
//  as finished tasks. Once the import commits, the table is retired
//  (`SchedulerDatabase.retireLegacyTable`).
//  Automation runs are skipped: their `event_runs` rows already imported
//  them (`EventManager.importLedgerIntoTasks`).
//

import Foundation

@MainActor
enum TaskMigration {
    static let agentRunsKey = "import.agent_runs.v1"
    static let agentRunsLimit = 5000

    /// The encrypted scheduler store is read off the main thread, and never
    /// opened (or created) on installs that don't have one.
    static func importAgentRuns(into store: TaskStore, database: SchedulerDatabase = .shared) async {
        let limit = agentRunsLimit
        let rows = await Task.detached(priority: .utility) { () -> [AgentRunRecord]? in
            guard database.isOpen || FileManager.default.fileExists(atPath: OsaurusPaths.schedulerDatabaseFile().path),
                (try? database.open()) != nil
            else { return nil }
            return try? database.legacyRuns(limit: limit)
        }.value
        guard let rows, !rows.isEmpty else { return }
        guard store.importHistory(agentRunsKey, rows.compactMap(task(from:))) else { return }
        try? database.retireLegacyTable("agent_runs")
    }

    /// nil for automation runs (imported from `event_runs`).
    static func task(from run: AgentRunRecord) -> OsaurusTask? {
        let origin: TaskOrigin
        let source: SessionSource
        switch run.triggerKind {
        case .schedule:
            origin = .selfSchedule
            source = .selfSchedule
        case .user:
            origin = .manual
            source = .chat
        case .recurringSchedule, .watcher, .webhook, .email, .automation:
            return nil
        }
        let state: TaskState
        switch run.status {
        case .success: state = .succeeded
        case .error: state = .failed
        case .cancelled: state = .cancelled
        case .clamped: state = .suppressed
        case .running: state = .interrupted
        }
        let firstLine = run.instructions.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        var task = OsaurusTask(
            id: run.id,
            title: firstLine.map { String($0.prefix(80)) } ?? L("Agent run"),
            origin: origin,
            createdBy: origin == .selfSchedule ? .agent(run.agentId) : .user,
            work: .agentTurn(AgentTurnWork(agentId: run.agentId, source: source)),
            state: state,
            createdAt: run.startedAt)
        task.startedAt = run.startedAt
        task.finishedAt = run.endedAt ?? run.startedAt
        task.lastError = run.error
        task.reason = run.status == .running ? "interrupted" : nil
        task.result = TaskResult(tokensIn: run.tokensIn, tokensOut: run.tokensOut, costUSD: run.costUSD)
        return task
    }
}
