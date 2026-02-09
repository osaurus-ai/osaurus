//
//  DispatchRequest.swift
//  osaurus
//
//  Defines the async dispatch trigger types for executing Chat or Agent tasks
//  programmatically. Any trigger (schedules, webhooks, shortcuts, etc.) creates
//  a DispatchRequest and hands it to TaskDispatcher.
//

import Foundation

// MARK: - Request

/// Describes a task to dispatch to either Chat or Agent mode
public struct DispatchRequest: Sendable {
    public let id: UUID
    public let mode: ChatMode
    public let prompt: String
    public let personaId: UUID?
    public let title: String?
    public let parameters: [String: String]
    public let folderPath: String?
    public let folderBookmark: Data?
    /// Set to `false` for headless execution (e.g. webhooks).
    public let showToast: Bool

    public init(
        id: UUID = UUID(),
        mode: ChatMode,
        prompt: String,
        personaId: UUID? = nil,
        title: String? = nil,
        parameters: [String: String] = [:],
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        showToast: Bool = true
    ) {
        self.id = id
        self.mode = mode
        self.prompt = prompt
        self.personaId = personaId
        self.title = title
        self.parameters = parameters
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.showToast = showToast
    }
}

// MARK: - Handle

/// Returned after dispatch; used for observation and cancellation
public struct DispatchHandle: Sendable {
    public let id: UUID
    public let windowId: UUID?
    public let request: DispatchRequest
}

// MARK: - Result

/// Outcome of a dispatched task
public enum DispatchResult: Sendable {
    case completed(sessionId: UUID?)
    case cancelled
    case failed(String)
}
