//
//  ScheduleRunHistory.swift
//  osaurus
//
//  Durable run-history models for user-authored schedules.
//

import Foundation

public enum ScheduleRunStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case running
    case succeeded
    case failed
    case cancelled
    case skipped

    public var isTerminal: Bool {
        switch self {
        case .running:
            return false
        case .succeeded, .failed, .cancelled, .skipped:
            return true
        }
    }

    public var isError: Bool {
        switch self {
        case .failed:
            return true
        case .running, .succeeded, .cancelled, .skipped:
            return false
        }
    }
}

public enum ScheduleRunHistorySource: String, Codable, Sendable, Equatable {
    case scheduleStore = "schedule_store"
    case agentRun = "agent_run"
}

public struct ScheduleRunHistoryEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var scheduleId: UUID
    public var agentId: UUID?
    public var status: ScheduleRunStatus
    public var source: ScheduleRunHistorySource
    public var startedAt: Date
    public var endedAt: Date?
    public var chatSessionId: UUID?
    public var agentRunId: UUID?
    public var errorMessage: String?
    public var instructionsPreview: String?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var costUSD: Double?

    public init(
        id: UUID = UUID(),
        scheduleId: UUID,
        agentId: UUID?,
        status: ScheduleRunStatus,
        source: ScheduleRunHistorySource = .scheduleStore,
        startedAt: Date,
        endedAt: Date? = nil,
        chatSessionId: UUID? = nil,
        agentRunId: UUID? = nil,
        errorMessage: String? = nil,
        instructionsPreview: String? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.id = id
        self.scheduleId = scheduleId
        self.agentId = agentId
        self.status = status
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.chatSessionId = chatSessionId
        self.agentRunId = agentRunId
        self.errorMessage = errorMessage
        self.instructionsPreview = instructionsPreview
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costUSD = costUSD
    }

    public var durationSeconds: TimeInterval? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

public enum ScheduleNextRunPreviewState: String, Codable, Sendable, Equatable {
    case scheduled
    case due
    case paused
    case exhausted
}

public struct ScheduleNextRunPreview: Codable, Sendable, Equatable {
    public var state: ScheduleNextRunPreviewState
    public var nextRunAt: Date?
    public var generatedAt: Date
    public var description: String

    public init(
        state: ScheduleNextRunPreviewState,
        nextRunAt: Date?,
        generatedAt: Date,
        description: String
    ) {
        self.state = state
        self.nextRunAt = nextRunAt
        self.generatedAt = generatedAt
        self.description = description
    }
}

public struct ScheduleLastErrorDiagnostic: Codable, Sendable, Equatable {
    public var runId: UUID
    public var occurredAt: Date
    public var message: String
    public var status: ScheduleRunStatus

    public init(runId: UUID, occurredAt: Date, message: String, status: ScheduleRunStatus) {
        self.runId = runId
        self.occurredAt = occurredAt
        self.message = message
        self.status = status
    }
}

extension Schedule {
    public static let maxRunHistoryEntries = 50

    public func nextRunPreview(asOf now: Date = Date()) -> ScheduleNextRunPreview {
        guard isEnabled else {
            return ScheduleNextRunPreview(
                state: .paused,
                nextRunAt: nil,
                generatedAt: now,
                description: "Paused"
            )
        }

        guard let nextRun = nextRunDateAfterExecutionAnchor(asOf: now) else {
            return ScheduleNextRunPreview(
                state: .exhausted,
                nextRunAt: nil,
                generatedAt: now,
                description: "No upcoming run"
            )
        }

        if nextRun <= now {
            return ScheduleNextRunPreview(
                state: .due,
                nextRunAt: nextRun,
                generatedAt: now,
                description: "Due now"
            )
        }

        return ScheduleNextRunPreview(
            state: .scheduled,
            nextRunAt: nextRun,
            generatedAt: now,
            description: Self.formatNextRun(nextRun, relativeTo: now)
        )
    }

    public mutating func recordRunStarted(at startedAt: Date) {
        if runHistory.contains(where: { entry in
            entry.status == .running
                && abs(entry.startedAt.timeIntervalSince(startedAt)) < 0.001
        }) {
            return
        }

        runHistory.append(
            ScheduleRunHistoryEntry(
                scheduleId: id,
                agentId: agentId,
                status: .running,
                startedAt: startedAt,
                instructionsPreview: Self.instructionsPreview(instructions)
            )
        )
        trimRunHistory()
    }

