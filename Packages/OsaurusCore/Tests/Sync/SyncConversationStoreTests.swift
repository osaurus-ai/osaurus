//
//  SyncConversationStoreTests.swift
//  OsaurusCoreTests
//
//  Sessions saved through the sync store read back unchanged, saves only
//  write what changed, and headless sessions stay on this device.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncConversationStoreTests {
    private func withStore(_ body: @MainActor @Sendable (SyncConversationStore, SyncCore) throws -> Void) async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            try body(SyncConversationStore.shared, core)
        }
    }

    private func toolSession(source: SessionSource = .chat) -> ChatSessionData {
        let call = ToolCall(
            id: "call_1",
            type: "function",
            function: ToolCallFunction(name: "get_weather", arguments: #"{"city":"Lisbon"}"#)
        )
        var assistant = ChatTurnData(
            role: .assistant,
            content: "",
            toolCalls: [call],
            toolResults: ["call_1": #"{"temp_c":21}"#],
            toolCallDurations: ["call_1": 0.42],
            thinkingDuration: 1.5,
            thinking: "Call the weather tool.",
            createdAt: Date(timeIntervalSince1970: 1_767_225_602)
        )
        assistant.generationTokenCount = 12
        return ChatSessionData(
            id: UUID(),
            title: "Weather in Lisbon",
            createdAt: Date(timeIntervalSince1970: 1_767_225_600),
            updatedAt: Date(timeIntervalSince1970: 1_767_225_604),
            selectedModel: "OsaurusAI/gemma",
            turns: [
                ChatTurnData(
                    role: .user,
                    content: "What's the weather in Lisbon?",
                    createdAt: Date(timeIntervalSince1970: 1_767_225_600),
                    injectedContextPrefix: "<memory>Celsius</memory>"
                ),
                assistant,
                ChatTurnData(
                    role: .tool,
                    content: #"{"temp_c":21}"#,
                    toolCallId: "call_1",
                    createdAt: Date(timeIntervalSince1970: 1_767_225_603)
                ),
                ChatTurnData(
                    role: .assistant,
                    content: "It's 21°C and clear.",
                    createdAt: Date(timeIntervalSince1970: 1_767_225_604),
                    terminalStopReason: "stop"
                ),
            ],
            agentId: UUID(),
            source: source,
            capabilities: [.search, .vision],
            folderPath: "~/Projects/trip",
            projectId: UUID()
        )
    }

    private func messages(_ core: SyncCore, _ scope: String) throws -> [OsaurusSync.Message] {
        try core.messages(scope: scope, before: nil, limit: 500).messages
    }

    @Test
    func savedSessionReadsBackUnchanged() async throws {
        try await withStore { store, core in
            let session = toolSession()
            try store.saveSession(session)

            let loaded = try #require(store.loadSession(id: session.id))
            #expect(loaded.title == session.title)
            #expect(loaded.agentId == session.agentId)
            #expect(loaded.projectId == session.projectId)
            #expect(loaded.selectedModel == session.selectedModel)
            #expect(loaded.capabilities == session.capabilities)
            #expect(loaded.folderPath == session.folderPath)
            #expect(abs(loaded.createdAt.timeIntervalSince(session.createdAt)) < 0.001)
            #expect(loaded.turns.map(\.id) == session.turns.map(\.id))
            #expect(loaded.turns.map(\.role) == session.turns.map(\.role))
            #expect(loaded.turns.map(\.content) == session.turns.map(\.content))
            #expect(loaded.turns[0].injectedContextPrefix == "<memory>Celsius</memory>")
            #expect(loaded.turns[1].toolCalls?.first?.function.name == "get_weather")
            #expect(loaded.turns[1].toolResults == ["call_1": #"{"temp_c":21}"#])
            #expect(loaded.turns[1].thinking == "Call the weather tool.")
            #expect(loaded.turns[1].generationTokenCount == 12)
            #expect(loaded.turns[2].toolCallId == "call_1")
            #expect(loaded.turns[3].terminalStopReason == "stop")

            let scope = try #require(store.scope(forSession: session.id))
            let stored = try messages(core, scope)
            #expect(stored.map(\.role) == [.user, .assistant, .toolResult, .assistant])
            #expect(stored[2].toolName == "get_weather")
            let conversation = try #require(try core.conversation(scope: scope))
            #expect(conversation.replication == .synced)
            #expect(conversation.tag("osaurus.session") == session.id.uuidString.lowercased())
            #expect(conversation.tag("source") == "chat")
        }
    }

    @Test
    func theOrchestratorsSessionStateSurvivesAReload() async throws {
        try await withStore { store, _ in
            var session = toolSession()
            let state = SessionState(
                goal: "weekly report", decisions: ["use the Files worker"], facts: ["folder is ~/Reports"],
                openItems: ["offered to keep \"Weekly report\" (keep_draft 1234)"],
                inFlight: [RunRef(runId: "run-1", workflow: "Weekly report", status: "awaiting_user")], stale: true)
            session.sessionState = state
            try store.saveSession(session)
            store.invalidateCaches()

            let loaded = try #require(store.loadSession(id: session.id))
            #expect(loaded.sessionState == state)

            session.sessionState = nil
            try store.saveSession(session)
            store.invalidateCaches()
            #expect(store.loadSession(id: session.id)?.sessionState == nil)
        }
    }

    @Test
    func resavingUnchangedSessionWritesNothing() async throws {
        try await withStore { store, core in
            let session = toolSession()
            try store.saveSession(session)
            let scope = try #require(store.scope(forSession: session.id))
            let before = try messages(core, scope)

            try store.saveSession(session)
            store.invalidateCaches()
            try store.saveSession(try #require(store.loadSession(id: session.id)))

            let after = try messages(core, scope)
            #expect(after.map(\.id) == before.map(\.id))
            #expect(after.map(\.hlc) == before.map(\.hlc))
            #expect(after.allSatisfy { !$0.edited })
        }
    }

    @Test
    func savesOnlyTouchChangedTurns() async throws {
        try await withStore { store, core in
            var session = toolSession()
            try store.saveSession(session)
            let scope = try #require(store.scope(forSession: session.id))
            let before = try messages(core, scope)

            session.turns[3].content = "It's 21°C and sunny."
            session.turns.append(ChatTurnData(role: .user, content: "Thanks!"))
            try store.saveSession(session)

            let after = try messages(core, scope)
            #expect(after.count == 5)
            #expect(Array(after.prefix(4).map(\.id)) == before.map(\.id))
            #expect(after[3].edited)
            #expect(after[3].content == "It's 21°C and sunny.")
            #expect(!after[0].edited && !after[1].edited)
            #expect(store.loadSession(id: session.id)?.turns.map(\.content).last == "Thanks!")

            session.turns.remove(at: 1)
            try store.saveSession(session)
            let reloaded = try #require(store.loadSession(id: session.id))
            #expect(reloaded.turns.map(\.id) == session.turns.map(\.id))
        }
    }

    @Test
    func insertedTurnKeepsOrder() async throws {
        try await withStore { store, _ in
            var session = toolSession()
            try store.saveSession(session)
            session.turns.insert(ChatTurnData(role: .user, content: "Inserted"), at: 1)
            try store.saveSession(session)
            store.invalidateCaches()
            let reloaded = try #require(store.loadSession(id: session.id))
            #expect(reloaded.turns.map(\.id) == session.turns.map(\.id))
        }
    }

    @Test
    func headlessSessionsStayOnThisDevice() async throws {
        try await withStore { store, core in
            var session = toolSession(source: .http)
            session.externalSessionKey = "caller-1"
            session.sourcePluginId = "http"
            try store.saveSession(session)
            let scope = try #require(store.scope(forSession: session.id))
            #expect(try core.conversation(scope: scope)?.replication == .deviceLocal)

            let found = try #require(store.findSession(pluginId: "http", externalKey: "caller-1", agentId: session.agentId))
            #expect(found.id == session.id)
            #expect(store.findSession(pluginId: "http", externalKey: "caller-1", agentId: nil) == nil)
            #expect(store.findSession(source: .http, externalKey: "caller-1", agentId: session.agentId)?.id == session.id)

            try store.deleteSession(id: session.id)
            #expect(try core.conversation(scope: scope) == nil)
            #expect(store.loadSession(id: session.id) == nil)
        }
    }

    @Test
    func emptySessionIsADraftUntilItHasTurns() async throws {
        try await withStore { store, core in
            let draft = ChatSessionData(id: UUID(), title: "New Chat")
            try store.saveSession(draft)
            #expect(try core.conversations().isEmpty)
            #expect(store.loadAllMetadata().map(\.id) == [draft.id])
            #expect(store.loadSession(id: draft.id)?.title == "New Chat")

            var started = draft
            started.turns = [ChatTurnData(role: .user, content: "Hello")]
            try store.saveSession(started)
            #expect(try core.conversations().count == 1)
            #expect(store.loadAllMetadata().map(\.id) == [draft.id])
        }
    }

    @Test
    func metadataUpdatesApply() async throws {
        try await withStore { store, core in
            let session = toolSession()
            try store.saveSession(session)
            let project = UUID()
            store.updateSessionTitleAsync(id: session.id, title: "Lisbon trip", updatedAt: nil)
            store.updateSessionPinnedAsync(id: session.id, pinned: true)
            store.updateSessionArchivedAsync(id: session.id, archived: true)
            store.updateSessionProjectAsync(id: session.id, projectId: project)
            store.drain(timeout: 5)

            let loaded = try #require(store.loadMetadata(ids: [session.id]).first)
            #expect(loaded.title == "Lisbon trip")
            #expect(loaded.pinned)
            #expect(loaded.archived)
            #expect(loaded.projectId == project)
            #expect(store.loadSession(id: session.id)?.turns.count == 4)

            store.clearProjectAsync(projectId: project)
            store.drain(timeout: 5)
            #expect(store.loadMetadata(ids: [session.id]).first?.projectId == nil)
            let scope = try #require(store.scope(forSession: session.id))
            #expect(try core.conversation(scope: scope)?.tag("projectId") == nil)
        }
    }

    @Test
    func turnCountsAndSearch() async throws {
        try await withStore { store, _ in
            let session = toolSession()
            try store.saveSession(session)
            #expect(store.turnCounts(forAgent: session.agentId)[session.id] == 4)
            #expect(store.turnCounts(forAgent: UUID())[session.id] == nil)
            #expect(store.sessionIds(withContentContaining: "Lisbon") == [session.id])
            #expect(store.sessionIds(withContentContaining: "zanzibar").isEmpty)
        }
    }

    @Test
    func largeValuesMoveToBlobsAndReadBack() async throws {
        try await withStore { store, core in
            var session = toolSession()
            let big = String(repeating: "result line\n", count: 4_000)
            session.turns[1].toolResults["call_1"] = big
            session.turns[2] = ChatTurnData(
                id: session.turns[2].id,
                role: .tool,
                content: big,
                toolCallId: "call_1"
            )
            session.turns[0].injectedContextPrefix = String(repeating: "m", count: 20_000)
            try store.saveSession(session)

            let scope = try #require(store.scope(forSession: session.id))
            let stored = try messages(core, scope)
            let appData = try #require(stored[1].appData("ai.osaurus.turn/1"))
            #expect(appData.bytes.count < 64 * 1024)
            #expect(appData.blobs.count == 1)

            store.invalidateCaches()
            let loaded = try #require(store.loadSession(id: session.id))
            #expect(loaded.turns[1].toolResults["call_1"] == big)
            #expect(loaded.turns[2].content == big)
            #expect(loaded.turns[0].injectedContextPrefix?.count == 20_000)
        }
    }

    @Test
    func attachmentsRoundTrip() async throws {
        try await withStore { store, core in
            let smallImage = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 1, count: 100))
            let bigImage = Data([0xFF, 0xD8, 0xFF] + Array(repeating: 2, count: 40_000))
            let document = Attachment.document(filename: "notes.txt", content: "Day 1: Alfama.", fileSize: 14)
            let session = ChatSessionData(
                id: UUID(),
                title: "Files",
                turns: [
                    ChatTurnData(
                        role: .user,
                        content: "See attached",
                        attachments: [.image(smallImage), .image(bigImage), document]
                    )
                ]
            )
            try store.saveSession(session)
            let scope = try #require(store.scope(forSession: session.id))
            let stored = try messages(core, scope)
            #expect(stored[0].blobs.count == 3)
            #expect(stored[0].blobs[0].mediaType == "image/png")
            #expect(stored[0].blobs[1].mediaType == "image/jpeg")

            store.invalidateCaches()
            let turn = try #require(store.loadSession(id: session.id)?.turns.first)
            #expect(turn.attachments.map(\.id) == session.turns[0].attachments.map(\.id))
            #expect(turn.attachments[0].loadImageData() == smallImage)
            #expect(turn.attachments[1].loadImageData() == bigImage)
            #expect(turn.attachments[2].loadDocumentContent() == "Day 1: Alfama.")
            #expect(turn.attachments[2].filename == "notes.txt")
        }
    }

    @Test
    func attachmentAddedToAStoredTurnSurvivesReload() async throws {
        try await withStore { store, _ in
            let answer = ChatTurnData(role: .assistant, content: "Here it is")
            var session = ChatSessionData(
                id: UUID(), title: "Late file", turns: [ChatTurnData(role: .user, content: "Write notes"), answer])
            try store.saveSession(session)

            let document = Attachment.document(filename: "notes.txt", content: "Day 1: Alfama.", fileSize: 14)
            session.turns[1].attachments = [document]
            try store.saveSession(session)

            store.invalidateCaches()
            let loaded = try #require(store.loadSession(id: session.id))
            #expect(loaded.turns.map(\.id) == session.turns.map(\.id))
            #expect(loaded.turns[1].attachments.map(\.id) == [document.id])
            #expect(loaded.turns[1].attachments.first?.loadDocumentContent() == "Day 1: Alfama.")
        }
    }

    @Test
    func localStateStaysOnThisDevice() async throws {
        try await withStore { store, core in
            var session = toolSession()
            session.folderBookmark = Data([1, 2, 3])
            try store.saveSession(session)
            let scope = try #require(store.scope(forSession: session.id))
            let conversation = try #require(try core.conversation(scope: scope))
            let object = try #require(SyncConversationMapper.parseObject(conversation.appData("ai.osaurus.session/1")))
            #expect(object["folderBookmark"] == nil)
            #expect(object["folderPath"] as? String == "~/Projects/trip")

            store.invalidateCaches()
            #expect(store.loadSession(id: session.id)?.folderBookmark == Data([1, 2, 3]))
        }
    }
}
