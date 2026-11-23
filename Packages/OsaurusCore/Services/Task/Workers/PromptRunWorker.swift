//
//  PromptRunWorker.swift
//  osaurus
//
//  Runs an automation's "Ask a Model" action: one generation with no tools
//  and no agent, saved as an automation chat. The trigger's content goes
//  in wrapped as untrusted, exactly as it does for an agent turn.
//

import Foundation

@MainActor
enum PromptRunWorker: TaskWorker {
    /// What the model returned: its visible answer and the reasoning it
    /// streamed on the separate channel, kept for the chat's thinking block.
    struct Answer: Sendable {
        var content: String
        var reasoning: String = ""
    }

    /// The answer to one prompt, injectable for tests.
    typealias Generate = @Sendable (_ model: String, _ messages: [ChatMessage], _ source: RequestSource) async throws
        -> Answer

    static let liveGenerate: Generate = { model, messages, source in
        let engine = ChatEngine(source: source, activitySource: source, privacyReviewMode: .autoScrub)
        var request = ChatCompletionRequest(
            model: model, messages: messages, temperature: nil, max_tokens: nil, stream: false,
            top_p: nil, frequency_penalty: nil, presence_penalty: nil, stop: nil, n: nil,
            tools: nil, tool_choice: nil, session_id: nil)
        request.samplingParametersAreImplicit = true
        let response = try await engine.completeChat(request: request)
        let message = response.choices.first?.message
        return Answer(content: message?.content ?? "", reasoning: message?.reasoning_content ?? "")
    }

    /// The action's model, else the default model for new agents, else the
    /// Default agent's model.
    static func resolvedModel(_ action: PromptEventAction) -> String? {
        let chosen = action.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let chosen, !chosen.isEmpty { return chosen }
        return ChatConfigurationStore.load().defaultModel ?? DefaultAgentConfigurationStore.load().defaultModel
    }

    static func prompt(event: OsaurusEvent, action: PromptEventAction, occurrence: EventOccurrence) -> String {
        AgentTurnWorker.wrappedPrompt(event: event, instructions: action.instructions, occurrence: occurrence)
    }

    static func run(taskId: UUID, input: AutomationWorkInput, onStarted: TaskStartedHandler) async -> TaskOutcome {
        await run(taskId: taskId, input: input, onStarted: onStarted, generate: liveGenerate)
    }

    static func run(
        taskId: UUID, input: AutomationWorkInput, onStarted: TaskStartedHandler, generate: Generate
    ) async -> TaskOutcome {
        let event = input.event
        guard case .prompt(let action) = event.action else {
            return TaskOutcome(status: .suppressed, reason: "not_a_prompt_action")
        }
        guard let model = resolvedModel(action) else {
            return TaskOutcome(
                status: .failed, error: L("Choose a model for \(event.name), or set a default model for new agents."),
                reason: "model_not_selected")
        }
        let prompt = prompt(event: event, action: action, occurrence: input.occurrence)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TaskOutcome(status: .failed, error: L("\(event.name) has nothing to ask."), reason: "empty_prompt")
        }

        let requestedAt = Date()
        var session = ChatSessionData(
            title: event.name,
            selectedModel: model,
            turns: [ChatTurnData(role: .user, content: prompt, createdAt: requestedAt)],
            source: .automation,
            automationKind: event.sourceKind,
            externalSessionKey: event.id.uuidString,
            dispatchTaskId: taskId
        )
        save(session)
        onStarted(session.id, nil)

        do {
            let answer = try await generate(
                model, [ChatMessage(role: "user", content: prompt)], event.sourceKind.descriptor.requestSource)
            try Task.checkCancellation()
            session.turns.append(
                ChatTurnData(
                    role: .assistant, content: answer.content, thinking: answer.reasoning, createdAt: requestedAt,
                    completedAt: Date()))
            session.updatedAt = Date()
            save(session)
            return TaskOutcome(status: .succeeded, sessionId: session.id, summary: ["model": model])
        } catch is CancellationError {
            return TaskOutcome(status: .cancelled, sessionId: session.id)
        } catch {
            return TaskOutcome(
                status: Task.isCancelled ? .cancelled : .failed, sessionId: session.id,
                error: error.localizedDescription, summary: ["model": model])
        }
    }

    private static func save(_ session: ChatSessionData) {
        ChatSessionStore.save(session)
        NotificationCenter.default.post(
            name: ChatHistoryWriter.didPersistExternallyNotification, object: nil,
            userInfo: ["sessionId": session.id])
    }
}
