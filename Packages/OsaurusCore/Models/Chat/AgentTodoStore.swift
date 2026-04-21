//
//  AgentTodoStore.swift
//  osaurus
//
//  Per-session in-memory store for the agent's `todo` markdown.
//
//  The agent's `todo` tool writes here; the chat session subscribes to
//  `.agentTodoChanged` notifications and mirrors into `@Published`
//  state for the inline UI block.
//

import Foundation

extension Notification.Name {
    /// Posted when the agent's todo for a session is created or
    /// replaced. `userInfo["sessionId"]` is the chat session id (String).
    public static let agentTodoChanged = Notification.Name("agentTodoChanged")
}

/// Actor-isolated in-memory store. The agent tool writes from a
/// cooperative-pool task; the UI reads on the main actor; the actor
/// keeps the dictionary safe.
public actor AgentTodoStore {
    public static let shared = AgentTodoStore()

    private var todosBySession: [String: AgentTodo] = [:]

    private init() {}

    public func todo(for sessionId: String) -> AgentTodo? {
        todosBySession[sessionId]
    }

    /// Replace the session's todo wholesale and notify observers.
    @discardableResult
    public func setTodo(markdown: String, for sessionId: String) -> AgentTodo {
        let todo = AgentTodo.parse(markdown)
        todosBySession[sessionId] = todo
        Self.postChanged(sessionId: sessionId)
        return todo
    }

    /// Drop the todo for `sessionId` (called when a chat is reset).
    public func clear(for sessionId: String) {
        guard todosBySession.removeValue(forKey: sessionId) != nil else { return }
        Self.postChanged(sessionId: sessionId)
    }

    private static func postChanged(sessionId: String) {
        NotificationCenter.default.post(
            name: .agentTodoChanged,
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }
}
