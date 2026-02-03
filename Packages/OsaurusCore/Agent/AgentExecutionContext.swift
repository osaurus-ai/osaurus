//
//  AgentExecutionContext.swift
//  osaurus
//
//  TaskLocal context for tracking the current issue during agent tool execution.
//

import Foundation

/// Execution context for agent operations using TaskLocal storage
public enum AgentExecutionContext {
    /// The current issue ID being executed (available during tool calls)
    @TaskLocal public static var currentIssueId: String?

    /// The current batch ID for grouped operations (nil for non-batch operations)
    @TaskLocal public static var currentBatchId: UUID?
}
