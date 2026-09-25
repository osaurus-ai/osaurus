//
//  DelegationRecord.swift
//  osaurus
//
//  One row of the Orchestrator's Delegations list: a delegated worker run
//  (sent — `source: .delegation`) or a shared-agent run this Mac served for a
//  teammate (received — `source: .workspace` stamped with the caller). Built
//  from the persisted chat session plus, while it runs, the live background
//  task, so the list needs no second store.
//

import Foundation

public struct DelegationRecord: Identifiable, Sendable, Equatable {
    public enum Direction: String, Sendable {
        /// This Osaurus delegated the task (Orchestrator or custom agent).
        case sent
        /// A teammate's Osaurus ran one of this Mac's shared agents.
        case received
    }

    public enum Status: String, Sendable {
        case queued, running, waitingForInput, completed, failed, cancelled
    }

    /// The child session id (== the background task id).
    public let id: UUID
    public let direction: Direction
    /// Worker agent name (or the shared agent's name for received runs).
    public let agentName: String
    /// Workspace name when the run crossed a workspace relay.
    public let workspaceName: String?
    /// Caller label for received runs (teammate name / short wallet).
    public let callerLabel: String?
    /// The task, from the session title (`Delegated: …` prefix stripped).
    public let task: String
    public let status: Status
    public let startedAt: Date
    public let duration: TimeInterval
    public let completionTokens: Int?
    public let tokensPerSecond: Double?
    public let artifactCount: Int
    /// Whether the worker ended asking for input (`NEEDS INPUT:`).
    public let needsInput: Bool
    /// True while a live background task still drives the session.
    public let isLive: Bool

    public init(
        id: UUID,
        direction: Direction,
        agentName: String,
        workspaceName: String?,
        callerLabel: String?,
        task: String,
        status: Status,
        startedAt: Date,
        duration: TimeInterval,
        completionTokens: Int?,
        tokensPerSecond: Double?,
        artifactCount: Int,
        needsInput: Bool,
        isLive: Bool
    ) {
        self.id = id
        self.direction = direction
        self.agentName = agentName
        self.workspaceName = workspaceName
        self.callerLabel = callerLabel
        self.task = task
        self.status = status
        self.startedAt = startedAt
        self.duration = duration
        self.completionTokens = completionTokens
        self.tokensPerSecond = tokensPerSecond
        self.artifactCount = artifactCount
        self.needsInput = needsInput
        self.isLive = isLive
    }

    /// Strip the dispatcher's session-title prefix. Pure, for tests.
    static func taskTitle(from sessionTitle: String) -> String {
        let prefix = AgentDelegationDispatcher.titlePrefix
        if sessionTitle.hasPrefix(prefix) {
            return String(sessionTitle.dropFirst(prefix.count))
        }
        return sessionTitle
    }

    /// Build a record from a persisted session (turns loaded) and, when the
    /// run is still live, its background task status. Pure apart from the
    /// caller-supplied `agentName`, so the mapping is unit-testable.
    static func make(
        from session: ChatSessionData,
        direction: Direction,
        agentName: String,
        workspaceName: String?,
        liveStatus: BackgroundTaskStatus?
    ) -> DelegationRecord {
        let usage = AgentDelegationDispatcher.usageAccounting(for: session.turns)
        let outcome = AgentDelegationDispatcher.outcome(from: session, elapsed: 0)
        let status: Status
        var isLive = false
        if let liveStatus {
            isLive = liveStatus.isActive
            switch liveStatus {
            case .queued: status = .queued
            case .running: status = .running
            case .waitingForInput: status = .waitingForInput
            case .completed: status = .completed
            case .failed: status = .failed
            case .cancelled: status = .cancelled
            }
        } else {
            status = outcome == nil ? .failed : .completed
        }
        let end = isLive ? Date() : session.updatedAt
        return DelegationRecord(
            id: session.id,
            direction: direction,
            agentName: agentName,
            workspaceName: workspaceName,
            callerLabel: direction == .received ? session.workspace?.callerLabel : nil,
            task: taskTitle(from: session.title),
            status: status,
            startedAt: session.createdAt,
            duration: max(0, end.timeIntervalSince(session.createdAt)),
            completionTokens: usage.completionTokens,
            tokensPerSecond: usage.tokensPerSecond,
            artifactCount: AgentDelegationDispatcher.harvestArtifacts(from: session.turns).count,
            needsInput: outcome?.needsInput ?? false,
            isLive: isLive
        )
    }
}

/// Loads the Delegations list from the chat history DB + live tasks.
@MainActor
enum DelegationRecordLoader {
    /// Most recent `limit` records per direction, newest first.
    static func load(limit: Int = 40) -> (sent: [DelegationRecord], received: [DelegationRecord]) {
        let db = ChatHistoryDatabase.shared
        if !db.isOpen { try? db.open() }
        let sentMeta = db.loadMetadata(forAgent: nil, source: .delegation).prefix(limit)
        let receivedMeta = db.loadMetadata(forAgent: nil, source: .workspace)
            .filter { $0.workspace?.isServedForTeammate == true }
            .prefix(limit)
        let manager = BackgroundTaskManager.shared
        let agents = AgentManager.shared
        let rosters = WorkspaceRosterStore.shared.rosters

        func workspaceName(_ id: String?) -> String? {
            guard let id, !id.isEmpty else { return nil }
            return rosters.first { $0.id == id }?.workspace.name
        }

        var sent: [DelegationRecord] = []
        for meta in sentMeta {
            guard let session = db.loadSession(id: meta.id) else { continue }
            let name: String
            if let ws = session.workspace {
                name = AgentTargetResolver.displayName(
                    for: WorkspaceAgentRef(workspaceId: ws.workspaceId, agentAddress: ws.agentAddress)
                )
            } else if let agentId = session.agentId, let agent = agents.agent(for: agentId) {
                name = agent.name
            } else {
                name = L("Removed agent")
            }
            sent.append(
                DelegationRecord.make(
                    from: session,
                    direction: .sent,
                    agentName: name,
                    workspaceName: workspaceName(session.workspace?.workspaceId),
                    liveStatus: manager.taskState(for: session.id)?.status
                )
            )
        }
        var received: [DelegationRecord] = []
        for meta in receivedMeta {
            guard let session = db.loadSession(id: meta.id) else { continue }
            let name = session.agentId.flatMap { agents.agent(for: $0)?.name } ?? L("Shared agent")
            received.append(
                DelegationRecord.make(
                    from: session,
                    direction: .received,
                    agentName: name,
                    workspaceName: workspaceName(session.workspace?.workspaceId),
                    liveStatus: manager.taskState(for: session.id)?.status
                )
            )
        }
        return (sent, received)
    }
}
