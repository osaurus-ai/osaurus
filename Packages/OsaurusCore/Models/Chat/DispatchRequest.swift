//
//  DispatchRequest.swift
//  osaurus
//
//  Async dispatch trigger for running a chat task.
//  Any trigger (schedules, webhooks, shortcuts, plugins, etc.) creates a
//  DispatchRequest and hands it to TaskDispatcher.
//

import Foundation

// MARK: - Request

/// Describes a task to dispatch as a (possibly headless) chat session.
public struct DispatchRequest: Sendable {
    public let id: UUID
    public let prompt: String
    public let agentId: UUID?
    public let title: String?
    public let parameters: [String: String]
    public let folderPath: String?
    public let folderBookmark: Data?
    /// Set to `false` for headless execution (e.g. webhooks).
    public let showToast: Bool
    /// Plugin that originated this dispatch (for on_task_event callback routing).
    public let sourcePluginId: String?
    /// Where this dispatch came from. Drives the persisted `SessionSource`
    /// so the sidebar / DB can distinguish plugin / HTTP / scheduler runs
    /// from user-initiated chats.
    public let source: SessionSource
    /// Stable external grouping key (e.g. Telegram chat id, HTTP `X-Session-Id`).
    /// Lets repeated dispatches from the same conversation accrete into one
    /// persisted session row instead of a fresh one per call.
    public let externalSessionKey: String?

    public init(
        id: UUID = UUID(),
        prompt: String,
        agentId: UUID? = nil,
        title: String? = nil,
        parameters: [String: String] = [:],
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        showToast: Bool = true,
        sourcePluginId: String? = nil,
        source: SessionSource = .chat,
        externalSessionKey: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.agentId = agentId
        self.title = title
        self.parameters = parameters
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.showToast = showToast
        self.sourcePluginId = sourcePluginId
        self.source = source
        self.externalSessionKey = externalSessionKey
    }
}

// MARK: - Handle

/// Returned after dispatch; used for observation and cancellation
public struct DispatchHandle: Sendable {
    public let id: UUID
    public let request: DispatchRequest
}

// MARK: - Result

/// Outcome of a dispatched task
public enum DispatchResult: Sendable {
    case completed(sessionId: UUID?)
    case cancelled
    case failed(String)
}
