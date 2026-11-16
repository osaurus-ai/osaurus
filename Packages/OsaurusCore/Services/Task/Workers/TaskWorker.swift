//
//  TaskWorker.swift
//  osaurus
//
//  A worker runs one admitted task's work and reports how it ended.
//

import Foundation

/// How a task's work ended, as its worker reports it.
public struct TaskOutcome: Error, Sendable, Equatable {
    public var status: TaskState
    public var sessionId: UUID?
    public var workflowRunId: UUID?
    public var error: String?
    public var reason: String?
    public var summary: [String: String]

    public init(
        status: TaskState, sessionId: UUID? = nil, workflowRunId: UUID? = nil, error: String? = nil,
        reason: String? = nil, summary: [String: String] = [:]
    ) {
        self.status = status
        self.sessionId = sessionId
        self.workflowRunId = workflowRunId
        self.error = error
        self.reason = reason
        self.summary = summary
    }
}

/// Called once the work has an id to show (chat session or workflow run).
public typealias TaskStartedHandler = @MainActor (_ sessionId: UUID?, _ workflowRunId: UUID?) -> Void

@MainActor
protocol TaskWorker {
    associatedtype Input
    /// Runs the work for `taskId`; the task already holds its slots.
    static func run(taskId: UUID, input: Input, onStarted: TaskStartedHandler) async -> TaskOutcome
}

/// What an automation hands its worker.
struct AutomationWorkInput {
    var event: OsaurusEvent
    var occurrence: EventOccurrence
}

@MainActor
enum AutomationWorker {
    /// Runs an automation's action: an agent turn, a workflow run, or one
    /// tool-less model answer.
    static func run(taskId: UUID, event: OsaurusEvent, occurrence: EventOccurrence, onStarted: TaskStartedHandler)
        async -> TaskOutcome
    {
        let input = AutomationWorkInput(event: event, occurrence: occurrence)
        switch event.action {
        case .agent:
            return await AgentTurnWorker.run(taskId: taskId, input: input, onStarted: onStarted)
        case .workflow:
            return await WorkflowRunWorker.run(taskId: taskId, input: input, onStarted: onStarted)
        case .prompt:
            return await PromptRunWorker.run(taskId: taskId, input: input, onStarted: onStarted)
        }
    }
}
