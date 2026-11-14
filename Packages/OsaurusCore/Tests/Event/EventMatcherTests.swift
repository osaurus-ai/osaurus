//
//  EventMatcherTests.swift
//  OsaurusCoreTests
//
//  Which channel events a message fires (alias, room-scoped and any-room
//  tiers, fan-out, mention gating), why nothing fired, and the Only When
//  filter clauses.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Event matcher")
struct EventMatcherTests {
    private let salesAgent = UUID()
    private let supportAgent = UUID()
    private let defaultAgent = UUID()

    private func event(
        _ agent: UUID,
        name: String = "Event",
        kind: AgentChannelKind = .slack,
        connectionId: String? = nil,
        rooms: [String] = [],
        aliases: [String] = [],
        requireMention: Bool = false,
        continueThreads: Bool = true,
        enabled: Bool = true
    ) -> OsaurusEvent {
        EventTestFixtures.channelAgentEvent(
            name: name, kind: kind, connectionId: connectionId, agentId: agent, rooms: rooms, aliases: aliases,
            requireMention: requireMention, continueThreads: continueThreads, isEnabled: enabled)
    }

    private func facts(
        room: String,
        _ content: String,
        kind: AgentChannelKind = .slack,
        connectionId: String = "slack",
        mentionsBot: Bool? = true,
        hasPriorOutbound: Bool = false
    ) -> EventMatcher.ChannelFacts {
        EventMatcher.ChannelFacts(
            kind: kind, connectionId: connectionId, roomId: room, content: content, mentionsBot: mentionsBot,
            hasPriorOutbound: hasPriorOutbound)
    }

    private func agents(_ matches: [EventMatcher.ChannelMatch]) -> [UUID?] {
        matches.map(\.event.agentId)
    }

    // MARK: - Tiers

    @Test
    func roomEventClaimsItsRoomAndAnyRoomEventTheRest() {
        let events = [event(salesAgent, rooms: ["C-SALES"]), event(defaultAgent)]
        let inRoom = EventMatcher.rankChannelEvents(events, facts: facts(room: "C-SALES", "how are numbers?"))
        #expect(agents(inRoom) == [salesAgent])
        #expect(inRoom.first?.rule == "room:C-SALES")
        #expect(inRoom.first?.content == "how are numbers?")

        let other = EventMatcher.rankChannelEvents(events, facts: facts(room: "C-OTHER", "hello"))
        #expect(agents(other) == [defaultAgent])
        #expect(other.first?.rule == "default")
    }

    @Test
    func aliasBeatsRoomEventAndStripsPrefix() {
        let events = [
            event(salesAgent, rooms: ["C-SHARED"]),
            event(supportAgent, rooms: ["C-SHARED"], aliases: ["support"]),
            event(defaultAgent),
        ]
        let aliased = EventMatcher.rankChannelEvents(events, facts: facts(room: "C-SHARED", "support: reset my password"))
        #expect(agents(aliased) == [supportAgent])
        #expect(aliased.first?.rule == "alias:support")
        #expect(aliased.first?.content == "reset my password")

        let plain = EventMatcher.rankChannelEvents(events, facts: facts(room: "C-SHARED", "what changed this week?"))
        #expect(agents(plain) == [salesAgent])
        #expect(plain.first?.rule == "room:C-SHARED")
    }

    @Test
    func aliasMatchingIsCaseInsensitiveAndAcceptsAtPrefix() {
        let events = [event(supportAgent, aliases: ["Support"])]
        for content in ["SUPPORT: hi", "@support hi", "support, hi", "support hi"] {
            let matches = EventMatcher.rankChannelEvents(events, facts: facts(room: "C-ANY", content))
            #expect(agents(matches) == [supportAgent], "content: \(content)")
            #expect(matches.first?.content == "hi", "content: \(content)")
        }
    }

    @Test
    func aliasRequiresDelimiterSoPrefixWordsDoNotHijack() {
        let events = [event(supportAgent, aliases: ["sales"]), event(defaultAgent)]
        let matches = EventMatcher.rankChannelEvents(events, facts: facts(room: "C-ANY", "salesforce is down"))
        #expect(agents(matches) == [defaultAgent])
        #expect(matches.first?.rule == "default")
    }

