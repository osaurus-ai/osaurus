//
//  AttentionActivityLoggerTests.swift
//  osaurusTests
//
//  What a settled attention item writes: the Insights row (method, status,
//  details, participant), the redaction of reply text and titles, the
//  participant column on the activity store, the transcript event text,
//  and the conversation event placement.
//

import Foundation
import Testing

@testable import OsaurusCore

private let alice = Participant(kind: .teammate, handle: "alice", wallet: "0x9c3e0000000000000000000000000000000011aa")
private let owner = Participant(kind: .owner, handle: "tpae")

private func settled(
    _ kind: AttentionKind = .ownerApproval,
    outcome: AttentionResolution.Outcome,
    surface: AttentionSurface = .phone,
    decidedBy: Participant? = owner,
    reply: String? = nil,
    tool: String? = "web_fetch"
) -> AttentionItem {
    var item = AttentionItem(
        kind: kind,
        requester: alice,
        agent: .agent(name: "Research Agent", address: "0xab1200000000000000000000000000000000f291"),
        sessionId: UUID(),
        title: "@alice wants Research Agent to use web_fetch",
        toolName: tool,
        createdAt: Date().addingTimeInterval(-42)
    )
    item.deliveredTo = ["in_app", "phone"]
    item.state = .resolved(AttentionResolution(outcome: outcome, surface: surface, decidedBy: decidedBy, replyText: reply))
    item.settledAt = Date()
    return item
}

@Suite("Attention activity logger")
@MainActor
struct AttentionActivityLoggerTests {
    @Test func methodAndStatusFollowTheOutcome() {
        let cases: [(AttentionResolution.Outcome, String, Int)] = [
            (.approved, "APPROVE", 200), (.denied, "DENY", 403), (.allowedForConversation, "ALLOW_CONVERSATION", 200),
            (.replied, "REPLY", 200), (.dismissed, "DISMISS", 200), (.timedOut, "TIMEOUT", 408),
            (.abandoned, "ABANDON", 499),
        ]
        for (outcome, method, status) in cases {
            let item = settled(outcome: outcome)
            #expect(AttentionActivityLogger.method(for: item) == method)
            #expect(AttentionActivityLogger.statusCode(for: item) == status)
        }
        var withdrawn = settled(outcome: .approved)
        withdrawn.state = .retracted
        #expect(AttentionActivityLogger.method(for: withdrawn) == "RETRACT")
    }

    @Test func detailsCarryWhoWhatAndWhere() {
        let item = settled(outcome: .allowedForConversation)
        let details = AttentionActivityLogger.details(for: item)
        #expect(details["tool"] == "web_fetch")
        #expect(details["approval_id"] == item.id.uuidString)
        #expect(details["decision"] == "allowed_for_conversation")
        #expect(details["scope"] == "conversation")
        #expect(details["surface"] == "phone")
        #expect(details["delivered_to"] == "in_app,phone")
        #expect(details["requester"] == "@alice · 0x9c3e…11aa")
        #expect(details["requester_key"] == alice.wallet)
        #expect(details["agent_address"] == "0xab1200000000000000000000000000000000f291")
        #expect(details["decided_by_kind"] == "owner")
        #expect(Int(details["wait_ms"] ?? "") ?? 0 >= 41_000)
        let attribution = AttentionActivityLogger.attribution(for: item)
        #expect(attribution.participant == alice)
        #expect(attribution.sessionId == item.sessionId)
    }

    @Test func aDenialIsNotAnError() {
        let denied = RequestLog(
            source: .httpAPI, method: "DENY", path: "/attention/owner_approval", statusCode: 403, durationMs: 0,
            category: .interaction, locality: .local
        )
        #expect(!denied.isError)
        let timedOut = RequestLog(
            source: .httpAPI, method: "TIMEOUT", path: "/attention/owner_approval", statusCode: 408, durationMs: 0,
            category: .interaction, locality: .local
        )
        #expect(timedOut.isError)
    }

    @Test func titleReadsLikeASentence() {
        let item = settled(outcome: .approved)
        let log = RequestLog(
            source: .httpAPI, method: "APPROVE", path: "/attention/owner_approval", statusCode: 200, durationMs: 42_000,
            category: .interaction, locality: .local, egress: EgressInfo(details: AttentionActivityLogger.details(for: item))
        )
        #expect(log.title == "Allowed web_fetch")
    }

