//
//  SyncApprovalPushTests.swift
//  osaurusTests
//
//  The notice an iPhone gets when a chat it started waits on an approval:
//  what it says, and that only the iPhone can read it.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

struct SyncApprovalPushTests {

    private static func approval(
        tool: String = "shell_run",
        description: String
    ) -> SyncHostedRunContract.PendingApproval {
        SyncHostedRunContract.PendingApproval(
            id: "a1", turnId: "t1", tool: tool, description: description, arguments: "{}",
            surface: nil, offersRunLease: false, requestedMs: 0)
    }

    private static func open(_ payload: Data, key: Data) throws -> [String: Any] {
        let outer = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let encoded = try #require(outer["o"] as? String)
        let sealed = try #require(Data(base64Encoded: encoded))
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: SymmetricKey(data: key))
        return try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
    }

    @Test("the summary is the description's first line, or the tool when there is none")
    func summary() {
        let twoLines = Self.approval(description: "Run `sleep 60`\nin the sandbox")
        #expect(SyncApprovalPush.summary(twoLines) == "Run `sleep 60`")
        // A tool's own description, as `shell_run`'s reads: its first sentence only.
        let toolDescription = Self.approval(
            description: "Run a shell command in the working directory. **Reserve this for builds, tests, git.**")
        #expect(SyncApprovalPush.summary(toolDescription) == "Run a shell command in the working directory")
        #expect(SyncApprovalPush.summary(Self.approval(description: "  \n")) == "shell_run")
        let long = String(repeating: "x", count: 500)
        #expect(SyncApprovalPush.summary(Self.approval(description: long)).count == 160)
    }

    @Test("a waiting notice shows a generic alert, with the agent and the request sealed")
    func waitingPayload() throws {
        let key = Data(repeating: 3, count: 32)
        let session = UUID()
        let payload = try SyncApprovalPush.payload(
            .waiting(agentName: "Builder", what: "Run `sleep 60`"),
            sessionId: session, agentId: UUID(), key: key, macDevice: "mac")
        let clear = String(decoding: payload, as: UTF8.self)
        #expect(!clear.contains("Builder"))
        #expect(!clear.contains("sleep"))
        let content = try Self.open(payload, key: key)
        #expect(content["event"] as? String == SyncApprovalPush.event)
        #expect(content["title"] as? String == "Builder")
        #expect(content["sessionId"] as? String == session.uuidString.lowercased())
        #expect((content["body"] as? String)?.hasSuffix("Run `sleep 60`") == true)
    }

    @Test("clearing is a background push naming only the chat")
    func clearedPayload() throws {
        let key = Data(repeating: 3, count: 32)
        let session = UUID()
        let payload = try SyncApprovalPush.payload(
            .cleared, sessionId: session, agentId: nil, key: key, macDevice: "mac")
        let outer = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let aps = try #require(outer["aps"] as? [String: Any])
        #expect(aps["content-available"] as? Int == 1)
        #expect(aps["alert"] == nil)
        let content = try Self.open(payload, key: key)
        #expect(content["event"] as? String == "approval_cleared")
        #expect(content["sessionId"] as? String == session.uuidString.lowercased())
        #expect(content["title"] == nil)
    }
}
