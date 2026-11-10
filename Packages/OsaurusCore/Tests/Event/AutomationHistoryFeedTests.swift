//
//  AutomationHistoryFeedTests.swift
//  OsaurusCoreTests
//
//  Automations History: ledger runs merged with channel messages that never
//  reached an automation, the source/status/channel filters, and the audit
//  row written for an unclaimed message.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Automation history feed")
struct AutomationHistoryFeedTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(
        _ name: String,
        _ kind: EventSourceKind,
        _ status: EventRunStatus,
        at offset: TimeInterval,
        connectionId: String? = nil
    ) -> EventRun {
        EventRun(
            eventId: UUID(), eventName: name, sourceKind: kind, actionKind: .agent,
            firedAt: base.addingTimeInterval(offset), status: status,
            summary: connectionId.map { ["connection_id": $0] } ?? [:])
    }

    private func audit(
        _ status: AgentChannelAuditStatus,
        at offset: TimeInterval,
        connectionId: String = "slack",
        action: String = "receive_message",
        reason: String? = nil,
        direction: AgentChannelAuditDirection = .inbound
    ) -> AgentChannelAuditRecord {
        AgentChannelAuditRecord(
            databaseId: Int64(offset), connectionId: connectionId, roomId: "C1", direction: direction,
            action: action, status: status, reason: reason, createdAt: base.addingTimeInterval(offset))
    }

    private var sampleRuns: [EventRun] {
        [
            run("Morning", .schedule, .succeeded, at: 10),
            run("Inbox", .folder, .filtered, at: 20),
            run("Hook", .webhook, .failed, at: 30),
            run("Sales", .channelMessage, .succeeded, at: 40, connectionId: "slack"),
            run("Ops", .channelMessage, .suppressed, at: 50, connectionId: "discord"),
        ]
    }

    private var sampleAudit: [AgentChannelAuditRecord] {
        [
            audit(.accepted, at: 41),
            audit(.duplicate, at: 42),
            audit(.denied, at: 43, reason: "sender_not_allowlisted"),
            audit(.denied, at: 44, action: AutomationHistoryFeed.unclaimedAction, reason: "no_event_configured"),
            audit(.failed, at: 45, connectionId: "discord", reason: "undecodable_envelope"),
            audit(.failed, at: 46, direction: .outbound),
        ]
    }

    private func names(_ items: [AutomationHistoryItem]) -> [String] {
        items.map {
            switch $0 {
            case .run(let run): run.eventName
            case .message(let record): "\(record.connectionId):\(record.reason ?? record.status.rawValue)"
            }
        }
    }

    @Test func allMergesRunsWithUnreachedInboundMessagesNewestFirst() {
        let items = AutomationHistoryFeed.merge(runs: sampleRuns, audit: sampleAudit, filter: .init())
        #expect(
            names(items) == [
                "Ops", "discord:undecodable_envelope", "slack:no_event_configured", "slack:sender_not_allowlisted",
                "Sales", "Hook", "Inbox", "Morning",
            ])
    }

    @Test func runSourcesHideMessages() {
        let schedule = AutomationHistoryFeed.merge(
            runs: sampleRuns, audit: sampleAudit, filter: .init(source: .schedule))
        #expect(names(schedule) == ["Morning"])
        let webhook = AutomationHistoryFeed.merge(runs: sampleRuns, audit: sampleAudit, filter: .init(source: .webhook))
        #expect(names(webhook) == ["Hook"])
    }

    @Test func messagesScopeToOneChannel() {
        let all = AutomationHistoryFeed.merge(runs: sampleRuns, audit: sampleAudit, filter: .init(source: .messages))
        #expect(
            names(all) == [
                "Ops", "discord:undecodable_envelope", "slack:no_event_configured", "slack:sender_not_allowlisted",
                "Sales",
            ])
        let slack = AutomationHistoryFeed.merge(
            runs: sampleRuns, audit: sampleAudit, filter: .init(source: .messages, connectionId: " slack "))
        #expect(names(slack) == ["slack:no_event_configured", "slack:sender_not_allowlisted", "Sales"])
    }

    @Test func channelPickerIsIgnoredOutsideMessages() {
        let items = AutomationHistoryFeed.merge(
            runs: sampleRuns, audit: sampleAudit, filter: .init(source: .all, connectionId: "discord"))
        #expect(items.count == 8)
    }

    @Test func statusFilters() {
        let ran = AutomationHistoryFeed.merge(runs: sampleRuns, audit: sampleAudit, filter: .init(status: .ran))
        #expect(names(ran) == ["Sales", "Morning"])
        let skipped = AutomationHistoryFeed.merge(runs: sampleRuns, audit: sampleAudit, filter: .init(status: .skipped))
        #expect(
            names(skipped) == ["Ops", "slack:no_event_configured", "slack:sender_not_allowlisted", "Inbox"])
        let failed = AutomationHistoryFeed.merge(runs: sampleRuns, audit: sampleAudit, filter: .init(status: .failed))
        #expect(names(failed) == ["discord:undecodable_envelope", "Hook"])
    }

    @Test func limitKeepsTheNewest() {
        let items = AutomationHistoryFeed.merge(runs: sampleRuns, audit: sampleAudit, filter: .init(), limit: 2)
        #expect(names(items) == ["Ops", "discord:undecodable_envelope"])
    }

    @Test func unclaimedMessageAuditRowCarriesTheReasonAndARedactedPreview() {
        let message = ChannelInboundMessage(
            identity: ChannelIdentity(
                kind: .slack, installationId: "slack", groupId: "C-9", sender: ChannelSenderMetadata(senderId: "U1")),
            kind: .slack,
            connectionId: "slack",
            providerEventId: "Ev-1",
            providerRoute: AgentChannelProviderRoute(conversationId: "C-9"),
            content: "hello there",
            sourceLabel: "Slack"
        )
        let record = EventManager.unclaimedAuditRecord(message, reason: "no_event_for_room", at: base)
        #expect(record.action == AutomationHistoryFeed.unclaimedAction)
        #expect(record.status == .denied)
        #expect(record.direction == .inbound)
        #expect(record.reason == "no_event_for_room")
        #expect(record.roomId == "C-9")
        #expect(record.providerEventId == "Ev-1")
        #expect(record.redactedSummary == "hello there")
        #expect(AutomationHistoryFeed.isUnclaimed(record))
        #expect(AutomationHistoryFeed.isUnreachedMessage(record))
    }

    @Test func formAnswersShowUnderMessagesAndRan() {
        let answer = audit(.accepted, at: 47, action: EventManager.dialogAnswerAction, reason: "dialog_answered")
        let records = sampleAudit + [answer]
        let all = AutomationHistoryFeed.merge(runs: [], audit: records, filter: .init())
        #expect(names(all).first == "slack:dialog_answered")
        #expect(AutomationHistoryFeed.isFormAnswer(answer))
        #expect(!AutomationHistoryFeed.isUnreachedMessage(answer))

        let messagesRan = AutomationHistoryFeed.merge(
            runs: [], audit: records, filter: .init(source: .messages, status: .ran))
        #expect(names(messagesRan) == ["slack:dialog_answered"])
        let skipped = AutomationHistoryFeed.merge(
            runs: [], audit: records, filter: .init(source: .messages, status: .skipped))
        #expect(!names(skipped).contains("slack:dialog_answered"))
        let otherChannel = AutomationHistoryFeed.merge(
            runs: [], audit: records, filter: .init(source: .messages, connectionId: "discord"))
        #expect(!names(otherChannel).contains("slack:dialog_answered"))

        for rule in ["dialog_answer", "dialog_answered", "dialog_cancelled", "dialog_invalid", "dialog_invalid_limit", "dialog_expired"] {
            #expect(AutomationHistoryFeed.formAnswerDetail(reason: rule) != nil, "\(rule)")
        }
        #expect(AutomationHistoryFeed.formAnswerDetail(reason: "other") == nil)

        let message = ChannelInboundMessage(
            identity: ChannelIdentity(
                kind: .slack, installationId: "slack", groupId: "C-9", sender: ChannelSenderMetadata(senderId: "U1")),
            kind: .slack, connectionId: "slack", providerEventId: "Ev-2",
            providerRoute: AgentChannelProviderRoute(conversationId: "C-9"), content: "yes", sourceLabel: "Slack")
        let record = EventManager.dialogAnswerAuditRecord(
            message, submission: .fired(eventNames: ["Intake"], rule: "dialog_expired"), at: base)
        #expect(AutomationHistoryFeed.isFormAnswer(record))
        #expect(record.reason == "dialog_expired")
    }

    @Test func workflowRunsSayHowTheirReplyWent() {
        var byStep = run("Triage", .channelMessage, .succeeded, at: 1)
        byStep.summary["replied_by_step"] = "true"
        #expect(AutomationHistoryFeed.replyStatus(byStep) != nil)
        var refused = run("Triage", .channelMessage, .succeeded, at: 2)
        refused.summary["reply_error"] = "send_failed"
        #expect(AutomationHistoryFeed.replyStatus(refused)?.contains("send_failed") == true)
        #expect(AutomationHistoryFeed.replyStatus(run("Triage", .channelMessage, .succeeded, at: 3)) == nil)
    }
}
