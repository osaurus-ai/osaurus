import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct RetainedChatTitleSynchronizationTests {
    private func exerciseRename(quiet: Bool, canonicalAlreadyRenamed: Bool = false) async throws {
        try await ChatHistoryTestStorage.run {
            let suiteName = "RetainedChatTitleSynchronizationTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let manager = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
            let id = UUID()
            let context = ExecutionContext(id: id, agentId: Agent.defaultId)
            context.chatSession.chatEngineFactory = { _ in MockChatEngine() }
            context.chatSession.title = "Original retained title"
            context.chatSession.turns = [
                ChatTurn(role: .user, content: "Keep this transcript"),
                ChatTurn(role: .assistant, content: "The retained result"),
            ]
            context.chatSession.save()
            let state = BackgroundTaskState(
                id: id,
                taskTitle: "Original retained title",
                agentId: Agent.defaultId,
                chatSession: context.chatSession,
                executionContext: context,
                status: .completed(summary: "Chat completed")
            )
            manager.registerTaskForTesting(state)
            manager.dehydrateTaskForTesting(id)
            let initialSaved = await Task.detached { manager.flushRetainedTabWrites() }.value
            #expect(initialSaved)
            let target = quiet ? "Generated canonical title" : "Renamed through Chat UI"
            do {
                let before = try #require(ChatSessionStore.load(id: id))
                if canonicalAlreadyRenamed {
                    // Canonical data may already have the generated title
                    // before renameQuietly reconciles the metadata list.
                    ChatSessionsManager.shared.renameQuietly(id: id, title: target)
                }
                if quiet {
                    ChatSessionsManager.shared.renameQuietly(id: id, title: target, retainedTaskManager: manager)
                } else {
                    ChatSessionsManager.shared.rename(id: id, title: target, retainedTaskManager: manager)
                }
                let renamed = try #require(ChatSessionStore.load(id: id))
                #expect(renamed.title == target)
                if quiet { #expect(renamed.updatedAt == before.updatedAt) }
                #expect(state.taskTitle == target, "The retained record must use the canonical Chat title")
                let saved = await Task.detached { manager.flushRetainedTabWrites() }.value
                #expect(saved)
                let relaunched = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
                let restored = try #require(relaunched.taskState(for: id))
                #expect(restored.taskTitle == target)

                // No window owns this session. This is the actual headless
                // reveal path that reconciles the DB from retained metadata.
                let revealed = try #require(relaunched.executionContextForReveal(id))
                #expect(revealed.chatSession.title == target)
                let afterReveal = try #require(ChatSessionStore.load(id: id))
                #expect(afterReveal.title == target, "A stale retained alias must not revert a saved title")
                #expect(afterReveal.turns.map(\.content) == before.turns.map(\.content))
                // Optional proof-run receipt. A unique filename and exclusive
                // creation retain every iteration; normal CI needs no path.
                if let path = ProcessInfo.processInfo.environment["OSAURUS_TEST_EVIDENCE_DIR"] {
                    let root = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let receipt: [String: Any] = [
                        "quiet": quiet,
                        "canonical_already_renamed": canonicalAlreadyRenamed,
                        "expected_title": target,
                        "initial_title": before.title,
                        "renamed_canonical_title": renamed.title,
                        "retained_live_title": state.taskTitle,
                        "restored_record_title": restored.taskTitle,
                        "revealed_title": revealed.chatSession.title,
                        "canonical_after_reveal": afterReveal.title,
                        "initial_updated_at": before.updatedAt.timeIntervalSince1970,
                        "renamed_updated_at": renamed.updatedAt.timeIntervalSince1970,
                        "initial_transcript": before.turns.map(\.content),
                        "after_transcript": afterReveal.turns.map(\.content),
                        "retained_payload_base64": defaults.data(forKey: "retainedNotchTabs.v1")?.base64EncodedString()
                            ?? "",
                    ]
                    let data = try JSONSerialization.data(
                        withJSONObject: receipt,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    try data.write(
                        to: root.appendingPathComponent(UUID().uuidString + ".json"),
                        options: [.withoutOverwriting]
                    )
                }
            } catch {
                manager.finalizeTask(id)
                _ = await Task.detached { manager.flushRetainedTabWrites() }.value
                throw error
            }
            manager.finalizeTask(id)
            let cleared = await Task.detached { manager.flushRetainedTabWrites() }.value
            #expect(cleared)
        }
    }

    @Test func manualChatRenameUpdatesRetainedMetadataAndHeadlessReveal() async throws {
        try await exerciseRename(quiet: false)
    }

    @Test func automaticTitlePreservesTimestampAndRetainedMetadata() async throws {
        try await exerciseRename(quiet: true)
    }

    @Test func equalCanonicalTitleStillReconcilesAStaleRetainedTitle() async throws {
        try await exerciseRename(quiet: true, canonicalAlreadyRenamed: true)
    }

    @Test func ordinaryChatRenameWithoutARetainedOwnerPreservesTranscript() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = BackgroundTaskManager.makeForTesting()
            let id = UUID()
            let context = ExecutionContext(id: id, agentId: Agent.defaultId)
            context.chatSession.turns = [
                ChatTurn(role: .user, content: "An ordinary conversation"),
                ChatTurn(role: .assistant, content: "Keep its transcript"),
            ]
            context.chatSession.save()
            let before = try #require(ChatSessionStore.load(id: id))
            ChatSessionsManager.shared.rename(id: id, title: "Ordinary rename", retainedTaskManager: manager)
            let after = try #require(ChatSessionStore.load(id: id))
            #expect(after.title == "Ordinary rename")
            #expect(after.turns.map(\.content) == before.turns.map(\.content))
            #expect(manager.taskState(for: id) == nil)
        }
    }
}
