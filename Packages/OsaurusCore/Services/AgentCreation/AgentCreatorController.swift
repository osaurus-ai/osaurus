//
//  AgentCreatorController.swift
//  osaurus
//
//  The New Agent creator on Settings' Agents page: a Configurator chat that
//  lives outside any chat window. It stays alive while the person looks
//  elsewhere in Settings, and its draft can be picked up again after a
//  relaunch.
//

import Foundation

@MainActor
final class AgentCreatorController: ObservableObject {
    static let shared = AgentCreatorController()

    /// The creator's chat, until it is closed, discarded or creates its agent.
    @Published private(set) var chat: ChatWindowState?
    /// Whether the Agents page shows the creator rather than its list.
    @Published var isShowing = false

    private init() {}

    /// The open chat's draft, until it is created.
    var openDraft: AgentDraft? {
        guard let draft = AgentDraftStore.shared.draft(forSession: chat?.session.sessionId?.uuidString),
            !draft.isCreated
        else { return nil }
        return draft
    }

    /// The draft the Agents page offers to continue: the open one, else the
    /// newest one left with something in it.
    var resumableDraft: AgentDraft? {
        openDraft ?? AgentDraftStore.shared.unfinishedDrafts.first
    }

    /// Shows the creator. Without a `brief` it continues the draft in
    /// progress; a `brief` starts a fresh one and is sent first when a
    /// model can answer.
    func open(brief: String?, source: AgentCreatorLauncher.Source) {
        let brief = brief?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if brief.isEmpty, let draft = resumableDraft {
            resume(draft)
        } else {
            startFresh(brief: brief)
            FeatureTelemetry.agentCreationStarted(source: source.rawValue)
        }
        isShowing = true
    }

    /// Continues `draft`, reopening its chat when it isn't the one on screen.
    func resume(_ draft: AgentDraft) {
        if openDraft?.id == draft.id { isShowing = true; return }
        let sessionId = draft.sessionID.flatMap(UUID.init(uuidString:))
        let saved = sessionId.flatMap(ChatSessionStore.load(id:))
        let state = ChatWindowState(windowId: UUID(), agentId: Agent.configuratorId, sessionData: saved)
        if saved == nil {
            // The chat was never saved: open on the draft with a new opening.
            let id = sessionId ?? UUID()
            if draft.sessionID == nil { AgentDraftStore.shared.bind(draft.id, to: id.uuidString) }
            state.session.sessionId = id
            state.session.createdAt = Date()
            AgentCreatorLauncher.start(in: state.session)
            AgentCreatorLauncher.retitle(sessionId: id, name: draft.agent.name)
        }
        replaceChat(with: state)
        isShowing = true
    }

    /// Back to the Agents list; the chat and its draft wait.
    func hide() { isShowing = false }

    /// Drops the draft in progress (`draft`, or the open one) and its chat.
    func discard(_ draft: AgentDraft? = nil) {
        guard let draft = draft ?? openDraft else { return }
        if openDraft?.id == draft.id { closeChat() }
        AgentDraftStore.shared.delete(draft.id)
        FeatureTelemetry.agentCreationAbandoned(touchedFields: draft.touched.count)
        isShowing = false
    }

    /// The draft became an agent: close the creator and forget the draft.
    func finish() {
        let draft = AgentDraftStore.shared.draft(forSession: chat?.session.sessionId?.uuidString)
        closeChat()
        if let draft, draft.isCreated { AgentDraftStore.shared.delete(draft.id) }
        isShowing = false
    }

    private func startFresh(brief: String) {
        let state = ChatWindowState(windowId: UUID(), agentId: Agent.configuratorId)
        AgentCreatorLauncher.start(in: state.session)
        replaceChat(with: state)
        if !brief.isEmpty, state.session.hasAnyModel || state.session.isDiscoveringModels {
            state.session.send(brief)
        }
    }

    private func replaceChat(with state: ChatWindowState) {
        closeChat()
        chat = state
    }

    /// Stops and saves the chat. A draft nobody put anything in goes with it.
    private func closeChat() {
        guard let chat else { return }
        if let draft = AgentDraftStore.shared.draft(forSession: chat.session.sessionId?.uuidString),
            !draft.isCreated, draft.isEmpty
        {
            AgentDraftStore.shared.delete(draft.id)
        }
        chat.cleanup()
        self.chat = nil
    }
}
