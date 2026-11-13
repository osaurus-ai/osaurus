//
//  SyncServedChatsTests.swift
//  OsaurusCoreTests
//
//  Served chats: a chat this Mac served for a teammate syncs to the user's
//  other devices tagged with this Mac, lists there under this Mac's agent,
//  an owner turn written on another device is delivered once, and owner
//  approvals are answered from any device with the earliest answer winning.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncServedChatsTests {
    private typealias Contract = SyncServedChatsContract

    private final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ new: [T]) { lock.withLock { items += new } }
        var all: [T] { lock.withLock { items } }
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 20,
        _ condition: () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private let context = WorkspaceSessionContext(
        workspaceId: "ws-acme",
        agentAddress: "0xshared",
        callerWallet: "0xcaller",
        callerName: "Alice",
        callerHandle: "alice"
    )

    private func servedSession(context: WorkspaceSessionContext? = nil, turns: [ChatTurnData]? = nil)
        -> ChatSessionData
    {
        let context = context ?? self.context
        return ChatSessionData(
            title: "Draft the release notes",
            turns: turns ?? [
                ChatTurnData(role: .user, content: "Draft the notes", author: Participant.caller(from: context)),
                ChatTurnData(role: .assistant, content: "Here is a draft."),
            ],
            agentId: UUID(),
            source: .workspace,
            sourcePluginId: ChatHistoryWriter.workspacePseudoPluginId,
            externalSessionKey: "0xcaller:convo-1",
            workspace: context
        )
    }

    /// Opens this Mac's core and a second device paired with it over loopback.
    private func pairedCores() async throws -> (mac: SyncCore, peer: SyncCore) {
        let mac = try SyncService.shared.open()
        try await mac.resume()
        let directory = OsaurusPaths.root().appendingPathComponent("other-mac/sync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var network = localNetworkConfig()
        network.enabled = true
        let peer = try SyncCore.open(
            dataDirectory: directory,
            deviceName: "Other Mac",
            network: network,
            keyStore: SyncKeyStores.make(dataDirectory: directory)
        )
        let events = Recorder<CoreEvent>()
        peer.setListener { events.append([$0]) }
        try mac.addPeerAddress(address: #require(peer.localAddress()))
        try peer.addPeerAddress(address: #require(mac.localAddress()))
        let offer = try mac.pairingOffer(ttlMs: 300_000)
        try await peer.pairWithOffer(payload: offer.payload)
        try await SyncTestPairing.confirm(host: mac, joiner: peer)
        try await waitUntil("paired") {
            events.all.contains { if case .paired = $0 { return true } else { return false } }
        }
        return (mac, peer)
    }

    private func send(_ turn: ChatTurnData, from core: SyncCore, scope: String) throws {
        let encoded = try SyncConversationMapper.encode(turn: turn, toolName: nil)
        _ = try core.sendMessage(
            scope: scope,
            message: OutgoingMessage(
                role: encoded.role,
                content: encoded.content,
                attachments: [],
                replyTo: nil,
                asAgent: nil,
                toolCallId: nil,
                toolName: nil,
                appData: [AppDataWrite(namespace: SyncConversationMapper.turnNamespace, bytes: encoded.appData, attachments: [])]
            )
        )
        core.syncNow()
    }

    private func answer(_ answer: Contract.Answer, _ id: UUID, from core: SyncCore, scope: String) throws {
        let answers = Contract.Answers(answers: [
            id.uuidString.lowercased(): Contract.AnswerEntry(answer: answer, answeredMs: SyncHostedRunContract.nowMs())
        ])
        try core.setConversationAppData(
            scope: scope,
            namespace: Contract.answerNamespace(device: core.deviceKey()),
            bytes: SyncHostedRunContract.encode(answers)
        )
        core.syncNow()
    }

    private func pending(_ core: SyncCore, _ scope: String) throws -> [Contract.PendingApproval] {
        guard let conversation = try core.conversation(scope: scope) else { return [] }
        return Contract.read(Contract.Approvals.self, Contract.approvalNamespace, from: conversation)?.pending ?? []
    }

    private func delivered(_ core: SyncCore, _ scope: String) throws -> [String] {
        guard let conversation = try core.conversation(scope: scope) else { return [] }
        return Contract.read(Contract.Delivery.self, Contract.deliveryNamespace, from: conversation)?.delivered ?? []
    }

    private func mailbox(_ session: ChatSessionData) -> [ParticipantMessage] {
        ConversationMailbox.shared.messages(callerKey: "0xcaller", sessionId: "convo-1", after: 0)
    }

    private func useMailbox(for session: ChatSessionData) {
        ConversationMailbox.shared.resetForTesting(
            fileURL: OsaurusPaths.root().appendingPathComponent("mailbox-\(UUID().uuidString).json"))
        ConversationMailbox.shared.bind(taskId: session.id, callerKey: "0xcaller", sessionId: "convo-1")
    }

    // MARK: - Storage

    @Test
    func aServedChatSyncsTaggedWithTheMacThatServedIt() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let store = SyncConversationStore.shared

            let served = servedSession()
            try store.saveSession(served)
            let scope = try #require(store.scope(forSession: served.id))
            var conversation = try #require(try core.conversation(scope: scope))
            #expect(conversation.replication == .synced)
            #expect(conversation.tag(SyncConversationMapper.TagKey.servedBy) == core.deviceKey())
            #expect(conversation.tag(SyncConversationMapper.TagKey.hostDevice) == nil, "not a hosted run")

            let chat = ChatSessionData(title: "Mine", turns: [ChatTurnData(role: .user, content: "Hi")])
            try store.saveSession(chat)
            let chatScope = try #require(store.scope(forSession: chat.id))
            #expect(try core.conversation(scope: chatScope)?.tag(SyncConversationMapper.TagKey.servedBy) == nil)

            // A save that doesn't know the tag (another device, a new turn) keeps it.
            store.invalidateCaches()
            var reloaded = try #require(store.loadSession(id: served.id))
            #expect(reloaded.servedBy == core.deviceKey())
            #expect(reloaded.servedElsewhere(me: core.deviceKey()) == nil)
            #expect(reloaded.servedElsewhere(me: "another-mac") == core.deviceKey())
            reloaded.servedBy = nil
            reloaded.title = "Renamed"
            reloaded.turns.append(ChatTurnData(role: .user, content: "One more", author: Participant.owner()))
            try store.saveSession(reloaded)
            conversation = try #require(try core.conversation(scope: scope))
            #expect(conversation.title == "Renamed")
            #expect(conversation.tag(SyncConversationMapper.TagKey.servedBy) == core.deviceKey())
        }
    }

    @Test
    func servedChatsFromBeforeSyncArePromotedOnce() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let sourceKey = SyncConversationMapper.TagKey.source
            func local(_ source: SessionSource) throws -> String {
                let scope = try core.createConversation(title: source.rawValue, replication: .deviceLocal)
                try core.setConversationTags(scope: scope, tags: [Tag(key: sourceKey, value: source.rawValue)])
                return scope
            }
            let old = try local(.workspace)
            let http = try local(.http)

            #expect(try SyncServedChats.promoteServedChats(core: core) == 1)
            let promoted = try #require(try core.conversation(scope: old))
            #expect(promoted.replication == .synced)
            #expect(promoted.tag(SyncConversationMapper.TagKey.servedBy) == core.deviceKey())
            #expect(promoted.tag(sourceKey) == SessionSource.workspace.rawValue)
            #expect(try core.conversation(scope: http)?.replication == .deviceLocal)
            #expect(try SyncServedChats.promoteServedChats(core: core) == 0)
        }
    }

    @Test
    func authorsRoundTripThroughTheStore() async throws {
        try await ChatHistoryTestStorage.run {
            _ = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let store = SyncConversationStore.shared
            let session = servedSession(turns: [
                ChatTurnData(role: .user, content: "Teammate", author: Participant.caller(from: context)),
                ChatTurnData(role: .user, content: "Owner here", author: Participant.owner()),
                ChatTurnData(role: .user, content: "Owner elsewhere", author: .ownerDevice("Other Mac")),
            ])
            try store.saveSession(session)
            store.invalidateCaches()
            let reloaded = try #require(store.loadSession(id: session.id))
            #expect(reloaded.turns.map { $0.author?.kind } == [.teammate, .owner, .ownerDevice])
            #expect(reloaded.turns[0].author?.handle == "alice")
            #expect(reloaded.turns[2].author?.deviceLabel == "Other Mac")
        }
    }

    // MARK: - Owner turns

    @Test
    func onlyTheOwnersTurnsFromOtherDevicesAreDelivered() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let store = SyncConversationStore.shared
            let session = servedSession(turns: [
                ChatTurnData(role: .user, content: "Teammate", author: Participant.caller(from: context)),
                ChatTurnData(role: .assistant, content: "Reply"),
                ChatTurnData(role: .user, content: "Owner elsewhere", author: .ownerDevice("Other Mac")),
                ChatTurnData(role: .user, content: "Owner", author: Participant.owner()),
                ChatTurnData(role: .user, content: "Nobody"),
            ])
            try store.saveSession(session)
            let scope = try #require(store.scope(forSession: session.id))
            let messages = try core.messages(scope: scope, before: nil, limit: 50).messages
            let writer = core.deviceKey()
            let now = SyncHostedRunContract.nowMs()

            // Read as another device would, with this core as the writer.
            let turns = SyncServedChats.ownerTurns(in: messages, me: "another-mac", devices: [writer], nowMs: now)
            #expect(turns.map(\.content) == ["Owner elsewhere", "Owner"])
            #expect(SyncServedChats.ownerTurns(in: messages, me: writer, devices: [writer], nowMs: now).isEmpty)
            #expect(SyncServedChats.ownerTurns(in: messages, me: "another-mac", devices: [], nowMs: now).isEmpty)
            let late = now + SyncServedChats.deliveryWindowMs + 1
            #expect(SyncServedChats.ownerTurns(in: messages, me: "another-mac", devices: [writer], nowMs: late).isEmpty)
            let asAgent = messages.map { message -> SyncMessage in
                var message = message
                message.isAgent = true
                return message
            }
            #expect(SyncServedChats.ownerTurns(in: asAgent, me: "another-mac", devices: [writer], nowMs: now).isEmpty)
        }
    }

    @Test
    func theOwnerSpeakingHereIsSavedAndDeliveredOnce() async throws {
        try await ChatHistoryTestStorage.run {
            _ = try SyncService.shared.open()
            defer {
                SyncService.shared.close()
                ConversationMailbox.shared.resetForTesting()
                ChatSessionsManager.shared.refresh()
            }
            let bridge = InboundSharedRunBridge.shared
            let session = servedSession()
            ChatSessionStore.save(session)
            ChatSessionsManager.shared.refresh()
            useMailbox(for: session)

            let turn = try #require(bridge.appendOwnerTurn(sessionId: session.id, text: "  Keep it short  ", author: .ownerDevice("Other Mac")))
            #expect(turn.content == "Keep it short")
            #expect(mailbox(session).isEmpty, "appending doesn't deliver")
            let message = try #require(bridge.deliverOwnerTurn(sessionId: session.id, turn: turn))
            #expect(message.author.kind == .ownerDevice)
            #expect(mailbox(session).map(\.text) == ["Keep it short"])
            #expect(ChatSessionStore.load(id: session.id)?.turns.filter { $0.id == turn.id }.count == 1)

            #expect(bridge.postOwnerMessage(sessionId: session.id, text: "And add dates") != nil)
            #expect(mailbox(session).map(\.text) == ["Keep it short", "And add dates"])
            let stored = try #require(ChatSessionStore.load(id: session.id))
            #expect(stored.turns.suffix(2).map { $0.author?.kind } == [.ownerDevice, .owner])

            let teammate = ChatTurnData(role: .user, content: "Me again", author: Participant.caller(from: context))
            #expect(bridge.deliverOwnerTurn(sessionId: session.id, turn: teammate) == nil)

            var phone = context
            phone.workspaceId = ""
            phone.callerName = MobileConnectMigration.legacyKeyLabels.first
            let phoneSession = servedSession(context: phone)
            ChatSessionStore.save(phoneSession)
            ChatSessionsManager.shared.refresh()
            #expect(bridge.appendOwnerTurn(sessionId: phoneSession.id, text: "Hi", author: Participant.owner()) == nil)
        }
    }

    @Test
    func anOwnerTurnFromAnotherDeviceIsDeliveredOnceAcrossRestarts() async throws {
        try await ChatHistoryTestStorage.run {
            let (mac, peer) = try await pairedCores()
            let served = SyncServedChats.shared
            served._resetForTesting()
            defer {
                served._resetForTesting()
                SyncService.shared.close()
                ConversationMailbox.shared.resetForTesting()
                ChatSessionsManager.shared.refresh()
            }
            let store = SyncConversationStore.shared
            let session = servedSession()
            try store.saveSession(session)
            ChatSessionsManager.shared.refresh()
            useMailbox(for: session)
            let scope = try #require(store.scope(forSession: session.id))
            try await waitUntil("chat on the other device") { try peer.conversation(scope: scope) != nil }

            let turn = ChatTurnData(
                role: .user, content: "Leave out the refactors.", createdAt: Date(), author: .ownerDevice("Other Mac"))
            try send(turn, from: peer, scope: scope)
            try await waitUntil("owner turn on this Mac") {
                try mac.messages(scope: scope, before: nil, limit: 50).messages.contains { $0.authorDevice == peer.deviceKey() }
            }

            await served._processForTesting(scope)
            let id = turn.id.uuidString.lowercased()
            #expect(served._ledgerForTesting().turns[id] != nil)
            #expect(mailbox(session).map(\.text) == ["Leave out the refactors."])
            #expect(mailbox(session).first?.author.deviceLabel == "Other Mac")
            try await waitUntil("delivery on the other device") { try delivered(peer, scope) == [id] }

            await served._processForTesting(scope)
            #expect(mailbox(session).count == 1, "seen again")

            // A restart that also lost the record still doesn't deliver it twice.
            try store.performWrite { core in
                try core.setConversationAppData(
                    scope: scope,
                    namespace: Contract.deliveryNamespace,
                    bytes: SyncHostedRunContract.encode(Contract.Delivery(delivered: []))
                )
            }
            served._resetForTesting()
            served.start()
            try await waitUntil("attached") { served._isAttachedForTesting }
            await served._processForTesting(scope)
            try await Task.sleep(for: .milliseconds(300))
            #expect(mailbox(session).count == 1, "after a restart")
            #expect(try delivered(mac, scope).isEmpty)
            try await peer.close()
        }
    }

    // MARK: - Approvals

    @Test
    func theEarliestAnswerFromAKnownDeviceWins() {
        func answers(_ entries: [String: (Contract.Answer, Int64)]) -> Contract.Answers {
            Contract.Answers(answers: entries.mapValues { Contract.AnswerEntry(answer: $0.0, answeredMs: $0.1) })
        }
        let decisions = Contract.firstAnswers(
            [
                "phone": answers(["a": (.denied, 20), "b": (.approved, 5)]),
                "air": answers(["a": (.approved, 10)]),
                "revoked": answers(["a": (.allowedForConversation, 1), "c": (.approved, 1)]),
            ],
            deviceNames: ["phone": "iPhone", "air": "MacBook Air"]
        )
        #expect(decisions.map(\.id) == ["b", "a"])
        #expect(decisions.map(\.answer) == [.approved, .approved])
        #expect(decisions.map(\.device) == ["iPhone", "MacBook Air"])
    }

    @Test
    func answersSkipValuesTheyDontKnow() throws {
        let json = Data(
            #"{"v":1,"answers":{"a":{"answer":"approved","answeredMs":1},"b":{"answer":"later","answeredMs":2},"c":"denied"}}"#
                .utf8)
        let decoded = try JSONDecoder().decode(Contract.Answers.self, from: json)
        #expect(decoded.answers.keys.sorted() == ["a"])
        #expect(Contract.Answer(.timedOut) == nil)
        #expect(Contract.Answer(.allowedForConversation)?.outcome == .allowedForConversation)
    }

    @Test
    func anAnswerFromAnotherDeviceSettlesTheApprovalOnce() async throws {
        try await ChatHistoryTestStorage.run {
            let (mac, peer) = try await pairedCores()
            let served = SyncServedChats.shared
            served._resetForTesting()
            AttentionCenter.shared.resetForTesting()
            defer {
                AttentionCenter.shared.resetForTesting()
                served._resetForTesting()
                SyncService.shared.close()
                ChatSessionsManager.shared.refresh()
            }
            let store = SyncConversationStore.shared
            let session = servedSession()
            try store.saveSession(session)
            ChatSessionsManager.shared.refresh()
            let scope = try #require(store.scope(forSession: session.id))

            let approval = UUID()
            let resolutions = Recorder<AttentionResolution>()
            AttentionCenter.shared.raise(
                AttentionItem(
                    id: approval,
                    kind: .ownerApproval,
                    requester: Participant.caller(from: context),
                    sessionId: session.id,
                    title: "@alice wants Writer to use file_write",
                    body: "Approve to let it run.",
                    toolName: "file_write",
                    actions: [.approve, .deny, .open],
                    expiresAt: Date().addingTimeInterval(600)
                )
            ) { resolutions.append([$0]) }

            await served._processForTesting(scope)
            try await waitUntil("approval on the other device") { try pending(peer, scope).count == 1 }
            let published = try #require(try pending(peer, scope).first)
            #expect(published.id == approval.uuidString.lowercased())
            #expect(published.tool == "file_write")
            #expect(published.caller?.hasPrefix("@alice") == true)
            #expect(!published.offersConversationLease)
            #expect(published.expiresMs != nil)

            try answer(.approved, approval, from: peer, scope: scope)
            try await waitUntil("answer on this Mac") {
                try mac.conversation(scope: scope).map { Contract.answers(in: $0)[peer.deviceKey()] != nil } ?? false
            }
            await served._processForTesting(scope)
            try await waitUntil("resolved") { !resolutions.all.isEmpty }
            let resolution = try #require(resolutions.all.first)
            #expect(resolution.outcome == .approved)
            #expect(resolution.decidedBy?.kind == .ownerDevice)
            #expect(resolution.decidedBy?.deviceLabel == "Other Mac")
            #expect(!AttentionCenter.shared.pending.contains { $0.id == approval })
            try await waitUntil("approval withdrawn on the other device") { try pending(peer, scope).isEmpty }

            // A later, different answer for the same approval changes nothing.
            try answer(.denied, approval, from: peer, scope: scope)
            try await waitUntil("late answer on this Mac") {
                try mac.conversation(scope: scope).map {
                    Contract.answers(in: $0)[peer.deviceKey()]?.answers.values.first?.answer == .denied
                } ?? false
            }
            await served._processForTesting(scope)
            try await Task.sleep(for: .milliseconds(200))
            #expect(resolutions.all.count == 1)
            try await peer.close()
        }
    }

    // MARK: - Other devices

    @Test
    func anotherMacsServedChatListsUnderItsAgentAndMirrorsItsApprovals() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let served = SyncServedChats.shared
            served._resetForTesting()
            AttentionCenter.shared.resetForTesting()
            defer {
                AttentionCenter.shared.resetForTesting()
                served._resetForTesting()
                SyncService.shared.close()
                ChatSessionsManager.shared.refresh()
            }
            let store = SyncConversationStore.shared
            let session = servedSession()
            try store.saveSession(session)
            let scope = try #require(store.scope(forSession: session.id))
            let studio = "studio-device-key"
            try store.performWrite { core in
                let conversation = try #require(try core.conversation(scope: scope))
                let tags = conversation.tags.filter { $0.key != SyncConversationMapper.TagKey.servedBy }
                    + [Tag(key: SyncConversationMapper.TagKey.servedBy, value: studio)]
                try core.setConversationTags(scope: scope, tags: tags.sorted { $0.key < $1.key })
            }
            store.invalidateCaches()
            ChatSessionsManager.shared.refresh()

            let agentId = try #require(session.agentId)
            #expect(ChatSessionsManager.shared.sessions(forHost: studio, agentId: agentId).map(\.id) == [session.id])
            #expect(!ChatSessionsManager.shared.sessions(for: nil).contains { $0.id == session.id })
            #expect(!ChatSessionsManager.shared.sessions(for: agentId).contains { $0.id == session.id })
            let row = try #require(ChatSessionsManager.shared.sessions.first { $0.id == session.id })
            #expect(row.hostDevice == nil, "the host runner doesn't watch it")
            #expect(row.servedElsewhere(me: core.deviceKey()) == studio)

            // The record says which of this device's turns were delivered.
            let mine = ChatTurn(role: .user, content: "Mine")
            mine.author = .ownerDevice("This Mac")
            let other = ChatTurn(role: .user, content: "Mine too")
            other.author = .ownerDevice("This Mac")
            let approval = UUID()
            let dropped = UUID()
            func publish(_ ids: [UUID]) throws {
                try store.performWrite { core in
                    try core.setConversationAppData(
                        scope: scope,
                        namespace: Contract.deliveryNamespace,
                        bytes: SyncHostedRunContract.encode(Contract.Delivery(delivered: [mine.id.uuidString.lowercased()]))
                    )
                    let pending = ids.map {
                        Contract.PendingApproval(
                            id: $0.uuidString.lowercased(),
                            tool: "file_write",
                            title: "@alice wants Writer to use file_write",
                            description: "Approve to let it run.",
                            caller: "@alice",
                            agent: "Writer",
                            offersConversationLease: true,
                            requestedMs: SyncHostedRunContract.nowMs(),
                            expiresMs: SyncHostedRunContract.nowMs() + 600_000
                        )
                    }
                    try core.setConversationAppData(
                        scope: scope,
                        namespace: Contract.approvalNamespace,
                        bytes: SyncHostedRunContract.encode(Contract.Approvals(pending: pending))
                    )
                }
            }
            try publish([approval, dropped])
            await served._processForTesting(scope)
            #expect(!served.isAwaitingDelivery(mine, sessionId: session.id))
            #expect(served.isAwaitingDelivery(other, sessionId: session.id))
            #expect(served._mirroredIdsForTesting == [approval, dropped])
            let item = try #require(AttentionCenter.shared.pending.first { $0.id == approval })
            #expect(item.kind == .ownerApproval)
            #expect(item.sessionId == session.id)
            #expect(item.actions == [.approve, .allowForConversation, .deny, .open])
            #expect(item.requester?.handle == "alice")

            // Answering here writes this device's answer; it is not applied here.
            #expect(
                AttentionCenter.shared.resolve(
                    id: approval,
                    with: AttentionResolution(outcome: .allowedForConversation, surface: .desktop, decidedBy: Participant.owner())
                ))
            try await waitUntil("answer written") {
                try core.conversation(scope: scope).map {
                    Contract.answers(in: $0)[core.deviceKey()]?.answers[approval.uuidString.lowercased()]?.answer
                } == .allowedForConversation
            }
            #expect(served._mirroredIdsForTesting == [dropped])

            // The serving Mac withdrew the other one.
            try publish([approval])
            await served._processForTesting(scope)
            #expect(served._mirroredIdsForTesting.isEmpty, "answered here, so not raised again")
            #expect(!AttentionCenter.shared.pending.contains { $0.id == dropped })
        }
    }
}
