//
//  HarnessClarifyBridge.swift
//  osaurus
//
//  `clarify` for the Architect on a harness. The built-in tool only works
//  inside Osaurus's own loop, which pauses and takes the person's next
//  message as the answer; a harness waits on its tool call instead. So the
//  question goes on the open chat's question card, and the answer comes
//  back as the call's result.
//

import Foundation

enum HarnessClarifyBridge {
    static let toolName = "clarify"

    /// How long the card waits: under Claude Code's MCP tool timeout, so an
    /// answer given in time still reaches the harness.
    static let answerWindow: TimeInterval =
        TimeInterval(ClaudeCodeConfiguration.mcpToolTimeoutMilliseconds) / 1000 - 60

    /// The listing description: the built-in one promises the person's next
    /// message, which isn't how a harness gets the answer.
    static let description =
        "Ask the person a single critical question ONLY when the task is genuinely under-specified "
        + "— a required input is missing or contradictory and guessing wrong would change the result. "
        + "The question appears on the chat's question card and this call returns the person's answer. "
        + "For minor preferences, pick a sensible default and proceed. When the answer is one of a few "
        + "short choices (≤6), pass them as `options`; set `allowMultiple` only when more than one may "
        + "be picked."

    enum Outcome: Sendable, Equatable {
        case answered(String)
        case dismissed
        case noWindow
        case expired
    }

    /// Eval seam: answers in place of the person. Nil is "nobody answered".
    @MainActor static var answerOverride: (@MainActor (_ chatId: UUID, _ question: String) -> String?)?

    /// The question queue of the window showing the chat, or nil.
    @MainActor static var queue: @MainActor (UUID) -> PromptQueue? = { chatId in
        ChatWindowManager.shared.session(forSessionId: chatId)?.promptQueue
    }

    /// Validates like the built-in tool, asks, and returns the answer or a
    /// failure that tells the model how to continue.
    static func execute(chatId: UUID, argumentsJSON: String, window: TimeInterval = answerWindow) async -> String {
        let validation = (try? await ClarifyTool().execute(argumentsJSON: argumentsJSON)) ?? ""
        if ToolEnvelope.isError(validation) { return validation }
        guard let payload = ClarifyTool.parse(argumentsJSON: argumentsJSON) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`question` must be a non-empty string.", field: "question",
                tool: toolName)
        }
        switch await ask(chatId: chatId, payload: payload, window: window) {
        case .answered(let answer):
            return ToolEnvelope.success(tool: toolName, result: ["answer": answer])
        case .dismissed:
            return refusal(
                "The person closed the question without answering. Continue with a sensible default, or "
                    + "ask in a short plain reply and end your turn.")
        case .noWindow:
            return refusal(
                "No window shows this chat, so nobody can answer the question card. Ask in a short plain "
                    + "reply and end your turn.")
        case .expired:
            return refusal(
                "Nobody answered within \(Int(window / 60)) minutes and the question card closed. Ask in a "
                    + "short plain reply and end your turn.")
        }
    }

    private static func refusal(_ message: String) -> String {
        ToolEnvelope.failure(kind: .unavailable, message: message, tool: toolName, retryable: false)
    }

    @MainActor
    private final class Pending {
        var state: ClarifyPromptState?
        var continuation: CheckedContinuation<Outcome, Never>?

        func finish(_ outcome: Outcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    /// Waits on the card until it's answered, closed, or expires. Cancelling
    /// the task (Stop) takes the card down.
    @MainActor
    static func ask(chatId: UUID, payload: ClarifyPayload, window: TimeInterval) async -> Outcome {
        if let answerOverride {
            return answerOverride(chatId, payload.question).map(Outcome.answered) ?? .noWindow
        }
        guard let queue = queue(chatId) else { return .noWindow }
        let pending = Pending()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .dismissed)
                    return
                }
                pending.continuation = continuation
                let state = ClarifyPromptState(
                    question: payload.question,
                    options: payload.options,
                    allowMultiple: payload.allowMultiple,
                    expiresAt: Date().addingTimeInterval(window),
                    onSubmit: { pending.finish(.answered($0)) },
                    onCancel: { pending.finish(.dismissed) }
                )
                pending.state = state
                queue.enqueue(.clarify(state))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(window))
                    guard pending.continuation != nil else { return }
                    pending.finish(.expired)
                    queue.dismiss([ObjectIdentifier(state)])
                }
            }
        } onCancel: {
            Task { @MainActor in
                if let state = pending.state { queue.dismiss([ObjectIdentifier(state)]) }
                pending.finish(.dismissed)
            }
        }
    }
}
