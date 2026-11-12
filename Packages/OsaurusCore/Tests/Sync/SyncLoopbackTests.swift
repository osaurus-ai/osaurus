//
//  SyncLoopbackTests.swift
//  OsaurusCoreTests
//
//  Two devices paired over loopback: a chat saved on one reads back
//  unchanged on the other, replies stream live, and headless sessions never
//  leave the device that ran them.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncLoopbackTests {
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

    private func toolSession() -> ChatSessionData {
        let call = ToolCall(
            id: "call_1",
            type: "function",
            function: ToolCallFunction(name: "get_weather", arguments: #"{"city":"Lisbon"}"#)
        )
        return ChatSessionData(
            id: UUID(),
            title: "Weather in Lisbon",
            createdAt: Date(timeIntervalSince1970: 1_767_225_600),
            updatedAt: Date(timeIntervalSince1970: 1_767_225_604),
            selectedModel: "OsaurusAI/gemma",
            turns: [
                ChatTurnData(
                    role: .user,
                    content: "What's the weather in Lisbon?",
                    createdAt: Date(timeIntervalSince1970: 1_767_225_600)
                ),
                ChatTurnData(
                    role: .assistant,
                    content: "",
                    toolCalls: [call],
                    toolResults: ["call_1": #"{"temp_c":21}"#],
                    thinkingDuration: 1.5,
                    thinking: "Call the weather tool.",
                    createdAt: Date(timeIntervalSince1970: 1_767_225_602)
                ),
                ChatTurnData(
                    role: .tool,
                    content: #"{"temp_c":21}"#,
                    toolCallId: "call_1",
                    createdAt: Date(timeIntervalSince1970: 1_767_225_603)
                ),
                ChatTurnData(
                    role: .assistant,
                    content: "It's 21°C and clear.",
                    createdAt: Date(timeIntervalSince1970: 1_767_225_604)
                ),
            ],
            agentId: UUID(),
            source: .chat
        )
    }

    @Test
    func aChatReachesThePairedDeviceAndHeadlessSessionsDoNot() async throws {
        try await ChatHistoryTestStorage.run {
            let store = SyncConversationStore.shared
            let mac = try SyncService.shared.open()
            try await mac.resume()

            let otherRoot = OsaurusPaths.root().appendingPathComponent("other-mac", isDirectory: true)
            let otherDirectory = otherRoot.appendingPathComponent("sync", isDirectory: true)
            try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
            var network = localNetworkConfig()
            network.enabled = true
            var other: SyncCore? = try SyncCore.open(
                dataDirectory: otherDirectory,
                deviceName: "Other Mac",
                network: network,
                keyStore: SyncKeyStores.make(dataDirectory: otherDirectory)
            )
            let peer = try #require(other)
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
            #expect(try peer.userKey() == mac.userKey())

            var chat = toolSession()
            try store.saveSession(chat)
            var headless = toolSession()
            headless.source = .http
            headless.externalSessionKey = "http-1"
            try store.saveSession(headless)
            let scope = try #require(store.scope(forSession: chat.id))
            let headlessScope = try #require(store.scope(forSession: headless.id))

            let changes = Recorder<ScopeChange>()
            let subscription = try peer.subscribe(scope: scope) { changes.append($0) }
            try await waitUntil("history") {
                try peer.messages(scope: scope, before: nil, limit: 50).messages.count == chat.turns.count
            }

            chat.turns.append(ChatTurnData(role: .user, content: "And tomorrow?", createdAt: Date()))
            try store.saveSession(chat)
            let stream = try mac.openStream(scope: scope, role: .assistant, asAgent: nil)
            try stream.push(delta: "Rain")
            try await waitUntil("streamed tokens") {
                changes.all.contains {
                    if case .stream(let update) = $0 { return update.text == "Rain" && update.state == .streaming }
                    return false
                }
            }
            let reply = ChatTurnData(role: .assistant, content: "Rain, 17°C.", createdAt: Date())
            store.finishStream(stream, sessionId: chat.id, turn: reply)
            chat.turns.append(reply)
            try store.saveSession(chat)
            try await waitUntil("reply committed") {
                try peer.messages(scope: scope, before: nil, limit: 50).messages.map(\.content).contains("Rain, 17°C.")
            }
            try await waitUntil("acknowledged") { try mac.syncStatus(scope: scope).pendingOutbox == 0 }
            #expect((try? peer.conversation(scope: headlessScope)) == nil)
            subscription.cancel()

            other = nil
            try await peer.close()
            SyncService.shared.close()
            OsaurusPaths.overrideRoot = otherRoot
            try SyncService.shared.open()
            store.invalidateCaches()

            let received = try #require(store.loadSession(id: chat.id))
            #expect(received.title == chat.title)
            #expect(received.source == .chat)
            #expect(received.agentId == chat.agentId)
            #expect(received.turns.map(\.id) == chat.turns.map(\.id))
            #expect(received.turns.map(\.role) == chat.turns.map(\.role))
            #expect(received.turns.map(\.content) == chat.turns.map(\.content))
            #expect(received.turns[1].thinking == "Call the weather tool.")
            #expect(received.turns[1].toolCalls?.map(\.function.name) == ["get_weather"])
            #expect(received.turns[1].toolResults["call_1"] == #"{"temp_c":21}"#)
            #expect(received.turns[2].toolCallId == "call_1")
            #expect(store.loadSession(id: headless.id) == nil)
        }
    }

    @Test
    func anIPhonesAnswersAndRequestsReachTheMacUnderItsOwnName() async throws {
        try await ChatHistoryTestStorage.run {
            let mac = try SyncService.shared.open()
            try await mac.resume()

            let phoneRoot = OsaurusPaths.root().appendingPathComponent("phone", isDirectory: true)
            let phoneDirectory = phoneRoot.appendingPathComponent("sync", isDirectory: true)
            try FileManager.default.createDirectory(at: phoneDirectory, withIntermediateDirectories: true)
            var network = localNetworkConfig()
            network.enabled = true
            let phone = try SyncCore.open(
                dataDirectory: phoneDirectory,
                deviceName: "Tae's iPhone",
                platform: .ios,
                network: network,
                keyStore: SyncKeyStores.make(dataDirectory: phoneDirectory)
            )
            let events = Recorder<CoreEvent>()
            phone.setListener { events.append([$0]) }
            try mac.addPeerAddress(address: #require(phone.localAddress()))
            try phone.addPeerAddress(address: #require(mac.localAddress()))
            try await phone.pairWithOffer(payload: mac.pairingOffer(ttlMs: 300_000).payload)
            try await SyncTestPairing.confirm(host: mac, joiner: phone)
            try await waitUntil("paired") {
                events.all.contains { if case .paired = $0 { return true } else { return false } }
            }
            try await waitUntil("the Mac lists the iPhone") {
                try mac.devices().contains { $0.id == phone.deviceKey() }
            }
            let devices = try mac.devices()
            #expect(devices.first { $0.id == phone.deviceKey() }?.devicePlatform == .iPhone)
            let names = SyncDeviceFeedContract.deviceNames(devices)
            #expect(names[phone.deviceKey()] == "Tae's iPhone")

            let feed = Data(#"{"v":1,"items":[],"recent":[]}"#.utf8)
            _ = try SyncAttentionFeed.publish(feed, core: mac, createIfMissing: true)
            try SyncManageFeed.publish(
                SyncManageFeed.state(device: mac.deviceKey(), agents: [], models: []),
                core: mac,
                createIfMissing: true
            )
            var attention: Conversation?
            var manage: Conversation?
            try await waitUntil("the iPhone sees both feeds") {
                attention = try SyncDeviceFeedContract.conversation(
                    kind: SyncDeviceFeedContract.attentionKind, device: mac.deviceKey(), core: phone)
                manage = try SyncDeviceFeedContract.conversation(
                    kind: SyncDeviceFeedContract.manageKind, device: mac.deviceKey(), core: phone)
                return attention != nil && manage != nil
            }

            let now = SyncHostedRunContract.nowMs()
            let answers = SyncDeviceFeedContract.AttentionAnswers(answers: [
                "item-1": .init(action: "approve", redact: ["d1"], answeredMs: now)
            ])
            let requests = SyncDeviceFeedContract.ManageRequests(requests: [
                .init(id: "r1", op: .warm, agentId: UUID().uuidString, requestedMs: now)
            ])
            try phone.setConversationAppData(
                scope: #require(attention).scope,
                namespace: SyncDeviceFeedContract.attentionAnswerNamespace(device: phone.deviceKey()),
                bytes: JSONEncoder().encode(answers)
            )
            try phone.setConversationAppData(
                scope: #require(manage).scope,
                namespace: SyncDeviceFeedContract.manageRequestNamespace(device: phone.deviceKey()),
                bytes: JSONEncoder().encode(requests)
            )

            var labeled: [SyncAttentionFeed.LabeledAnswer] = []
            var sources: [SyncManageFeed.RequestSource] = []
            try await waitUntil("the Mac reads them") {
                let macAttention = try SyncDeviceFeedContract.conversation(
                    kind: SyncDeviceFeedContract.attentionKind, device: mac.deviceKey(), core: mac)
                let macManage = try SyncDeviceFeedContract.conversation(
                    kind: SyncDeviceFeedContract.manageKind, device: mac.deviceKey(), core: mac)
                labeled = macAttention.map { SyncAttentionFeed.answers(in: $0, deviceNames: names, legacyLabel: "x") } ?? []
                sources = macManage.map { SyncManageFeed.sources(in: $0, deviceNames: names) } ?? []
                return !labeled.isEmpty && !sources.isEmpty
            }
            #expect(labeled.map(\.id) == ["item-1"])
            #expect(labeled.first?.deviceLabel == "Tae's iPhone")
            #expect(labeled.first?.answer.redact == ["d1"])
            #expect(sources.map(\.device) == [phone.deviceKey()])
            #expect(sources.first?.requests.map(\.op) == [.warm])
            #expect(sources.first?.keyPrefix == "\(phone.deviceKey())/")

            try await phone.close()
            SyncService.shared.close()
        }
    }

    @Test
    func aMacThatSignsOutKeepingChatsPairsAgainWithFreshFeedsAndRevokesTheIPhone() async throws {
        try await ChatHistoryTestStorage.run {
            let before = try SyncService.shared.open()
            let deviceKey = before.deviceKey()
            let feed = Data(#"{"v":1,"items":[],"recent":[]}"#.utf8)
            _ = try SyncAttentionFeed.publish(feed, core: before, createIfMissing: true)
            let oldFeed = try #require(
                try SyncDeviceFeedContract.conversation(
                    kind: SyncDeviceFeedContract.attentionKind, device: deviceKey, core: before)
            ).scope

            try await SyncService.shared.signOut(keepConversations: true)
            let mac = try #require(SyncService.shared.core)
            #expect(mac.deviceKey() == deviceKey, "signing out keeps the device key")
            #expect(try mac.conversation(scope: oldFeed)?.replication == .deviceLocal)
            #expect(
                try SyncDeviceFeedContract.conversation(
                    kind: SyncDeviceFeedContract.attentionKind, device: deviceKey, core: mac) == nil,
                "the device-local leftover isn't this Mac's feed any more")
            try await mac.resume()

            let phoneDirectory = OsaurusPaths.root().appendingPathComponent("phone/sync", isDirectory: true)
            try FileManager.default.createDirectory(at: phoneDirectory, withIntermediateDirectories: true)
            var network = localNetworkConfig()
            network.enabled = true
            let phone = try SyncCore.open(
                dataDirectory: phoneDirectory,
                deviceName: "Tae's iPhone",
                platform: .ios,
                network: network,
                keyStore: SyncKeyStores.make(dataDirectory: phoneDirectory)
            )
            let events = Recorder<CoreEvent>()
            phone.setListener { events.append([$0]) }
            try mac.addPeerAddress(address: #require(phone.localAddress()))
            try phone.addPeerAddress(address: #require(mac.localAddress()))
            try await phone.pairWithOffer(payload: mac.pairingOffer(ttlMs: 300_000).payload)
            try await SyncTestPairing.confirm(host: mac, joiner: phone)
            try await waitUntil("paired") {
                events.all.contains { if case .paired = $0 { return true } else { return false } }
            }

            _ = try SyncAttentionFeed.publish(feed, core: mac, createIfMissing: true)
            let newFeed = try #require(
                try SyncDeviceFeedContract.conversation(
                    kind: SyncDeviceFeedContract.attentionKind, device: deviceKey, core: mac)
            ).scope
            #expect(newFeed != oldFeed)
            try await waitUntil("the iPhone sees the new feed") {
                try SyncDeviceFeedContract.conversation(
                    kind: SyncDeviceFeedContract.attentionKind, device: deviceKey, core: phone)?.scope == newFeed
            }

            let phoneKey = phone.deviceKey()
            try await waitUntil("the Mac lists the iPhone") {
                SyncService.shared.devices.contains { $0.id == phoneKey && !$0.revoked }
            }
            #expect(SyncHostRunner.mayRequest(phoneKey, me: deviceKey, devices: SyncService.shared.devices, ownChat: false))

            try mac.revokeDevice(device: phoneKey)
            try await waitUntil("the Mac marks the iPhone removed") {
                SyncService.shared.devices.contains { $0.id == phoneKey && $0.revoked }
            }
            #expect(!SyncHostRunner.mayRequest(phoneKey, me: deviceKey, devices: SyncService.shared.devices, ownChat: false))
            #expect(SyncDeviceFeedContract.deviceNames(SyncService.shared.devices)[phoneKey] == nil)

            try await waitUntil("the iPhone is told it was removed") {
                events.all.contains { if case .selfRevoked = $0 { return true } else { return false } }
            }
            let late = SyncDeviceFeedContract.AttentionAnswers(answers: [
                "item-1": .init(action: "approve", answeredMs: SyncHostedRunContract.nowMs())
            ])
            #expect(throws: (any Error).self, "a removed iPhone can't write") {
                try phone.setConversationAppData(
                    scope: newFeed,
                    namespace: SyncDeviceFeedContract.attentionAnswerNamespace(device: phoneKey),
                    bytes: JSONEncoder().encode(late)
                )
            }
            try await Task.sleep(for: .seconds(2))
            let macFeed = try #require(try mac.conversation(scope: newFeed))
            #expect(
                !macFeed.appData.contains {
                    $0.namespace == SyncDeviceFeedContract.attentionAnswerNamespace(device: phoneKey)
                }, "a removed iPhone's answer doesn't arrive")

            try await phone.close()
            SyncService.shared.close()
        }
    }

    @Test
    func aWrongCodeIsReportedAsWrongOrExpired() async throws {
        try await ChatHistoryTestStorage.run {
            let mac = try SyncService.shared.open()
            try await mac.resume()
            let otherDirectory = OsaurusPaths.root().appendingPathComponent("other/sync", isDirectory: true)
            try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
            var network = localNetworkConfig()
            network.enabled = true
            let other = try SyncCore.open(
                dataDirectory: otherDirectory,
                deviceName: "Other Mac",
                network: network,
                keyStore: SyncKeyStores.make(dataDirectory: otherDirectory)
            )
            let events = Recorder<CoreEvent>()
            other.setListener { events.append([$0]) }
            try mac.addPeerAddress(address: #require(other.localAddress()))
            try other.addPeerAddress(address: #require(mac.localAddress()))
            let offer = try mac.pairingOffer(ttlMs: 300_000)
            let wrong = offer.code.first == "A" ? "BBBBBBBBBBBB" : "AAAAAAAAAAAA"
            try await other.pairWithOffer(payload: PairingOffer.payload(device: offer.device, code: wrong))
            var reason: String?
            try await waitUntil("refused") {
                reason = events.all.lazy.compactMap { if case .pairingFailed(let r) = $0 { return r } else { return nil } }.first
                return reason != nil
            }
            #expect(
                SyncStatusModel.pairingFailureMessage(try #require(reason))
                    == L("The code was wrong or has expired. Show a new code on your other device and paste its link again."))
            #expect(SyncStatusModel.pairingFailureMessage("something new") == L("Pairing didn't finish. Check the code and try again."))
            #expect(
                SyncStatusModel.pairingFailureMessage("update the app on the new device to pair with this one")
                    == L("The new device needs the latest version of Osaurus to pair. Update it, then try again."))
            #expect(SyncStatusModel.isOfferStillOpen(after: "the new device disconnected before pairing finished"))
            #expect(!SyncStatusModel.isOfferStillOpen(after: "pairing was declined on the other device"))
            #expect(SyncStatusModel.groupedConfirmationCode("483920") == "483 920")

            try await other.close()
            SyncService.shared.close()
        }
    }

    @Test
    func sameNetworkSuggestsAnywhereOnlyAfterFindingNobodyForAWhile() {
        var local = SyncConfiguration()
        local.networkEnabled = true
        local.networkMode = .localNetworkOnly
        var anywhere = local
        anywhere.networkMode = .anywhere
        let start = Date()
        let later = start.addingTimeInterval(SyncStatusModel.anywhereHintDelay)

        let first = SyncStatusModel.anywhereHint(
            configuration: local, otherDevices: 1, connected: 0, unreachableSince: nil, now: start)
        #expect(!first.suggest)
        #expect(first.unreachableSince == start)
        #expect(
            SyncStatusModel.anywhereHint(
                configuration: local, otherDevices: 1, connected: 0, unreachableSince: start, now: later
            ).suggest)
        for (configuration, others, connected) in [(anywhere, 1, 0), (local, 0, 0), (local, 2, 1)] {
            let hint = SyncStatusModel.anywhereHint(
                configuration: configuration, otherDevices: others, connected: connected,
                unreachableSince: start, now: later)
            #expect(!hint.suggest)
            #expect(hint.unreachableSince == nil)
        }
    }

    @Test
    func everySourceRoutesToTheRightReplication() {
        for source in SessionSource.allCases {
            let expected: Replication = [.chat, .imported, .workspace].contains(source) ? .synced : .deviceLocal
            #expect(SyncConversationMapper.replication(for: source) == expected, "\(source)")
            #expect(source.syncsAcrossDevices == (expected == .synced), "\(source)")
        }
    }
}
