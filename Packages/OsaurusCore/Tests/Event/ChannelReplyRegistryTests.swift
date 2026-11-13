//
//  ChannelReplyRegistryTests.swift
//  osaurusTests
//
//  How a workflow run finds its way back to the conversation: the live
//  sink by run id, up the parent chain, or by conversation; which runs
//  count as having replied; and the replier's fallback to the connection.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChannelReplyRegistryTests {

    static let target = WorkflowChannelReplyTarget(connectionId: "slack", kind: .slack, conversationId: "C-1")

    static func sink(_ label: String, into log: WorkflowReplyStepTests.Log) -> ChannelReplySink {
        ChannelReplySink(
            connectionId: "slack", providerRoute: AgentChannelProviderRoute(conversationId: "C-1"),
            reply: { await log.text("\(label):\($0)") }, writeGate: WorkflowReplyStepTests.gate())
    }

    @Test func resolvesByRunThenParentChainThenConversation() {
        let registry = ChannelReplyRegistry()
        let log = WorkflowReplyStepTests.Log()
        let owner = UUID()
        registry.register(runID: owner, target: Self.target, sink: Self.sink("owner", into: log))

        let direct = registry.resolve(runID: owner, target: Self.target, parentOf: { _ in nil })
        #expect(direct?.ownerRunID == owner)
        #expect(direct?.speaksForOwner == true)

        let child = UUID()
        let grandchild = UUID()
        let parents = [grandchild: child, child: owner]
        let viaChain = registry.resolve(
            runID: grandchild, target: nil, parentRunID: child, parentOf: { parents[$0] })
        #expect(viaChain?.ownerRunID == owner)
        #expect(viaChain?.speaksForOwner == true)

        let stranger = registry.resolve(runID: UUID(), target: Self.target, parentOf: { _ in nil })
        #expect(stranger?.ownerRunID == owner)
        #expect(stranger?.speaksForOwner == false, "a sink borrowed by conversation does not speak for its run")

        let otherRoom = WorkflowChannelReplyTarget(connectionId: "slack", kind: .slack, conversationId: "C-2")
        #expect(registry.resolve(runID: UUID(), target: otherRoom, parentOf: { _ in nil }) == nil)

        registry.markReplied(runID: owner)
        #expect(registry.hasStepReplied(runID: owner))
        registry.unregister(runID: owner)
        #expect(!registry.hasStepReplied(runID: owner))
        #expect(registry.resolve(runID: owner, target: Self.target, parentOf: { _ in nil }) == nil)
    }

    static func replier(
        registry: ChannelReplyRegistry, connectionSends: WorkflowReplyStepTests.Log
    ) -> WorkflowChannelReplier {
        WorkflowChannelReplier(
            resolveSink: { runID, caller in
                await MainActor.run {
                    registry.resolve(
                        runID: runID, target: caller.channelReply, parentRunID: caller.parentRunID,
                        parentOf: { _ in nil })
                }
            },
            sendThroughConnection: { _, text in await connectionSends.text(text) },
            markReplied: { id in await MainActor.run { registry.markReplied(runID: id) } })
    }

    @Test func childReplySpeaksForItsParentButABorrowedSinkDoesNot() async {
        let registry = ChannelReplyRegistry()
        let log = WorkflowReplyStepTests.Log()
        let parent = UUID()
        registry.register(runID: parent, target: Self.target, sink: Self.sink("live", into: log))
        let replier = Self.replier(registry: registry, connectionSends: log)

        let child = UUID()
        let childCaller = WorkflowCaller(kind: .workflow, parentRunID: parent, channelReply: Self.target)
        let delivery = await replier.send("from child", runID: child, caller: childCaller)
        #expect(delivery.sent && delivery.path == .live)
        #expect(registry.hasStepReplied(runID: child))
        #expect(registry.hasStepReplied(runID: parent), "the parent's final post stands down")

        let other = UUID()
        let otherParent = UUID()
        registry.register(runID: otherParent, target: Self.target, sink: Self.sink("live", into: log))
        registry.unregister(runID: parent)
        let borrowed = await replier.send(
            "same room", runID: other, caller: WorkflowCaller(kind: .event, channelReply: Self.target))
        #expect(borrowed.sent)
        #expect(registry.hasStepReplied(runID: other))
        #expect(!registry.hasStepReplied(runID: otherParent))
        #expect(await log.texts == ["live:from child", "live:same room"])
    }

    @Test func dialogTextDoesNotCountAsAReplyAndNoSinkFallsBackToTheConnection() async {
        let registry = ChannelReplyRegistry()
        let log = WorkflowReplyStepTests.Log()
        let run = UUID()
        registry.register(runID: run, target: Self.target, sink: Self.sink("live", into: log))
        let replier = Self.replier(registry: registry, connectionSends: log)
        let caller = WorkflowCaller(kind: .event, channelReply: Self.target)

        _ = await replier.send("Which project?", runID: run, caller: caller, marksReplied: false)
        #expect(!registry.hasStepReplied(runID: run))

        registry.unregister(runID: run)
        let relaunched = await replier.send("after relaunch", runID: run, caller: caller)
        #expect(relaunched.sent && relaunched.path == .connection)
        #expect(await log.texts == ["live:Which project?", "after relaunch"])

        let none = await replier.send("nobody", runID: UUID(), caller: WorkflowCaller(kind: .user))
        #expect(none == .noConversation)
    }

    @Test func pausedWritesReportWritesPaused() async throws {
        let gate = WorkflowReplyStepTests.gate()
        _ = try gate.disableWrites()
        let registry = ChannelReplyRegistry()
        let log = WorkflowReplyStepTests.Log()
        let run = UUID()
        registry.register(
            runID: run, target: Self.target,
            sink: ChannelReplySink(
                connectionId: "slack", providerRoute: AgentChannelProviderRoute(conversationId: "C-1"),
                reply: { await log.text($0) }, writeGate: gate))
        let delivery = await Self.replier(registry: registry, connectionSends: log)
            .send("Hi", runID: run, caller: WorkflowCaller(kind: .event, channelReply: Self.target))
        #expect(!delivery.sent)
        #expect(delivery.reason == "writes_paused")
        #expect(!registry.hasStepReplied(runID: run))
        #expect(await log.texts.isEmpty)
    }

    final class Counts {
        var persisted: [UUID: Int] = [:]
    }

    @Test func replyCountOutlivesTheLiveEntry() {
        let counts = Counts()
        let known = UUID()
        let registry = ChannelReplyRegistry(
            persistReply: { id in
                guard id == known else { return nil }
                counts.persisted[id, default: 0] += 1
                return counts.persisted[id]
            },
            persistedCount: { counts.persisted[$0] ?? 0 })
        registry.markReplied(runID: known)
        registry.markReplied(runID: known)
        #expect(registry.replyCount(runID: known) == 2)
        registry.unregister(runID: known)
        #expect(registry.replyCount(runID: known) == 2, "the record keeps the count")
        #expect(registry.hasStepReplied(runID: known))

        let unrecorded = UUID()
        registry.markReplied(runID: unrecorded)
        #expect(registry.replyCount(runID: unrecorded) == 1, "counted in memory while the run has no record")
        registry.unregister(runID: unrecorded)
        #expect(!registry.hasStepReplied(runID: unrecorded))

        let relaunched = UUID()
        counts.persisted[relaunched] = 4
        #expect(ChannelReplyRegistry(persistReply: { _ in nil }, persistedCount: { counts.persisted[$0] ?? 0 })
            .replyCount(runID: relaunched) == 4)
    }

    @Test func runStoreKeepsTheReplyCountOverTheRunnersStaleCopy() {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "W", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .event, channelReply: Self.target), input: .object([:]), nodeIDs: [])
        run.status = .running
        WorkflowRunStore.shared.record(run)
        #expect(WorkflowRunStore.shared.noteChannelReply(runID: run.id) == 1)
        #expect(WorkflowRunStore.shared.noteChannelReply(runID: run.id) == 2)
        run.status = .completed
        WorkflowRunStore.shared.record(run)
        let stored = WorkflowRunStore.shared.run(id: run.id)
        #expect(stored?.status == .completed)
        #expect(stored?.channelReplyCount == 2)
        #expect(WorkflowRunStore.shared.noteChannelReply(runID: UUID()) == nil)
    }

    @Test func fallbackFilesAndTelegramThreads() {
        #expect(WorkflowChannelReplier.connectionSendsFiles(.imessage))
        #expect(WorkflowChannelReplier.connectionSendsFiles(.whatsapp))
        #expect(!WorkflowChannelReplier.connectionSendsFiles(.telegram))
        #expect(!WorkflowChannelReplier.connectionSendsFiles(.slack))

        var telegram = WorkflowChannelReplyTarget(connectionId: "tg", kind: .telegram, conversationId: "chat-1")
        #expect(WorkflowChannelReplier.telegramReplyTo(telegram) == nil)
        telegram.threadId = "812"
        #expect(WorkflowChannelReplier.telegramReplyTo(telegram) == 812)
        telegram.threadId = "topic-a"
        #expect(WorkflowChannelReplier.telegramReplyTo(telegram) == nil)
        var slack = Self.target
        slack.threadId = "812"
        #expect(WorkflowChannelReplier.telegramReplyTo(slack) == nil)
    }

    @Test func replyTargetIsTakenFromTheMessage() {
        let message = ChannelInboundMessage(
            identity: ChannelIdentity(
                kind: .slack, installationId: "slack", groupId: "C-1",
                sender: ChannelSenderMetadata(senderId: "U1", displayName: "Dana")),
            kind: .slack, connectionId: "slack", providerEventId: "Ev-1",
            providerRoute: AgentChannelProviderRoute(conversationId: "C-1", threadId: "T-9"),
            content: "hi", sourceLabel: "Slack")
        let target = EventManager.replyTarget(for: message)
        #expect(target.conversationId == "C-1")
        #expect(target.threadId == "T-9")
        #expect(target.senderId == "U1")
        #expect(target.senderName == "Dana")
        #expect(target.conversationKey == message.conversationKey)
    }
}
