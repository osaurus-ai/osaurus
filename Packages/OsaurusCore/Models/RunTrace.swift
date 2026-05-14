//
//  RunTrace.swift
//  osaurus
//
//  Per-run JSON trace written to
//  `~/.osaurus/agents/<id>/runs/<run_id>.json` when a DB-enabled
//  agent's chat task terminates (spec §1.8). Captures the inputs
//  and outputs of a single run so the user can inspect what the
//  agent saw and did without re-running the model — and so the
//  Activity tab + bundle export can carry an audit trail beyond
//  what `agent_runs` stores.
//
//  Best-effort: write failures only forfeit this audit row, never
//  the run's completion signal.
//

import Foundation

/// Codable transcript of a single agent run.
public struct RunTrace: Codable, Sendable, Equatable {
    /// `agent_runs.id` in `SchedulerDatabase`.
    public let runId: UUID
    /// The agent that owns the run.
    public let agentId: UUID
    /// `BackgroundTaskState.id` / `ExecutionContext.id` — the chat
    /// session/dispatch id. Stored as a string for forward-compat
    /// with sessions identified by something other than UUID.
    public let sessionId: String
    /// Trigger source as it appears in `SessionSource.rawValue`
    /// (e.g. `chat`, `schedule`, `self_schedule`, `watcher`,
    /// `plugin`, `http`).
    public let triggerSource: String
    /// Terminal status: `success`, `error`, `cancelled`.
    public let status: String
    /// Wall-clock window for the run.
    public let startedAt: Date
    public let endedAt: Date
    /// Token / cost accounting at terminal moment (nil when the
    /// streaming layer never reported any).
    public let tokensIn: Int?
    public let tokensOut: Int?
    public let costUSD: Double?
    /// Human-readable error if the run ended in `error` or
    /// budget-cancelled state.
    public let errorMessage: String?
    /// Full turn list captured from the session at termination.
    public let turns: [Turn]

    public struct Turn: Codable, Sendable, Equatable {
        public let id: UUID
        public let role: String
        public let content: String
        public let thinking: String?
        public let toolCalls: [ToolCallSnapshot]?
        public let toolCallId: String?
        public let toolResults: [String: String]?

        public init(
            id: UUID,
            role: String,
            content: String,
            thinking: String?,
            toolCalls: [ToolCallSnapshot]?,
            toolCallId: String?,
            toolResults: [String: String]?
        ) {
            self.id = id
            self.role = role
            self.content = content
            self.thinking = thinking
            self.toolCalls = toolCalls
            self.toolCallId = toolCallId
            self.toolResults = toolResults
        }
    }

    public struct ToolCallSnapshot: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let arguments: String

        public init(id: String, name: String, arguments: String) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    public init(
        runId: UUID,
        agentId: UUID,
        sessionId: String,
        triggerSource: String,
        status: String,
        startedAt: Date,
        endedAt: Date,
        tokensIn: Int?,
        tokensOut: Int?,
        costUSD: Double?,
        errorMessage: String?,
        turns: [Turn]
    ) {
        self.runId = runId
        self.agentId = agentId
        self.sessionId = sessionId
        self.triggerSource = triggerSource
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costUSD = costUSD
        self.errorMessage = errorMessage
        self.turns = turns
    }
}

// MARK: - Persistence

public enum RunTraceWriter {
    /// Encode `trace` and write atomically to
    /// `OsaurusPaths.agentRunTraceFile(agentId:runId:)`. Creates the
    /// parent `runs/` directory on demand. Best-effort: logs on
    /// failure and returns `false` so callers can keep moving.
    @discardableResult
    public static func write(_ trace: RunTrace) -> Bool {
        let url = OsaurusPaths.agentRunTraceFile(agentId: trace.agentId, runId: trace.runId)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(trace)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("[RunTraceWriter] failed to write \(url.path): \(error)")
            return false
        }
    }
}
