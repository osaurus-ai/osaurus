//
//  ChatSessionDataWorkspaceCodingTests.swift
//  osaurusTests
//
//  Pins the workspace identity a persisted chat session can carry:
//  `WorkspaceSessionContext` round-trips through `ChatSessionData`'s
//  Codable, legacy rows without the field still decode, the v16 SQLite
//  columns (`workspace_context` JSON + `remote_agent_address`) are written
//  and read back, and `ChatSessionsManager` keys teammate-agent chats by
//  address instead of by the local agent that hosted the tab.
//

import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ChatSessionDataWorkspaceCodingTests {

    private static let address = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01"

    private func makeSession(
        workspace: WorkspaceSessionContext?,
        agentId: UUID? = nil,
        source: SessionSource = .chat
    ) -> ChatSessionData {
        ChatSessionData(
            id: UUID(),
            title: "Team chat",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            selectedModel: "m",
            turns: [
                ChatTurnData(role: .user, content: "hello"),
                ChatTurnData(role: .assistant, content: "hi"),
            ],
            agentId: agentId,
            source: source,
            sourcePluginId: nil,
            externalSessionKey: nil,
            dispatchTaskId: nil,
            workspace: workspace
        )
    }

    // MARK: - WorkspaceSessionContext

    @Test func context_lowercasesAddressesAndDerivesCallerLabel() {
        let teammateSide = WorkspaceSessionContext(workspaceId: "ws-1", agentAddress: Self.address)
        #expect(teammateSide.agentAddress == Self.address.lowercased())
        #expect(teammateSide.isServedForTeammate == false)
        #expect(teammateSide.callerLabel == nil)

        let named = WorkspaceSessionContext(
            workspaceId: "ws-1",
            agentAddress: Self.address,
            callerWallet: "0xCALLER00000000000000000000000000000000AA",
            callerName: "Alice"
        )
        #expect(named.isServedForTeammate)
        #expect(named.callerWallet == "0xcaller00000000000000000000000000000000aa")
        #expect(named.callerLabel == "Alice")

        let unnamed = WorkspaceSessionContext(
            workspaceId: "ws-1",
            agentAddress: Self.address,
            callerWallet: "0xCALLER00000000000000000000000000000000AA"
        )
        #expect(unnamed.callerLabel == "0xcall…00aa")
    }

    @Test func context_jsonColumnCodecRoundTrips() throws {
        let context = WorkspaceSessionContext(
            workspaceId: "ws-9",
            agentAddress: Self.address,
            callerWallet: "0xcaller",
            callerName: "Bob"
        )
        let json = try #require(context.encodedJSON())
        #expect(json.contains("\"workspaceId\":\"ws-9\""))
        #expect(WorkspaceSessionContext.decode(json: json) == context)
        #expect(WorkspaceSessionContext.decode(json: nil) == nil)
        #expect(WorkspaceSessionContext.decode(json: "") == nil)
        #expect(WorkspaceSessionContext.decode(json: "not json") == nil)
    }

    // MARK: - ChatSessionData Codable

    @Test func sessionData_roundTripsWorkspaceContext() throws {
        let context = WorkspaceSessionContext(workspaceId: "ws-1", agentAddress: Self.address)
        let original = makeSession(workspace: context)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatSessionData.self, from: data)

        #expect(decoded.workspace == context)
        #expect(decoded.remoteAgentAddress == Self.address.lowercased())
        #expect(decoded.isWorkspaceAgentChat)
    }

    @Test func sessionData_legacyPayloadWithoutWorkspaceDecodesAsLocal() throws {
        // A row written before the field existed: no `workspace` key at all.
        let legacy = makeSession(workspace: nil)
        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        payload.removeValue(forKey: "workspace")
        let data = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try JSONDecoder().decode(ChatSessionData.self, from: data)
        #expect(decoded.workspace == nil)
        #expect(decoded.remoteAgentAddress == nil)
        #expect(decoded.isWorkspaceAgentChat == false)
    }

    @Test func sessionData_hostServedRowIsNotATeammateAgentChat() {
        // Host side: served FOR a teammate → stays under the local shared
        // agent (not filtered out of its list), even though it has an address.
        let served = makeSession(
            workspace: WorkspaceSessionContext(
                workspaceId: "ws-1",
                agentAddress: Self.address,
                callerWallet: "0xcaller",
                callerName: "Alice"
            ),
            agentId: UUID(),
            source: .workspace
        )
        #expect(served.isWorkspaceAgentChat == false)
        #expect(served.remoteAgentAddress == Self.address.lowercased())
        #expect(served.source.originLabel(workspace: served.workspace) == "for Alice · Workspace")
    }

    // MARK: - SQLite v16 columns

    @Test func database_persistsWorkspaceContextAndRemoteAddressColumn() throws {
        let db = ChatHistoryDatabase()
        try db.openInMemory()
        defer { db.close() }

        let context = WorkspaceSessionContext(workspaceId: "ws-1", agentAddress: Self.address)
        let session = makeSession(workspace: context)
        try db.saveSession(session)

        let loaded = try #require(db.loadSession(id: session.id))
        #expect(loaded.workspace == context)

        // The denormalized address column is populated for indexed lookups.
        var storedAddress: String?
        var storedJSON: String?
        try db.executeReadInTest(
            "SELECT remote_agent_address, workspace_context FROM sessions WHERE id = ?1"
        ) { stmt in
            sqlite3_bind_text(
                stmt,
                1,
                (session.id.uuidString as NSString).utf8String,
                -1,
                unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            )
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { storedAddress = String(cString: c) }
                if let c = sqlite3_column_text(stmt, 1) { storedJSON = String(cString: c) }
            }
        }
        #expect(storedAddress == Self.address.lowercased())
        #expect(WorkspaceSessionContext.decode(json: storedJSON) == context)

        // A plain local session leaves both columns NULL.
        let local = makeSession(workspace: nil)
        try db.saveSession(local)
        var localAddressIsNull = false
        try db.executeReadInTest("SELECT remote_agent_address FROM sessions WHERE id = ?1") { stmt in
            sqlite3_bind_text(
                stmt,
                1,
                (local.id.uuidString as NSString).utf8String,
                -1,
                unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            )
            if sqlite3_step(stmt) == SQLITE_ROW {
                localAddressIsNull = sqlite3_column_type(stmt, 0) == SQLITE_NULL
            }
        }
        #expect(localAddressIsNull)
        #expect(db.loadSession(id: local.id)?.workspace == nil)
    }

    @Test func database_schemaVersionIsV16WithRemoteAgentIndex() throws {
        let db = ChatHistoryDatabase()
        try db.openInMemory()
        defer { db.close() }

        #expect(ChatHistoryDatabase.latestSchemaVersion == 16)
        var indexNames: [String] = []
        try db.executeReadInTest("PRAGMA index_list('sessions')") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) { indexNames.append(String(cString: c)) }
            }
        }
        #expect(indexNames.contains("idx_sessions_remote_agent"))
    }

    // MARK: - ChatSessionsManager filtering

    @Test @MainActor func sessionsManager_keysTeammateChatsByAddressNotLocalAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = ChatSessionsManager.shared
            let localAgent = UUID()
            let context = WorkspaceSessionContext(workspaceId: "ws-1", agentAddress: Self.address)

            // Teammate-agent chat hosted by the Default tab.
            let teamChat = makeSession(workspace: context, agentId: Agent.defaultId)
            // Ordinary local chat with a custom agent.
            let localChat = makeSession(workspace: nil, agentId: localAgent)
            // Host-side row served for a teammate under the local shared agent.
            let served = makeSession(
                workspace: WorkspaceSessionContext(
                    workspaceId: "ws-1",
                    agentAddress: Self.address,
                    callerWallet: "0xcaller",
                    callerName: "Alice"
                ),
                agentId: localAgent,
                source: .workspace
            )
            defer {
                manager.delete(id: teamChat.id)
                manager.delete(id: localChat.id)
                manager.delete(id: served.id)
            }

            manager.save(teamChat)
            manager.save(localChat)
            manager.save(served)

            let allLocal = manager.sessions(for: nil).map(\.id)
            #expect(!allLocal.contains(teamChat.id), "team-agent chats must not appear in the Default 'all' list")
            #expect(allLocal.contains(localChat.id))
            #expect(allLocal.contains(served.id), "host-served rows stay under the shared agent")

            let forLocalAgent = manager.sessions(for: localAgent).map(\.id)
            #expect(forLocalAgent.contains(localChat.id))
            #expect(forLocalAgent.contains(served.id))
            #expect(!forLocalAgent.contains(teamChat.id))

            let byAddress = manager.sessions(forRemoteAgentAddress: Self.address.uppercased()).map(\.id)
            #expect(byAddress == [teamChat.id], "address lookup is case-insensitive and excludes host-served rows")
        }
    }
}

// MARK: - Test hook

extension ChatHistoryDatabase {
    /// Prepare `sql` on this instance's connection and let the caller bind +
    /// step (same shape as `IncrementalSaveSessionTests`' helper).
    fileprivate func executeReadInTest(_ sql: String, _ body: (OpaquePointer) -> Void) throws {
        #if DEBUG
            try queueRunForTest { connection in
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                    throw ChatHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
                }
                defer { sqlite3_finalize(s) }
                body(s)
            }
        #endif
    }
}
