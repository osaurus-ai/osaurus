//
//  TaskActivityLogger.swift
//  osaurus
//
//  One Insights row per finished task: queue, origin, what it ran, how it
//  ended and how long it waited. The task's own model, tool and network
//  rows carry its id, so "All Events for This Task" lists them together.
//

import Foundation

@MainActor
enum TaskActivityLogger {
    private static var token: TaskBus.Token?
    /// Tasks already logged this launch, so a late update to a finished
    /// task does not write a second row.
    private static var logged: Set<UUID> = []
    private static let loggedLimit = 5_000

    static func start(store: TaskStore = .shared) {
        guard token == nil else { return }
        token = store.bus.observe { event in
            guard case .taskChanged(let task) = event else { return }
            log(task, store: store)
        }
    }

    static func log(_ task: OsaurusTask, store: TaskStore = .shared) {
        guard shouldLog(task), !logged.contains(task.id) else { return }
        if logged.count >= loggedLimit { logged.removeAll() }
        logged.insert(task.id)
        let queue = store.resolvedQueue(task.queueId)
        InsightsService.logEgress(
            category: .task,
            source: requestSource(task.origin),
            method: "TASK",
            path: "/tasks/\(queue.slug)/\(task.work.kind.rawValue)",
            statusCode: statusCode(task.state),
            durationMs: durationSeconds(task) * 1000,
            egress: EgressInfo(details: details(task, queue: queue)),
            locality: .local,
            errorMessage: task.state == .failed ? (task.lastError ?? task.reason) : nil,
            attribution: InsightsService.ActivityAttribution(
                agentId: task.agentId,
                sessionId: task.sessionId,
                workflowRunId: task.workflowRunId,
                taskId: task.id
            )
        )
    }

    /// Filtered and duplicate deliveries never became work.
    static func shouldLog(_ task: OsaurusTask) -> Bool {
        task.state.isTerminal && task.state != .filtered && task.state != .duplicate
    }

    static func details(_ task: OsaurusTask, queue: TaskQueue) -> [String: String] {
        var details: [String: String] = [
            "task_id": task.id.uuidString,
            "task_title": task.title,
            "queue": queue.name,
            "queue_id": queue.id.uuidString,
            "origin": task.origin.rawValue,
            "work": task.work.kind.rawValue,
            "state": task.state.rawValue,
        ]
        if let reason = task.reason { details["reason"] = reason }
        if let parent = task.parentId { details["parent_task_id"] = parent.uuidString }
        if task.rootId != task.id { details["root_task_id"] = task.rootId.uuidString }
        if task.depth > 0 { details["depth"] = String(task.depth) }
        if task.attemptCount > 1 { details["attempts"] = String(task.attemptCount) }
        if let started = task.startedAt {
            details["wait_ms"] = String(Int(max(0, started.timeIntervalSince(task.createdAt)) * 1000))
        }
        if let subscription = task.subscriptionId { details["automation_id"] = subscription.uuidString }
        return details
    }

    static func requestSource(_ origin: TaskOrigin) -> RequestSource {
        switch origin {
        case .automation: .automation
        case .selfSchedule: .selfSchedule
        case .channel: .channel
        case .spawn, .workflowStep: .agent
        case .apiDispatch: .httpAPI
        case .plugin: .plugin
        case .manual: .chatUI
        case .system: .system
        }
    }

    static func statusCode(_ state: TaskState) -> Int {
        switch state {
        case .succeeded: 200
        case .suppressed, .filtered, .duplicate: 204
        case .cancelled, .interrupted: 499
        case .failed: 500
        case .received, .queued, .admitted, .running, .waitingUser: 200
        }
    }

    private static func durationSeconds(_ task: OsaurusTask) -> TimeInterval {
        guard let started = task.startedAt else { return 0 }
        return max(0, (task.finishedAt ?? Date()).timeIntervalSince(started))
    }
}
