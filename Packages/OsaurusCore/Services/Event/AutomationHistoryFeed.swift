//
//  AutomationHistoryFeed.swift
//  osaurus
//
//  The Automations History list: every automation run from the event ledger,
//  plus the channel messages that never reached an automation (refused by an
//  allowlist, failed, or claimed by no automation) and those taken as answers
//  to a workflow's form, from the channel audit store. Other accepted and
//  duplicate deliveries are left out — an accepted message either shows up
//  as a run or as an unclaimed row.
//

import Foundation

enum AutomationHistoryItem: Identifiable, Equatable, Sendable {
    case run(EventRun)
    case message(AgentChannelAuditRecord)

    var id: String {
        switch self {
        case .run(let run): "run:" + run.id.uuidString
        case .message(let record): "message:" + record.id
        }
    }

    var date: Date {
        switch self {
        case .run(let run): run.firedAt
        case .message(let record): record.createdAt
        }
    }
}

struct AutomationHistoryFilter: Equatable, Sendable {
    /// One History chip: every run, or one source kind's (chips come from
    /// the descriptors' `historyChipTitle`).
    struct Source: Hashable, Sendable, Identifiable {
        /// nil = all.
        let sourceKind: EventSourceKind?

        static let all = Source(sourceKind: nil)
        static let schedule = Source(sourceKind: .schedule)
        static let folder = Source(sourceKind: .folder)
        static let webhook = Source(sourceKind: .webhook)
        static let messages = Source(sourceKind: .channelMessage)

        static var allCases: [Source] {
            [.all]
                + EventSourceKind.allCases
                .filter { $0.descriptor.historyChipTitle != nil }
                .map { Source(sourceKind: $0) }
        }

        var id: String { sourceKind?.rawValue ?? "all" }

        var displayName: String {
            guard let sourceKind else { return L("All") }
            return sourceKind.descriptor.historyChipTitle ?? sourceKind.displayName
        }

        var icon: String? { sourceKind?.icon }
    }

    enum Status: String, CaseIterable, Sendable, Identifiable {
        case all, ran, skipped, failed

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: L("All")
            case .ran: L("Ran")
            case .skipped: L("Skipped")
            case .failed: L("Failed")
            }
        }
    }

    var source: Source = .all
    var status: Status = .all
    /// Messages only: one channel connection; nil = every channel.
    var connectionId: String?
}

enum AutomationHistoryFeed {
    /// Audit action for a message that passed the allowlists but matched no
    /// automation; `reason` carries the `no_event_*` / `mention_required` code.
    static let unclaimedAction = "unclaimed_message"

    static func merge(
        runs: [EventRun],
        audit: [AgentChannelAuditRecord],
        filter: AutomationHistoryFilter,
        limit: Int = 200
    ) -> [AutomationHistoryItem] {
        let connection = filter.source == .messages ? filter.connectionId.map(AgentChannelConnection.normalizedId) : nil

        let runItems = runs.filter { run in
            if let kind = filter.source.sourceKind, run.sourceKind != kind { return false }
            if let connection {
                guard let id = run.summary["connection_id"], AgentChannelConnection.normalizedId(id) == connection
                else { return false }
            }
            return matches(run.status, filter.status)
        }.map(AutomationHistoryItem.run)

        let includeMessages = filter.source == .all || filter.source == .messages
        let messageItems =
            includeMessages
            ? audit.filter { record in
                guard isUnreachedMessage(record) || isFormAnswer(record) else { return false }
                if let connection, AgentChannelConnection.normalizedId(record.connectionId) != connection {
                    return false
                }
                switch filter.status {
                case .all: return true
                case .ran: return isFormAnswer(record)
                case .skipped: return record.status == .denied
                case .failed: return record.status == .failed
                }
            }.map(AutomationHistoryItem.message) : []

        let merged = (runItems + messageItems).sorted { lhs, rhs in
            lhs.date != rhs.date ? lhs.date > rhs.date : lhs.id < rhs.id
        }
        return Array(merged.prefix(limit))
    }

    /// An inbound channel message that never started an automation.
    static func isUnreachedMessage(_ record: AgentChannelAuditRecord) -> Bool {
        record.direction == .inbound && (record.status == .denied || record.status == .failed)
    }

    static func isUnclaimed(_ record: AgentChannelAuditRecord) -> Bool {
        record.action == unclaimedAction
    }

    /// A message taken as the answer to a workflow's form question.
    static func isFormAnswer(_ record: AgentChannelAuditRecord) -> Bool {
        record.direction == .inbound && record.action == EventManager.dialogAnswerAction
    }

    /// What a form answer did, by the relay's rule code.
    static func formAnswerDetail(reason: String?) -> String? {
        switch reason {
        case "dialog_answer": L("Answered a question; the next one was asked.")
        case "dialog_answered": L("Finished the form; the workflow goes on.")
        case "dialog_cancelled": L("Stopped the workflow.")
        case "dialog_invalid": L("Did not fit the question, so it was asked again.")
        case "dialog_invalid_limit": L("Too many answers did not fit; the form moved to the Mac.")
        case "dialog_expired": L("The question was open for a day; the form moved to the Mac.")
        default: nil
        }
    }

    /// How a workflow run's channel reply went, from the ledger summary.
    static func replyStatus(_ run: EventRun) -> String? {
        if let error = run.summary["reply_error"], !error.isEmpty {
            return L("The reply was not posted: \(error)")
        }
        if run.summary["replied_by_step"] == "true" { return L("A reply step answered in the conversation.") }
        return nil
    }

    private static func matches(_ status: EventRunStatus, _ filter: AutomationHistoryFilter.Status) -> Bool {
        switch filter {
        case .all: true
        case .ran: status.didRun && status != .failed
        case .skipped: status == .filtered || status == .duplicate || status == .suppressed
        case .failed: status == .failed
        }
    }
}
