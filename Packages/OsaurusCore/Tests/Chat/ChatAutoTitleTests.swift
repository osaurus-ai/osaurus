//
//  ChatAutoTitleTests.swift
//  osaurusTests
//
//  Pin the auto-title trigger contract: the pure eligibility check that
//  decides when a background title generation fires (and when a failed
//  attempt may retry), and `renameQuietly`'s promise to land a generated
//  title without bumping `updatedAt` — a bump would reorder the sidebar
//  out from under the user.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Auto-title decision")
struct AutoTitleDecisionTests {

    private let exchange: [ChatTurnData] = [
        ChatTurnData(role: .user, content: "How do I fix a SwiftUI layout bug?"),
        ChatTurnData(role: .assistant, content: "Start by checking the frame modifiers…"),
    ]

    private func decide(
        alreadyStarted: Bool = false,
        settingEnabled: Bool = true,
        runCompletedCleanly: Bool = true,
        isChatSource: Bool = true,
        currentTitle: String,
        turns: [ChatTurnData]
    ) -> ChatSession.AutoTitleDecision {
        ChatSession.autoTitleDecision(
            alreadyStarted: alreadyStarted,
            settingEnabled: settingEnabled,
            runCompletedCleanly: runCompletedCleanly,
            isChatSource: isChatSource,
            currentTitle: currentTitle,
            turns: turns
        )
    }

    @Test("first completed exchange with a preview title generates")
    func generatesFromPreviewTitle() {
        let preview = ChatSessionData.generateTitle(from: exchange)
        let decision = decide(currentTitle: preview, turns: exchange)
        #expect(
            decision
                == .generate(
                    userText: "How do I fix a SwiftUI layout bug?",
                    assistantText: "Start by checking the frame modifiers…",
                    previewTitle: preview
                )
        )
    }

    @Test("the untouched default title also generates")
    func generatesFromDefaultTitle() {
        let preview = ChatSessionData.generateTitle(from: exchange)
        guard case .generate(_, _, let previewTitle) = decide(
            currentTitle: "New Chat", turns: exchange)
        else {
            Issue.record("expected .generate")
            return
        }
        #expect(previewTitle == preview)
    }

    @Test("a user rename latches so later runs never re-title")
    func userRenameLatches() {
        #expect(decide(currentTitle: "My renamed chat", turns: exchange) == .latchAndSkip)
    }

    @Test("an in-flight or completed attempt skips")
    func alreadyStartedSkips() {
        let preview = ChatSessionData.generateTitle(from: exchange)
        #expect(
            decide(alreadyStarted: true, currentTitle: preview, turns: exchange) == .skip
        )
    }

    @Test("disabled setting, dirty run, and non-chat sources skip")
    func gatesSkip() {
        let preview = ChatSessionData.generateTitle(from: exchange)
        #expect(
            decide(settingEnabled: false, currentTitle: preview, turns: exchange) == .skip
        )
        #expect(
            decide(runCompletedCleanly: false, currentTitle: preview, turns: exchange) == .skip
        )
        #expect(
            decide(isChatSource: false, currentTitle: preview, turns: exchange) == .skip
        )
    }

    @Test("skips until a non-empty assistant response exists")
    func requiresAssistantContent() {
        let userOnly = [ChatTurnData(role: .user, content: "Hello there")]
        #expect(
            decide(
                currentTitle: ChatSessionData.generateTitle(from: userOnly),
                turns: userOnly
            ) == .skip
        )

        let blankAssistant =
            userOnly + [ChatTurnData(role: .assistant, content: "   \n")]
        #expect(
            decide(
                currentTitle: ChatSessionData.generateTitle(from: blankAssistant),
                turns: blankAssistant
            ) == .skip
        )
    }
}

@Suite(.serialized)
@MainActor
struct RenameQuietlyTests {

    @Test("renameQuietly updates the title without bumping updatedAt")
    func noUpdatedAtBump() async throws {
        try await ChatHistoryTestStorage.run {
            let originalUpdatedAt = Date(timeIntervalSinceNow: -3_600)
            let session = ChatSessionData(
                id: UUID(),
                title: "How do I fix a SwiftUI layout bug?",
                createdAt: Date(timeIntervalSinceNow: -7_200),
                updatedAt: originalUpdatedAt,
                turns: [ChatTurnData(role: .user, content: "How do I fix a SwiftUI layout bug?")]
            )
            ChatSessionsManager.shared.save(session)

            ChatSessionsManager.shared.renameQuietly(id: session.id, title: "SwiftUI Layout Bug")

            let inMemory = try #require(ChatSessionsManager.shared.session(for: session.id))
            #expect(inMemory.title == "SwiftUI Layout Bug")
            #expect(inMemory.updatedAt == originalUpdatedAt)

            // The write is handed to the store's async path; poll until it
            // lands rather than assuming the queue drained.
            try await waitUntil(timeout: .seconds(2)) {
                ChatSessionStore.load(id: session.id)?.title == "SwiftUI Layout Bug"
            }
            let persisted = try #require(ChatSessionStore.load(id: session.id))
            // Tolerance for the store's timestamp round-trip precision.
            #expect(
                abs(persisted.updatedAt.timeIntervalSince(originalUpdatedAt)) < 0.001
            )
        }
    }

    @Test("renameQuietly on a metadata-only copy never deletes turn rows")
    func preservesTurnsFromMetadataOnlyCopy() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSessionData(
                id: UUID(),
                title: "How do I fix a SwiftUI layout bug?",
                turns: [
                    ChatTurnData(role: .user, content: "How do I fix a SwiftUI layout bug?"),
                    ChatTurnData(role: .assistant, content: "Check the frame modifiers…"),
                ]
            )
            ChatSessionsManager.shared.save(session)

            // Reload from disk so the manager holds the metadata-only shape
            // (`loadAllMetadata` returns sessions with empty turns) — the
            // exact state that would wipe the conversation if the rename
            // went through the full incremental turn save.
            ChatSessionsManager.shared.refresh()
            let inMemory = try #require(ChatSessionsManager.shared.session(for: session.id))
            #expect(inMemory.turns.isEmpty)

            ChatSessionsManager.shared.renameQuietly(id: session.id, title: "SwiftUI Layout Bug")

            try await waitUntil(timeout: .seconds(2)) {
                ChatSessionStore.load(id: session.id)?.title == "SwiftUI Layout Bug"
            }
            let persisted = try #require(ChatSessionStore.load(id: session.id))
            #expect(persisted.turns.count == 2)
        }
    }

    @Test("renameQuietly with an unknown id is a no-op")
    func unknownIdNoOp() async throws {
        try await ChatHistoryTestStorage.run {
            let ghost = UUID()
            ChatSessionsManager.shared.renameQuietly(id: ghost, title: "Ghost")
            #expect(ChatSessionsManager.shared.session(for: ghost) == nil)
        }
    }
}

/// Local polling helper, matching the pattern in the other chat suites.
@MainActor
private func waitUntil(
    timeout: Duration,
    _ predicate: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(predicate(), "condition not met within \(timeout)")
}
