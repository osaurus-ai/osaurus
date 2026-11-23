//
//  RawInferenceHistoryTests.swift
//  osaurusTests
//
//  Raw inference calls (HTTP `/chat/completions` from API clients, model
//  sharing peers and guests; plugin `complete` / `complete_stream`) belong in
//  Insights, not chat history. Rows earlier versions wrote for them listed
//  under the Orchestrator; they now stay out of every chat list, while
//  dispatched API and plugin runs remain ordinary chats.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct RawInferenceHistoryTests {

    @Test(arguments: [
        (SessionSource.http, false, true),
        (.plugin, false, true),
        (.http, true, false),
        (.plugin, true, false),
        (.chat, false, false),
        (.workspace, false, false),
        (.schedule, false, false),
    ] as [(SessionSource, Bool, Bool)])
    func rawInferenceRecordIsUndispatchedHTTPOrPlugin(source: SessionSource, dispatched: Bool, expected: Bool) {
        let session = ChatSessionData(source: source, dispatchTaskId: dispatched ? UUID() : nil)
        #expect(session.isRawInferenceRecord == expected)
    }

    @MainActor
    @Test func sessionListsOmitLegacyRawInferenceRowsAndKeepDispatchedRuns() async throws {
        try await ChatHistoryTestStorage.run {
            let db = ConversationStores.current
            try db.open()
            let turns = [ChatTurnData(role: .user, content: "### Task: title"), ChatTurnData(role: .assistant, content: "ok")]
            let legacyAPI = ChatSessionData(title: "Legacy API", turns: turns, source: .http)
            let legacyPlugin = ChatSessionData(
                title: "Legacy plugin", turns: turns, source: .plugin, sourcePluginId: "legacy.plugin")
            let dispatchedId = UUID()
            let dispatchedAPI = ChatSessionData(
                id: dispatchedId, title: "Dispatched API", turns: turns, source: .http, dispatchTaskId: dispatchedId)
            let chat = ChatSessionData(title: "Typed chat", turns: turns)
            for session in [legacyAPI, legacyPlugin, dispatchedAPI, chat] { try db.saveSession(session) }

            let listed = Set(ChatSessionStore.loadAll().map(\.id))
            #expect(!listed.contains(legacyAPI.id))
            #expect(!listed.contains(legacyPlugin.id))
            #expect(listed.contains(dispatchedAPI.id))
            #expect(listed.contains(chat.id))
            let listedAsync = Set(await ChatSessionStore.loadAllAsync().map(\.id))
            #expect(listedAsync == listed)

            ChatSessionsManager.shared.refresh()
            let orchestratorRows = ChatSessionsManager.shared.sessions(for: Agent.defaultId).map(\.id)
            #expect(!orchestratorRows.contains(legacyAPI.id))
            #expect(!orchestratorRows.contains(legacyPlugin.id))

            // Still on disk: hidden from lists, not deleted.
            #expect(db.loadSession(id: legacyAPI.id) != nil)
        }
    }

    @MainActor
    @Test(arguments: [true, false])
    func chatCompletionsNeverWritesChatHistory(stream: Bool) async throws {
        try await ChatHistoryTestStorage.run {
            let db = ConversationStores.current
            try db.open()
            let before = db.loadAllMetadata().count
            let model = "raw-inference-\(UUID().uuidString)"
            let server = try await startChatStreamingTestServer(
                with: MockChatEngine(deltas: ["hello"], completeText: "hello", model: model))
            defer { Task { await server.shutdown() } }

            var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("raw-inference-session", forHTTPHeaderField: "X-Session-Id")
            request.authenticate()
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "stream": stream,
                "messages": [["role": "user", "content": "Hi, I want to pay my bill"]],
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self).contains("hello"))

            // The old writer persisted on a detached task after the response.
            try await Task.sleep(for: .milliseconds(500))
            #expect(db.loadAllMetadata().count == before)
            #expect(!db.loadAllMetadata().contains { $0.source == .http })
        }
    }
}
