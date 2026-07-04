//
//  ChatSessionQueuedSendTests.swift
//  osaurusTests
//
//  Covers the Cursor-style "queue + interrupt" UX on `ChatSession`:
//
//  - `enqueueSend(_:attachments:)` captures the payload and clears the
//    bound input. Replacing semantics on a second call.
//  - `cancelQueuedSend()` drops the pending payload.
//  - Auto-flush in `completeRunCleanup` dispatches the queued send when
//    the run ends naturally, and is gated off when `stop()` is in-flight.
//  - `sendNowInterrupting()` cancels the active run and immediately
//    dispatches the queued payload as a new user turn.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionQueuedSendTests {

    // MARK: - Pure state helpers (no streaming engine needed)

    @Test
    func enqueueSend_capturesPayloadAndClearsInput() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.input = "ignored — enqueueSend takes its arg explicitly"
            session.pendingAttachments = []
            session.pendingOneOffSkillId = nil

            session.enqueueSend("plan B please", attachments: [])

            #expect(session.queuedSend?.text == "plan B please")
            #expect(session.queuedSend?.attachments.isEmpty == true)
            #expect(session.queuedSend?.oneOffSkillId == nil)
            #expect(session.input == "")
            #expect(session.pendingAttachments.isEmpty)
        }
    }

    @Test
    func enqueueSend_trimsWhitespace() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.enqueueSend("   hi   ", attachments: [])
            #expect(session.queuedSend?.text == "hi")
        }
    }

    @Test
    func enqueueSend_emptyIsNoOp() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.enqueueSend("   ", attachments: [])
            #expect(session.queuedSend == nil)
        }
    }

    @Test
    func enqueueSend_replacesExistingQueue() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.enqueueSend("first queued", attachments: [])
            session.enqueueSend("second queued", attachments: [])
            #expect(session.queuedSend?.text == "second queued")
        }
    }

    @Test
    func enqueueSend_capturesPendingOneOffSkillId() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let skillId = UUID()
            session.pendingOneOffSkillId = skillId

            session.enqueueSend("with skill", attachments: [])

            #expect(session.queuedSend?.oneOffSkillId == skillId)
            // Skill is consumed into the queue snapshot.
            #expect(session.pendingOneOffSkillId == nil)
        }
    }

    @Test
    func cancelQueuedSend_clearsQueue() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.enqueueSend("nevermind", attachments: [])
            #expect(session.queuedSend != nil)

            session.cancelQueuedSend()
            #expect(session.queuedSend == nil)
        }
    }

    // MARK: - Streaming integration

    @Test
    func naturalCompletion_autoFlushesQueuedSend() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { SlowFinishingChatEngine(delayMs: 60) }

            session.send("first")
            // Wait for the streaming flag to flip so the queued send
            // genuinely lands during an active run.
            try await waitUntil(timeout: .seconds(1)) { session.isStreaming }

            session.enqueueSend("auto flush me", attachments: [])
            #expect(session.queuedSend?.text == "auto flush me")

            // First run drains, completeRunCleanup auto-flushes which
            // kicks off a second run. Wait for everything to settle.
            try await waitUntil(timeout: .seconds(3)) {
                !session.isStreaming && session.queuedSend == nil
            }

            let userTurns = session.turns.filter { $0.role == .user }
            #expect(userTurns.map(\.content) == ["first", "auto flush me"])
            #expect(session.queuedSend == nil)
        }
    }

    @Test
    func stop_doesNotAutoFlushAndLeavesQueueIntact() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { SlowFinishingChatEngine(delayMs: 500) }

            session.send("first")
            try await waitUntil(timeout: .seconds(1)) { session.isStreaming }

            session.enqueueSend("should not auto-send", attachments: [])
            session.stop()

            #expect(session.isStreaming == false)
            // Queue is preserved so the user can re-decide via the chip
            // or Send Now. The plain Stop path must not dispatch.
            #expect(session.queuedSend?.text == "should not auto-send")

            // Let any pending tasks settle and confirm no follow-up
            // run was dispatched.
            try await Task.sleep(for: .milliseconds(200))
            let userTurns = session.turns.filter { $0.role == .user }
            #expect(userTurns.map(\.content) == ["first"])
            #expect(session.queuedSend?.text == "should not auto-send")
        }
    }

    @Test
    func sendNowInterrupting_stopsAndDispatchesAsNewUserTurn() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { SlowFinishingChatEngine(delayMs: 500) }

            session.send("first")
            try await waitUntil(timeout: .seconds(1)) { session.isStreaming }

            session.enqueueSend("urgent follow-up", attachments: [])
            session.sendNowInterrupting()

            // Queue is consumed; the new turn is appended synchronously
            // inside send(...) (the assistant placeholder follows in the
            // task body).
            #expect(session.queuedSend == nil)
            let userTurns = session.turns.filter { $0.role == .user }
            #expect(userTurns.map(\.content) == ["first", "urgent follow-up"])

            // Let the second run finish so we leave a clean session.
            try await waitUntil(timeout: .seconds(3)) {
                !session.isStreaming
            }
        }
    }

    @Test
    func sendNowInterrupting_isNoOpWhenQueueEmpty() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            // Not streaming, no queue → no-op, no crash.
            session.sendNowInterrupting()

            #expect(session.queuedSend == nil)
            #expect(session.turns.isEmpty)
            #expect(session.isStreaming == false)
        }
    }

    @Test
    func send_attachmentOnlyTurnPersistsBeforeAssistantCompletes() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { SlowFinishingChatEngine(delayMs: 500) }
            let attachment = Attachment.document(
                filename: "assessment.txt",
                content: "rubric details",
                fileSize: 13
            )

            session.send("   ", attachments: [attachment])

            let sessionId = try #require(session.sessionId)
            let persisted = try #require(ChatSessionStore.load(id: sessionId))
            #expect(persisted.turns.count == 1)
            #expect(persisted.turns[0].role == .user)
            #expect(persisted.turns[0].content == "")
            #expect(persisted.turns[0].attachments.count == 1)
            #expect(persisted.turns[0].attachments[0].filename == "assessment.txt")
            #expect(persisted.turns[0].attachments[0].documentContent == "rubric details")

            session.stop()
            try await waitUntil(timeout: .seconds(1)) { !session.isStreaming }
        }
    }

    @Test
    func send_plainTextPersistsBeforeAssistantCompletes() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { SlowFinishingChatEngine(delayMs: 500) }

            session.send("persist while streaming")
            try await waitUntil(timeout: .seconds(1)) { session.isStreaming }

            let sessionId = try #require(session.sessionId)
            let persisted = try #require(ChatSessionStore.load(id: sessionId))
            #expect(persisted.turns.count == 1)
            #expect(persisted.turns[0].role == .user)
            #expect(persisted.turns[0].content == "persist while streaming")

            session.stop()
            try await waitUntil(timeout: .seconds(1)) { !session.isStreaming }
        }
    }

    @Test
    func privacyCancelRemovesPersistedTransientUserTurn() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { CancellingBeforeDeltaChatEngine() }

            session.send("review will cancel")

            let transientId = try #require(session.sessionId)
            try await waitUntil(timeout: .seconds(2)) {
                !session.isStreaming && session.turns.isEmpty && session.sessionId == nil
            }

            #expect(ChatSessionStore.load(id: transientId) == nil)
            #expect(ChatSessionsManager.shared.session(for: transientId) == nil)
            #expect(session.input == "review will cancel")
        }
    }

    @Test
    func privacyCancelRemovesPersistedTurnFromPremintedEmptySession() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let premintedId = UUID()
            session.sessionId = premintedId
            session.chatEngineFactory = { CancellingBeforeDeltaChatEngine() }

            session.send("review will cancel")

            try await waitUntil(timeout: .seconds(2)) {
                !session.isStreaming && session.turns.isEmpty && session.sessionId == nil
            }

            #expect(ChatSessionStore.load(id: premintedId) == nil)
            #expect(ChatSessionsManager.shared.session(for: premintedId) == nil)
            #expect(session.input == "review will cancel")
        }
    }

    @Test
    func privacyCancelOnExistingSessionKeepsPersistedHistory() async throws {
        try await ChatHistoryTestStorage.run {
            let existingId = UUID()
            let existing = ChatSessionData(
                id: existingId,
                title: "Existing chat",
                turns: [ChatTurnData(role: .user, content: "previous question")]
            )
            ChatSessionsManager.shared.save(existing)

            let session = ChatSession()
            session.load(from: existing)
            session.chatEngineFactory = { CancellingBeforeDeltaChatEngine() }

            session.send("review will cancel")

            try await waitUntil(timeout: .seconds(2)) {
                !session.isStreaming && session.sessionId == existingId && session.turns.count == 1
            }

            let persisted = try #require(ChatSessionStore.load(id: existingId))
            #expect(persisted.turns.map(\.content) == ["previous question"])
            #expect(session.turns.map(\.content) == ["previous question"])
            #expect(session.input == "review will cancel")
        }
    }

    @Test
    func privacyCancelLeavesQueuedSendPending() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { DelayedCancellingBeforeDeltaChatEngine(delayMs: 120) }

            session.send("review will cancel")
            try await waitUntil(timeout: .seconds(1)) { session.isStreaming }
            let transientId = try #require(session.sessionId)

            let queuedAttachment = Attachment.document(
                filename: "follow-up.txt",
                content: "queued context",
                fileSize: 14
            )
            session.enqueueSend("queued follow-up", attachments: [queuedAttachment])

            try await waitUntil(timeout: .seconds(2)) {
                !session.isStreaming && session.turns.isEmpty && session.queuedSend != nil
            }

            #expect(session.sessionId == nil)
            #expect(session.input == "review will cancel")
            #expect(session.queuedSend?.text == "queued follow-up")
            #expect(session.queuedSend?.attachments.first?.filename == "follow-up.txt")
            #expect(ChatSessionStore.load(id: transientId) == nil)
            #expect(ChatSessionsManager.shared.session(for: transientId) == nil)
        }
    }

    @Test
    func stopBeforeFirstDeltaKeepsPersistedUserTurn() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.chatEngineFactory = { SlowFinishingChatEngine(delayMs: 500) }

            session.send("keep this after stop")
            try await waitUntil(timeout: .seconds(1)) { session.isStreaming }
            let sessionId = try #require(session.sessionId)

            session.stop()

            try await waitUntil(timeout: .seconds(1)) { !session.isStreaming }
            let persisted = try #require(ChatSessionStore.load(id: sessionId))
            #expect(persisted.turns.count == 1)
            #expect(persisted.turns[0].role == .user)
            #expect(persisted.turns[0].content == "keep this after stop")
        }
    }

    @Test
    func privacyCancelDuringRegenerationRestoresHistoricalTurns() async throws {
        try await ChatHistoryTestStorage.run {
            let sessionId = UUID()
            let existing = ChatSessionData(
                id: sessionId,
                title: "Regenerate chat",
                turns: [
                    ChatTurnData(role: .user, content: "original question"),
                    ChatTurnData(role: .assistant, content: "original answer"),
                ]
            )
            ChatSessionsManager.shared.save(existing)

            let session = ChatSession()
            session.load(from: existing)
            session.chatEngineFactory = { CancellingBeforeDeltaChatEngine() }
            let assistantId = try #require(session.turns.last?.id)

            session.regenerate(turnId: assistantId)

            try await waitUntil(timeout: .seconds(2)) {
                !session.isStreaming && session.sessionId == sessionId && session.turns.count == 2
            }

            let persisted = try #require(ChatSessionStore.load(id: sessionId))
            #expect(session.turns.map(\.content) == ["original question", "original answer"])
            #expect(persisted.turns.map(\.content) == ["original question", "original answer"])
        }
    }

    @Test
    func privacyCancelDuringEditRegenerationRestoresEditedHistory() async throws {
        try await ChatHistoryTestStorage.run {
            let sessionId = UUID()
            let existing = ChatSessionData(
                id: sessionId,
                title: "Edit regenerate chat",
                turns: [
                    ChatTurnData(role: .user, content: "original question"),
                    ChatTurnData(role: .assistant, content: "original answer"),
                ]
            )
            ChatSessionsManager.shared.save(existing)

            let session = ChatSession()
            session.load(from: existing)
            session.chatEngineFactory = { CancellingBeforeDeltaChatEngine() }
            let userId = try #require(session.turns.first?.id)

            session.editAndRegenerate(turnId: userId, newContent: "edited question")

            try await waitUntil(timeout: .seconds(2)) {
                !session.isStreaming && session.sessionId == sessionId && session.turns.count == 2
            }

            let persisted = try #require(ChatSessionStore.load(id: sessionId))
            #expect(session.turns.map(\.content) == ["original question", "original answer"])
            #expect(persisted.turns.map(\.content) == ["original question", "original answer"])
        }
    }

    @Test
    func abortedRegenerationDoesNotPoisonLaterPrivacyCancel() async throws {
        try await ChatHistoryTestStorage.run {
            let sessionId = UUID()
            let existing = ChatSessionData(
                id: sessionId,
                title: "Aborted regenerate chat",
                turns: [
                    ChatTurnData(role: .user, content: "original question"),
                    ChatTurnData(role: .assistant, content: "original answer"),
                ]
            )
            ChatSessionsManager.shared.save(existing)

            let session = ChatSession()
            session.load(from: existing)
            let assistantId = try #require(session.turns.last?.id)

            session.isStreaming = true
            session.regenerate(turnId: assistantId)
            session.isStreaming = false

            #expect(session.turns.map(\.content) == ["original question", "original answer"])

            session.chatEngineFactory = { CancellingBeforeDeltaChatEngine() }
            session.send("later normal message")

            try await waitUntil(timeout: .seconds(2)) {
                !session.isStreaming && session.sessionId == sessionId && session.turns.count == 2
            }

            let persisted = try #require(ChatSessionStore.load(id: sessionId))
            #expect(session.turns.map(\.content) == ["original question", "original answer"])
            #expect(persisted.turns.map(\.content) == ["original question", "original answer"])
            #expect(session.input == "later normal message")
        }
    }

    // MARK: - Mid-run steering (iteration-boundary injection)

    @Test
    func injectQueuedSteer_appendsUserTurnAndClearsQueue() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.turns.append(ChatTurn(role: .user, content: "first"))
            session.enqueueSend("actually, check the README too", attachments: [])

            let injected = session.injectQueuedSteerIfEligible()

            #expect(injected)
            #expect(session.queuedSend == nil)
            let userTurns = session.turns.filter { $0.role == .user }
            #expect(userTurns.map(\.content) == ["first", "actually, check the README too"])
        }
    }

    @Test
    func injectQueuedSteer_noOpWhenQueueEmpty() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            #expect(session.injectQueuedSteerIfEligible() == false)
            #expect(session.turns.isEmpty)
        }
    }

    @Test
    func injectQueuedSteer_attachmentsStayQueuedForFullSendPath() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let attachment = Attachment(kind: .image(Data([0x1])))
            session.enqueueSend("look at this", attachments: [attachment])

            let injected = session.injectQueuedSteerIfEligible()

            // Attachments need the full send path (media gating), so the
            // payload must stay queued for the run-end flush / Send Now.
            #expect(injected == false)
            #expect(session.queuedSend?.text == "look at this")
            #expect(session.turns.isEmpty)
        }
    }

    @Test
    func injectQueuedSteer_oneOffSkillStaysQueuedForFullSendPath() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.pendingOneOffSkillId = UUID()
            session.enqueueSend("use the skill", attachments: [])

            let injected = session.injectQueuedSteerIfEligible()

            #expect(injected == false)
            #expect(session.queuedSend?.text == "use the skill")
            #expect(session.turns.isEmpty)
        }
    }
}

