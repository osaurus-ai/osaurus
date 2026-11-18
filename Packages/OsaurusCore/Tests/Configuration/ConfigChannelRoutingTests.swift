//
//  ConfigChannelRoutingTests.swift
//  osaurusTests
//
//  `channels.<platform>.routing` and `.posting`: a routing rule plans,
//  applies and exports as the channel automation the Routing table shows,
//  prune is scoped to the declared platform, names are unique across
//  automations and rules, and posting writes the agent's bindings with
//  `without_asking` flagged.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ConfigChannelRoutingTests {

    private func withAgent(_ body: (Agent) async throws -> Void) async throws {
        let agent = AgentManager.shared.create(
            name: "Routing Probe \(UUID().uuidString.prefix(6))",
            description: "Exercises channel routing configuration in this isolated test.", systemPrompt: "")
        do {
            try await body(agent)
        } catch {
            _ = await AgentManager.shared.delete(id: agent.id)
            throw error
        }
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    private func slackDocument(
        _ rules: [ChannelRoutingRuleEntry], writable: [String]? = nil, readable: [String]? = nil
    ) -> OsaurusConfigDocument {
        var slack = ChannelPlatformSection()
        slack.routing = rules
        if let writable {
            slack.writeEnabled = !writable.isEmpty
            slack.writeAllowlist = writable
        }
        slack.readAllowlist = readable
        var channels = ChannelsSection()
        channels.slack = slack
        var document = OsaurusConfigDocument()
        document.channels = channels
        return document
    }

    private func deleteEvents(named name: String) {
        for event in EventManager.shared.events where event.name == name {
            _ = EventManager.shared.delete(id: event.id)
        }
    }

    // MARK: - Routing

    @Test func aRoutingRulePlansAppliesAndExportsUnderItsChannel() async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            try await Self.runRoutingRoundTrip()
        }
    }

    @MainActor
    private static func runRoutingRoundTrip() async throws {
        let before = ConfigExporter.export().channels?.slack
        var thrown: Error?
        do { try await routingRoundTrip() } catch { thrown = error }
        var restore = ChannelPlatformSection()
        restore.writeEnabled = before?.writeEnabled
        restore.writeAllowlist = before?.writeAllowlist ?? []
        var channels = ChannelsSection()
        channels.slack = restore
        var document = OsaurusConfigDocument()
        document.channels = channels
        _ = await ConfigApplier.apply(document: document, prune: false)
        if let thrown { throw thrown }
    }

    @MainActor
    private static func routingRoundTrip() async throws {
        try await Self().withAgent { agent in
            let test = Self()
            let name = "Support triage \(UUID().uuidString.prefix(6))"
            defer { test.deleteEvents(named: name) }
            var rule = ChannelRoutingRuleEntry(name: name)
            rule.agent = agent.name
            rule.rooms = ["C0SUPPORT", "C0HELP"]
            rule.replies = "automatic"
            // Automatic replies need the rooms writable.
            let document = test.slackDocument([rule], writable: ["C0SUPPORT", "C0HELP"])

            let plan = try ConfigPlanner.plan(document: document, prune: false)
            let create = try #require(plan.actions.first { $0.target == "slack routing: \(name)" })
            #expect(create.section == "channels")
            #expect(create.kind == .create)
            #expect(create.changes.first?.contains("answers in C0SUPPORT, C0HELP (replies automatically)") == true)
            #expect(create.risks == [ConfigRisk.channelAutoReply("Slack")])

            let results = await ConfigApplier.apply(document: document, prune: false)
            #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
            let event = try #require(EventManager.shared.events.first { $0.name == name })
            #expect(event.source.channelMessage?.kind == .slack)
            #expect(event.source.channelMessage?.roomIds == ["C0SUPPORT", "C0HELP"])
            #expect(event.reply.autoReply)
            #expect(event.agentId == agent.id)

            // Exported under channels, not automations; re-planning is a no-op.
            let exported = ConfigExporter.export()
            #expect(exported.channels?.slack?.routing?.contains { $0.name == name } == true)
            #expect(exported.automations?.contains { $0.name == name } != true)
            let again = try ConfigPlanner.plan(document: test.slackDocument([rule]), prune: false)
            #expect(!again.actions.contains { $0.target.contains(name) }, "\(again.summaryText())")

            // Patch: approval instead of automatic.
            var quieter = ChannelRoutingRuleEntry(name: name)
            quieter.replies = "approval"
            let patch = try ConfigPlanner.plan(document: test.slackDocument([quieter]), prune: false)
            let update = try #require(patch.actions.first { $0.target == "slack routing: \(name)" })
            #expect(update.changes == ["replies: automatic -> approval"])
        }
    }

    @Test func pruneOnlyTouchesTheDeclaredChannel() async throws {
        try await withAgent { agent in
            let slackRule = EventManager.shared.create(
                OsaurusEvent(
                    name: "Prune slack \(UUID().uuidString.prefix(6))", isEnabled: false,
                    source: .channelMessage(ChannelMessageSourceConfig(kind: .slack, roomIds: ["C1"])),
                    action: .agent(AgentEventAction(target: .local(agent.id), instructions: ""))))
            let telegramRule = EventManager.shared.create(
                OsaurusEvent(
                    name: "Prune telegram \(UUID().uuidString.prefix(6))", isEnabled: false,
                    source: .channelMessage(ChannelMessageSourceConfig(kind: .telegram)),
                    action: .agent(AgentEventAction(target: .local(agent.id), instructions: ""))))
            defer {
                _ = EventManager.shared.delete(id: slackRule.id)
                _ = EventManager.shared.delete(id: telegramRule.id)
            }

            let plan = try ConfigPlanner.plan(document: slackDocument([]), prune: true)
            #expect(plan.actions.contains { $0.kind == .delete && $0.target == "slack routing: \(slackRule.name)" })
            #expect(!plan.actions.contains { $0.target.contains(telegramRule.name) })

            // `automations: []` with prune never deletes channel rules.
            var automationsOnly = OsaurusConfigDocument()
            automationsOnly.automations = []
            let triggers = try ConfigPlanner.plan(document: automationsOnly, prune: true)
            #expect(!triggers.actions.contains { $0.target.contains(slackRule.name) })
            #expect(!triggers.actions.contains { $0.target.contains(telegramRule.name) })
        }
    }

    @Test func namesAreUniqueAcrossAutomationsAndRulesAndErrorsNameTheKey() async throws {
        try await withAgent { agent in
            let schedule = EventManager.shared.create(
                OsaurusEvent(
                    name: "Taken name \(UUID().uuidString.prefix(6))", isEnabled: false,
                    source: .schedule(ScheduleSourceConfig(frequency: .daily(hour: 8, minute: 0))),
                    action: .agent(AgentEventAction(target: .local(agent.id), instructions: "x"))))
            defer { _ = EventManager.shared.delete(id: schedule.id) }

            var clash = ChannelRoutingRuleEntry(name: schedule.name)
            clash.agent = agent.name
            var badReplies = ChannelRoutingRuleEntry(name: "Bad replies \(UUID().uuidString.prefix(6))")
            badReplies.agent = agent.name
            badReplies.replies = "none"
            var unknown = ChannelRoutingRuleEntry(name: "Unknown agent \(UUID().uuidString.prefix(6))")
            unknown.agent = "Nobody \(UUID().uuidString.prefix(6))"
            do {
                _ = try ConfigPlanner.plan(document: slackDocument([clash, badReplies, unknown]), prune: false)
                Issue.record("expected validation issues")
            } catch let issues as ConfigPlanIssues {
                #expect(issues.issues.contains { $0.contains("channels.slack.routing[\(schedule.name)]") && $0.contains("taken by schedule automation") })
                #expect(issues.issues.contains { $0.contains("channels.slack.routing[\(badReplies.name)].replies") })
                #expect(issues.issues.contains { $0.contains("channels.slack.routing[\(unknown.name)].agent") })
            }
        }
    }

    @Test func unknownConnectionsAreReported() throws {
        var connection = ChannelConnectionEntry(connection: "No such bridge \(UUID().uuidString.prefix(6))")
        connection.routing = []
        var channels = ChannelsSection()
        channels.connections = [connection]
        var document = OsaurusConfigDocument()
        document.channels = channels
        do {
            _ = try ConfigPlanner.plan(document: document, prune: false)
            Issue.record("expected an unknown connection issue")
        } catch let issues as ConfigPlanIssues {
            #expect(issues.issues.contains { $0.contains("channels.connections[\(connection.connection)]") })
        }
    }

    @Test func exportRuleRoundTripsThroughBuild() throws {
        let target = AgentDispatchTarget.local(UUID())
        let event = OsaurusEvent(
            name: "Ops alias",
            source: .channelMessage(
                ChannelMessageSourceConfig(
                    kind: .slack, roomIds: ["C9"], aliases: ["ops"], requireMention: false, continueThreads: false)),
            filter: EventFilter(keywordsAny: ["deploy"]),
            action: .agent(AgentEventAction(target: target, instructions: "Be brief")),
            reply: EventReplyPolicy(autoReply: false))
        var rule = ConfigChannelRouting.exportRule(event)
        rule.agent = "Ops"
        #expect(rule.replies == "approval")
        #expect(rule.rooms == ["C9"])
        #expect(rule.aliases == ["ops"])
        #expect(rule.continueThreads == false)
        #expect(rule.delivery == nil)

        let built = try ConfigEvents.build(
            rule.eventEntry(kind: .slack, connection: nil), existing: nil,
            resolveAgent: { $0 == "Ops" ? target : nil }, resolveWorkflow: { _ in nil }, mintBookmarks: false,
            path: "channels.slack.routing"
        ).get().event
        var again = ConfigChannelRouting.exportRule(built)
        again.agent = "Ops"
        #expect(again == rule)
        #expect(built.source == event.source)
        #expect(built.filter == event.filter)
        #expect(built.reply == event.reply)
    }

    @Test func automaticRepliesNeedWritableRooms() async throws {
        try await withAgent { agent in
            @MainActor func issues(_ document: OsaurusConfigDocument) -> [String] {
                do {
                    _ = try ConfigPlanner.plan(document: document, prune: false)
                    return []
                } catch let issues as ConfigPlanIssues {
                    return issues.issues
                } catch {
                    return ["\(error)"]
                }
            }
            var rule = ChannelRoutingRuleEntry(name: "Writable probe \(UUID().uuidString.prefix(6))")
            rule.agent = agent.name
            rule.rooms = ["C1", "C2"]
            rule.replies = "automatic"

            // A room the bot cannot post in is named, with the fix.
            let missing = issues(slackDocument([rule], writable: ["C1"]))
            #expect(missing.contains { $0.contains("channels.slack.routing") && $0.contains("C2") && !$0.contains("C1,") }, "\(missing)")
            #expect(missing.contains { $0.contains("replies: approval") })
            #expect(issues(slackDocument([rule], writable: ["C1", "C2"])).isEmpty)

            // Replying after approval, or a rule that is off, needs nothing.
            var approval = rule
            approval.replies = "approval"
            #expect(issues(slackDocument([approval], writable: [])).isEmpty)
            var off = rule
            off.enabled = false
            #expect(issues(slackDocument([off], writable: [])).isEmpty)

            // Any room means every readable room; sending off means none.
            var anyRoom = rule
            anyRoom.rooms = nil
            let unreadable = issues(slackDocument([anyRoom], writable: ["C1"], readable: ["C1", "C3"]))
            #expect(unreadable.contains { $0.contains("C3") }, "\(unreadable)")
            let sendingOff = issues(slackDocument([rule], writable: []))
            #expect(sendingOff.contains { $0.contains("C1, C2") }, "\(sendingOff)")
        }
    }

    @Test func rosterNamesTheRoomsAutoRepliesCannotPostIn() {
        typealias R = ChannelAgentRoster.ReplyingRule
        let rules = [
            R(roomIds: ["C1", "C2"], isEnabled: true, replies: true),
            R(roomIds: ["C4"], isEnabled: false, replies: true),
            R(roomIds: ["C5"], isEnabled: true, replies: false),
            R(roomIds: [], isEnabled: true, replies: true),
        ]
        let missing = ChannelAgentRoster.autoReplyRoomsNotWritable(
            rules, readable: ["C1", "C3", " C2 "], writable: ["C1"])
        #expect(missing == ["C2", "C3"])
        #expect(ChannelAgentRoster.autoReplyRoomsNotWritable(rules, readable: [], writable: ["C1", "C2"]).isEmpty)
    }

    // MARK: - Posting

    @Test func postingPlansFlagWithoutAskingAndCheckTheWritableRooms() async throws {
        try await withAgent { agent in
            var slack = ChannelPlatformSection()
            slack.writeEnabled = true
            slack.writeAllowlist = ["C1", "C2"]
            slack.posting = [ChannelPostingEntry(agent: agent.name, mode: "without_asking")]
            var channels = ChannelsSection()
            channels.slack = slack
            var document = OsaurusConfigDocument()
            document.channels = channels

            let plan = try ConfigPlanner.plan(document: document, prune: false)
            let posting = try #require(plan.actions.first { $0.target == "slack posting: \(agent.name)" })
            #expect(posting.changes == ["C1: (automatic) -> without_asking", "C2: (automatic) -> without_asking"])
            #expect(posting.risks == [ConfigRisk.channelAutonomousPosting(agent.name, "slack")])

            var outside = slack
            outside.posting = [ChannelPostingEntry(agent: agent.name, mode: "ask_first", rooms: ["C9"])]
            channels.slack = outside
            document.channels = channels
            #expect(throws: ConfigPlanIssues.self) { try ConfigPlanner.plan(document: document, prune: false) }

            var badMode = slack
            badMode.posting = [ChannelPostingEntry(agent: agent.name, mode: "always")]
            channels.slack = badMode
            document.channels = channels
            do {
                _ = try ConfigPlanner.plan(document: document, prune: false)
                Issue.record("expected a mode issue")
            } catch let issues as ConfigPlanIssues {
                #expect(issues.issues.contains { $0.contains("posting[\(agent.name)].mode") })
            }
        }
    }

    @Test func postingAppliesAndExportsTheAgentsBindings() async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            try await Self.runPostingRoundTrip()
        }
    }

    @MainActor
    private static func runPostingRoundTrip() async throws {
        try await Self().withAgent { agent in
                let before = ConfigExporter.export().channels?.slack
                defer {
                    try? AgentChannelConnectionManager.shared.deleteBindings(agentId: agent.id)
                }
                var slack = ChannelPlatformSection()
                slack.writeEnabled = true
                slack.writeAllowlist = ["C1", "C2"]
                slack.posting = [
                    ChannelPostingEntry(agent: agent.name, mode: "ask_first", rooms: ["C1"]),
                    ChannelPostingEntry(agent: agent.name, mode: "off", rooms: ["C2"]),
                ]
                var channels = ChannelsSection()
                channels.slack = slack
                var document = OsaurusConfigDocument()
                document.channels = channels
                let results = await ConfigApplier.apply(document: document, prune: false)
                #expect(results.allSatisfy { $0.status != .failed }, "\(results)")

                let stored = ConfigChannelPosting.storedBindings(connectionId: "slack").filter { $0.agentId == agent.id }
                #expect(Set(stored.map(\.roomId)) == ["C1", "C2"])
                #expect(stored.first { $0.roomId == "C1" }?.outboundMode == .confirm)
                #expect(stored.first { $0.roomId == "C2" }?.outboundMode == .off)

                let exported = ConfigExporter.export().channels?.slack?.posting ?? []
                #expect(exported.contains(ChannelPostingEntry(agent: agent.name, mode: "ask_first", rooms: ["C1"])))
                #expect(exported.contains(ChannelPostingEntry(agent: agent.name, mode: "off", rooms: ["C2"])))
                let replan = try ConfigPlanner.plan(
                    document: ConfigExporter.export().filtered(to: [.channels]), prune: false)
                #expect(!replan.actions.contains { $0.target.contains(agent.name) }, "\(replan.summaryText())")

                var restore = ChannelPlatformSection()
                restore.writeEnabled = before?.writeEnabled
                restore.writeAllowlist = before?.writeAllowlist ?? []
                var restoreChannels = ChannelsSection()
                restoreChannels.slack = restore
                var restoreDocument = OsaurusConfigDocument()
                restoreDocument.channels = restoreChannels
                _ = await ConfigApplier.apply(document: restoreDocument, prune: false)
        }
    }

    // MARK: - Legacy

    @Test func channelMessageAutomationsMoveToTheirChannelsRouting() {
        var entry = EventEntry(name: "Old slack rule")
        var source = EventSourceEntry(kind: "channel_message")
        source.platform = "slack"
        source.rooms = ["C1"]
        entry.source = source
        entry.agent = "Helper"
        entry.reply = EventReplyEntry()
        entry.reply?.autoReply = true
        var schedule = EventEntry(name: "Daily")
        schedule.source = EventSourceEntry(kind: "schedule")
        var document = OsaurusConfigDocument()
        document.automations = [entry, schedule]

        let (translated, notes) = document.translatingLegacyEvents()
        #expect(translated.automations?.map(\.name) == ["Daily"])
        let rule = translated.channels?.slack?.routing?.first
        #expect(rule?.name == "Old slack rule")
        #expect(rule?.rooms == ["C1"])
        #expect(rule?.eventEntry(kind: .slack, connection: nil).reply?.autoReply == true)
        #expect(notes.contains { $0.contains("channels.slack.routing") })

        let (again, moreNotes) = translated.translatingLegacyEvents()
        #expect(again == translated)
        #expect(moreNotes.isEmpty)
    }

    @Test func schemaReferenceDocumentsRoutingPostingAndTriggerValues() {
        let text = ConfigSchemaReference.text(sections: [.channels, .automations])
        #expect(text.contains("routing:"))
        #expect(text.contains("posting:"))
        #expect(text.contains("sample_body"))
        #expect(text.contains("{{schedule.scheduled_for}}"))
        #expect(text.contains("{{folder.changed_paths}}"))
        #expect(text.contains("{{message.text}}"))
        #expect(text.contains("required"))
    }
}
