//
//  ChatSessionCompactionTests.swift
//  osaurusTests
//
//  Session-level contracts for LLM context compaction gates:
//  - the manual Compact button is available whenever there is a compactable
//    span, independent of utilization;
//  - with no compaction model configured, runs fall back to the chat's
//    current model instead of opening the model-selection dialog;
//  - a FAILED auto-triggered (pre-send) compaction keeps the dialog up with
//    the draft intact instead of silently proceeding, and dismissing it
//    resumes the stashed send.
//
//  The fallback model is deliberately one no service handles, so every run
//  fails fast with `modelUnavailable(<model>)` — the error text names the
//  model that was actually chosen, which is the proof we want.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionCompactionTests {
    private static let asyncTimeout: Duration = .seconds(15)
    private static let chatModel = "compaction-fallback-test-model"

    @Test("manual Compact is available at low utilization with no configured model")
    func manualCompactAvailableAtLowUtilization() async throws {
        try await ChatHistoryTestStorage.run {
            clearCompactionModel(contextCap: nil)
            let session = makeSession(pairs: 4, charsPerTurn: 40)
            #expect(ContextCompactionService.configuredModelIdentifier() == nil)
            #expect(session.effectiveCompactionModelIdentifier == Self.chatModel)
            #expect(session.hasCompactableConversation)
            #expect(session.canManuallyCompactConversation)
            #expect(session.compactionState == .idle)
        }
    }

    @Test("manual run falls back to the chat model and reports failure inline")
    func manualRunUsesChatModelFallback() async throws {
        try await ChatHistoryTestStorage.run {
            clearCompactionModel(contextCap: nil)
            let session = makeSession(pairs: 4, charsPerTurn: 40)

            session.requestManualCompaction()
            try await waitUntil(timeout: Self.asyncTimeout) {
                if case .failed = session.compactionState { return true }
                return false
            }
            guard case .failed(let message) = session.compactionState else {
                Issue.record("expected a failed compaction state")
                return
            }
            // The unavailable-model error names the model that was chosen:
            // the chat model, not a dialog request.
            #expect(message.contains(Self.chatModel))
            #expect(session.showCompactionDialog == false)
            #expect(session.hasPendingSendAfterCompaction == false)
            #expect(session.conversationSummary == nil)
        }
    }

    @Test("failed auto compaction keeps the dialog and draft; dismissing resumes the send")
    func failedAutoCompactionHoldsSendUntilDismissed() async throws {
        try await ChatHistoryTestStorage.run {
            // Small window so a modest transcript sits past the 85% auto gate.
            clearCompactionModel(contextCap: 8_192)
            let session = makeSession(pairs: 4, charsPerTurn: 4_000)
            let engine = ImmediateAnswerChatEngine()
            session.chatEngineFactory = { _ in engine }
            let turnCountBefore = session.turns.count

            session.input = "one more question"
            session.sendCurrent()

            try await waitUntil(timeout: Self.asyncTimeout) {
                if case .failed = session.compactionState { return true }
                return false
            }
            // Auto path: the send was stashed, not performed; the dialog is
            // up in its failed state with the draft untouched.
            #expect(session.showCompactionDialog)
            #expect(session.hasPendingSendAfterCompaction)
            #expect(session.input == "one more question")
            #expect(session.turns.count == turnCountBefore)
            if case .failed(let message) = session.compactionState {
                #expect(message.contains(Self.chatModel))
            }

            // "Send without compacting" → the stashed send proceeds.
            session.cancelCompactionDialog()
            try await waitUntil(timeout: Self.asyncTimeout) {
                session.turns.count > turnCountBefore
            }
            #expect(session.showCompactionDialog == false)
            #expect(session.hasPendingSendAfterCompaction == false)
            #expect(session.compactionState == .idle)
            #expect(session.turns[turnCountBefore].role == .user)
            #expect(session.turns[turnCountBefore].content == "one more question")
            try await waitUntil(timeout: Self.asyncTimeout) { !session.isSendActiveForComposer }
        }
    }

    // MARK: - Helpers

    private func clearCompactionModel(contextCap: Int?) {
        var cfg = ChatConfigurationStore.load()
        cfg.compactionModelProvider = nil
        cfg.compactionModelName = nil
        cfg.contextLengthCap = contextCap
        ChatConfigurationStore.save(cfg)
    }

    private func makeSession(pairs: Int, charsPerTurn: Int) -> ChatSession {
        let session = ChatSession()
        session.toolsDisabledForTestingOverride = true
        session.forceChatEngineRouteForTests = true
        session.selectedModel = Self.chatModel
        let filler = String(repeating: "lorem ipsum ", count: max(1, charsPerTurn / 12))
        for i in 0 ..< pairs {
            session.turns.append(ChatTurn(role: .user, content: "question \(i) \(filler)"))
            session.turns.append(ChatTurn(role: .assistant, content: "answer \(i) \(filler)"))
        }
        return session
    }
}

/// Answers immediately so the resumed send settles without a real model.
private actor ImmediateAnswerChatEngine: ChatEngineProtocol {
    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatSessionCompactionTests", code: 1)
    }
}

@MainActor
private func waitUntil(
    timeout: Duration,
    _ predicate: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "ChatSessionCompactionTests", code: 3)
}
