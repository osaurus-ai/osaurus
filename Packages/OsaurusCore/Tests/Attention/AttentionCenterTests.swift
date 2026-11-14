//
//  AttentionCenterTests.swift
//  osaurusTests
//
//  The attention hub: one resolver call per item, first answer wins,
//  channels retracted everywhere once settled, expiry times out, and
//  notification routing follows the per-category preferences.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
private final class RecordingChannel: NotificationChannel {
    let id: NotificationChannelID
    var delivered: [UUID] = []
    var retracted: [UUID] = []
    var gate: (AttentionItem) -> Bool = { _ in true }

    init(_ id: NotificationChannelID) { self.id = id }

    func shouldDeliver(_ item: AttentionItem) -> Bool { gate(item) }
    func deliver(_ item: AttentionItem) { delivered.append(item.id) }
    func retract(_ item: AttentionItem) { retracted.append(item.id) }
}

@MainActor
private func makeCenter(
    _ channels: [RecordingChannel],
    preferences: NotificationPreferences = .default
) -> AttentionCenter {
    let center = AttentionCenter(channels: channels)
    center.preferences = { preferences }
    return center
}

@Suite("Attention center")
@MainActor
struct AttentionCenterTests {
    @Test func resolverRunsOnceAndFirstAnswerWins() {
        let center = makeCenter([])
        var answers: [AttentionResolution.Outcome] = []
        let id = center.raise(AttentionItem(kind: .toolApproval, title: "Allow web_fetch?")) {
            answers.append($0.outcome)
        }
        #expect(center.pending.map(\.id) == [id])

        #expect(center.resolve(id: id, with: AttentionResolution(outcome: .approved, surface: .desktop)))
        #expect(!center.resolve(id: id, with: AttentionResolution(outcome: .denied, surface: .phone)))
        #expect(answers == [.approved])
        #expect(center.pending.isEmpty)
        #expect(center.item(id: id)?.resolution?.surface == .desktop)
    }

    @Test func settlingRetractsEveryChannelThatGotTheItem() {
        let desktop = RecordingChannel(.desktop)
        let phone = RecordingChannel(.phone)
        let center = makeCenter([desktop, phone])
        let id = center.raise(AttentionItem(kind: .ownerApproval, title: "x"))
        #expect(desktop.delivered == [id])
        #expect(phone.delivered == [id])

        center.resolve(id: id, with: AttentionResolution(outcome: .denied, surface: .phone))
        #expect(desktop.retracted == [id])
        #expect(phone.retracted == [id])
    }

    @Test func retractSettlesWithoutCallingTheResolver() {
        let center = makeCenter([])
        var called = false
        let id = center.raise(AttentionItem(kind: .inboundSharedRun, title: "x")) { _ in called = true }
        center.retract(id: id)
        #expect(!called)
        #expect(center.item(id: id)?.state == .retracted)
    }

    @Test func expiryTimesOut() async throws {
        let center = makeCenter([])
        var outcome: AttentionResolution.Outcome?
        center.raise(
            AttentionItem(kind: .ownerApproval, title: "x", expiresAt: Date().addingTimeInterval(0.05))
        ) { outcome = $0.outcome }
        for _ in 0 ..< 100 where outcome == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(outcome == .timedOut)
    }

    @Test func eventsAreSequencedForReplay() {
        let center = makeCenter([])
        let id = center.raise(AttentionItem(kind: .clarification, title: "x"))
        center.resolve(id: id, with: AttentionResolution(outcome: .replied, surface: .inline))
        let events = center.events(after: 0) ?? []
        #expect(events.map(\.event.wireName) == ["raised", "resolved"])
        #expect(center.events(after: center.lastSeq)?.isEmpty == true)
    }

    @Test func thePhoneFeedNamesTheOwnerAsYou() {
        let phone = Participant(kind: .ownerDevice, deviceLabel: "Phone")
        #expect(PairedDeviceChannel.wire(phone)["label"] as? String == "You · Phone")
        let teammate = Participant(kind: .teammate, handle: "alice", wallet: "0x9c3e0000000000000000000000000000000011aa")
        #expect(PairedDeviceChannel.wire(teammate)["label"] as? String == "@alice · 0x9c3e…11aa")
    }
}

@Suite("Notification routing")
@MainActor
struct NotificationRoutingTests {
    @Test func defaultRoutesKeepMessagesOffTheDesktop() {
        let desktop = RecordingChannel(.desktop)
        let inApp = RecordingChannel(.inApp)
        let center = makeCenter([desktop, inApp])
        let message = center.raise(AttentionItem(kind: .inboundMessage, title: "x"))
        let approval = center.raise(AttentionItem(kind: .ownerApproval, title: "y"))
        #expect(desktop.delivered == [approval])
        #expect(Set(inApp.delivered) == [message, approval])
        #expect(center.item(id: approval)?.deliveredTo == ["desktop", "in_app"])
    }

    @Test func switchingACategoryOffStopsDelivery() {
        var prefs = NotificationPreferences.default
        prefs.set(.approvals, .phone, false)
        let phone = RecordingChannel(.phone)
        let center = makeCenter([phone], preferences: prefs)
        center.raise(AttentionItem(kind: .toolApproval, title: "x"))
        center.raise(AttentionItem(kind: .clarification, title: "y"))
        #expect(phone.delivered.count == 1)
    }

    @Test func channelGateIsHonoured() {
        let desktop = RecordingChannel(.desktop)
        desktop.gate = { !$0.hasInlineCard }
        let center = makeCenter([desktop])
        center.raise(AttentionItem(kind: .toolApproval, title: "x", hasInlineCard: true))
        let shown = center.raise(AttentionItem(kind: .toolApproval, title: "y", hasInlineCard: false))
        #expect(desktop.delivered == [shown])
    }

    @Test func preferencesRoundTripAndFillMissingCategories() throws {
        var prefs = NotificationPreferences.default
        prefs.set(.messages, .desktop, true)
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(NotificationPreferences.self, from: data)
        #expect(decoded == prefs)

        let partial = try JSONDecoder().decode(
            NotificationPreferences.self, from: Data(#"{"routes":{"approvals":["in_app"]}}"#.utf8)
        )
        #expect(partial.allows(.ownerApproval, on: .inApp))
        #expect(!partial.allows(.ownerApproval, on: .desktop))
        #expect(partial.allows(.clarification, on: .desktop))
    }
}
