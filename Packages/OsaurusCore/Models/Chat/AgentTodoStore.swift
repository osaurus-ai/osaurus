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

    /// Store a checklist only when its parsed tasks or checkbox states changed.
    ///
    /// Models sometimes repeat the same `todo` call after a successful action.
    /// Treating that replay as a fresh update churns the UI timestamp and can
    /// convince the model that rewriting the checklist is forward progress.
    /// Keep the comparison actor-isolated so concurrent calls for one session
    /// cannot both report a change.
    public func setTodoIfChanged(
        markdown: String,
        for sessionId: String
    ) -> (todo: AgentTodo, changed: Bool, previousDoneCount: Int?) {
        let candidate = AgentTodo.parse(markdown)
        let previousDoneCount = todosBySession[sessionId]?.doneCount
        if let existing = todosBySession[sessionId],
            Self.hasSameChecklist(existing, candidate)
        {
            return (existing, false, previousDoneCount)
        }
        todosBySession[sessionId] = candidate
        Self.postChanged(sessionId: sessionId)
        return (candidate, true, previousDoneCount)
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

    private static func hasSameChecklist(_ lhs: AgentTodo, _ rhs: AgentTodo) -> Bool {
        guard lhs.items.count == rhs.items.count else { return false }
        return zip(lhs.items, rhs.items).allSatisfy {
            $0.text == $1.text && $0.isDone == $1.isDone
        }
    }
}
