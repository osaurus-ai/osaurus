//
//  ChatExecutionContext.swift
//  osaurus
//
//  TaskLocal context populated by the chat engine before dispatching every
//  tool call so per-session state (the agent todo, file-operation undo
//  log, method telemetry, etc.) can be addressed by the active session.
//

import Foundation

/// TaskLocal storage carrying the active chat session / agent / batch ids
/// down through tool execution. The chat engine seeds these in
/// `ChatSession.send` (and equivalent headless paths) so any tool reading
/// them picks up the right scope without an explicit parameter.
public enum ChatExecutionContext {
    /// The current chat session id whose tool calls are running. Tools that
    /// need per-conversation state (todo store, file-op undo log, method
    /// telemetry) key off this.
    @TaskLocal public static var currentSessionId: String?

    /// The current batch ID for grouped operations (nil for non-batch operations).
    @TaskLocal public static var currentBatchId: UUID?

    /// The agent ID whose context is active for the current execution.
    @TaskLocal public static var currentAgentId: UUID?
}
