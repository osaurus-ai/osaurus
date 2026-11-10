//
//  AgentCreatorLauncher.swift
//  osaurus
//
//  Opens a New Agent chat: a Configurator chat with an empty draft bound
//  to it. Settings hosts it on the Agents page (`AgentCreatorController`):
//  an intro asks what the agent should do, then the agent takes shape
//  beside the conversation; only its Create button saves anything.
//

import Foundation

@MainActor
enum AgentCreatorLauncher {
    enum Source: String {
        case agentsPage = "agents_page"
        case sidebar
        case discovery
    }

    /// Opens the New Agent creator in Settings → Agents, continuing the
    /// draft in progress unless a `brief` asks for a fresh one.
    static func open(brief: String? = nil, source: Source = .agentsPage) {
        AgentCreatorController.shared.open(brief: brief, source: source)
        AppDelegate.shared?.showManagementWindow(initialTab: .agents)
    }

    /// A live session showing `sessionId`: a chat window's, or the creator's.
    static func liveSessions(_ sessionId: UUID) -> [ChatSession] {
        var sessions = ChatWindowManager.shared.sessions(forSessionId: sessionId)
        if let creator = AgentCreatorController.shared.chat?.session, creator.sessionId == sessionId {
            sessions.append(creator)
        }
        return sessions
    }

    /// Binds a fresh draft to `session`.
    static func start(in session: ChatSession) {
        if session.sessionId == nil {
            session.sessionId = UUID()
            session.createdAt = Date()
        }
        guard let sessionID = session.sessionId?.uuidString else { return }
        if AgentDraftStore.shared.draft(forSession: sessionID) == nil {
            AgentDraftStore.shared.create(sessionID: sessionID)
        }
        session.title = L("New Agent")
    }

    /// Titles the creation chat after the draft ("New agent: Trip
    /// Planner"). The next turn's save persists it.
    static func retitle(sessionId: UUID?, name: String) {
        guard let sessionId else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? L("New Agent") : L("New agent: \(name)")
        for session in liveSessions(sessionId) where session.title != title {
            session.title = title
        }
    }

    /// Titles the creation chat after the agent it made and saves it.
    static func noteCreated(_ agent: Agent, sessionId: UUID?) {
        retitle(sessionId: sessionId, name: agent.name)
        guard let sessionId else { return }
        for session in liveSessions(sessionId) { session.save() }
    }

    /// A closed New Agent tab whose draft was never created.
    static func noteClosed(_ session: ChatSession) {
        guard session.agentId == Agent.configuratorId,
            let draft = AgentDraftStore.shared.draft(forSession: session.sessionId?.uuidString), !draft.isCreated
        else { return }
        FeatureTelemetry.agentCreationAbandoned(touchedFields: draft.touched.count)
    }

    /// What a starter sends: the template's name and one-line job.
    static func starterBrief(_ template: AgentStarterTemplate) -> String {
        "\(template.label): \(template.tagline)"
    }
}
