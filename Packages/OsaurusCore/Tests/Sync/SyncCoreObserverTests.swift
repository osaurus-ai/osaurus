//
//  SyncCoreObserverTests.swift
//  OsaurusCoreTests
//
//  `SyncService.observeCore`: consumers attach to the open core, drop their
//  subscriptions when it closes, and get changes again once it reopens.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncCoreObserverTests {
    @MainActor
    private final class Probe {
        var attached = 0
        var detached = 0
        var changes = 0
        var subscription: OsaurusSync.Subscription?
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func chat(_ title: String) -> ChatSessionData {
        ChatSessionData(title: title, turns: [ChatTurnData(role: .user, content: title)])
    }

    @Test
    func attachesNowDetachesOnCloseAndGetsChangesAgainAfterReopening() async throws {
        try await ChatHistoryTestStorage.run {
            let service = SyncService.shared
            let store = SyncConversationStore.shared
            try service.open()
            let probe = Probe()
            let observers = service.observeCore(
                attach: { core in
                    probe.attached += 1
                    probe.subscription?.cancel()
                    probe.subscription = core.subscribeConversations { _ in
                        Task { @MainActor in probe.changes += 1 }
                    }
                },
                detach: {
                    probe.detached += 1
                    probe.subscription?.cancel()
                    probe.subscription = nil
                }
            )
            defer { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
            #expect(probe.attached == 1)

            try store.saveSession(chat("before close"))
            try await waitUntil("a change while open") { probe.changes > 0 }

            service.close()
            try await waitUntil("detach") { probe.detached == 1 }

            let attachedBeforeReopen = probe.attached
            try service.open()
            try await waitUntil("reattach") { probe.attached > attachedBeforeReopen }
            let before = probe.changes
            try store.saveSession(chat("after reopen"))
            try await waitUntil("a change after reopening") { probe.changes > before }
        }
    }

    @Test
    func everySyncConsumerDropsItsSubscriptionOnCloseAndResubscribesOnReopen() async throws {
        try await ChatHistoryTestStorage.run {
            let service = SyncService.shared
            try service.open()
            SyncInboundApplier.shared._resetForTesting()
            SyncAgentDirectory.shared._resetForTesting()
            SyncHostRunner.shared._resetForTesting()
            SyncHostedRunMonitor.shared._resetForTesting()
            defer {
                SyncInboundApplier.shared._resetForTesting()
                SyncAgentDirectory.shared._resetForTesting()
                SyncHostRunner.shared._resetForTesting()
                SyncHostedRunMonitor.shared._resetForTesting()
            }
            SyncInboundApplier.shared.start()
            SyncAgentDirectory.shared.start()
            SyncHostRunner.shared.start()
            SyncHostedRunMonitor.shared.start()

            let attached = {
                [
                    SyncInboundApplier.shared._isAttachedForTesting,
                    SyncAgentDirectory.shared._isAttachedForTesting,
                    SyncHostRunner.shared._isAttachedForTesting,
                    SyncHostedRunMonitor.shared._isAttachedForTesting,
                ]
            }
            #expect(attached() == [true, true, true, true])

            service.close()
            try await waitUntil("every consumer detached") { attached() == [false, false, false, false] }

            try service.open()
            try await waitUntil("every consumer reattached") { attached() == [true, true, true, true] }
        }
    }
}
