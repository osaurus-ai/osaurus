//
//  SyncSaveRetryTests.swift
//  OsaurusCoreTests
//
//  A save that failed and is tried again compares against what the store
//  had seen when it was first handed over. A turn another device added
//  meanwhile survives the retry. Before, a retry of the old snapshot
//  deleted it: an iPhone's edited prompt and the Mac's reply to it
//  vanished seconds after the edit (ChatSessionStore.retryUnsaved).
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncSaveRetryTests {
    private func session(_ turns: [ChatTurnData]) -> ChatSessionData {
        ChatSessionData(
            id: UUID(),
            title: "Hello",
            createdAt: Date(timeIntervalSince1970: 1_767_225_600),
            updatedAt: Date(timeIntervalSince1970: 1_767_225_601),
            turns: turns,
            agentId: UUID(),
            source: .chat
        )
    }

    @Test func aRetriedSaveKeepsATurnAnotherDeviceAddedMeanwhile() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let store = SyncConversationStore.shared
            let first = session([
                ChatTurnData(role: .user, content: "Hey", createdAt: Date(timeIntervalSince1970: 1_767_225_600)),
                ChatTurnData(
                    role: .assistant, content: "Hey! How's it going?",
                    createdAt: Date(timeIntervalSince1970: 1_767_225_601)),
            ])
            try store.saveSession(first)
            let scope = try #require(store.scope(forSession: first.id))

            // A save of that snapshot fails: its basis is kept for the retry.
            store.keepRetryBasis(for: first)

            // The iPhone sends the next prompt, and this Mac reads it.
            let promptId = UUID()
            let turn = #"{"v":1,"id":"\#(promptId.uuidString.lowercased())","role":"user","createdAt":1767225700000}"#
            var prompt = OutgoingMessage.text("Write a short essay about AGI")
            prompt.appData = [AppDataWrite(namespace: SyncConversationMapper.turnNamespace, bytes: Data(turn.utf8))]
            _ = try core.sendMessage(scope: scope, message: prompt)
            store.invalidate(sessionId: first.id)
            store.drain(timeout: 5)
            let loaded = try #require(store.loadSession(id: first.id))
            #expect(loaded.turns.map(\.id).contains(promptId))

            // The failed save is tried again with the old snapshot.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                store.retrySessionSaveAsync(first, onSaved: { done.resume() }, onDropped: { _ in done.resume() })
            }

            let after = try #require(store.loadSession(id: first.id))
            #expect(after.turns.map(\.id).contains(promptId), "the retry deleted the other device's prompt")
            #expect(after.turns.count == 3)
        }
    }
}
