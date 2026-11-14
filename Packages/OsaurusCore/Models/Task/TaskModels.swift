//
//  TaskModels.swift
//  osaurus
//
//  The task substrate: every unit of offloaded work (an automation's agent
//  turn or workflow run, a dispatched agent run, a spawned helper) is an
//  `OsaurusTask` on a `TaskQueue`, with an append-only journal of
//  `TaskEvent`s. See docs/TASK_QUEUE.md.
//

import Foundation

// MARK: - State

/// One status vocabulary for every kind of run.
public enum TaskState: String, Codable, Sendable, CaseIterable {
    case received
    case filtered
    case duplicate
    case queued
    case admitted
    case running
    case waitingUser = "waiting_user"
    case succeeded
    case failed
    case cancelled
    case suppressed
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .received, .queued, .admitted, .running, .waitingUser: false
        case .filtered, .duplicate, .succeeded, .failed, .cancelled, .suppressed, .interrupted: true
        }
    }

    /// The task actually started work.
    public var didRun: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .interrupted: true
        default: false
        }
    }

    /// Terminal states of tasks that ran: the "finished" history lists.
    public static let finishedStates: [TaskState] = allCases.filter(\.didRun)

    /// Admitted and holding (or about to hold) a slot.
    public var isActive: Bool {
        self == .admitted || self == .running || self == .waitingUser
    }

    public var displayName: String {
        switch self {
        case .received: L("Received")
        case .filtered: L("Filtered")
        case .duplicate: L("Duplicate")
        case .queued: L("Waiting")
        case .admitted: L("Starting")
        case .running: L("Running")
        case .waitingUser: L("Waiting on You")
        case .succeeded: L("Succeeded")
        case .failed: L("Failed")
        case .cancelled: L("Stopped")
        case .suppressed: L("Skipped")
        case .interrupted: L("Interrupted")
        }
    }
}

extension TaskState {
    public init(_ status: EventRunStatus) {
        switch status {
        case .received: self = .received
        case .filtered: self = .filtered
        case .duplicate: self = .duplicate
        case .queued: self = .queued
        case .running: self = .running
        case .awaitingUser: self = .waitingUser
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        case .suppressed: self = .suppressed
        }
    }

    public init(_ status: WorkflowRunStatus) {
        switch status {
        case .running: self = .running
        case .awaitingUser: self = .waitingUser
        case .completed: self = .succeeded
        case .failed, .needsSetup: self = .failed
        case .cancelled: self = .cancelled
        }
    }

    public init(_ status: BackgroundTaskStatus) {
        switch status {
        case .queued: self = .queued
        case .running: self = .running
        case .waitingForInput: self = .waitingUser
        case .completed: self = .succeeded
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }
}

extension EventRunStatus {
    /// The ledger status a task state projects to.
    public init(_ state: TaskState) {
        switch state {
        case .received: self = .received
        case .filtered: self = .filtered
        case .duplicate: self = .duplicate
        case .queued: self = .queued
        case .admitted, .running: self = .running
        case .waitingUser: self = .awaitingUser
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        case .cancelled, .interrupted: self = .cancelled
        case .suppressed: self = .suppressed
        }
    }
}

// MARK: - Attribution

/// Which door a task came through.
public enum TaskOrigin: String, Codable, Sendable, CaseIterable {
    case automation
    case selfSchedule = "self_schedule"
    case channel
    case spawn
    case workflowStep = "workflow_step"
    case apiDispatch = "api_dispatch"
    case plugin
    case manual
    case system

    public var displayName: String {
        switch self {
        case .automation: L("Automation")
        case .selfSchedule: L("Agent-scheduled")
        case .channel: L("Channel")
        case .spawn: L("Helper")
        case .workflowStep: L("Workflow")
        case .apiDispatch: L("API")
        case .plugin: L("Plugin")
        case .manual: L("Manual")
        case .system: L("System")
        }
    }

