//
//  SyncTurnStreamerTests.swift
//  OsaurusCoreTests
//
//  A reply streamed to the user's other devices is stored once, whatever
//  the chat saves while it streams, and stays ahead of the turns after it.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncTurnStreamerTests {
    private final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ new: [T]) { lock.withLock { items += new } }
        var all: [T] { lock.withLock { items } }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Opens this Mac's core with a second device paired over loopback, so
    /// replies have somewhere to stream.
    private func pairedCore() async throws -> SyncCore {
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
        try await peer.pairWithOffer(payload: try mac.pairingOffer(ttlMs: 300_000).payload)
        try await SyncTestPairing.confirm(host: mac, joiner: peer)
        try await waitUntil("paired") { SyncService.shared.hasOtherDevices }
        return mac
    }

    private func flush() throws { try SyncConversationStore.shared.performWrite { _ in } }

    /// A saved chat with one user turn, running a reply that has started to stream.
    private func streamingChat() async throws -> (chat: ChatSession, reply: ChatTurn, scope: String) {
        let chat = ChatSession()
        chat.turns.append(ChatTurn(role: .user, content: "Where to?"))
        chat.save()
        try flush()
        let sessionId = try #require(chat.sessionId)
        let scope = try #require(SyncConversationStore.shared.scope(forSession: sessionId))
        let reply = ChatTurn(role: .assistant, content: "")
        chat.turns.append(reply)
        chat.isStreaming = true
        reply.appendContent("Lis")
        reply.notifyContentChanged()
        try await waitUntil("stream opened") { chat.syncStream?.streamingTurnId == reply.id }
        return (chat, reply, scope)
    }

    @Test
    func aReplySavedWhileItStreamsIsStoredOnce() async throws {
        try await ChatHistoryTestStorage.run {
            let mac = try await pairedCore()
            defer { SyncService.shared.close() }
            let (chat, reply, scope) = try await streamingChat()

            chat.save()
            reply.appendContent("bon.")
            reply.notifyContentChanged()
            // The run's own save lands before the run ends.
            chat.save()
            chat.isStreaming = false
            chat.save()
            try flush()

            let messages = try mac.messages(scope: scope, before: nil, limit: 10).messages
            #expect(messages.map(\.content) == ["Where to?", "Lisbon."])
            let stored = chat.sessionId.flatMap { SyncConversationStore.shared.loadSession(id: $0) }
            #expect(stored?.turns.map(\.id) == chat.turns.map(\.id))
        }
    }

    @Test
    func aTurnSavedRightAfterAStreamedReplyLandsAfterIt() async throws {
        try await ChatHistoryTestStorage.run {
            let mac = try await pairedCore()
            defer { SyncService.shared.close() }
            let (chat, reply, scope) = try await streamingChat()

            reply.appendContent("bon, let me check.")
            reply.notifyContentChanged()
            chat.turns.append(ChatTurn(role: .user, content: "Somewhere warm"))
            chat.save()
            chat.isStreaming = false
            chat.save()
            try flush()

            let messages = try mac.messages(scope: scope, before: nil, limit: 10).messages
            #expect(messages.map(\.content) == ["Where to?", "Lisbon, let me check.", "Somewhere warm"])
            let stored = chat.sessionId.flatMap { SyncConversationStore.shared.loadSession(id: $0) }
            #expect(stored?.turns.map(\.id) == chat.turns.map(\.id))
        }
    }
}