    @Test func requestsWithoutAToolReadAsSentences() {
        func title(_ method: String, kind: AttentionKind) -> String {
            RequestLog(
                source: .chatUI, method: method, path: "/attention/\(kind.rawValue)", statusCode: 200,
                durationMs: 1_000, category: .interaction, locality: .local,
                egress: EgressInfo(details: ["kind": kind.rawValue])
            ).title
        }
        #expect(title("REPLY", kind: .clarification) == "Replied to a question")
        #expect(title("TIMEOUT", kind: .workflowDialog) == "No answer to a workflow form in time")
        #expect(title("DENY", kind: .configApproval) == "Denied a configuration change")
        #expect(title("ABANDON", kind: .secretRequest) == "Run ended before you answered a secret request")
    }

    @Test func aPersonIsNotAnAPIClient() {
        var item = settled(outcome: .approved)
        #expect(AttentionActivityLogger.source(for: item) == .p2p)
        item.requester = .ownerDevice("Paired phone")
        #expect(AttentionActivityLogger.source(for: item) == .chatUI)
        item.requester = nil
        #expect(AttentionActivityLogger.source(for: item) == .chatUI)
    }

    @Test func durationsUseOneFormat() {
        #expect(RequestLog.formattedDuration(ms: 420) == "420ms")
        #expect(RequestLog.formattedDuration(ms: 4_200) == "4.2s")
        #expect(RequestLog.formattedDuration(ms: 125_000).contains("2"))
        #expect(!RequestLog.formattedDuration(ms: 125_000).contains("125"))
    }

    @Test func transcriptTextNamesBothSides() {
        let who = ParticipantFormatter.short(alice)
        #expect(
            AttentionActivityLogger.transcriptText(settled(outcome: .approved), requester: who)
                == "You allowed web_fetch for @alice · 0x9c3e…11aa · iPhone"
        )
        #expect(
            AttentionActivityLogger.transcriptText(settled(outcome: .denied, surface: .inline), requester: who)
                == "You denied web_fetch for @alice · 0x9c3e…11aa"
        )
        #expect(
            AttentionActivityLogger.transcriptText(settled(outcome: .timedOut, surface: .system), requester: who)?
                .hasPrefix("web_fetch for @alice") == true
        )
    }

    @Test func ownerApprovalDecisionsMapToAuditEvents() {
        #expect(OwnerApprovalService.auditEvent(for: .approved) == .approvalGranted)
        #expect(OwnerApprovalService.auditEvent(for: .allowedForConversation) == .approvalGranted)
        #expect(OwnerApprovalService.auditEvent(for: .denied) == .approvalDenied)
        #expect(OwnerApprovalService.auditEvent(for: .timedOut) == .approvalTimedOut)
        #expect(OwnerApprovalService.auditEvent(for: .leased) == nil)
        #expect(OwnerApprovalService.auditEvent(for: .abandoned) == nil)
    }
}

@Suite("Interaction redaction")
@MainActor
struct InteractionRedactionTests {
    @Test func replyTextAndTitlesAreContent() {
        let item = settled(.clarification, outcome: .replied, reply: "my secret plans", tool: nil)
        let details = AttentionActivityLogger.details(for: item)
        #expect(details["message"] == "my secret plans")
        let log = RequestLog(
            source: .chatUI, method: "REPLY", path: "/attention/clarification", statusCode: 200, durationMs: 0,
            category: .interaction, locality: .local, egress: EgressInfo(details: details)
        )
        let scrubbed = log.withoutContent()
        #expect(scrubbed.egress?.details["message"] == RequestLog.contentWithheldMarker)
        #expect(scrubbed.egress?.details["attention_title"] == RequestLog.contentWithheldMarker)
        #expect(scrubbed.egress?.details["decision"] == "replied")
    }

    @Test func secretRepliesAreNeverRecorded() {
        let item = settled(.secretRequest, outcome: .replied, reply: "hunter2", tool: nil)
        #expect(AttentionActivityLogger.details(for: item)["message"] == nil)
    }