    @Test
    func longerAliasWinsOverShorterAndRoomScopedBeatsAnyRoom() {
        let euAgent = UUID()
        let byLength = EventMatcher.rankChannelEvents(
            [event(salesAgent, aliases: ["sales"]), event(euAgent, aliases: ["sales-eu"])],
            facts: facts(room: "C-ANY", "sales-eu: forecast?"))
        #expect(agents(byLength) == [euAgent])

        let byScope = EventMatcher.rankChannelEvents(
            [event(salesAgent, aliases: ["bot"]), event(supportAgent, rooms: ["C-ROOM"], aliases: ["bot"])],
            facts: facts(room: "C-ROOM", "bot: hi"))
        #expect(agents(byScope) == [supportAgent])
    }

    @Test
    func aliasOnlyEventDoesNotClaimUnaliasedMessages() {
        let events = [event(supportAgent, rooms: ["C-ROOM"], aliases: ["support"])]
        #expect(EventMatcher.rankChannelEvents(events, facts: facts(room: "C-ROOM", "hello there")).isEmpty)
    }

    /// Several events in the winning tier all fire: one message can run an
    /// agent and a second agent with different instructions.
    @Test
    func everyEventInTheWinningTierFires() {
        let events = [
            event(salesAgent, name: "Answer", rooms: ["C-1"]),
            event(supportAgent, name: "Log", rooms: ["C-1"]),
            event(defaultAgent, name: "Fallback"),
        ]
        let matches = EventMatcher.rankChannelEvents(events, facts: facts(room: "C-1", "hi"))
        #expect(Set(matches.map(\.event.name)) == ["Answer", "Log"])
    }

