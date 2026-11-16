//
//  AgentTurnWorker.swift
//  osaurus
//
//  Runs an automation's agent turn: builds the dispatch request (prompt,
//  session key, folder, load intent), hands it to `BackgroundTaskManager`
//  under the task's admission, and waits for it to end. Channel agent
//  turns do not come here — `AgentChannelInboundRelay` owns those
//  (steering, reattach, reply delivery).
//

import Foundation

@MainActor
enum AgentTurnWorker: TaskWorker {
    /// nil when the target can run, otherwise the suppression reason.
    static func agentRejection(_ target: AgentDispatchTarget?, eventName: String) -> String? {
        guard let target else { return "agent_not_selected" }
        if case .local(let id) = target,
            Agent.rejectBuiltInForExternalSurface(id, source: "event/\(eventName)") != nil
        {
            return "agent_unavailable"
        }
        return nil
    }

    static func agentPrompt(event: OsaurusEvent, action: AgentEventAction, occurrence: EventOccurrence) -> String {
        if let prompt = occurrence.agentPrompt { return prompt }
        return wrappedPrompt(event: event, instructions: action.instructions, occurrence: occurrence)
    }

    /// The rendered instructions, then the trigger's untrusted content
    /// wrapped so the model reads it as data.
    static func wrappedPrompt(event: OsaurusEvent, instructions template: String, occurrence: EventOccurrence)
        -> String
    {
        let instructions = EventTemplate.render(template, payload: occurrence.payload)
        guard
            let untrusted = event.sourceKind.descriptor.untrustedContent(
                payload: occurrence.payload, eventName: event.name)
        else { return instructions }
        let wrapped = ChannelRemoteSafetyGate.wrapUntrustedContent(untrusted.content, source: untrusted.source)
        return instructions.isEmpty ? wrapped : instructions + "\n\n" + wrapped
    }

    static func sessionKey(event: OsaurusEvent, occurrence: EventOccurrence) -> (key: String, reattach: Bool) {
        let fresh = event.action.agent?.freshSessionPerFire ?? true
        if let conversation = occurrence.conversationKey, event.sourceKind.descriptor.usesConversationSessions {
            return ("\(event.id.uuidString):\(conversation)", true)
        }
        return (event.id.uuidString, !fresh)
    }

    /// Schedule and folder automations fire with nobody watching; a webhook
    /// or mail automation has a sender on the other end.
    static func isUnattended(event: OsaurusEvent, occurrence: EventOccurrence) -> Bool {
        !occurrence.isExternal && (event.sourceKind == .schedule || event.sourceKind == .folder)
    }

    /// Automation sessions persist as `.automation` with the kind beside it;
    /// a channel message stays a `.channel` conversation.
    static func persistedSource(_ kind: EventSourceKind) -> SessionSource {
        kind.sessionSource == .channel ? .channel : .automation
    }

    /// The run an agent event starts. A folder occurrence works in the
    /// watched folder; anything else uses the action's working folder.
    static func dispatchRequest(
        event: OsaurusEvent,
        action: AgentEventAction,
        occurrence: EventOccurrence,
        taskId: UUID = UUID()
    ) -> DispatchRequest {
        if let wake = SelfScheduleAutomations.dispatchRequest(event: event, occurrence: occurrence, taskId: taskId) {
            return wake
        }
        let key = sessionKey(event: event, occurrence: occurrence)
        return DispatchRequest(
            id: taskId,
            prompt: agentPrompt(event: event, action: action, occurrence: occurrence),
            target: action.target,
            title: event.name,
            parameters: event.parameters,
            folderPath: occurrence.folderPath ?? action.folderPath,
            folderBookmark: occurrence.folderPath != nil ? occurrence.folderBookmark : action.folderBookmark,
            source: persistedSource(event.sourceKind),
            automationKind: event.sourceKind,
            externalSessionKey: key.key,
            reattachSession: key.reattach,
            externalSurface: occurrence.isExternal,
            loadIntent: occurrence.loadIntent,
            unattended: isUnattended(event: event, occurrence: occurrence),
            queueId: event.delivery.queueId,
            taskOrigin: .automation,
            subscriptionId: event.id
        )
    }

    static func run(taskId: UUID, input: AutomationWorkInput, onStarted: TaskStartedHandler) async -> TaskOutcome {
        let event = input.event
        guard case .agent(let action) = event.action else {
            return TaskOutcome(status: .suppressed, reason: "not_an_agent_action")
        }
        if let rejection = agentRejection(action.target, eventName: event.name) {
            return TaskOutcome(status: .suppressed, reason: rejection)
        }
        let request = dispatchRequest(event: event, action: action, occurrence: input.occurrence, taskId: taskId)
        let manager = BackgroundTaskManager.shared
        guard let handle = await manager.dispatchChat(request, admittedTaskId: taskId) else {
            let refusal = action.target?.workspaceRef.flatMap { manager.consumeWorkspaceDispatchRefusal(for: $0) }
            return TaskOutcome(
                status: .failed, error: refusal ?? L("The agent could not accept the run."),
                reason: "dispatch_unavailable")
        }
        onStarted(handle.id, nil)
        switch await manager.awaitCompletion(handle.id) {
        case .completed(let sessionId):
            return TaskOutcome(status: .succeeded, sessionId: sessionId ?? handle.id)
        case .cancelled:
            return TaskOutcome(status: .cancelled, sessionId: handle.id)
        case .failed(let message):
            return TaskOutcome(status: .failed, sessionId: handle.id, error: message)
        }
    }
}