    /// The origin of a dispatched agent run, from its session source.
    public init(source: SessionSource) {
        switch source {
        case .schedule, .watcher, .webhook, .email, .automation: self = .automation
        case .selfSchedule: self = .selfSchedule
        case .channel: self = .channel
        case .delegation: self = .spawn
        case .http, .workspace: self = .apiDispatch
        case .plugin: self = .plugin
        case .chat, .imported: self = .manual
        }
    }
}

/// Who created a task or wrote a journal event.
public struct TaskActor: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case user, agent, workflow, system
        /// Someone other than the owner: a teammate, invite peer, remote
        /// agent or channel sender. `id` is their `Participant.key`.
        case participant
    }

    public var kind: Kind
    /// Agent or workflow id, or the system service's name.
    public var id: String?

    public init(kind: Kind, id: String? = nil) {
        self.kind = kind
        self.id = id
    }

    public static let user = TaskActor(kind: .user)
    public static func agent(_ id: UUID) -> TaskActor { TaskActor(kind: .agent, id: id.uuidString) }
    public static func workflow(_ id: UUID) -> TaskActor { TaskActor(kind: .workflow, id: id.uuidString) }
    public static func system(_ name: String) -> TaskActor { TaskActor(kind: .system, id: name) }
    /// The owner acting at this Mac is `.user`; anyone else is a participant.
    static func participant(_ p: Participant) -> TaskActor {
        switch p.kind {
        case .owner, .ownerDevice: return .user
        default: return TaskActor(kind: .participant, id: p.key)
        }
    }
}

public enum TaskPriorityClass: String, Codable, Sendable, CaseIterable {
    case high, normal, batch
}

// MARK: - Work

/// The durable description of what a task runs. The live payload (a
/// `DispatchRequest`, a workflow input) stays in memory with the worker.
public enum TaskWork: Codable, Sendable, Equatable {
    case agentTurn(AgentTurnWork)
    case workflowRun(WorkflowRunWork)
    case subagent(SubagentWork)

    public var kind: TaskWorkKind {
        switch self {
        case .agentTurn: .agentTurn
        case .workflowRun: .workflowRun
        case .subagent: .subagent
        }
    }

    public var agentId: UUID? {
        switch self {
        case .agentTurn(let work): work.agentId
        case .workflowRun: nil
        case .subagent(let work): work.agentId
        }
    }

    public var workflowID: UUID? {
        if case .workflowRun(let work) = self { return work.workflowID }
        return nil
    }

    /// An automation's "Ask a Model" run: an agent turn with no agent or
    /// target behind it.
    public var isModelAnswer: Bool {
        if case .agentTurn(let work) = self { return work.agentId == nil && work.targetKey == nil }
        return false
    }
}

public enum TaskWorkKind: String, Codable, Sendable, CaseIterable {
    case agentTurn = "agent_turn"
    case workflowRun = "workflow_run"
    case subagent

    public var displayName: String {
        switch self {
        case .agentTurn: L("Agent run")
        case .workflowRun: L("Workflow run")
        case .subagent: L("Helper")
        }
    }
}

public struct AgentTurnWork: Codable, Sendable, Equatable {
    public var agentId: UUID?
    /// Stable target key (`local:<uuid>`, a workspace address).
    public var targetKey: String?
    public var source: SessionSource
    public var externalSessionKey: String?

    public init(agentId: UUID?, targetKey: String? = nil, source: SessionSource, externalSessionKey: String? = nil) {
        self.agentId = agentId
        self.targetKey = targetKey
        self.source = source
        self.externalSessionKey = externalSessionKey
    }
}

public struct WorkflowRunWork: Codable, Sendable, Equatable {
    public var workflowID: UUID
    public var callerKind: String?

    public init(workflowID: UUID, callerKind: String? = nil) {
        self.workflowID = workflowID
        self.callerKind = callerKind
    }
}

public struct SubagentWork: Codable, Sendable, Equatable {
    public var agentId: UUID?
    public var parentSessionId: String?
    public var toolCallId: String?
    public var model: String?

    public init(agentId: UUID?, parentSessionId: String?, toolCallId: String?, model: String?) {
        self.agentId = agentId
        self.parentSessionId = parentSessionId
        self.toolCallId = toolCallId
        self.model = model
    }
}

// MARK: - Execution

/// What the resource arbiter reads.
public struct ResourceClaim: Codable, Sendable, Equatable {
    /// Resolved model id, when known.
    public var model: String?
    /// The model runs on this Mac (MLX), not a remote provider.
    public var isLocal: Bool
    public var estimatedBytes: Int64?
    /// Further local models the task loads (a workflow with several model
    /// slots). Absent in rows written before workflows claimed.
    public var additionalModels: [String]?
    /// The sandbox identity the task runs commands as: an agent's Linux
    /// name, or `wf-<template-id>` for a workflow that uses the sandbox.
    /// Absent when the task never touches the sandbox.
    public var sandboxMember: String?

