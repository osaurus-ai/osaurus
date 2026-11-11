//
//  SyncWorkflowPushTests.swift
//  OsaurusCoreTests
//
//  Workflow notifications (`workflow_push`): which run changes are news,
//  which registrations get them, and the payload an iPhone decrypts.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Sync workflow push")
struct SyncWorkflowPushTests {
    private typealias Entry = SyncDeviceFeedContract.WorkflowRunEntry
    private typealias Registration = SyncDeviceFeedContract.PushRegistration

    private static let since: Int64 = 1_000_000

    private static func entry(_ id: String, _ status: String, started: Int64 = since + 10, finished: Int64? = nil)
        -> Entry
    {
        Entry(
            workflowId: "wf",
            card: SyncWorkflowCard(runId: id, name: "Weekly Report", status: status, steps: [], error: nil),
            caller: "user",
            startedMs: started,
            finishedMs: finished
        )
    }

    private static func registration(
        events: [String] = ["started", "awaiting_user", "completed", "failed", "needs_setup"],
        install: String = "install-1",
        updated: Int64 = 1,
        grantId: String = "g1",
        expires: Int64 = .max
    ) -> Registration {
        Registration(
            grant: Data([1, 2, 3]).base64EncodedString(),
            grantId: grantId,
            expiresMs: expires,
            contentKey: Data(repeating: 7, count: 32).base64EncodedString(),
            installId: install,
            events: events,
            onlyOthers: true,
            updatedMs: updated
        )
    }

    private static func kinds(_ events: [SyncWorkflowPush.Event]) -> [String] { events.map(\.kind) }

    @Test func historyIsNotNews() {
        let runs = [
            Self.entry("old", "completed", started: Self.since - 100, finished: Self.since - 50),
            Self.entry("new", "running"),
        ]
        let (events, next) = SyncWorkflowPush.events(previous: nil, runs: runs, sinceMs: Self.since)
        #expect(Self.kinds(events) == ["started"])
        #expect(next == ["old": "completed", "new": "running"])
    }

    @Test func statusChangesBecomeEvents() {
        let previous = ["a": "running", "b": "awaiting_user", "c": "running", "d": "awaiting_user"]
        let runs = [
            Self.entry("a", "awaiting_user"),
            Self.entry("b", "running"),
            Self.entry("c", "failed", finished: Self.since + 20),
            Self.entry("d", "awaiting_user"),
        ]
        let (events, _) = SyncWorkflowPush.events(previous: previous, runs: runs, sinceMs: Self.since)
        #expect(Self.kinds(events) == ["awaiting_user", "cleared", "failed"])
    }

    @Test func aRunThatEndedBetweenListsStillSendsItsEnd() {
        let (events, _) = SyncWorkflowPush.events(
            previous: [:], runs: [Self.entry("x", "completed", finished: Self.since + 5)], sinceMs: Self.since)
        #expect(Self.kinds(events) == ["completed"])
    }

    @Test func registrationsFollowTheirEvents() {
        let started = SyncWorkflowPush.Event(kind: "started", runId: "r", workflowId: "wf", name: "W", error: nil)
        let cleared = SyncWorkflowPush.Event(kind: "cleared", runId: "r", workflowId: "wf", name: "W", error: nil)
        let all = Self.registration()
        #expect(SyncWorkflowPush.wants(all, started, fromPhone: []))
        // A run the phone started isn't announced to it.
        #expect(!SyncWorkflowPush.wants(all, started, fromPhone: ["r"]))
        #expect(SyncWorkflowPush.wants(all, cleared, fromPhone: []))
        let endsOnly = Self.registration(events: ["completed", "failed"])
        #expect(!SyncWorkflowPush.wants(endsOnly, started, fromPhone: []))
        #expect(!SyncWorkflowPush.wants(endsOnly, cleared, fromPhone: []))
    }

    @Test func oneTargetPerInstallOfALiveDevice() {
        let found: [(String, Registration)] = [
            ("old-identity", Self.registration(updated: 10, grantId: "g-old")),
            ("new-identity", Self.registration(updated: 20, grantId: "g-new")),
            ("other-phone", Self.registration(install: "install-2", grantId: "g2")),
            ("revoked-phone", Self.registration(install: "install-3", grantId: "g3")),
            ("expired", Self.registration(install: "install-4", grantId: "g4", expires: 5)),
            ("dropped", Self.registration(install: "install-5", grantId: "g5")),
        ]
        let live: Set = ["old-identity", "new-identity", "other-phone", "expired", "dropped"]
        let targets = SyncWorkflowPush.choose(found, live: live, dropped: ["g5"], nowMs: 100)
        #expect(targets.map(\.device) == ["new-identity", "other-phone"])
    }

    @Test func thePayloadOpensWithTheRegistrationsKey() throws {
        let key = Data(repeating: 9, count: 32)
        let event = SyncWorkflowPush.Event(
            kind: "failed", runId: "r1", workflowId: "wf", name: "Weekly Report", error: "Draft: timed out")
        let text = SyncWorkflowPush.text(event, macName: "Studio")
        let payload = try SyncWorkflowPush.payload(event, text: text, key: key, macDevice: "mac")
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let aps = try #require(object["aps"] as? [String: Any])
        #expect(aps["mutable-content"] as? Int == 1)
        let sealed = try #require(Data(base64Encoded: try #require(object["o"] as? String)))
        let opened = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: SymmetricKey(data: key))
        let content = try #require(try JSONSerialization.jsonObject(with: opened) as? [String: Any])
        #expect(content["runId"] as? String == "r1")
        #expect(content["title"] as? String == "Weekly Report")
        #expect((content["body"] as? String)?.contains("timed out") == true)
        // Nothing readable outside the sealed part.
        #expect(String(data: payload, encoding: .utf8)?.contains("Weekly Report") == false)
    }

    @Test func aClearIsABackgroundPush() throws {
        let event = SyncWorkflowPush.Event(kind: "cleared", runId: "r1", workflowId: "wf", name: "W", error: nil)
        let payload = try SyncWorkflowPush.payload(
            event, text: ("W", ""), key: Data(repeating: 1, count: 32), macDevice: "mac")
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let aps = try #require(object["aps"] as? [String: Any])
        #expect(aps["content-available"] as? Int == 1)
        #expect(aps["alert"] == nil)
    }
}
