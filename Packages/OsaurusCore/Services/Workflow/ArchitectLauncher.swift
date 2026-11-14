//
//  ArchitectLauncher.swift
//  osaurus
//
//  Opens the Architect in a chat, with a draft bound to that chat: empty
//  for a new workflow and Orchestrator handoffs, or seeded from a
//  template for "Edit with the Architect" and for picking a workflow in an
//  Architect chat's Workflows lens. A brief, when given, is sent as the
//  first message.
//

import Foundation

@MainActor
enum ArchitectLauncher {
    @discardableResult
    static func open(template: Template? = nil) -> Bool {
        let manager = ChatWindowManager.shared
        let windowID: UUID
        if let focused = manager.lastFocusedWindowId, let state = manager.windowState(id: focused)
        {
            windowID = focused
            state.newTab(agentId: Agent.architectId)
            manager.showWindow(id: focused)
        } else {
            windowID = manager.createWindow(agentId: Agent.architectId)
        }
        guard let state = manager.windowState(id: windowID) else { return false }
        defer { state.showWorkflowDetail() }
        guard let sessionID = ensureSessionID(state.session) else { return false }
        if template != nil || WorkflowDraftStore.shared.draft(forSession: sessionID) == nil {
            seed(sessionID: sessionID, from: template)
        }
        state.showInspector(.draft)
        return true
    }

    /// Edit `workflow` with the Architect in `state`'s window. The latest
    /// Architect chat that built or edited it opens with its history, its
    /// draft brought up to the saved version when that is newer; a workflow
    /// no saved chat has touched starts a new Architect chat. The inspector
    /// switches to the draft.
    static func edit(_ workflow: InstalledWorkflow, in state: ChatWindowState) {
        defer { state.showWorkflowDetail() }
        let drafts = WorkflowDraftStore.shared
        defer { state.showInspector(.draft) }
        if state.agentId == Agent.architectId, state.activeTab?.workflowID == nil,
            let current = drafts.draft(forSession: state.session.sessionId?.uuidString),
            current.templateID == workflow.templateID
        {
            drafts.rebase(current.id, onto: workflow.template)
            return
        }
        if let draft = drafts.drafts(templateID: workflow.templateID).first {
            drafts.rebase(draft.id, onto: workflow.template)
            resume(draft, in: state)
            return
        }
        discardUntouchedDraft(in: state)
        state.startNewChat(with: Agent.architectId)
        guard let sessionID = ensureSessionID(state.session) else { return }
        seed(sessionID: sessionID, from: workflow.template)
    }

    /// The most recent saved Architect chat whose draft edits `workflow`.
    static func earlierChat(editing workflow: InstalledWorkflow) -> (WorkflowDraft, ChatSessionData)? {
        for draft in WorkflowDraftStore.shared.drafts(templateID: workflow.templateID) {
            guard let id = draft.sessionID.flatMap(UUID.init(uuidString:)),
                let chat = ChatSessionsManager.shared.session(for: id),
                chat.agentId == Agent.architectId
            else { continue }
            return (draft, chat)
        }
        return nil
    }

    /// "Fix with the Architect" on a failed run: opens the workflow for
    /// editing, hands the run to the draft so `workflow_runs` and
    /// `workflow_test` `from_run` default to it, and sends the brief, so the
    /// Architect starts reading the run and proposing a fix right away.
    static func repair(_ run: WorkflowRun, of workflow: InstalledWorkflow, in state: ChatWindowState) {
        edit(workflow, in: state)
        guard let sessionID = ensureSessionID(state.session),
            let draft = WorkflowDraftStore.shared.draft(forSession: sessionID)
        else { return }
        let drafts = WorkflowDraftStore.shared
        drafts.setRepairRun(draft.id, runID: run.id)
        drafts.notePending(draft.id, WorkflowRepairBrief.note(run, workflow: workflow))
        state.session.send(WorkflowRepairBrief.message(run, definition: workflow.definition))
    }

    /// The same, from outside a chat window (the Workflows library): the
    /// last focused chat window comes forward, or a new one opens.
    static func repair(_ run: WorkflowRun, of workflow: InstalledWorkflow) {
        let manager = ChatWindowManager.shared
        let windowID =
            manager.lastFocusedWindowId.flatMap { manager.windowState(id: $0) == nil ? nil : $0 }
            ?? manager.createWindow(agentId: Agent.architectId)
        guard let state = manager.windowState(id: windowID) else { return }
        manager.showWindow(id: windowID)
        repair(run, of: workflow, in: state)
    }