    public init(
        model: String?, isLocal: Bool, estimatedBytes: Int64? = nil, additionalModels: [String]? = nil,
        sandboxMember: String? = nil
    ) {
        self.model = model
        self.isLocal = isLocal
        self.estimatedBytes = estimatedBytes
        self.additionalModels = additionalModels
        self.sandboxMember = sandboxMember
    }

    /// Every local model the task loads.
    public var localModels: [String] {
        guard isLocal, let model else { return [] }
        return [model] + (additionalModels ?? [])
    }

    public static let unknown = ResourceClaim(model: nil, isLocal: false)
}

/// A running task's liveness. Workers are in-process, so a missed
/// heartbeat means a hung run, not a crash.
public struct TaskLease: Codable, Sendable, Equatable {
    public var owner: String
    public var lastHeartbeatAt: Date
    public var leaseExpiresAt: Date

    public static let heartbeatInterval: TimeInterval = 15
    public static let staleAfter: TimeInterval = 60

    public init(owner: String, at now: Date = Date()) {
        self.owner = owner
        self.lastHeartbeatAt = now
        self.leaseExpiresAt = now.addingTimeInterval(Self.staleAfter)
    }

    public func isStale(at now: Date = Date()) -> Bool { now > leaseExpiresAt }

    public mutating func renew(at now: Date = Date()) {
        lastHeartbeatAt = now
        leaseExpiresAt = now.addingTimeInterval(Self.staleAfter)
    }
}

/// A finished task's small structured outcome, handed to follow-ups.
public struct TaskResult: Codable, Sendable, Equatable {
    public var summary: String?
    /// Ids of what the task produced (session, workflow run, artifacts).
    public var producedIds: [String]
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var costUSD: Double?

    public init(
        summary: String? = nil, producedIds: [String] = [], tokensIn: Int? = nil, tokensOut: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.summary = summary
        self.producedIds = producedIds
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costUSD = costUSD
    }
}

// MARK: - Task

public struct OsaurusTask: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var rootId: UUID
    public var parentId: UUID?
    public var depth: Int
    public var queueId: UUID
    /// The automation that started it.
    public var subscriptionId: UUID?
    public var origin: TaskOrigin
    public var createdBy: TaskActor
    public var work: TaskWork

    public var priorityClass: TaskPriorityClass
    public var orderingKey: String?
    public var idempotencyKey: String?

    public var state: TaskState
    public var attemptCount: Int
    public var lastError: String?
    public var reason: String?
    public var lease: TaskLease?
    public var progressNote: String?
    /// Why a queued task is not admitted yet (`foreground_active`, `paused`, `queue_full`).
    public var waitReason: String?
    public var claim: ResourceClaim?
    /// Bumped on every write; stale writers are refused.
    public var version: Int

    public var sessionId: UUID?
    /// The chat session whose turn started this task's tree (a helper, a
    /// background agent or a workflow run started from a chat). Unlike
    /// `sessionId`, not the session the task runs in.
    public var originSessionId: UUID?
    public var workflowRunId: UUID?
    public var result: TaskResult?
    /// Metadata only, never bodies.
    public var summary: [String: String]

    public var createdAt: Date
    public var queuedAt: Date?
    public var admittedAt: Date?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        rootId: UUID? = nil,
        parentId: UUID? = nil,
        depth: Int = 0,
        queueId: UUID = TaskQueue.defaultID,
        subscriptionId: UUID? = nil,
        origin: TaskOrigin,
        createdBy: TaskActor,
        work: TaskWork,
        priorityClass: TaskPriorityClass = .normal,
        orderingKey: String? = nil,
        idempotencyKey: String? = nil,
        state: TaskState = .received,
        claim: ResourceClaim? = nil,
        summary: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.rootId = rootId ?? id
        self.parentId = parentId
        self.depth = depth
        self.queueId = queueId
        self.subscriptionId = subscriptionId
        self.origin = origin
        self.createdBy = createdBy
        self.work = work
        self.priorityClass = priorityClass
        self.orderingKey = orderingKey
        self.idempotencyKey = idempotencyKey
        self.state = state
        self.attemptCount = 0
        self.claim = claim
        self.version = 0
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public var agentId: UUID? { work.agentId }

    /// A child inherits its parent's chat; a root takes the chat driving
    /// the execution that starts it.
    static func originSessionId(parent: OsaurusTask?, interactive: UUID?) -> UUID? {
        if let parent { return parent.originSessionId }
        return interactive
    }

    /// A running task whose heartbeat stopped.
    public func isStale(at now: Date = Date()) -> Bool {
        state == .running && (lease?.isStale(at: now) ?? false)
    }

    /// Failed with no retries left: counted in Needs you.
    public var needsAttention: Bool {
        state == .waitingUser || state == .failed
    }

    /// Moves to `state`, stamping the matching timestamp.
    public mutating func transition(to next: TaskState, at now: Date = Date()) {
        state = next
        updatedAt = now
        switch next {
        case .queued: queuedAt = queuedAt ?? now
        case .admitted: admittedAt = admittedAt ?? now
        case .running:
            admittedAt = admittedAt ?? now
            startedAt = startedAt ?? now
            waitReason = nil
        default:
            if next.isTerminal {
                finishedAt = finishedAt ?? now
                lease = nil
                waitReason = nil
            }
        }
    }
}

