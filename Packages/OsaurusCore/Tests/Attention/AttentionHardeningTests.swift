//
//  AttentionHardeningTests.swift
//  osaurusTests
//
//  The caller side of a shared conversation (host-history sends, mailbox
//  polling, the events page), the attention stores on disk (caps, corrupt
//  files, concurrent writes), `ask_owner`, the phone's view of a settled
//  item, and how Insights finds and times an interaction.
//

import Foundation
import Testing

@testable import OsaurusCore

private let owner = Participant(kind: .owner, handle: "tpae")
private let scoutAddress = "0xab1200000000000000000000000000000000f291"

private func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("osaurus-\(name)-\(UUID().uuidString).json")
}

private func quarantined(_ url: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        .contains { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".corrupt-") }
}

private func permissions(_ url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

// MARK: - Caller client

@Suite("Shared agent caller client", .serialized)
struct SharedAgentCallerClientTests {
    init() { RemoteAgentHostHistory.resetForTesting() }

    private let system = ChatMessage(role: "system", content: "sys")
    private func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: text) }
    private func assistant(_ text: String) -> ChatMessage { ChatMessage(role: "assistant", content: text) }

    @Test func aFirstMessageGoesAloneInHostForm() {
        let session = UUID().uuidString
        let out = RemoteAgentHostHistory.outbound([system, user("hi")], sessionId: session)
        #expect(out.host)
        #expect(out.messages.map(\.content) == ["sys", "hi"])
    }

    @Test func aFollowUpSendsOnlyTheNewMessage() {
        let session = UUID().uuidString
        _ = RemoteAgentHostHistory.outbound([system, user("hi")], sessionId: session)
        let out = RemoteAgentHostHistory.outbound(
            [system, user("hi"), assistant("hello"), user("next")], sessionId: session)
        #expect(out.host)
        #expect(out.messages.map(\.content) == ["sys", "next"])
    }

    @Test func anEditedHistorySendsEverything() {
        let session = UUID().uuidString
        _ = RemoteAgentHostHistory.outbound([user("hi"), assistant("hello"), user("a")], sessionId: session)
        let edited = [user("hi"), assistant("hello"), user("b"), assistant("ok"), user("c")]
        let out = RemoteAgentHostHistory.outbound(edited, sessionId: session)
        #expect(!out.host)
        #expect(out.messages.count == edited.count)
    }

    @Test func aRetryOrRelaunchSendsEverything() {
        let session = UUID().uuidString
        let conversation = [user("hi"), assistant("hello"), user("next")]
        let fresh = RemoteAgentHostHistory.outbound(conversation, sessionId: session)
        #expect(!fresh.host)

        let retried = RemoteAgentHostHistory.outbound(conversation, sessionId: session)
        #expect(!retried.host)

        RemoteAgentHostHistory.forget(sessionId: session)
        let first = RemoteAgentHostHistory.outbound([user("hi")], sessionId: session)
        #expect(first.host)
    }

    @Test func aNonUserLastMessageIsNeverHostForm() {
        let out = RemoteAgentHostHistory.outbound([user("hi"), assistant("hello")], sessionId: UUID().uuidString)
        #expect(!out.host)
        #expect(out.messages.count == 2)
    }

    @Test func pollingBacksOffAndSpeedsUpOnActivity() {
        let fast = SharedConversationPoller.fastInterval
        let max = SharedConversationPoller.maxInterval
        #expect(SharedConversationPoller.nextInterval(after: fast, gotMessages: false, runJustEnded: false) == fast * 2)
        #expect(SharedConversationPoller.nextInterval(after: max, gotMessages: false, runJustEnded: false) == max)
        #expect(SharedConversationPoller.nextInterval(after: max, gotMessages: true, runJustEnded: false) == fast)
        #expect(SharedConversationPoller.nextInterval(after: max, gotMessages: false, runJustEnded: true) == fast)
        #expect(SharedConversationPoller.nextInterval(after: 0, gotMessages: false, runJustEnded: false) == fast)
    }

    @Test func eventsPageParses() throws {
        let body = """
            {"messages":[
              {"id":"m1","text":"hello","author_kind":"owner","author_handle":"tpae"},
              {"id":"m2","text":""},
              {"id":"m3","text":"hi","author_wallet":"0x9c3e0000000000000000000000000000000011aa"}
            ],"next":7,"reset":true}
            """
        let page = try #require(RemoteProviderService.parseConversationEvents(from: Data(body.utf8)))
        #expect(page.messages.map(\.id) == ["m1", "m3"])
        #expect(page.messages[0].authorHandle == "tpae")
        #expect(page.messages[1].authorKind == ParticipantKind.owner.rawValue)
        #expect(page.next == 7)
        #expect(page.reset)

        let plain = try #require(
            RemoteProviderService.parseConversationEvents(from: Data(#"{"messages":[],"next":-3}"#.utf8)))
        #expect(plain.next == 0)
        #expect(!plain.reset)
        #expect(RemoteProviderService.parseConversationEvents(from: Data("nope".utf8)) == nil)
    }

    @Test func eventsPageCapsLongMessages() throws {
        let long = String(repeating: "x", count: AttentionLimits.textCharacters + 100)
        let body = #"{"messages":[{"id":"m1","text":"\#(long)"}],"next":1}"#
        let page = try #require(RemoteProviderService.parseConversationEvents(from: Data(body.utf8)))
        #expect(page.messages.first?.text.count == AttentionLimits.textCharacters)
    }

    @Test func peerFeaturesAreRememberedPerProvider() throws {
        RemotePeerFeatures.resetForTesting()
        defer { RemotePeerFeatures.resetForTesting() }
        let metadata = try #require(
            RemoteProviderService.parseAgentMetadata(
                from: Data(#"{"name":"Scout","features":["host_history","conversation_events"]}"#.utf8)))
        #expect(metadata.features == [RemotePeerFeatures.hostHistory, RemotePeerFeatures.conversationEvents])

        let peer = UUID()
        RemotePeerFeatures.record(metadata.features, providerId: peer)
        #expect(RemotePeerFeatures.supports(RemotePeerFeatures.hostHistory, providerId: peer))
        #expect(!RemotePeerFeatures.supports(RemotePeerFeatures.callerV2, providerId: peer))
        #expect(!RemotePeerFeatures.supports(RemotePeerFeatures.hostHistory, providerId: UUID()))
    }
}

// MARK: - Stores on disk

@Suite("Attention stores", .serialized)
@MainActor
struct AttentionStoreTests {
    @Test func conversationEventsAreCappedPerConversation() {
        let log = ConversationEventLog()
        log.resetForTesting(fileURL: tempURL("events"))
        let busy = UUID()
        let quiet = UUID()
        log.record(sessionId: quiet, text: "joined", icon: "person")
        let start = Date()
        for index in 0 ..< ConversationEventLog.perConversationCapacity + 3 {
            log.record(sessionId: busy, text: "e\(index)", icon: "bell", at: start.addingTimeInterval(Double(index)))
        }
        let kept = log.events(for: busy)
        #expect(kept.count == ConversationEventLog.perConversationCapacity)
        #expect(kept.first?.text == "e3")
        #expect(log.events(for: quiet).count == 1)
    }

    @Test func conversationEventsSurviveAReload() throws {
        let url = tempURL("events")
        let log = ConversationEventLog()
        log.resetForTesting(fileURL: url)
        let session = UUID()
        log.record(sessionId: session, text: "joined", icon: "person", key: "joined:a")
        log.reloadForTesting()
        #expect(log.events(for: session).map(\.text) == ["joined"])
        #expect(log.record(sessionId: session, text: "joined", icon: "person", key: "joined:a") == nil)
        #expect(try permissions(url) == 0o600)

        log.forget(sessionId: session)
        log.reloadForTesting()
        #expect(log.events(for: session).isEmpty)
    }

    @Test func aCorruptEventLogIsSetAside() throws {
        let url = tempURL("events")
        try Data("[{".utf8).write(to: url)
        let log = ConversationEventLog()
        log.resetForTesting(fileURL: url)
        log.reloadForTesting()
        #expect(log.events(for: UUID()).isEmpty)
        #expect(try quarantined(url))
    }

    @Test func notificationPreferencesRoundTripAndSurviveCorruption() throws {
        let url = tempURL("notification-prefs")
        NotificationPreferencesStore.setOverrideFileURL(url)
        defer { NotificationPreferencesStore.setOverrideFileURL(nil) }

        #expect(NotificationPreferencesStore.load() == nil)
        var prefs = NotificationPreferences.default
        let category = try #require(NotificationCategory.allCases.first)
        let channel = try #require(NotificationChannelID.allCases.first)
        prefs.set(category, channel, !prefs.isOn(category, channel))
        NotificationPreferencesStore.save(prefs)
        #expect(NotificationPreferencesStore.load() == prefs)
        #expect(try permissions(url) == 0o600)

        try Data("{nope".utf8).write(to: url)
        #expect(NotificationPreferencesStore.load() == nil)
        #expect(try quarantined(url))
        NotificationPreferencesStore.save(.default)
        #expect(NotificationPreferencesStore.load() == .default)
    }

    @Test func invitePeerWalletsSurviveConcurrentRedeems() async throws {
        let url = tempURL("invite-peers")
        InvitePeerIdentityStore.setOverrideFileURL(url)
        defer { InvitePeerIdentityStore.setOverrideFileURL(nil) }

        let nonces = (0 ..< 40).map { "nonce-\($0)" }
        await withTaskGroup(of: Void.self) { group in
            for (index, nonce) in nonces.enumerated() {
                group.addTask {
                    InvitePeerIdentityStore.record(
                        wallet: String(format: "0xABC%037d", index), forKeyNonce: nonce)
                }
            }
        }
        InvitePeerIdentityStore.setOverrideFileURL(url)
        for (index, nonce) in nonces.enumerated() {
            #expect(InvitePeerIdentityStore.wallet(forKeyNonce: nonce) == String(format: "0xabc%037d", index))
        }
        #expect(try permissions(url) == 0o600)

        InvitePeerIdentityStore.remove(keyNonces: Array(nonces.prefix(10)))
        InvitePeerIdentityStore.setOverrideFileURL(url)
        #expect(InvitePeerIdentityStore.wallet(forKeyNonce: "nonce-0") == nil)
        #expect(InvitePeerIdentityStore.wallet(forKeyNonce: "nonce-10") != nil)
    }

    @Test func aCorruptInvitePeerFileIsSetAsideNotOverwritten() throws {
        let url = tempURL("invite-peers")
        try Data("garbage".utf8).write(to: url)
        InvitePeerIdentityStore.setOverrideFileURL(url)
        defer { InvitePeerIdentityStore.setOverrideFileURL(nil) }

        #expect(InvitePeerIdentityStore.wallet(forKeyNonce: "n") == nil)
        #expect(try quarantined(url))
        InvitePeerIdentityStore.record(wallet: "0xAA", forKeyNonce: "n")
        InvitePeerIdentityStore.setOverrideFileURL(url)
        #expect(InvitePeerIdentityStore.wallet(forKeyNonce: "n") == "0xaa")
    }
}

// MARK: - ask_owner

@Suite("ask_owner", .serialized)
@MainActor
struct AskOwnerToolTests {
    init() {
        OwnerApprovalService.shared.resetForTesting(leasesFileURL: tempURL("leases"))
    }

    private func route() -> OwnerApprovalRoute {
        OwnerApprovalRoute(
            agentId: UUID(), agentName: "Research Agent", agentAddress: scoutAddress,
            caller: Participant(kind: .teammate, handle: "alice", wallet: "0x\(UUID().uuidString.prefix(8))a11ce"),
            workspaceId: nil, hostedSessionId: nil, conversationKey: UUID().uuidString, timeout: 30,
            onStatus: { _ in })
    }

    private func ask(_ question: String, answer: AttentionResolution?) async throws -> String {
        if let answer {
            Task { @MainActor in
                for _ in 0 ..< 300 {
                    if let item = AttentionCenter.shared.pending.first(where: {
                        $0.toolName == AskOwnerTool.toolName && $0.body == question
                    }) {
                        AttentionCenter.shared.resolve(id: item.id, with: answer)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        }
        let route = route()
        return try await ChatExecutionContext.$ownerApprovalRoute.withValue(route) {
            try await AskOwnerTool().execute(argumentsJSON: #"{"question":"\#(question)"}"#)
        }
    }

    @Test func theOwnersReplyIsTheResult() async throws {
        let question = "Which branch? \(UUID().uuidString)"
        let result = try await ask(
            question, answer: AttentionResolution(outcome: .replied, surface: .phone, replyText: "main"))
        #expect(!ToolEnvelope.isError(result))
        #expect(result.contains("main"))
    }

    @Test func aDismissalIsAnError() async throws {
        let question = "Ship it? \(UUID().uuidString)"
        let result = try await ask(question, answer: AttentionResolution(outcome: .dismissed, surface: .desktop))
        #expect(ToolEnvelope.isError(result))
    }

    @Test func outsideASharedRunTheToolRefuses() async throws {
        let result = try await AskOwnerTool().execute(argumentsJSON: #"{"question":"hi"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(!AttentionCenter.shared.pending.contains { $0.toolName == AskOwnerTool.toolName && $0.body == "hi" })
    }

    @Test func anEmptyQuestionIsRejected() async throws {
        let result = try await ChatExecutionContext.$ownerApprovalRoute.withValue(route()) {
            try await AskOwnerTool().execute(argumentsJSON: #"{"question":"   "}"#)
        }
        #expect(ToolEnvelope.isError(result))
    }
}

// MARK: - Phone and Insights

@Suite("Attention on the phone and in Insights")
@MainActor
struct AttentionInsightsTests {
    @Test func aSettledItemLinksToItsInsightsRow() {
        var item = AttentionItem(kind: .ownerApproval, title: "x", toolName: "web_fetch")
        let pending = PairedDeviceChannel.wire(item)
        #expect(pending["insights_id"] == nil)
        #expect(pending["settled_at"] == nil)

        item.state = .resolved(AttentionResolution(outcome: .approved, surface: .phone))
        item.settledAt = Date()
        let settled = PairedDeviceChannel.wire(item)
        #expect(settled["insights_id"] as? String == item.id.uuidString)
        #expect(settled["settled_at"] is String)
        #expect(settled["outcome"] as? String == "approved")
    }

    @Test func agentAddressFindsRowsByParticipantOrDestination() throws {
        let store = ActivityLogStore()
        try store.openInMemory()
        let scout = Participant(kind: .remoteAgent, agentName: "Scout", agentAddress: scoutAddress)
        let teammate = Participant(kind: .teammate, handle: "alice", wallet: "0x9c3e0000000000000000000000000000000011aa")
        try store.append(
            RequestLog(
                source: .httpAPI, method: "POST", path: "/agents/x/run", statusCode: 200, durationMs: 1,
                participant: scout))
        try store.append(
            RequestLog(
                source: .httpAPI, method: "POST", path: "/agents/x/run", statusCode: 200, durationMs: 1,
                participant: teammate))

        let filter = ActivityFilter(agentAddress: scoutAddress.uppercased())
        let rows = try store.fetch(filter: filter)
        #expect(rows.count == 1)
        #expect(rows.first?.relatedAgentAddress == scoutAddress)
        #expect(InsightsService.filterInMemory(try store.fetch(), filter).count == 1)

        let clause = ActivityLogStore.whereClause(filter)
        #expect(clause.sql.contains("agent_address"))
        #expect(clause.sql.contains("participant_key"))
    }

    @Test func onlyAgentsHaveARelatedAgentAddress() {
        let teammate = Participant(kind: .teammate, handle: "alice", wallet: "0x9c3e0000000000000000000000000000000011aa")
        let log = RequestLog(
            source: .httpAPI, method: "POST", path: "/agents/x/run", statusCode: 200, durationMs: 1,
            participant: teammate)
        #expect(log.relatedAgentAddress == nil)
    }

    @Test func timelineShowsAskedNotifiedAndSettled() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let raised = 1_700_000_000_000.0
        let details = [
            "raised_at_ms": String(Int(raised)),
            "delivered_at_ms": String(Int(raised + 200)),
            "settled_at_ms": String(Int(raised + 42_000)),
            "delivered_to": "in_app,phone",
        ]
        let steps = InteractionTimeline.steps(details: details, method: "approved", timeZone: utc)
        #expect(steps.map(\.id) == ["raised", "delivered", "settled"])
        #expect(!steps[1].value.contains("+"))
        #expect(steps[2].value.contains("+42.0s"))
        #expect(steps[1].label == "Notified")
        #expect(steps[1].value.contains(NotificationChannelID.phone.displayName))

        #expect(InteractionTimeline.steps(details: [:], method: "approved").isEmpty)
        let unsettled = InteractionTimeline.steps(details: ["raised_at_ms": String(Int(raised))], method: "approved")
        #expect(unsettled.map(\.id) == ["raised"])
    }
}
