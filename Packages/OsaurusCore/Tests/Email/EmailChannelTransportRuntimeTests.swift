//
//  EmailChannelTransportRuntimeTests.swift
//  osaurusTests
//
//  The Email channel's mailbox checks with a fake mailbox: one scope per
//  watched account + mailbox, a baseline first, new mail handed to the
//  service and the cursor saved, catch-up at launch, a newly watched
//  mailbox starting at its newest mail, Receive off stopping checks, and a
//  refused sign-in pausing the account until Check Now.
//

import Foundation
import Testing

@testable import OsaurusCore

/// Cursor storage standing in for the event ledger.
actor EmailCursorStore {
    private var values: [String: JSONValue] = [:]
    func load(_ scope: String) -> JSONValue? { values[scope] }
    func save(_ value: JSONValue?, _ scope: String) { values[scope] = value }
}

@Suite(.serialized)
struct EmailChannelTransportRuntimeTests {
    static let connection = SourceConnection(
        id: "c1", displayName: "Work", config: .imap(IMAPConnectionConfig(host: "imap.example.com", username: "me@x.com")))

    struct Fixture {
        let runtime: EmailChannelTransportRuntime
        let service: EmailChannelService
        let fetcher: FakeMailboxFetcher
        let cursors: EmailCursorStore
        let deliveries: EmailDeliveryRecorder
        let health: AgentChannelTransportHealthCenter
    }

