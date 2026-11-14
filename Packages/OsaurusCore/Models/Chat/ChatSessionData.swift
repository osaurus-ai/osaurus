//
//  ChatSessionData.swift
//  osaurus
//
//  Persistable chat session model
//

import Foundation

/// Codable session data for persistence
public struct ChatSessionData: Codable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var selectedModel: String?
    public var turns: [ChatTurnData]
    /// The agent this session belongs to. nil = Default agent
    public var agentId: UUID?

    /// Where this session originated. Defaults to `.chat` for legacy rows.
    public var source: SessionSource
    /// The trigger kind when `source == .automation`, otherwise nil.
    public var automationKind: EventSourceKind?
    /// Plugin identifier when `source == .plugin`, otherwise nil.
    public var sourcePluginId: String?
    /// Stable external key (e.g. Telegram chat id, HTTP `X-Session-Id`) used
    /// to group multi-call conversations into a single session row.
    public var externalSessionKey: String?
    /// For `.plugin` / `.http` / `.schedule` / `.watcher` sessions that came
    /// in via `BackgroundTaskManager.dispatchChat`, this is the dispatch
    /// task UUID. Equal to `id` once `ExecutionContext` is taught to align
    /// the two (Phase 2 of the chat-sessions refactor).
    public var dispatchTaskId: UUID?
    /// User-set archive flag. Hidden from the default sidebar view, shown
    /// under the "Archived" filter chip.
    public var archived: Bool
    /// User-set pin flag. Pinned sessions float to the top of the sidebar
    /// list (within their current filter) so frequently-used chats stay
    /// reachable without searching.
    public var pinned: Bool
    /// Derived from turns at save time and persisted so the sidebar can
    /// render badges without loading every turn.
    public var capabilities: Set<SessionCapability>
    /// Security-scoped bookmark of this chat's working folder, nil when no
    /// folder is selected. Folder ownership is PER SESSION: each chat
    /// persists (and restores) its own folder independently.
    public var folderBookmark: Data?
    /// Non-sensitive display path of the working folder. Kept alongside the
    /// bookmark so the UI can show where the folder lived even when the
    /// bookmark has gone stale (folder moved/deleted).
    public var folderPath: String?
    /// LLM context-compaction summary covering the oldest turns, or nil
    /// when the session has never been compacted. See `ConversationSummary`.
    public var conversationSummary: ConversationSummary?
    /// The project this session belongs to. nil = not in any project.
    /// Orthogonal to `agentId`: a project can group chats across agents.
    public var projectId: UUID?
    /// Workspace (team) identity when this chat is with — or was served for —
    /// a shared agent. nil for ordinary local chats. See
    /// `WorkspaceSessionContext` for the client/host split.
    public var workspace: WorkspaceSessionContext?
    /// Workflow calls a Work Mode task was waiting on when it was saved.
    /// Their runs resume on relaunch; a reopened chat picks them up again.
    public var parkedWorkflowRuns: [ParkedWorkflowCall]
    /// The Orchestrator's session state (goal, decisions, facts, open items,
    /// in-flight runs). Nil for chats that never wrote one.
    public var sessionState: SessionState?
    /// Sync device id of the Mac that runs this chat's agent when it isn't
    /// this one; `agentId` then names that Mac's agent. Nil = this device.
    public var hostDevice: String?
    /// Sync device id of the Mac that served this `.workspace` chat, from the
    /// conversation's `servedBy` tag. Never encoded: only that Mac writes it.
    public var servedBy: String?

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        selectedModel: String? = nil,
        turns: [ChatTurnData] = [],
        agentId: UUID? = nil,
        source: SessionSource = .chat,
        automationKind: EventSourceKind? = nil,
        sourcePluginId: String? = nil,
        externalSessionKey: String? = nil,
        dispatchTaskId: UUID? = nil,
        archived: Bool = false,
        pinned: Bool = false,
        capabilities: Set<SessionCapability> = [],
        folderBookmark: Data? = nil,
        folderPath: String? = nil,
        conversationSummary: ConversationSummary? = nil,
        projectId: UUID? = nil,
        workspace: WorkspaceSessionContext? = nil,
        parkedWorkflowRuns: [ParkedWorkflowCall] = [],
        sessionState: SessionState? = nil,
        hostDevice: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.selectedModel = selectedModel
        self.turns = turns
        self.agentId = agentId
        self.source = source
        self.automationKind = source == .automation ? automationKind : nil
        self.sourcePluginId = sourcePluginId
        self.externalSessionKey = externalSessionKey
        self.dispatchTaskId = dispatchTaskId
        self.archived = archived
        self.pinned = pinned
        self.capabilities = capabilities
        self.folderBookmark = folderBookmark
        self.folderPath = folderPath
        self.conversationSummary = conversationSummary
        self.projectId = projectId
        self.workspace = workspace
        self.parkedWorkflowRuns = parkedWorkflowRuns
        self.sessionState = sessionState
        self.hostDevice = hostDevice
    }

    // Custom decoder for backward compatibility with old sessions
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel)
        turns = try container.decode([ChatTurnData].self, forKey: .turns)
        agentId =
            try container.decodeIfPresent(UUID.self, forKey: .agentId)
            ?? container.decodeIfPresent(UUID.self, forKey: .personaId)
        source = try container.decodeIfPresent(SessionSource.self, forKey: .source) ?? .chat
        automationKind =
            source == .automation
            ? (try? container.decodeIfPresent(EventSourceKind.self, forKey: .automationKind)) : nil
        sourcePluginId = try container.decodeIfPresent(String.self, forKey: .sourcePluginId)
        externalSessionKey = try container.decodeIfPresent(String.self, forKey: .externalSessionKey)
        dispatchTaskId = try container.decodeIfPresent(UUID.self, forKey: .dispatchTaskId)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        capabilities = try container.decodeIfPresent(Set<SessionCapability>.self, forKey: .capabilities) ?? []
        folderBookmark = try container.decodeIfPresent(Data.self, forKey: .folderBookmark)
        folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)
        conversationSummary = try container.decodeIfPresent(
            ConversationSummary.self, forKey: .conversationSummary)
        projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        workspace = try container.decodeIfPresent(WorkspaceSessionContext.self, forKey: .workspace)
        parkedWorkflowRuns =
            try container.decodeIfPresent([ParkedWorkflowCall].self, forKey: .parkedWorkflowRuns) ?? []
        sessionState = try? container.decodeIfPresent(SessionState.self, forKey: .sessionState)
        hostDevice = try container.decodeIfPresent(String.self, forKey: .hostDevice)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(selectedModel, forKey: .selectedModel)
        try container.encode(turns, forKey: .turns)
        try container.encodeIfPresent(agentId, forKey: .agentId)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(automationKind, forKey: .automationKind)
        try container.encodeIfPresent(sourcePluginId, forKey: .sourcePluginId)
        try container.encodeIfPresent(externalSessionKey, forKey: .externalSessionKey)
        try container.encodeIfPresent(dispatchTaskId, forKey: .dispatchTaskId)
        try container.encode(archived, forKey: .archived)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(folderBookmark, forKey: .folderBookmark)
        try container.encodeIfPresent(folderPath, forKey: .folderPath)
        try container.encodeIfPresent(conversationSummary, forKey: .conversationSummary)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encodeIfPresent(workspace, forKey: .workspace)
        if !parkedWorkflowRuns.isEmpty { try container.encode(parkedWorkflowRuns, forKey: .parkedWorkflowRuns) }
        try container.encodeIfPresent(sessionState, forKey: .sessionState)
        try container.encodeIfPresent(hostDevice, forKey: .hostDevice)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, selectedModel, turns, agentId
        case personaId  // legacy key for migration
        case source, automationKind, sourcePluginId, externalSessionKey, dispatchTaskId
        case archived
        case pinned
        case capabilities
        case folderBookmark, folderPath
        case conversationSummary
        case projectId
        case workspace
        case parkedWorkflowRuns
        case sessionState
        case hostDevice
    }

    /// Lowercased team-agent address when this is a chat with (or served for)
    /// a shared agent; nil for local chats.
    public var remoteAgentAddress: String? { workspace?.agentAddress }

    /// See `SessionSource.runtimeSource(automationKind:)`.
    public var runtimeSource: SessionSource { source.runtimeSource(automationKind: automationKind) }

    /// Field-wise equality for list rows. Must cover every stored property;
    /// `turns` compares by count because list rows carry none.
    func sameListRow(as other: ChatSessionData) -> Bool {
        id == other.id && title == other.title && createdAt == other.createdAt
            && updatedAt == other.updatedAt && selectedModel == other.selectedModel
            && turns.count == other.turns.count && agentId == other.agentId
            && source == other.source && automationKind == other.automationKind
            && sourcePluginId == other.sourcePluginId && externalSessionKey == other.externalSessionKey
            && dispatchTaskId == other.dispatchTaskId && archived == other.archived
            && pinned == other.pinned && capabilities == other.capabilities
            && folderBookmark == other.folderBookmark && folderPath == other.folderPath
            && conversationSummary == other.conversationSummary && projectId == other.projectId
            && workspace == other.workspace && parkedWorkflowRuns == other.parkedWorkflowRuns
            && sessionState == other.sessionState && hostDevice == other.hostDevice
            && servedBy == other.servedBy
    }

    static func sameListRows(_ lhs: [ChatSessionData], _ rhs: [ChatSessionData]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.sameListRow(as: $1) }
    }
}

