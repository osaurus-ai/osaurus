//
//  ChannelAgentRosterTests.swift
//  osaurusTests
//
//  A channel's routing picture: every channel automation is a rule in
//  routing order, posting summarizes per agent, the plain-language
//  summary and warnings, the by-agent overview, and the writes the
//  channel sheet performs (add rule, duplicate, set rooms, set posting).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ChannelAgentRosterTests {
    private let slack = AgentChannelConnection.nativeSlackConnectionId

    private func binding(
        agent: UUID, room: String, mode: AgentChannelBindingOutboundMode, connection: String? = nil,
        enabled: Bool = true, id: String? = nil
    ) -> AgentChannelBinding {
        AgentChannelBinding(
            id: id ?? "b-\(room)-\(agent.uuidString.prefix(4))", agentId: agent, connectionId: connection ?? slack,
            roomId: room, outboundMode: mode, enabled: enabled)
    }

    @Test func everyChannelAutomationIsARuleInRoutingOrder() {
        let triage = UUID()
        let ops = UUID()
        let dinoki = UUID()
        let sales = UUID()
        let anyRoom = EventTestFixtures.channelAgentEvent(name: "Dinoki", kind: .slack, agentId: dinoki)
        let support = EventTestFixtures.channelAgentEvent(
            name: "Triage", kind: .slack, agentId: triage, rooms: ["C-SUP"])
        let opsRooms = EventTestFixtures.channelAgentEvent(
            name: "Ops", kind: .slack, agentId: ops, rooms: ["C-OPS", "C-INC"])
        let aliased = EventTestFixtures.channelAgentEvent(
            name: "Sales", kind: .slack, agentId: sales, aliases: ["sales"])
        let roster = ChannelAgentRoster.build(
            events: [anyRoom, support, opsRooms, aliased], bindings: [], connectionId: slack, writableRoomIds: [])

        // Alias rules first, then room rules (in creation order), then any-room.
        #expect(roster.rules.map(\.id) == [aliased.id, support.id, opsRooms.id, anyRoom.id])
        #expect(roster.rules.map(\.scope) == [.alias, .room, .room, .anyRoom])
        #expect(roster.rules[1].target == .agent(.local(triage)))
        #expect(roster.rules[2].roomIds == ["C-OPS", "C-INC"])
        // Every local agent gets a posting entry; nothing is writable here.
        #expect(roster.posting.map(\.agentId) == [sales, triage, ops, dinoki])
        #expect(roster.posting.allSatisfy { $0.posting == .unavailable })
    }

    @Test func manyAgentsAcrossManyRoomsReadAsRoutingLines() {
        let triage = UUID()
        let ops = UUID()
        let dinoki = UUID()
        let roster = ChannelAgentRoster.build(
            events: [
                EventTestFixtures.channelAgentEvent(kind: .slack, agentId: triage, rooms: ["C-SUP"]),
                EventTestFixtures.channelAgentEvent(kind: .slack, agentId: ops, rooms: ["C-SUP", "C-OPS"]),
                EventTestFixtures.channelAgentEvent(kind: .slack, agentId: dinoki),
                EventTestFixtures.channelAgentEvent(kind: .slack, agentId: UUID(), isEnabled: false),
            ],
            bindings: [], connectionId: slack, writableRoomIds: [])
        let lines = roster.routingLines()
        #expect(lines.map(\.kind) == [.room("C-SUP"), .room("C-OPS"), .everywhereElse])
        #expect(lines[0].targets == [.agent(.local(triage)), .agent(.local(ops))])
        #expect(lines[1].targets == [.agent(.local(ops))])
        #expect(lines[2].targets == [.agent(.local(dinoki))])

        let warnings = roster.routingWarnings(readableRoomIds: ["C-SUP", "C-OPS", "C-DEV"])
        // Two agents answer #support; every room is covered by Any room.
        #expect(warnings == [.severalAnswer(.room("C-SUP"), [.agent(.local(triage)), .agent(.local(ops))])])
    }

    @Test func warningsCallOutLostAndUnansweredMessages() {
        let ops = UUID()
        let none = ChannelAgentRoster.build(events: [], bindings: [], connectionId: slack, writableRoomIds: [])
        #expect(none.routingWarnings(readableRoomIds: ["C1"]) == [.nobodyAnswers])

        let roomOnly = ChannelAgentRoster.build(
            events: [EventTestFixtures.channelAgentEvent(kind: .slack, agentId: ops, rooms: ["C1"])],
            bindings: [], connectionId: slack, writableRoomIds: [])
        #expect(roomOnly.routingWarnings(readableRoomIds: ["C1", "C2"]) == [.uncoveredRooms(["C2"])])
        #expect(roomOnly.routingLines().last == .init(kind: .everywhereElse, targets: [], mentionOnly: false))

        let noAgent = EventTestFixtures.channelAgentEvent(kind: .slack, agentId: nil)
        let missing = ChannelAgentRoster.build(events: [noAgent], bindings: [], connectionId: slack, writableRoomIds: [])
        #expect(missing.routingWarnings(readableRoomIds: []).contains(.missingTarget(noAgent.id)))

        // A mention names the one bot, so mention-only rules still both answer.
        let first = UUID()
        let second = UUID()
        let a = EventTestFixtures.channelAgentEvent(kind: .slack, agentId: first, requireMention: true)
        let b = EventTestFixtures.channelAgentEvent(kind: .slack, agentId: second, requireMention: true)
        let mentions = ChannelAgentRoster.build(events: [a, b], bindings: [], connectionId: slack, writableRoomIds: [])
        #expect(
            mentions.routingWarnings(readableRoomIds: [])
                == [.severalAnswer(.everywhereElse, [.agent(.local(first)), .agent(.local(second))])])
        #expect(mentions.routingLines().last?.mentionOnly == true)
    }

    @Test func workflowRulesHaveNoPostingEntry() {
        let workflowId = UUID()
        let event = OsaurusEvent(
            name: "Triage", source: .channelMessage(ChannelMessageSourceConfig(kind: .slack)),
            action: .workflow(WorkflowEventAction(workflowID: workflowId)),
            reply: EventReplyPolicy(replyWithWorkflowOutput: true))
        let roster = ChannelAgentRoster.build(
            events: [event], bindings: [], connectionId: slack, writableRoomIds: ["C1"])
        #expect(roster.rules.count == 1)
        #expect(roster.rules[0].target == .workflow(workflowId))
        #expect(roster.rules[0].repliesAutomatically)
        #expect(roster.posting.isEmpty)
    }

    @Test func postingSummarizesTheConnectionsBindings() {
        let agent = UUID()
        let askBoth = [binding(agent: agent, room: "C1", mode: .confirm), binding(agent: agent, room: "C2", mode: .confirm)]
        #expect(ChannelAgentRoster.postingSummary(askBoth) == .askFirst)
        #expect(ChannelAgentRoster.postingSummary([binding(agent: agent, room: "C1", mode: .autonomous)]) == .withoutAsking)
        #expect(
            ChannelAgentRoster.postingSummary([
                binding(agent: agent, room: "C1", mode: .confirm), binding(agent: agent, room: "C2", mode: .autonomous),
            ]) == .mixed)
        #expect(ChannelAgentRoster.postingSummary([binding(agent: agent, room: "C1", mode: .off)]) == .off)
        #expect(ChannelAgentRoster.postingSummary([binding(agent: agent, room: "C1", mode: .confirm, enabled: false)]) == .off)
        #expect(ChannelAgentRoster.postingSummary([]) == .off)
    }

    @Test func postOnlyAgentsGetAPostingEntryAndOtherConnectionsAreIgnored() {
        let digest = UUID()
        let elsewhere = binding(agent: UUID(), room: "D1", mode: .confirm, connection: AgentChannelConnection.nativeDiscordConnectionId)
        let roster = ChannelAgentRoster.build(
            events: [], bindings: [binding(agent: digest, room: "C1", mode: .confirm), elsewhere],
            connectionId: slack, writableRoomIds: ["C1"])
        #expect(roster.rules.isEmpty)
        #expect(roster.posting.map(\.agentId) == [digest])
        #expect(roster.posting[0].posting == .askFirst)
        #expect(roster.posting[0].bindings.map(\.roomId) == ["C1"])
    }

    @Test func newRuleIsScopedToTheChosenRoomsWithAUniqueName() {
        let agent = UUID()
        let anyRoom = ChannelAgentRoster.newRule(
            kind: .slack, connectionId: slack, connectionName: "Slack", target: .agent(.local(agent)),
            targetName: "Ops Agent")
        #expect(anyRoom.name == "Ops Agent on Slack")
        #expect(anyRoom.source.channelMessage?.roomIds.isEmpty == true)
        #expect(anyRoom.source.channelMessage?.aliases.isEmpty == true)
        #expect(anyRoom.filter.isEmpty)
        #expect(anyRoom.reply.autoReply)
        #expect(anyRoom.agentId == agent)

        let scoped = ChannelAgentRoster.newRule(
            kind: .slack, connectionId: slack, connectionName: "Slack", target: .agent(.local(agent)),
            targetName: "Ops Agent", roomIds: ["C-OPS", "C-INC"], roomName: { $0 == "C-OPS" ? "#ops" : $0 },
            existingNames: ["Ops Agent in #ops, C-INC on Slack"])
        #expect(scoped.source.channelMessage?.roomIds == ["C-OPS", "C-INC"])
        #expect(scoped.name == "Ops Agent in #ops, C-INC on Slack 2")

        let workflow = ChannelAgentRoster.newRule(
            kind: .n8n, connectionId: "n8n-main", connectionName: "n8n", target: .workflow(UUID()), targetName: "Triage")
        #expect(workflow.reply.replyWithWorkflowOutput)
        #expect(!workflow.reply.autoReply)
        #expect(workflow.source.channelMessage?.connectionId == "n8n-main")
    }

    @Test func newWorkflowRuleBindsInputsFromTheMessageAndDefersToReplySteps() {
        let def = WorkflowDefinition(
            inputSchema: WF.object(["request": WF.string, "sender_id": WF.string, "budget": WF.number], required: ["request", "sender_id", "budget"]),
            outputSchema: WF.object([:]),
            nodes: [WorkflowNode(id: "ack", name: "Ack", kind: .reply(ReplySpec(text: "On it")))],
            edges: [], output: .object([:]))
        let rule = ChannelAgentRoster.newRule(
            kind: .telegram, connectionId: "tg", connectionName: "Telegram", target: .workflow(UUID()),
            targetName: "Triage", workflowDefinition: def)
        let mapping = rule.action.workflow?.inputMapping ?? [:]
        #expect(mapping["request"] == "{{text}}")
        #expect(mapping["sender_id"]?.contains("sender_id") == true)
        #expect(mapping["budget"] == nil)
        #expect(!rule.reply.replyWithWorkflowOutput, "the workflow replies from its own steps")
        #expect(ChannelAgentRoster.unboundRequiredInputs(def).map(\.key) == ["budget"])

        var plain = def
        plain.nodes = [WF.code("work")]
        let posting = ChannelAgentRoster.newRule(
            kind: .telegram, connectionId: "tg", connectionName: "Telegram", target: .workflow(UUID()),
            targetName: "Triage", workflowDefinition: plain)
        #expect(posting.reply.replyWithWorkflowOutput)
    }

    @Test func duplicateAndSetRoomsKeepTheRestOfTheRule() {
        var original = EventTestFixtures.channelAgentEvent(
            name: "Ops", kind: .slack, agentId: UUID(), rooms: ["C1"], aliases: ["ops"], instructions: "Be brief",
            autoReply: false)
        original.filter = EventFilter(keywordsAny: ["deploy"])
        let copy = try! #require(
            ChannelAgentRoster.duplicate(
                original, roomIds: ["C2"], connectionName: "Slack", targetName: "Ops", existingNames: ["Ops"]))
        #expect(copy.id != original.id)
        #expect(copy.source.channelMessage?.roomIds == ["C2"])
        #expect(copy.source.channelMessage?.aliases == ["ops"])
        #expect(copy.filter == original.filter)
        #expect(copy.action == original.action)
        #expect(copy.reply == original.reply)
        #expect(copy.name == "Ops in C2 on Slack")

        let moved = ChannelAgentRoster.withRooms(original, roomIds: [])
        #expect(moved.id == original.id)
        #expect(moved.source.channelMessage?.roomIds.isEmpty == true)
        #expect(moved.source.channelMessage?.aliases == ["ops"])
        #expect(ChannelAgentRoster.uniqueName("A", among: ["a", "A 2"]) == "A 3")
    }

    @Test func settingPostingWritesOneStoredBindingPerWritableRoom() {
        let agent = UUID()
        let kept = binding(agent: agent, room: "C1", mode: .confirm, id: "my-standup")
        let plan = ChannelAgentRoster.postingBindings(
            mode: .autonomous, agentId: agent, connectionId: slack, connectionName: "Slack",
            writableRoomIds: ["C1", "C2"], stored: [kept])
        #expect(plan.map(\.roomId) == ["C1", "C2"])
        #expect(plan.allSatisfy { $0.outboundMode == .autonomous && $0.enabled })
        // The customized room keeps its identity; the new room gets a
        // deterministic non-automatic id.
        #expect(plan[0].id == "my-standup")
        #expect(plan[1].id == ChannelAgentRoster.placeBindingId(connectionId: slack, roomId: "C2", agentId: agent))
        #expect(!AgentChannelAutoDestinationResolver.isAutomaticBindingId(plan[1].id))
        #expect(plan[1].allowedSources == AgentChannelBindingRunSource.allCases)

        let off = ChannelAgentRoster.postingBindings(
            mode: .off, agentId: agent, connectionId: slack, connectionName: "Slack", writableRoomIds: ["C1"],
            stored: [])
        #expect(off.count == 1 && off[0].outboundMode == .off)
        #expect(ChannelAgentRoster.postingSummary(off) == .off)
    }

    @Test func presenceDetailReadsLikeTheRules() {
        let agent = UUID()
        let other = UUID()
        func detail(_ events: [OsaurusEvent], bindings: [AgentChannelBinding] = [], writable: [String] = ["C1"])
            -> String?
        {
            ChannelAgentRoster.build(events: events, bindings: bindings, connectionId: slack, writableRoomIds: writable)
                .presenceDetail(for: agent, roomName: { $0 == "C-OPS" ? "#ops" : $0 })
        }
        // Not on the channel at all.
        #expect(detail([], writable: []) == nil)
        #expect(detail([EventTestFixtures.channelAgentEvent(kind: .slack, agentId: other)], writable: []) == nil)

        let plain = EventTestFixtures.channelAgentEvent(kind: .slack, agentId: agent)
        #expect(detail([plain]) == "Answers, replies automatically")
        #expect(
            detail([plain], bindings: [binding(agent: agent, room: "C1", mode: .confirm)])
                == "Answers, replies automatically, posts after asking first")
        #expect(
            detail([plain], bindings: [binding(agent: agent, room: "C1", mode: .autonomous)])
                == "Answers, replies automatically, posts without asking")

        let held = EventTestFixtures.channelAgentEvent(kind: .slack, agentId: agent, rooms: ["C-OPS"], autoReply: false)
        #expect(detail([held]) == "Answers in #ops, replies after your approval")
        let second = EventTestFixtures.channelAgentEvent(kind: .slack, agentId: agent, rooms: ["C-INC"])
        #expect(detail([held, second]) == "Answers in #ops, C-INC, replies depend on the rule")

        let paused = EventTestFixtures.channelAgentEvent(kind: .slack, agentId: agent, isEnabled: false)
        #expect(detail([paused]) == "Answering is off")

        let aliased = EventTestFixtures.channelAgentEvent(kind: .slack, agentId: agent, aliases: ["ops"])
        #expect(detail([aliased]) == "Answers to “ops”, replies automatically")

        // Post-only (a digest agent).
        #expect(detail([], bindings: [binding(agent: agent, room: "C1", mode: .confirm)]) == "Posts after asking first")
        // An entry that exists but does nothing (posting switched off).
        #expect(detail([], bindings: [binding(agent: agent, room: "C1", mode: .off)]) == "Not active here")
    }

    @Test func agentOverviewGroupsEveryChannelByAgent() {
        let ops = UUID()
        let discord = AgentChannelConnection.nativeDiscordConnectionId
        let slackRoster = ChannelAgentRoster.build(
            events: [EventTestFixtures.channelAgentEvent(kind: .slack, agentId: ops, rooms: ["C1"])],
            bindings: [binding(agent: ops, room: "C1", mode: .confirm)],
            connectionId: slack, writableRoomIds: ["C1"])
        let discordRoster = ChannelAgentRoster.build(
            events: [EventTestFixtures.channelAgentEvent(kind: .discord, connectionId: discord, agentId: ops)],
            bindings: [], connectionId: discord, writableRoomIds: [])
        let rows = ChannelAgentRoster.agentOverview([(slack, slackRoster), (discord, discordRoster)])
        #expect(rows.count == 1)
        #expect(rows[0].target == .agent(.local(ops)))
        #expect(rows[0].answers.map(\.connectionId) == [slack, discord])
        #expect(rows[0].answers.map(\.roomIds) == [["C1"], []])
        #expect(rows[0].posts == [.init(connectionId: slack, posting: .askFirst)])
    }
}