    @Test
    func disabledEventsAndOtherConnectionsNeverMatch() {
        let events = [
            event(salesAgent, enabled: false),
            event(supportAgent, kind: .discord),
            event(defaultAgent, kind: .n8n, connectionId: "n8n-other"),
        ]
        #expect(EventMatcher.rankChannelEvents(events, facts: facts(room: "C-A", "hi")).isEmpty)
        #expect(
            EventMatcher.rankChannelEvents(
                events, facts: facts(room: "C-A", "hi", kind: .n8n, connectionId: "n8n-main")
            ).isEmpty)
        // Connection ids compare trimmed, like the listener snapshot key.
        #expect(
            agents(
                EventMatcher.rankChannelEvents(
                    events, facts: facts(room: "C-A", "hi", kind: .n8n, connectionId: " n8n-other "))) == [defaultAgent])
    }

    // MARK: - Mentions

    @Test
    func mentionGateAppliesPerEvent() {
        let gated = event(salesAgent, name: "Gated", requireMention: true)
        let open = event(supportAgent, name: "Open")
        let unmentioned = facts(room: "C-1", "hi", mentionsBot: false)
        #expect(EventMatcher.rankChannelEvents([gated, open], facts: unmentioned).map(\.event.name) == ["Open"])
        #expect(EventMatcher.rankChannelEvents([gated], facts: unmentioned).isEmpty)

        // A follow-up in a thread the bot already answered keeps going.
        let followUp = facts(room: "C-1", "and then?", mentionsBot: false, hasPriorOutbound: true)
        #expect(agents(EventMatcher.rankChannelEvents([gated], facts: followUp)) == [salesAgent])
        let noContinue = event(salesAgent, requireMention: true, continueThreads: false)
        #expect(EventMatcher.rankChannelEvents([noContinue], facts: followUp).isEmpty)

        // Unknown mention state (no bot identity) never blocks.
        #expect(!EventMatcher.rankChannelEvents([gated], facts: facts(room: "C-1", "hi", mentionsBot: nil)).isEmpty)
    }

    @Test
    func platformsWithoutMentionsIgnoreRequireMention() {
        let telegram = event(salesAgent, kind: .telegram, requireMention: true)
        let matches = EventMatcher.rankChannelEvents(
            [telegram], facts: facts(room: "chat", "hi", kind: .telegram, connectionId: "telegram", mentionsBot: false))
        #expect(agents(matches) == [salesAgent])
    }

    // MARK: - Why nothing fired

    @Test
    func noMatchReasonExplainsTheMiss() {
        let f = facts(room: "C-1", "hi", mentionsBot: false)
        #expect(EventManager.noMatchReason([], facts: f) == "no_event_configured")
        #expect(EventManager.noMatchReason([event(salesAgent, enabled: false)], facts: f) == "no_event_configured")
        #expect(EventManager.noMatchReason([event(salesAgent, rooms: ["C-2"])], facts: f) == "no_event_for_room")
        #expect(
            EventManager.noMatchReason([event(salesAgent, requireMention: true, continueThreads: false)], facts: f)
                == "mention_required")
        #expect(
            EventManager.noMatchReason([event(salesAgent, aliases: ["sales"])], facts: f) == "no_event_matched")
    }

    // MARK: - Filter

    private func messagePayload(text: String, senderId: String = "U1", senderName: String = "Ada") -> JSONValue {
        .object([
            "text": .string(text),
            "message": .object(["sender_id": .string(senderId), "sender_name": .string(senderName)]),
        ])
    }

    @Test
    func emptyFilterPassesEverything() {
        #expect(EventMatcher.filterRejection(EventFilter(), payload: .object([:])) == nil)
    }

    @Test
    func senderAllowlistMatchesIdOrNameCaseInsensitively() {
        let filter = EventFilter(senderAllowlist: ["ada"])
        #expect(EventMatcher.filterRejection(filter, payload: messagePayload(text: "x")) == nil)
        #expect(EventMatcher.filterRejection(EventFilter(senderAllowlist: ["u1"]), payload: messagePayload(text: "x")) == nil)
        #expect(
            EventMatcher.filterRejection(filter, payload: messagePayload(text: "x", senderId: "U2", senderName: "Bob"))
                == "filtered:sender")
    }

    @Test
    func keywordClauses() {
        let any = EventFilter(keywordsAny: ["invoice", "receipt"])
        #expect(EventMatcher.filterRejection(any, payload: messagePayload(text: "New INVOICE attached")) == nil)
        #expect(EventMatcher.filterRejection(any, payload: messagePayload(text: "hello")) == "filtered:keywords_any")

        let all = EventFilter(keywordsAll: ["urgent", "deploy"])
        #expect(EventMatcher.filterRejection(all, payload: messagePayload(text: "urgent: deploy now")) == nil)
        #expect(EventMatcher.filterRejection(all, payload: messagePayload(text: "urgent")) == "filtered:keywords_all")
    }

    @Test
    func pathGlobsMatchNameOrFullPathAndPassAnEmptyDiff() {
        let filter = EventFilter(pathGlobs: ["*.pdf"])
        func folder(_ paths: [String]) -> JSONValue {
            .object(["folder": .object(["changed_paths": .array(paths.map(JSONValue.string))])])
        }
        #expect(EventMatcher.filterRejection(filter, payload: folder(["notes.txt", "scan.pdf"])) == nil)
        #expect(EventMatcher.filterRejection(filter, payload: folder(["notes.txt"])) == "filtered:path_globs")
        #expect(EventMatcher.filterRejection(filter, payload: folder([])) == nil)
        #expect(EventMatcher.matchesAnyGlob("old.pdf (removed)", ["*.pdf"]))
        #expect(EventMatcher.matchesAnyGlob("/a/b/report.md", ["/a/b/*"]))
    }

    @Test
    func conditionsCompareRenderedPayloadValues() {
        let filter = EventFilter(conditions: [EventCondition(path: "webhook.body.action", equals: "opened")])
        func body(_ action: JSONValue) -> JSONValue {
            .object(["webhook": .object(["body": .object(["action": action])])])
        }
        #expect(EventMatcher.filterRejection(filter, payload: body(.string("Opened"))) == nil)
        #expect(
            EventMatcher.filterRejection(filter, payload: body(.string("closed")))
                == "filtered:condition:webhook.body.action")
        #expect(
            EventMatcher.filterRejection(filter, payload: .object([:])) == "filtered:condition:webhook.body.action")
    }

    // MARK: - Legacy routing still decodes for migration

    @Test
    func legacyInboundDispatchWithoutRoutesDecodes() throws {
        let legacy = Data(
            """
            {"enabled": true, "targetAgentId": "\(defaultAgent.uuidString)", "requireMention": true,
             "continueThreads": true, "autoReplyEnabled": false}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(AgentChannelInboundDispatchConfiguration.self, from: legacy)
        #expect(decoded.enabled)
        #expect(decoded.targetAgentId == defaultAgent)
        #expect(decoded.routes.isEmpty)
    }
}