extension ChatSessionData {
    /// Sessions the teammate had with a shared agent (client side). Host-side
    /// rows served for a teammate are excluded — those belong to the local
    /// shared agent's history, tagged with the caller.
    public var isWorkspaceAgentChat: Bool {
        guard let workspace else { return false }
        return !workspace.isServedForTeammate
    }

    /// The Mac that served this chat when it isn't `me`.
    func servedElsewhere(me: String?) -> String? {
        guard let servedBy, !servedBy.isEmpty, servedBy != me else { return nil }
        return servedBy
    }

    /// Generate a title from the first user message. Dispatch envelopes
    /// (channel wrapper, delegation contract, …) are stripped first so a
    /// machine header can never become the chat title; `source` (the
    /// runtime source) gates the marker-less watcher framing.
    public static func generateTitle(from turns: [ChatTurnData], source: SessionSource = .chat) -> String {
        guard let firstUserTurn = turns.first(where: { $0.role == .user }) else {
            return "New Chat"
        }
        let content = firstUserTurn.displayContent(sessionSource: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            return "New Chat"
        }
        // Take first line and truncate to reasonable length
        let firstLine = content.components(separatedBy: .newlines).first ?? content
        if firstLine.count <= 50 {
            return firstLine
        }
        return String(firstLine.prefix(47)) + "..."
    }
}