// MARK: - Test doubles

/// Mimics a real model: blocks briefly before yielding so callers can
/// observe `isStreaming == true` and enqueue a follow-up before the run
/// finishes. Yields one delta and finishes cleanly (so completeRunCleanup
/// path is the "natural" finish, not the cancel path).
private actor SlowFinishingChatEngine: ChatEngineProtocol {
    let delayMs: Int

    init(delayMs: Int) {
        self.delayMs = delayMs
    }

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        let delay = delayMs
        return AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(delay))
                continuation.yield("ok")
                continuation.finish()
            }
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionQueuedSendTests", code: 1)
    }
}

private actor CancellingBeforeDeltaChatEngine: ChatEngineProtocol {
    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CancellationError())
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionQueuedSendTests", code: 3)
    }
}

private actor DelayedCancellingBeforeDeltaChatEngine: ChatEngineProtocol {
    let delayMs: Int

    init(delayMs: Int) {
        self.delayMs = delayMs
    }

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        let delay = delayMs
        return AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(delay))
                continuation.finish(throwing: CancellationError())
            }
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionQueuedSendTests", code: 4)
    }
}

// MARK: - Local waitUntil (file-private to avoid colliding with other test files)

private func waitUntil(
    timeout: Duration,
    _ predicate: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "ChatSessionQueuedSendTests", code: 2)
}
