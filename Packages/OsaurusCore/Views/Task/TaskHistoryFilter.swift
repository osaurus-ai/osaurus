//
//  TaskHistoryFilter.swift
//  osaurus
//
//  The filter behind Tasks → History, the one run history: every
//  automation, background agent, workflow and helper run, narrowed by where
//  it came from, how it ended, its queue, or one agent or workflow.
//

import Foundation

struct TaskHistoryFilter: Equatable, Sendable {
    enum Status: String, CaseIterable, Identifiable, Sendable {
        case all, ran, skipped, failed

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: L("Any Result")
            case .ran: L("Ran")
            case .skipped: L("Skipped")
            case .failed: L("Failed")
            }
        }

        var states: [TaskState]? {
            switch self {
            case .all: nil
            case .ran: [.succeeded, .cancelled, .interrupted]
            case .skipped: [.filtered, .duplicate, .suppressed]
            case .failed: [.failed]
            }
        }
    }

    var origin: TaskOrigin?
    var status: Status = .all
    var queueId: UUID?
    var agentId: UUID?
    var workflowID: UUID?
    /// Tasks a chat started (`OsaurusTask.originSessionId`).
    var originSessionId: UUID?

    static let automations = TaskHistoryFilter(origin: .automation)

    static func agent(_ id: UUID) -> TaskHistoryFilter { TaskHistoryFilter(agentId: id) }
    static func workflow(_ id: UUID) -> TaskHistoryFilter { TaskHistoryFilter(workflowID: id) }
    static func chat(_ sessionId: UUID) -> TaskHistoryFilter { TaskHistoryFilter(originSessionId: sessionId) }

    func query(limit: Int = 200) -> TaskQuery {
        TaskQuery(
            queueId: queueId, states: status.states, origin: origin, agentId: agentId, workflowID: workflowID,
            originSessionId: originSessionId, limit: limit)
    }
}