    @Test func toolArgumentsNeverAppear() {
        let details = AttentionActivityLogger.details(for: settled(outcome: .approved))
        #expect(!details.keys.contains("arguments"))
    }
}

@Suite("Participant attribution in Insights")
@MainActor
struct ParticipantAttributionInsightsTests {
    @Test func rowsWithoutAParticipantEncodeAsBefore() throws {
        let log = RequestLog(source: .chatUI, method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 1)
        let json = try #require(String(data: ActivityLogStore.canonicalEncoder.encode(log), encoding: .utf8))
        #expect(!json.contains("participant"))
        let decoded = try JSONDecoder().decode(RequestLog.self, from: Data(json.utf8))
        #expect(decoded.participant == nil)
    }

    @Test func participantRoundTripsAndFilters() throws {
        let store = ActivityLogStore()
        try store.openInMemory()
        try store.append(
            RequestLog(
                source: .httpAPI, method: "POST", path: "/agents/x/run", statusCode: 200, durationMs: 1,
                participant: alice
            )
        )
        try store.append(RequestLog(source: .chatUI, method: "POST", path: "/chat/completions", statusCode: 200, durationMs: 1))

        let mine = try store.fetch(filter: ActivityFilter(participantKey: alice.key))
        #expect(mine.count == 1)
        #expect(mine.first?.participant == alice)
        #expect(try store.verify().isIntact)

        let inMemory = InsightsService.filterInMemory(
            try store.fetch(), ActivityFilter(participantKey: alice.key)
        )
        #expect(inMemory.count == 1)
    }

    @Test func attributionReadsTheTaskLocal() async {
        let attribution = ChatExecutionContext.$currentParticipant.withValue(alice) {
            InsightsService.ActivityAttribution.current()
        }
        #expect(attribution.participant == alice)
        #expect(InsightsService.ActivityAttribution.current().participant == nil)
    }

    @Test func interactionsHaveTheirOwnScope() {
        #expect(InsightsScope.scope(containing: .interaction) == .interactions)
        let tokens = ActivityFilterToken.tokens(for: ActivityFilter(participantKey: alice.key))
        #expect(tokens.contains { $0.kind == .participant && $0.label == "0x9c3e…11aa" })
    }
}

@Suite("Conversation events")
@MainActor
struct ConversationEventLogTests {
    private func makeLog() -> ConversationEventLog {
        let log = ConversationEventLog()
        log.resetForTesting(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-events-\(UUID().uuidString).json")
        )
        return log
    }

    @Test func oneTimeEventsAreRecordedOnce() {
        let log = makeLog()
        let session = UUID()
        #expect(log.record(sessionId: session, text: "joined", icon: "person", key: "joined:a") != nil)
        #expect(log.record(sessionId: session, text: "joined", icon: "person", key: "joined:a") == nil)
        #expect(log.record(sessionId: UUID(), text: "joined", icon: "person", key: "joined:a") != nil)
        #expect(log.events(for: session).count == 1)
    }

    @Test func eventsSitBetweenTurnsByTime() {
        let t1 = UUID()
        let t2 = UUID()
        let now = Date()
        let blocks = [
            ContentBlock(id: "a", turnId: t1, kind: .groupSpacer, position: .only),
            ContentBlock(id: "b", turnId: t1, kind: .groupSpacer, position: .only),
            ContentBlock(id: "c", turnId: t2, kind: .groupSpacer, position: .only),
        ]
        let between = ConversationEvent(
            id: UUID(), sessionId: UUID(), at: now.addingTimeInterval(5), text: "approved", icon: "checkmark",
            attentionId: nil, key: nil
        )
        let after = ConversationEvent(
            id: UUID(), sessionId: UUID(), at: now.addingTimeInterval(50), text: "late", icon: "clock",
            attentionId: nil, key: nil
        )
        let result = ConversationEventLog.interleave(
            [after, between], into: blocks, turnDates: [t1: now, t2: now.addingTimeInterval(10)]
        )
        #expect(result.map(\.id) == ["a", "b", "event-\(between.id.uuidString)", "c", "event-\(after.id.uuidString)"])
    }
}
