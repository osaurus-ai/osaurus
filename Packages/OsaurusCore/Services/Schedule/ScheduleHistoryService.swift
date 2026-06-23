//
//  ScheduleHistoryService.swift
//  osaurus
//
//  Summaries and export formatting for schedule automation history.
//

import Foundation

public protocol ScheduleAgentRunProviding: Sendable {
    func runs(agentId: UUID, limit: Int) throws -> [AgentRunRecord]
}

public struct LiveScheduleAgentRunProvider: ScheduleAgentRunProviding {
    public init() {}

    public func runs(agentId: UUID, limit: Int) throws -> [AgentRunRecord] {
        if !SchedulerDatabase.shared.isOpen {
            try SchedulerDatabase.shared.open()
        }
        return try SchedulerDatabase.shared.runs(agentId: agentId, limit: limit)
    }
}

public struct ScheduleAutomationSummary: Codable, Sendable, Equatable {
    public var scheduleId: UUID
    public var generatedAt: Date
    public var nextRun: ScheduleNextRunPreview
    public var runs: [ScheduleRunHistoryEntry]
    public var lastError: ScheduleLastErrorDiagnostic?

    public init(
        scheduleId: UUID,
        generatedAt: Date,
        nextRun: ScheduleNextRunPreview,
        runs: [ScheduleRunHistoryEntry],
        lastError: ScheduleLastErrorDiagnostic?
    ) {
        self.scheduleId = scheduleId
        self.generatedAt = generatedAt
        self.nextRun = nextRun
        self.runs = runs
        self.lastError = lastError
    }

    public var latestRun: ScheduleRunHistoryEntry? {
        runs.first
    }
}

public struct ScheduleHistoryService: Sendable {
    public static let shared = ScheduleHistoryService()

    private let agentRunProvider: any ScheduleAgentRunProviding
    private let calendar: Calendar

    public init(
        agentRunProvider: any ScheduleAgentRunProviding = LiveScheduleAgentRunProvider(),
        calendar: Calendar = .current
    ) {
        self.agentRunProvider = agentRunProvider
        self.calendar = calendar
    }

    public func summaries(
        for schedules: [Schedule],
        runLimit: Int = 8,
        asOf now: Date = Date()
    ) -> [UUID: ScheduleAutomationSummary] {
        Dictionary(
            uniqueKeysWithValues: schedules.map { schedule in
                (schedule.id, summary(for: schedule, runLimit: runLimit, asOf: now))
            }
        )
    }

    public func summariesOffMain(
        for schedules: [Schedule],
        runLimit: Int = 8,
        asOf now: Date = Date()
    ) async -> [UUID: ScheduleAutomationSummary] {
        await Task.detached(priority: .utility) {
            self.summaries(for: schedules, runLimit: runLimit, asOf: now)
        }.value
    }

    public func summary(
        for schedule: Schedule,
        runLimit: Int = 10,
        asOf now: Date = Date()
    ) -> ScheduleAutomationSummary {
        let agentRunEntries = loadAgentRunEntries(for: schedule, limit: max(runLimit, Schedule.maxRunHistoryEntries))
        let runs = merge(local: schedule.runHistory, agentRuns: agentRunEntries, limit: runLimit)
        let lastError = latestError(in: runs)
        return ScheduleAutomationSummary(
            scheduleId: schedule.id,
            generatedAt: now,
            nextRun: schedule.nextRunPreview(asOf: now),
            runs: runs,
            lastError: lastError
        )
    }

    public func summaryOffMain(
        for schedule: Schedule,
        runLimit: Int = 10,
        asOf now: Date = Date()
    ) async -> ScheduleAutomationSummary {
        await Task.detached(priority: .utility) {
            self.summary(for: schedule, runLimit: runLimit, asOf: now)
        }.value
    }

