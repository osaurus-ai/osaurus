//
//  SyncInboundTests.swift
//  OsaurusCoreTests
//
//  Another device's changes: a save from an older copy keeps what arrived
//  meanwhile, and open chats take the changes in once they're idle.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncInboundTests {
    private func withStore(_ body: @MainActor @Sendable (SyncConversationStore, SyncCore) throws -> Void) async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            SyncInboundApplier.shared._resetForTesting()
            defer { SyncInboundApplier.shared._resetForTesting() }
            try body(SyncConversationStore.shared, core)
        }
    }

    private func session(_ contents: [String]) -> ChatSessionData {
        let base = Date(timeIntervalSince1970: 1_767_225_600)
        return ChatSessionData(
            id: UUID(),
            title: "Plans",
            createdAt: base,
            updatedAt: base,
            turns: contents.enumerated().map { index, content in
                ChatTurnData(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: content,
                    createdAt: base.addingTimeInterval(Double(index))
                )
            }
        )
    }

    /// Writes a turn the way another device's save would.
    private func writeElsewhere(_ content: String, into scope: String, core: SyncCore) throws -> UUID {
        let turn = ChatTurnData(role: .user, content: content, createdAt: Date())
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
                appData: [AppDataWrite(namespace: SyncConversationMapper.turnNamespace, bytes: encoded.appData)]
            )
        )
        return turn.id
    }

    @Test
    func aSaveFromAnOlderCopyKeepsTurnsThatArrivedMeanwhile() async throws {
        try await withStore { store, core in
            let original = session(["Where to?", "Lisbon."])
            try store.saveSession(original)
            var onScreen = try #require(store.loadSession(id: original.id))
            let scope = try #require(store.scope(forSession: original.id))

            let arrived = try writeElsewhere("And food?", into: scope, core: core)
            store.invalidate(sessionId: original.id)

            onScreen.title = "Lisbon plans"
            try store.saveSession(onScreen)
            let stored = try #require(store.loadSession(id: original.id))
            #expect(stored.turns.map(\.id) == original.turns.map(\.id) + [arrived])
            #expect(stored.title == "Lisbon plans")
        }
    }

    @Test
    func aSaveFromAnOlderCopyDoesNotRestoreARemovedTurn() async throws {
        try await withStore { store, core in
            let original = session(["Where to?", "Lisbon.", "Thanks"])
            try store.saveSession(original)
            let onScreen = try #require(store.loadSession(id: original.id))
            let scope = try #require(store.scope(forSession: original.id))

            let last = try #require(try core.messages(scope: scope, before: nil, limit: 10).messages.last)
            try core.deleteMessage(id: last.id)
            store.invalidate(sessionId: original.id)

            try store.saveSession(onScreen)
            let stored = try #require(store.loadSession(id: original.id))
            #expect(stored.turns.map(\.content) == ["Where to?", "Lisbon."])
        }
    }

    @Test
    func aTurnTheCallerRemovedCanComeBack() async throws {
        try await withStore { store, _ in
            var current = session(["Where to?", "Lisbon."])
            try store.saveSession(current)
            let removed = current.turns.removeLast()
            try store.saveSession(current)
            #expect(store.loadSession(id: current.id)?.turns.count == 1)

            current.turns.append(removed)
            try store.saveSession(current)
            #expect(store.loadSession(id: current.id)?.turns.map(\.id) == [current.turns[0].id, removed.id])
        }
    }

    @Test
    func anOpenIdleChatTakesInAnotherDevicesChanges() async throws {
        try await withStore { store, core in
            let original = session(["Where to?", "Lisbon."])
            try store.saveSession(original)
            let chat = ChatSession()
            chat.load(from: try #require(store.loadSession(id: original.id)))
            LiveChatSessionRegistry.shared.register(chat, id: original.id)
            defer { LiveChatSessionRegistry.shared.unregister(id: original.id) }

            let scope = try #require(store.scope(forSession: original.id))
            let arrived = try writeElsewhere("And food?", into: scope, core: core)
            SyncInboundApplier.shared._receiveForTesting([.reset], sessionId: original.id)
            SyncInboundApplier.shared._flushForTesting()

            #expect(chat.turns.map(\.id) == original.turns.map(\.id) + [arrived])
            #expect(chat.turns.last?.content == "And food?")
        }
    }

    @Test
    func aStreamedReplyIsWrittenOnce() async throws {
        try await withStore { store, core in
            var current = session(["Where to?"])
            try store.saveSession(current)
            let scope = try #require(store.scope(forSession: current.id))

            let stream = try core.openStream(scope: scope, role: .assistant, asAgent: nil)
            try stream.push(delta: "Lis")
            try stream.push(delta: "bon.")
            let reply = ChatTurnData(role: .assistant, content: "Lisbon.", createdAt: Date())
            store.finishStream(stream, sessionId: current.id, turn: reply)
            current.turns.append(reply)
            try store.saveSession(current)

            let messages = try core.messages(scope: scope, before: nil, limit: 10).messages
            #expect(messages.map(\.content) == ["Where to?", "Lisbon."])
            #expect(messages.last?.id == stream.messageId())
            #expect(store.loadSession(id: current.id)?.turns.map(\.id) == current.turns.map(\.id))
        }
    }

    @Test
    func aReplySavedBeforeItsStreamOpenedIsReplacedByTheStream() async throws {
        try await withStore { store, core in
            var current = session(["Where to?", "Lis"])
            try store.saveSession(current)
            let scope = try #require(store.scope(forSession: current.id))

            let stream = try core.openStream(scope: scope, role: .assistant, asAgent: nil)
            try stream.push(delta: "Lisbon.")
            current.turns[1].content = "Lisbon."
            store.finishStream(stream, sessionId: current.id, turn: current.turns[1])
            try store.saveSession(current)

            let messages = try core.messages(scope: scope, before: nil, limit: 10).messages
            #expect(messages.map(\.content) == ["Where to?", "Lisbon."])
            #expect(messages.last?.id == stream.messageId())
        }
    }

    @Test
    func aStreamFinishedAfterTheIndexWasDroppedKeepsEveryTurnOnce() async throws {
        try await withStore { store, core in
            var current = session(["Where to?", "Lisbon.", "And food?"])
            try store.saveSession(current)
            let scope = try #require(store.scope(forSession: current.id))

            let stream = try core.openStream(scope: scope, role: .assistant, asAgent: nil)
            try stream.push(delta: "Pastéis.")
            store.invalidate(sessionId: current.id)
            let reply = ChatTurnData(role: .assistant, content: "Pastéis.", createdAt: Date())
            store.finishStream(stream, sessionId: current.id, turn: reply)
            current.turns.append(reply)
            try store.saveSession(current)

            let messages = try core.messages(scope: scope, before: nil, limit: 10).messages
            #expect(messages.map(\.content) == ["Where to?", "Lisbon.", "And food?", "Pastéis."])
            #expect(store.loadSession(id: current.id)?.turns.map(\.id) == current.turns.map(\.id))
        }
    }

    @Test
    func aTurnStoredTwiceReadsOnceAndTheNextSaveRemovesTheCopy() async throws {
        try await withStore { store, core in
            let original = session(["Where to?", "Lisbon."])
            try store.saveSession(original)
            let scope = try #require(store.scope(forSession: original.id))
            let encoded = try SyncConversationMapper.encode(turn: original.turns[1], toolName: nil)
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
                    appData: [AppDataWrite(namespace: SyncConversationMapper.turnNamespace, bytes: encoded.appData)]
                )
            )
            let copies = try core.messages(scope: scope, before: nil, limit: 10).messages.dropFirst().map(\.id)
            #expect(copies.count == 2)

            store.invalidateCaches()
            let loaded = try #require(store.loadSession(id: original.id))
            #expect(loaded.turns.map(\.id) == original.turns.map(\.id))

            try store.saveSession(loaded)
            let messages = try core.messages(scope: scope, before: nil, limit: 10).messages
            #expect(messages.map(\.content) == ["Where to?", "Lisbon."])
            #expect(messages.last?.id == copies.min())
        }
    }

    @Test
    func anotherDevicesReplyShowsUntilItsMessageArrivesAndIsNeverSaved() async throws {
        try await withStore { store, _ in
            let original = session(["Where to?"])
            try store.saveSession(original)
            let chat = ChatSession()
            chat.load(from: try #require(store.loadSession(id: original.id)))

            chat.showRemoteReply(.init(messageId: "m1", deviceName: "Work Mac", text: "Lis"))
            chat.showRemoteReply(.init(messageId: "m1", deviceName: "Work Mac", text: "Lisbon"))
            #expect(chat.turns.count == 2)
            #expect(chat.turns.last?.content == "Lisbon")
            #expect(chat.toSessionData().turns.count == 1)

            // A reload before the message lands keeps the bubble.
            chat.applyRemoteChanges(from: try #require(store.loadSession(id: original.id)))
            #expect(chat.turns.last?.isRemotePreview == true)

            chat.endRemoteReply()
            #expect(chat.turns.count == 1)
            #expect(chat.remoteReply == nil)
        }
    }

    @Test
    func aChatWithUnsavedEditsWaits() async throws {
        try await withStore { store, core in
            let original = session(["Where to?", "Lisbon."])
            try store.saveSession(original)
            let chat = ChatSession()
            chat.load(from: try #require(store.loadSession(id: original.id)))
            LiveChatSessionRegistry.shared.register(chat, id: original.id)
            defer { LiveChatSessionRegistry.shared.unregister(id: original.id) }

            chat.isDirty = true
            let scope = try #require(store.scope(forSession: original.id))
            _ = try writeElsewhere("And food?", into: scope, core: core)
            SyncInboundApplier.shared._receiveForTesting([.reset], sessionId: original.id)
            SyncInboundApplier.shared._flushForTesting()
            #expect(chat.turns.count == 2)

            chat.isDirty = false
            SyncInboundApplier.shared._flushForTesting()
            #expect(chat.turns.count == 3)
        }
    }

    /// A window open on the chat and a tab behind another one.
    private func windowShowing(_ stored: ChatSessionData, inBackgroundTab: Bool) -> ChatWindowState {
        let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId, sessionData: stored)
        if inBackgroundTab { window.newTab() }
        return window
    }

    @Test(arguments: [false, true])
    func aChatDeletedElsewhereIsNotSavedBackByItsOpenTab(inBackgroundTab: Bool) async throws {
        try await withStore { store, core in
            let stored = session(["Where to?", "Lisbon."])
            try store.saveSession(stored)
            let window = windowShowing(stored, inBackgroundTab: inBackgroundTab)
            let scope = try #require(store.scope(forSession: stored.id))

            ChatWindowManager.shared.withRegisteredWindowStateForTesting(window) {
                try? core.leaveConversation(scope: scope)
                SyncInboundApplier.shared._receiveForTesting([.removed(scope: scope)])
                SyncInboundApplier.shared._flushForTesting()
                #expect(!window.tabs.contains { $0.session.sessionId == stored.id })
                window.cleanup()
            }
            #expect(store.loadSession(id: stored.id) == nil)
        }
    }

    @Test(arguments: [false, true])
    func anOpenTabTakesFlagsChangedElsewhereEvenWhileBusy(inBackgroundTab: Bool) async throws {
        try await withStore { store, core in
            let stored = session(["Where to?", "Lisbon."])
            try store.saveSession(stored)
            let window = windowShowing(stored, inBackgroundTab: inBackgroundTab)
            let scope = try #require(store.scope(forSession: stored.id))
            let tab = try #require(window.tabs.first { $0.session.sessionId == stored.id }?.session)
            tab.isDirty = true
            SyncConversationStore.shared._resetForTesting()

            try ChatWindowManager.shared.withRegisteredWindowStateForTesting(window) {
                try core.setArchived(scope: scope, archived: true)
                try core.setPinned(scope: scope, pinned: true)
                try core.renameConversation(scope: scope, title: "Lisbon trip")
                let conversation = try #require(try core.conversation(scope: scope))
                SyncInboundApplier.shared._receiveForTesting([.changed(conversation: conversation)])
                SyncInboundApplier.shared._flushForTesting()
                #expect(tab.archived && tab.pinned && tab.title == "Lisbon trip")

                tab.isDirty = false
                window.cleanup()
            }
            let saved = try #require(store.loadSession(id: stored.id))
            #expect(saved.archived && saved.pinned && saved.title == "Lisbon trip")
        }
    }

    @Test
    func unarchivingHereReachesATabBehindAnotherOne() async throws {
        try await withStore { store, _ in
            var stored = session(["Where to?", "Lisbon."])
            stored.archived = true
            try store.saveSession(stored)
            let window = windowShowing(stored, inBackgroundTab: true)
            let tab = try #require(window.tabs.first { $0.session.sessionId == stored.id }?.session)

            ChatWindowManager.shared.withRegisteredWindowStateForTesting(window) {
                ChatSessionsManager.shared.setArchived(id: stored.id, archived: false)
                ChatSessionsManager.shared.setPinned(id: stored.id, pinned: true)
                ChatSessionsManager.shared.rename(id: stored.id, title: "Lisbon trip")
                #expect(!tab.archived && tab.pinned && tab.title == "Lisbon trip")
                window.cleanup()
            }
            let saved = try #require(store.loadSession(id: stored.id))
            #expect(!saved.archived && saved.pinned && saved.title == "Lisbon trip")
        }
    }
}