// MARK: - Journal

public enum TaskEventKind: String, Codable, Sendable, CaseIterable {
    case enqueued, admitted, leased, started, progress
    case toolCall = "tool_call"
    case modelLoadWait = "model_load_wait"
    case resourceWait = "resource_wait"
    case waitingUser = "waiting_user"
    case resumed
    case retryScheduled = "retry_scheduled"
    case childSpawned = "child_spawned"
    case finished, cancelled, error
    case timerFired = "timer_fired"
    case suppressed
    /// A person was asked to approve or answer something for this task.
    case approvalRequested = "approval_requested"
    /// That request was answered, timed out or withdrawn.
    case approvalResolved = "approval_resolved"

    public var displayName: String {
        switch self {
        case .enqueued: L("Queued")
        case .admitted: L("Admitted")
        case .leased: L("Picked up")
        case .started: L("Started")
        case .progress: L("Progress")
        case .toolCall: L("Tool call")
        case .modelLoadWait: L("Waiting for the model")
        case .resourceWait: L("Waiting")
        case .waitingUser: L("Waiting for you")
        case .resumed: L("Resumed")
        case .retryScheduled: L("Retry scheduled")
        case .childSpawned: L("Helper started")
        case .finished: L("Finished")
        case .cancelled: L("Stopped")
        case .error: L("Error")
        case .timerFired: L("Timer")
        case .suppressed: L("Skipped")
        case .approvalRequested: L("Waiting for your answer")
        case .approvalResolved: L("Answered")
        }
    }
}

public struct TaskEvent: Codable, Sendable, Identifiable, Equatable {
    public var taskId: UUID
    /// Per task, monotonic from 1.
    public var seq: Int
    public var at: Date
    public var kind: TaskEventKind
    public var actor: TaskActor?
    public var reason: String?
    public var data: [String: String]

    public var id: String { "\(taskId.uuidString)#\(seq)" }

    public init(
        taskId: UUID, seq: Int = 0, at: Date = Date(), kind: TaskEventKind, actor: TaskActor? = nil,
        reason: String? = nil, data: [String: String] = [:]
    ) {
        self.taskId = taskId
        self.seq = seq
        self.at = at
        self.kind = kind
        self.actor = actor
        self.reason = reason
        self.data = data
    }
}

// MARK: - Foreground reservations

/// Interactive work (a chat turn, an API client holding a connection) is
/// never queued; it takes a reservation the scheduler yields to.
public struct ForegroundReservation: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case chat, api
    }

    public let id: UUID
    /// Chat session id or API request id.
    public var owner: String
    public var kind: Kind
    public var model: String?
    public var isLocal: Bool
    public var estimatedBytes: Int64?
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: UUID = UUID(), owner: String, kind: Kind, model: String?, isLocal: Bool, estimatedBytes: Int64? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.owner = owner
        self.kind = kind
        self.model = model
        self.isLocal = isLocal
        self.estimatedBytes = estimatedBytes
        self.startedAt = startedAt
    }
}