    public func markdownSummary(for schedule: Schedule, summary: ScheduleAutomationSummary) -> String {
        var lines: [String] = []
        lines.append("# Schedule Run Summary: \(schedule.name)")
        lines.append("")
        lines.append("- Schedule ID: `\(schedule.id.uuidString)`")
        if let agentId = schedule.agentId {
            lines.append("- Agent ID: `\(agentId.uuidString)`")
        }
        lines.append("- Frequency: \(schedule.frequency.displayDescription)")
        lines.append("- State: \(schedule.isEnabled ? "Enabled" : "Paused")")
        lines.append("- Generated: \(formatDate(summary.generatedAt))")
        lines.append("- Next run: \(summary.nextRun.description)")
        if let nextRunAt = summary.nextRun.nextRunAt {
            lines.append("- Next run timestamp: \(isoString(nextRunAt))")
        }

        if let lastError = summary.lastError {
            lines.append("")
            lines.append("## Last Error")
            lines.append("")
            lines.append("- Run ID: `\(lastError.runId.uuidString)`")
            lines.append("- Occurred: \(formatDate(lastError.occurredAt))")
            lines.append("- Status: \(lastError.status.rawValue)")
            lines.append("- Message: \(lastError.message)")
        }

        lines.append("")
        lines.append("## Recent Runs")
        lines.append("")
        if summary.runs.isEmpty {
            lines.append("No runs yet.")
        } else {
            lines.append("| Started | Status | Duration | Session | Error |")
            lines.append("| --- | --- | --- | --- | --- |")
            for run in summary.runs {
                let started = formatDate(run.startedAt)
                let duration = run.durationSeconds.map(formatDuration) ?? "-"
                let session = run.chatSessionId?.uuidString ?? "-"
                let error = run.errorMessage.map(escapeMarkdownTableCell) ?? "-"
                lines.append(
                    "| \(escapeMarkdownTableCell(started)) | \(run.status.rawValue) | \(duration) | \(session) | \(error) |"
                )
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    public func jsonData(for summary: ScheduleAutomationSummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(summary)
    }

    public func suggestedExportFilename(for schedule: Schedule, generatedAt: Date = Date()) -> String {
        let safeName = schedule.name
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: generatedAt)
        return "\(safeName.isEmpty ? "schedule" : safeName)-runs-\(stamp).md"
    }

    private func loadAgentRunEntries(for schedule: Schedule, limit: Int) -> [ScheduleRunHistoryEntry] {
        guard let agentId = schedule.agentId else { return [] }
        do {
            return try agentRunProvider.runs(agentId: agentId, limit: limit)
                .filter { record in
                    record.triggerKind == .recurringSchedule
                        && Self.scheduleId(fromTriggerPayload: record.triggerPayload) == schedule.id
                }
                .map { Self.entry(from: $0, schedule: schedule) }
        } catch {
            return []
        }
    }

    private func merge(
        local: [ScheduleRunHistoryEntry],
        agentRuns: [ScheduleRunHistoryEntry],
        limit: Int
    ) -> [ScheduleRunHistoryEntry] {
        var merged = agentRuns
        for localEntry in local {
            if let index = merged.firstIndex(where: { Self.isSameRun($0, localEntry) }) {
                merged[index] = Self.combine(preferred: merged[index], fallback: localEntry)
            } else {
                merged.append(localEntry)
            }
        }

        merged = merged.sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.startedAt > rhs.startedAt
        }
        if merged.count > limit {
            merged.removeSubrange(limit...)
        }
        return merged
    }

    private func latestError(in runs: [ScheduleRunHistoryEntry]) -> ScheduleLastErrorDiagnostic? {
        for run in runs {
            guard run.status == .failed || (run.status != .succeeded && run.errorMessage != nil),
                let message = run.errorMessage,
                !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            return ScheduleLastErrorDiagnostic(
                runId: run.id,
                occurredAt: run.endedAt ?? run.startedAt,
                message: message,
                status: run.status
            )
        }
        return nil
    }

    private static func entry(from record: AgentRunRecord, schedule: Schedule) -> ScheduleRunHistoryEntry {
        ScheduleRunHistoryEntry(
            id: record.id,
            scheduleId: schedule.id,
            agentId: record.agentId,
            status: ScheduleRunStatus(record.status),
            source: .agentRun,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            agentRunId: record.id,
            errorMessage: record.error,
            instructionsPreview: preview(record.instructions),
            tokensIn: record.tokensIn,
            tokensOut: record.tokensOut,
            costUSD: record.costUSD
        )
    }

    private static func combine(
        preferred: ScheduleRunHistoryEntry,
        fallback: ScheduleRunHistoryEntry
    ) -> ScheduleRunHistoryEntry {
        var combined = preferred
        combined.chatSessionId = preferred.chatSessionId ?? fallback.chatSessionId
        combined.errorMessage = preferred.errorMessage ?? fallback.errorMessage
        combined.instructionsPreview = preferred.instructionsPreview ?? fallback.instructionsPreview
        return combined
    }

    private static func isSameRun(_ lhs: ScheduleRunHistoryEntry, _ rhs: ScheduleRunHistoryEntry) -> Bool {
        lhs.scheduleId == rhs.scheduleId
            && abs(lhs.startedAt.timeIntervalSince(rhs.startedAt)) < 2
    }

    private static func scheduleId(fromTriggerPayload payload: String?) -> UUID? {
        guard let payload,
            let data = payload.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let key = json["external_session_key"] as? String
        else { return nil }
        return UUID(uuidString: key)
    }

    private static func preview(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 240 { return trimmed }
        return String(trimmed.prefix(237)) + "..."
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 { return "<1s" }
        if duration < 60 { return "\(Int(duration.rounded()))s" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m \(seconds)s"
    }

    private func escapeMarkdownTableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }

}

extension ScheduleRunStatus {
    init(_ status: AgentRunStatus) {
        switch status {
        case .running:
            self = .running
        case .success:
            self = .succeeded
        case .error:
            self = .failed
        case .cancelled:
            self = .cancelled
        case .clamped:
            self = .skipped
        }
    }
}
