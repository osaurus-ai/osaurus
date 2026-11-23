//
//  HarnessClarifyBridgeTests.swift
//  osaurusTests
//
//  `clarify` for the Architect on a harness: only its token reaches it, the
//  question waits on the chat's card, and every way the card closes tells
//  the model what to do next.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct HarnessClarifyBridgeTests {
    private let chatId = UUID()

    private func architectGrant(chatId: UUID?) -> HarnessGrant {
        HarnessGrant(
            agentId: Agent.architectId, chatId: chatId, allowsConfigWrites: false,
            allowedToolNames: HarnessGrantStore.architectToolNames, expiresAt: nil)
    }

    private func withQueue<T>(_ queue: PromptQueue?, _ body: () async throws -> T) async rethrows -> T {
        let previous = HarnessClarifyBridge.queue
        let previousAnswers = HarnessClarifyBridge.answerOverride
        HarnessClarifyBridge.queue = { [chatId] in $0 == chatId ? queue : nil }
        HarnessClarifyBridge.answerOverride = nil
        defer {
            HarnessClarifyBridge.queue = previous
            HarnessClarifyBridge.answerOverride = previousAnswers
        }
        return try await body()
    }

    private func clarifyState(_ queue: PromptQueue) async throws -> ClarifyPromptState {
        for _ in 0 ..< 200 {
            if case .clarify(let state) = queue.current { return state }
            await Task.yield()
        }
        throw CancellationError()
    }

    private func object(_ envelope: String) throws -> [String: JSONValue] {
        try #require(JSONValue.parse(envelope)?.objectValue, "\(envelope)")
    }

    @Test func onlyATokenThatNamesClarifyMayCallIt() {
        #expect(architectGrant(chatId: chatId).permitsTool("clarify"))
        let deferred = HarnessGrant(agentId: UUID(), allowsConfigWrites: false, allowedToolNames: nil, expiresAt: nil)
        #expect(!deferred.permitsTool("clarify"))
        let listed = HarnessGrant(
            agentId: UUID(), allowsConfigWrites: false, allowedToolNames: ["status"], expiresAt: nil)
        #expect(!listed.permitsTool("clarify"))
        #expect(!HarnessToolSurface.filtered(["clarify", "status"]).contains("clarify"))
        #expect(ClaudeCodeConfiguration.architectToolPatterns.contains("clarify"))
    }

    @Test func theAnswerOnTheCardIsTheCallsResult() async throws {
        let queue = PromptQueue()
        try await withQueue(queue) {
            let call = Task {
                try await HTTPHandler.executeBridgeCall(
                    toolName: "clarify",
                    argumentsJSON: #"{"question":"Which folder?","options":["Inbox","Archive"]}"#,
                    grant: architectGrant(chatId: chatId), attended: nil, toolCallId: "toolu_q")
            }
            let state = try await clarifyState(queue)
            #expect(state.question == "Which folder?")
            #expect(state.options == ["Inbox", "Archive"])
            let expiresAt = try #require(state.expiresAt)
            #expect(expiresAt.timeIntervalSinceNow > 13 * 60)
            #expect(expiresAt.timeIntervalSinceNow < TimeInterval(ClaudeCodeConfiguration.mcpToolTimeoutMilliseconds) / 1000)
            state.submit("Archive")
            queue.advance()
            let result = try object(try await call.value)
            #expect(result["ok"]?.boolValue == true)
            #expect(result["result"]?.objectValue?["answer"]?.stringValue == "Archive")
        }
    }

    @Test func closingTheCardTellsTheModelToAskInAReply() async throws {
        let queue = PromptQueue()
        try await withQueue(queue) {
            let call = Task {
                await HarnessClarifyBridge.execute(chatId: chatId, argumentsJSON: #"{"question":"Which folder?"}"#)
            }
            let state = try await clarifyState(queue)
            queue.dismiss([ObjectIdentifier(state)])
            let result = try object(await call.value)
            #expect(result["ok"]?.boolValue == false)
            #expect(result["message"]?.stringValue?.contains("short plain reply") == true)
            #expect(queue.current == nil)
        }
    }

    @Test func noWindowAndExpiryFailWithoutWaiting() async throws {
        try await withQueue(nil) {
            let result = try object(await HarnessClarifyBridge.execute(chatId: chatId, argumentsJSON: #"{"question":"Q?"}"#))
            #expect(result["ok"]?.boolValue == false)
            #expect(result["message"]?.stringValue?.contains("No window shows this chat") == true)
        }
        let queue = PromptQueue()
        try await withQueue(queue) {
            let result = try object(
                await HarnessClarifyBridge.execute(chatId: chatId, argumentsJSON: #"{"question":"Q?"}"#, window: 0.05))
            #expect(result["ok"]?.boolValue == false)
            #expect(result["message"]?.stringValue?.contains("Nobody answered") == true)
            #expect(queue.current == nil)
        }
    }

    @Test func stopClosesTheCard() async throws {
        let queue = PromptQueue()
        try await withQueue(queue) {
            let call = Task {
                await HarnessClarifyBridge.execute(chatId: chatId, argumentsJSON: #"{"question":"Q?"}"#)
            }
            _ = try await clarifyState(queue)
            call.cancel()
            _ = await call.value
            for _ in 0 ..< 200 where queue.current != nil { await Task.yield() }
            #expect(queue.current == nil)
        }
    }

    @Test func badArgumentsFailLikeTheBuiltInTool() async throws {
        try await withQueue(PromptQueue()) {
            let result = try object(await HarnessClarifyBridge.execute(chatId: chatId, argumentsJSON: #"{"question":"  "}"#))
            #expect(result["ok"]?.boolValue == false)
            #expect(result["kind"]?.stringValue == "invalid_args")
        }
    }

    @Test func otherAgentsDontReachTheCard() async throws {
        let queue = PromptQueue()
        try await withQueue(queue) {
            let other = HarnessGrant(
                agentId: UUID(), chatId: chatId, allowsConfigWrites: false,
                allowedToolNames: HarnessGrantStore.architectToolNames, expiresAt: nil)
            _ = try? await HTTPHandler.executeBridgeCall(
                toolName: "clarify", argumentsJSON: #"{"question":"Q?"}"#, grant: other, attended: nil,
                toolCallId: nil)
            #expect(queue.current == nil)
        }
    }

    @Test func theEvalSeamAnswersInPlaceOfThePerson() async throws {
        try await withQueue(nil) {
            HarnessClarifyBridge.answerOverride = { [chatId] asked, _ in asked == chatId ? "Inbox" : nil }
            let result = try object(await HarnessClarifyBridge.execute(chatId: chatId, argumentsJSON: #"{"question":"Q?"}"#))
            #expect(result["result"]?.objectValue?["answer"]?.stringValue == "Inbox")
        }
    }
}
