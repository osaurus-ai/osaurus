//
//  SyncAgentCallsTests.swift
//  osaurusTests
//
//  Agent calls (`agent_calls`): which devices ring, what a call's outcome is
//  from the devices' answers, and that what a push carries opens only with
//  the device's own key.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

struct SyncAgentCallsTests {

    private static let nowMs: Int64 = 1_700_000_000_000

    private static func target(
        _ device: String,
        calls: Bool? = true,
        voipGrantId: String? = "voip-1",
        voipExpiresMs: Int64? = nowMs + 1000,
        key: Data = Data(repeating: 1, count: 32)
    ) -> SyncWorkflowPush.Target {
        let registration = SyncDeviceFeedContract.PushRegistration(
            grant: Data([1]).base64EncodedString(),
            grantId: "alert-\(device)",
            expiresMs: nowMs + 1000,
            contentKey: key.base64EncodedString(),
            installId: "install-\(device)",
            events: [],
            calls: calls,
            voipGrant: Data([2]).base64EncodedString(),
            voipGrantId: voipGrantId,
            voipExpiresMs: voipExpiresMs,
            updatedMs: nowMs
        )
        return SyncWorkflowPush.Target(device: device, registration: registration, grant: Data([1]), contentKey: key)
    }

    private static let request = SyncAgentCalls.Request(
        agentId: UUID(),
        agentName: "Builder",
        sessionId: UUID(),
        opening: "Your build finished: all tests pass.",
        reason: "Build finished"
    )

    // MARK: Who rings

    @Test("only devices set to ring, with a working PushKit grant, ring")
    func callTargets() {
        let targets = [
            Self.target("ringing"),
            Self.target("off", calls: false),
            Self.target("unset", calls: nil),
            Self.target("no-grant", voipGrantId: nil),
            Self.target("expired", voipExpiresMs: Self.nowMs - 1),
            Self.target("dropped", voipGrantId: "gone"),
        ]
        let chosen = SyncAgentCalls.callTargets(targets, dropped: ["gone"], nowMs: Self.nowMs)
        #expect(chosen.map(\.device) == ["ringing"])
        #expect(chosen.first?.voipGrant == Data([2]))
    }

    // MARK: Outcome

    @Test("no outcome while a device is still ringing")
    func stillRinging() {
        #expect(SyncAgentCalls.outcome(answers: ["a": "declined"], rang: ["a", "b"]) == nil)
    }

    @Test("an answer anywhere takes the call")
    func answered() {
        #expect(SyncAgentCalls.outcome(answers: ["a": "declined", "b": "answered"], rang: ["a", "b"]) == .answered)
    }

    @Test("turned down everywhere: declined if any declined, busy only if all were busy, else missed")
    func turnedDown() {
        #expect(SyncAgentCalls.outcome(answers: ["a": "declined", "b": "missed"], rang: ["a", "b"]) == .declined)
        #expect(SyncAgentCalls.outcome(answers: ["a": "busy", "b": "busy"], rang: ["a", "b"]) == .busy)
        #expect(SyncAgentCalls.outcome(answers: ["a": "busy", "b": "missed"], rang: ["a", "b"]) == .missed)
    }

    @Test("an answer from a device that didn't ring doesn't count")
    func strangerAnswer() {
        #expect(SyncAgentCalls.outcome(answers: ["x": "declined"], rang: ["a"]) == nil)
    }

    // MARK: Payloads

    private static func open(_ payload: Data, key: Data) throws -> [String: Any] {
        let outer = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let encoded = try #require(outer["o"] as? String)
        let sealed = try #require(Data(base64Encoded: encoded))
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: SymmetricKey(data: key))
        return try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
    }

    @Test("a ring carries the call sealed, and nothing in the clear")
    func ringPayload() throws {
        let key = Data(repeating: 7, count: 32)
        let payload = try SyncAgentCalls.payload(
            .ring, call: "c1", request: Self.request, key: key, macDevice: "mac", nowMs: Self.nowMs)
        let outer = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(Set(outer.keys) == ["o"])
        #expect(!String(decoding: payload, as: UTF8.self).contains("Builder"))

        let content = try Self.open(payload, key: key)
        #expect(content["kind"] as? String == "ring")
        #expect(content["callId"] as? String == "c1")
        #expect(content["agentName"] as? String == "Builder")
        #expect(content["sessionId"] as? String == Self.request.sessionId.uuidString.lowercased())
        #expect(content["opening"] as? String == Self.request.opening)
        #expect(content["reason"] as? String == "Build finished")

        #expect(throws: (any Error).self) { try Self.open(payload, key: Data(repeating: 8, count: 32)) }
    }

    @Test("a call-off names only the call")
    func cancelPayload() throws {
        let key = Data(repeating: 7, count: 32)
        let payload = try SyncAgentCalls.payload(
            .cancel, call: "c1", request: Self.request, key: key, macDevice: "mac", nowMs: Self.nowMs)
        let content = try Self.open(payload, key: key)
        #expect(content["kind"] as? String == "cancel")
        #expect(content["callId"] as? String == "c1")
        #expect(content["agentName"] == nil)
        #expect(content["opening"] == nil)
    }

    @Test("a missed-call notice shows a generic line, with the agent and reason sealed")
    func missedCallPayload() throws {
        let key = Data(repeating: 7, count: 32)
        let payload = try SyncAgentCalls.missedCallPayload(Self.request, key: key, macDevice: "mac")
        #expect(!String(decoding: payload, as: UTF8.self).contains("Builder"))
        let content = try Self.open(payload, key: key)
        #expect(content["event"] as? String == "missed_call")
        #expect(content["title"] as? String == "Builder")
        #expect(content["sessionId"] as? String == Self.request.sessionId.uuidString.lowercased())
    }
}
