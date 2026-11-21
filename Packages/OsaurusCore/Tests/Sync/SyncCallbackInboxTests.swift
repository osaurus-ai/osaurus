//
//  SyncCallbackInboxTests.swift
//  OsaurusCoreTests
//
//  The calls the user arranged, as the manage state lists them for the iPhone's Inbox (`callback_inbox`),
//  and the `cancelCallback` op that calls one off.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SyncCallbackInboxTests {

    private static let now: Int64 = 1_700_000_000_000

    private static func grant(
        createdMs: Int64? = now - 1000, end: AgentCallPolicy.End? = nil, attempts: [AgentCallPolicy.Attempt]? = nil
    ) -> AgentCallPolicy.Grant {
        AgentCallPolicy.Grant(
            id: UUID(), sessionId: UUID(), agentId: UUID(), about: "when the build finishes",
            expiresMs: now + 3_600_000, createdMs: createdMs, attempts: attempts, end: end,
            endedMs: end == nil ? nil : now)
    }

    @Test("the Mac says it lists arranged calls")
    func flag() {
        #expect(SyncDeviceFeedContract.features.contains("callback_inbox"))
    }

    @Test("waiting and ringing calls come first, then the ended ones with how they ended")
    func listing() {
        let waiting = Self.grant()
        let ringing = Self.grant()
        let missed = Self.grant(end: .missed)
        let listed = SyncAgentCalls.arrangedCalls(
            waiting: [(ringing, true), (waiting, false)], history: [missed], workingSessions: [waiting.sessionId])
        #expect(listed.map(\.state) == ["ringing", "waiting", "missed"])
        #expect(listed[0].id == ringing.id.uuidString.lowercased())
        #expect(listed[1].sessionId == waiting.sessionId.uuidString.lowercased())
        #expect(listed[1].about == "when the build finishes")
        #expect(listed[1].working == true)
        #expect(listed[0].working == nil && listed[2].working == nil)
        #expect(listed[2].endedMs == Self.now)
    }

    @Test("tries that rang nothing are listed; none is no list")
    func attempts() {
        let tried = Self.grant(attempts: [.init(atMs: Self.now, outcome: "busy")])
        let listed = SyncAgentCalls.arrangedCalls(
            waiting: [(tried, false), (Self.grant(attempts: []), false)], history: [], workingSessions: [])
        #expect(listed[0].attempts == [.init(atMs: Self.now, outcome: "busy")])
        #expect(listed[1].attempts == nil)
    }

    @Test("at most 20 ended calls go in the manage state")
    func historyCapped() {
        let history = (0..<30).map { _ in Self.grant(end: .answered) }
        let listed = SyncAgentCalls.arrangedCalls(waiting: [], history: history, workingSessions: [])
        #expect(listed.count == SyncDeviceFeedContract.callbackHistoryLimit)
    }

    @Test("every way a call ends is a state the contract names")
    func endNames() {
        let names: [AgentCallPolicy.End: String] = [
            .answered: "answered", .missed: "missed", .declined: "declined", .calledOff: "calledOff",
            .cancelled: "cancelled", .expired: "expired", .replaced: "replaced",
        ]
        for (end, name) in names { #expect(end.rawValue == name) }
    }

    // MARK: The Mac's Inbox rows

    @Test("a waiting call says when it was arranged, when it expires, the work, and tries that didn't ring")
    @MainActor
    func waitingSubtitle() {
        let grant = Self.grant(attempts: [
            .init(atMs: Self.now, outcome: "busy"), .init(atMs: Self.now, outcome: "notSent"),
        ])
        let now = Date(timeIntervalSince1970: TimeInterval(Self.now) / 1000)
        let subtitle = ArrangedCallPresentation.subtitle(grant, status: .waiting(working: true), now: now)
        #expect(subtitle.contains("Arranged"))
        #expect(subtitle.contains("Expires"))
        #expect(subtitle.contains("Work still running"))
        #expect(subtitle.contains("2 tries didn't reach you"))
    }

    @Test("a call the agent never made reads as not called")
    @MainActor
    func expiredRow() {
        let chip = ArrangedCallPresentation.chip(.ended(.expired))
        #expect(chip.text == "Not Called")
        let now = Date(timeIntervalSince1970: TimeInterval(Self.now) / 1000)
        #expect(
            ArrangedCallPresentation.subtitle(Self.grant(end: .expired), status: .ended(.expired), now: now)
                .hasPrefix("The agent didn't call in time"))
    }

    @Test("cancelCallback decodes with its callbackId")
    func decodesCancel() throws {
        let json = #"{"id":"r1","op":"cancelCallback","callbackId":"abc","requestedMs":1}"#
        let request = try JSONDecoder().decode(SyncDeviceFeedContract.ManageRequest.self, from: Data(json.utf8))
        #expect(request.op == .cancelCallback)
        #expect(request.callbackId == "abc")
    }

    @Test("cancelCallback without an id is refused before anything is called off")
    @MainActor
    func cancelNeedsId() async {
        let request = SyncDeviceFeedContract.ManageRequest(id: "r1", op: .cancelCallback, requestedMs: Self.now)
        let result = await SyncManageFeed.perform(request)
        #expect(!result.ok)
        #expect(result.error == "bad_request")
    }
}