    /// "Revise with Architect" on a change request from store review: opens
    /// the workflow for editing (its saved template when it isn't installed
    /// here), tells the draft why, and sends the reviewer's message as the
    /// brief. Saving offers Resubmit for Review. False when the template
    /// isn't on this Mac.
    @discardableResult
    static func revise(templateID: UUID, name: String, review: WorkflowsRegistryReview) -> Bool {
        let brief = PublishReviewBrief.message(name: name, review: review)
        let note = PublishReviewBrief.note(name: name, review: review)
        guard let workflow = InstalledWorkflowStore.shared.workflow(templateID: templateID) else {
            guard let template = TemplateStore.shared.allTemplates(kind: .workflow).first(where: { $0.id == templateID })
            else { return false }
            guard open(template: template) else { return false }
            if let state = ChatWindowManager.shared.lastFocusedWindowId.flatMap(ChatWindowManager.shared.windowState(id:)),
                let draft = WorkflowDraftStore.shared.draft(forSession: state.session.sessionId?.uuidString)
            {
                WorkflowDraftStore.shared.notePending(draft.id, note)
                state.session.send(brief)
            }
            return true
        }
        let manager = ChatWindowManager.shared
        let windowID =
            manager.lastFocusedWindowId.flatMap { manager.windowState(id: $0) == nil ? nil : $0 }
            ?? manager.createWindow(agentId: Agent.architectId)
        guard let state = manager.windowState(id: windowID) else { return false }
        manager.showWindow(id: windowID)
        edit(workflow, in: state)
        if let sessionID = ensureSessionID(state.session),
            let draft = WorkflowDraftStore.shared.draft(forSession: sessionID)
        {
            WorkflowDraftStore.shared.notePending(draft.id, note)
        }
        state.session.send(brief)
        return true
    }

    /// A fresh, empty draft in a new Architect chat.
    static func newWorkflow(in state: ChatWindowState) {
        defer { state.showWorkflowDetail() }
        defer { state.showInspector(.draft) }
        discardUntouchedDraft(in: state)
        state.startNewChat(with: Agent.architectId)
        guard let sessionID = ensureSessionID(state.session) else { return }
        seed(sessionID: sessionID, from: nil)
    }

    /// Resume the conversation already owned by this draft. A blank draft
    /// may not have a persisted chat yet; retain its identity in that case.
    static func resume(_ draft: WorkflowDraft, in state: ChatWindowState) {
        defer { state.showWorkflowDetail() }
        if let id = draft.sessionID.flatMap(UUID.init(uuidString:)) {
            if let tab = state.tabs.first(where: { $0.session.sessionId == id }) {
                state.selectTab(id: tab.id)
                return
            }
            if let chat = ChatSessionsManager.shared.session(for: id) {
                state.loadSession(chat)
                return
            }
        }
        state.newTab(agentId: Agent.architectId)
        state.session.sessionId = draft.sessionID.flatMap(UUID.init(uuidString:)) ?? UUID()
        state.session.createdAt = draft.createdAt
        if let id = state.session.sessionId { WorkflowDraftStore.shared.bind(draft.id, to: id.uuidString) }
    }

    /// A blank Architect chat is reused for the next pick; its draft goes
    /// with it when nobody changed it.
    private static func discardUntouchedDraft(in state: ChatWindowState) {
        guard state.agentId == Agent.architectId, state.activeTab?.workflowID == nil,
            state.session.turns.isEmpty,
            let draft = WorkflowDraftStore.shared.draft(forSession: state.session.sessionId?.uuidString),
            draft.history.isEmpty, draft.testRunIDs.isEmpty
        else { return }
        WorkflowDraftStore.shared.delete(draft.id)
    }

    private static func ensureSessionID(_ session: ChatSession) -> String? {
        if session.sessionId == nil {
            session.sessionId = UUID()
            session.createdAt = Date()
        }
        return session.sessionId?.uuidString
    }

    static func seed(sessionID: String, from template: Template?) {
        let draft = WorkflowDraftStore.shared.create(sessionID: sessionID, from: template)
        if let template, let version = draft.baseVersion {
            WorkflowDraftStore.shared.notePending(
                draft.id,
                "The user opened their saved workflow \"\(template.name)\" (version \(version)) to change it. "
                    + "The draft holds it as saved; change only what they ask for.")
        }
    }
}