    private func withRuntime(
        _ configuration: EmailChannelConfiguration, cursors: EmailCursorStore = EmailCursorStore(),
        _ body: @Sendable (Fixture) async throws -> Void
    ) async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let previous = EmailChannelConfigurationStore.overrideDirectory
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-email-transport-\(UUID().uuidString)", isDirectory: true)
            EmailChannelConfigurationStore.overrideDirectory = directory
            defer {
                EmailChannelConfigurationStore.overrideDirectory = previous
                try? FileManager.default.removeItem(at: directory)
            }
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let service = EmailChannelService(messageStore: store)
            let deliveries = EmailDeliveryRecorder()
            let connection = Self.connection
            service.connectionLookup = { $0 == connection.id ? connection : nil }
            service.deliverToEvents = { deliveries.record($0) }
            try service.saveConfiguration(configuration)
            let fetcher = FakeMailboxFetcher()
            let health = AgentChannelTransportHealthCenter()
            let runtime = EmailChannelTransportRuntime(
                service: service, health: health, makeFetcher: { _ in fetcher },
                loadState: { await cursors.load($0) }, saveState: { await cursors.save($0, $1) }, awaitReady: {})
            do {
                try await body(
                    Fixture(
                        runtime: runtime, service: service, fetcher: fetcher, cursors: cursors, deliveries: deliveries,
                        health: health))
            } catch {
                await runtime.stop()
                throw error
            }
            await runtime.stop()
        }
    }

    private static func config(
        mailboxes: [String] = [], catchUp: SourceCatchUpPolicy = .sinceCursor, receive: Bool = true
    ) -> EmailChannelConfiguration {
        EmailChannelConfiguration(
            accounts: [
                EmailChannelAccount(
                    connectionId: "c1", mailboxes: mailboxes, catchUp: catchUp, senderAllowlist: ["@example.com"],
                    receiveEnabled: receive)
            ])
    }

    private func until(_ condition: () async -> Bool) async {
        for _ in 0 ..< 400 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func health(_ f: Fixture, room: String = "c1/INBOX") async -> AgentChannelTransportHealthState? {
        await f.health.state(
            connectionId: "email", transportId: EmailChannelTransportRuntime.transportId(roomId: room))
    }

    @Test func newMailReachesTheServiceAndTheCursorIsSaved() async throws {
        try await withRuntime(Self.config()) { f in
            await f.runtime.refresh(atLaunch: true)
            #expect(await f.runtime.scopeKeys == ["emailchannel:c1:INBOX"])
            // The first check takes a baseline and delivers nothing.
            await until { f.fetcher.calls.count >= 1 }
            #expect(f.fetcher.calls[0].cursor == nil)
            #expect(f.deliveries.messages.isEmpty)

            f.fetcher.append(FakeMailboxFetcher.message("m1"), FakeMailboxFetcher.message("m2", from: "eve@other.org"))
            await f.runtime.checkNow()
            await until { f.deliveries.messages.count >= 1 }
            await until { await f.cursors.load("emailchannel:c1:INBOX") == .number(2) }
            #expect(f.deliveries.messages.map(\.providerEventId) == ["email:c1:m1"])
            #expect(await f.cursors.load("emailchannel:c1:INBOX") == .number(2))
            await until { await health(f)?.status == .healthy }
            let state = await health(f)
            #expect(state?.status == .healthy)
            #expect(state?.lastReceivedCount == 2)
        }
    }

    @Test func launchCatchUpFollowsTheAccount() async throws {
        let cursors = EmailCursorStore()
        await cursors.save(.number(0), "emailchannel:c1:INBOX")
        try await withRuntime(Self.config(catchUp: .latestOnly), cursors: cursors) { f in
            f.fetcher.append(
                FakeMailboxFetcher.message("a"), FakeMailboxFetcher.message("b"), FakeMailboxFetcher.message("c"))
            await f.runtime.refresh(atLaunch: true)
            await until { f.deliveries.messages.count >= 1 }
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(f.fetcher.calls.first?.cursor == .number(0))
            #expect(f.deliveries.messages.map(\.providerEventId) == ["email:c1:c"])
        }
    }

    @Test func aMailboxWatchedLaterStartsAtItsNewestMail() async throws {
        try await withRuntime(Self.config()) { f in
            await f.runtime.refresh(atLaunch: true)
            await until { f.fetcher.calls.count >= 1 }
            // A stale cursor from long ago is not replayed.
            await f.cursors.save(.number(0), "emailchannel:c1:Receipts")
            f.fetcher.append(FakeMailboxFetcher.message("old"))
            try f.service.saveConfiguration(Self.config(mailboxes: ["INBOX", "Receipts"]))
            await f.runtime.refresh()
            #expect(await f.runtime.scopeKeys == ["emailchannel:c1:INBOX", "emailchannel:c1:Receipts"])
            await until { f.fetcher.calls.contains { $0.mailbox == "Receipts" } }
            #expect(f.fetcher.calls.first { $0.mailbox == "Receipts" }?.cursor == nil)
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(f.deliveries.messages.isEmpty)
        }
    }

    @Test func receiveOffStopsChecking() async throws {
        try await withRuntime(Self.config(receive: false)) { f in
            await f.runtime.refresh(atLaunch: true)
            #expect(await f.runtime.scopeKeys.isEmpty)
            try f.service.saveConfiguration(Self.config())
            await f.runtime.refresh()
            #expect(await f.runtime.scopeKeys.count == 1)
            try f.service.saveConfiguration(Self.config(receive: false))
            await f.runtime.refresh()
            #expect(await f.runtime.scopeKeys.isEmpty)
        }
    }

    @Test func aRefusedSignInPausesChecksUntilCheckNow() async throws {
        try await withRuntime(Self.config()) { f in
            await f.runtime.refresh(atLaunch: true)
            await until { f.fetcher.calls.count >= 1 }

            f.fetcher.fail(.loginRefused("Invalid credentials"))
            await f.runtime.checkNow()
            await until { await health(f)?.status == .failed }
            let paused = await health(f)
            #expect(paused?.status == .failed)
            #expect(paused?.detail?.contains("Invalid credentials") == true)
            #expect(paused?.isRunning == false)

            f.fetcher.fail(nil)
            f.fetcher.append(FakeMailboxFetcher.message("m1"))
            await f.runtime.checkNow()
            await until { f.deliveries.messages.count == 1 }
            #expect(f.deliveries.messages.count == 1)
            await until { await health(f)?.status == .healthy }
            #expect(await health(f)?.status == .healthy)
        }
    }
}