    public mutating func recordRunSucceeded(endedAt: Date, chatSessionId: UUID?) {
        let startedAt = lastTriggeredAt ?? endedAt
        let index = latestRunningHistoryIndex(startedAt: startedAt)
        if let index {
            runHistory[index].status = .succeeded
            runHistory[index].endedAt = endedAt
            runHistory[index].chatSessionId = chatSessionId ?? runHistory[index].chatSessionId
            runHistory[index].errorMessage = nil
        } else {
            runHistory.append(
                ScheduleRunHistoryEntry(
                    scheduleId: id,
                    agentId: agentId,
                    status: .succeeded,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    chatSessionId: chatSessionId,
                    instructionsPreview: Self.instructionsPreview(instructions)
                )
            )
        }
        trimRunHistory()
    }

    public mutating func recordRunFailed(
        startedAt: Date,
        endedAt: Date,
        status: ScheduleRunStatus = .failed,
        errorMessage: String
    ) {
        let terminalStatus: ScheduleRunStatus = status.isTerminal ? status : .failed
        let index = latestRunningHistoryIndex(startedAt: startedAt)
        if let index {
            runHistory[index].status = terminalStatus
            runHistory[index].endedAt = endedAt
            runHistory[index].errorMessage = errorMessage
        } else {
            runHistory.append(
                ScheduleRunHistoryEntry(
                    scheduleId: id,
                    agentId: agentId,
                    status: terminalStatus,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    errorMessage: errorMessage,
                    instructionsPreview: Self.instructionsPreview(instructions)
                )
            )
        }
        trimRunHistory()
    }

    public mutating func mergeRunHistory(_ other: [ScheduleRunHistoryEntry]) {
        guard !other.isEmpty else {
            trimRunHistory()
            return
        }

        var mergedById: [UUID: ScheduleRunHistoryEntry] = [:]
        for entry in runHistory + other {
            if let existing = mergedById[entry.id] {
                mergedById[entry.id] = Self.preferredHistoryEntry(existing, entry)
            } else {
                mergedById[entry.id] = entry
            }
        }
        runHistory = Array(mergedById.values)
        trimRunHistory()
    }

    public mutating func trimRunHistory(limit: Int = Self.maxRunHistoryEntries) {
        runHistory =
            runHistory
            .sorted { lhs, rhs in
                if lhs.startedAt == rhs.startedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.startedAt > rhs.startedAt
            }
        if runHistory.count > limit {
            runHistory.removeSubrange(limit...)
        }
    }

    private func latestRunningHistoryIndex(startedAt: Date) -> Int? {
        let running = runHistory.indices
            .filter { runHistory[$0].status == .running }
            .sorted { runHistory[$0].startedAt > runHistory[$1].startedAt }

        if let exact = running.first(where: { abs(runHistory[$0].startedAt.timeIntervalSince(startedAt)) < 2 }) {
            return exact
        }
        return running.first
    }

    private static func preferredHistoryEntry(
        _ lhs: ScheduleRunHistoryEntry,
        _ rhs: ScheduleRunHistoryEntry
    ) -> ScheduleRunHistoryEntry {
        if lhs.status == .running, rhs.status.isTerminal { return rhs }
        if rhs.status == .running, lhs.status.isTerminal { return lhs }
        if lhs.source == .scheduleStore, rhs.source == .agentRun { return rhs }
        if (rhs.endedAt ?? rhs.startedAt) > (lhs.endedAt ?? lhs.startedAt) { return rhs }
        return lhs
    }

    private static func instructionsPreview(_ instructions: String) -> String? {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 240 { return trimmed }
        return String(trimmed.prefix(237)) + "..."
    }

    private static func formatNextRun(_ date: Date, relativeTo now: Date) -> String {
        let calendar = Calendar.current

        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        if calendar.isDate(date, inSameDayAs: now) {
            return "Today at \(timeFormatter.string(from: date))"
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
            calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return "Tomorrow at \(timeFormatter.string(from: date))"
        }

        let daysDiff = calendar.dateComponents([.day], from: now, to: date).day ?? 0
        if daysDiff < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE 'at' h:mm a"
            return formatter.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
