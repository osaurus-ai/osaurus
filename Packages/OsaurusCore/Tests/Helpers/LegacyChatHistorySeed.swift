//
//  LegacyChatHistorySeed.swift
//  OsaurusCoreTests
//
//  Writes fixtures into the pre-sync chat-history database with raw SQL, the
//  way older builds stored them. The app no longer writes this database, so
//  importer, migration and file-history tests seed it here.
//

import Foundation
import OsaurusSQLCipher

@testable import OsaurusCore

extension ChatHistoryDatabase {
    /// Replaces `session`'s row and all of its turns.
    func seedForTesting(_ session: ChatSessionData) throws {
        try queueRunForTest { db in
            try Self.seedStep(db, "BEGIN TRANSACTION")
            do {
                try Self.seedStep(
                    db,
                    """
                    INSERT OR REPLACE INTO sessions
                        (id, title, created_at, updated_at, selected_model, agent_id,
                         source, source_plugin_id, external_session_key, dispatch_task_id,
                         archived, capabilities, folder_bookmark, folder_path, pinned,
                         project_id, workspace_context, remote_agent_address, parked_workflow_runs,
                         automation_kind, turn_count, conversation_summary)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15,
                            ?16, ?17, ?18, ?19, ?20, ?21, ?22)
                    """
                ) { stmt in
                    Self.bindText(stmt, index: 1, value: session.id.uuidString)
                    Self.bindText(stmt, index: 2, value: session.title)
                    sqlite3_bind_double(stmt, 3, session.createdAt.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 4, session.updatedAt.timeIntervalSince1970)
                    Self.bindText(stmt, index: 5, value: session.selectedModel)
                    Self.bindText(stmt, index: 6, value: session.agentId?.uuidString)
                    Self.bindText(stmt, index: 7, value: session.source.rawValue)
                    Self.bindText(stmt, index: 8, value: session.sourcePluginId)
                    Self.bindText(stmt, index: 9, value: session.externalSessionKey)
                    Self.bindText(stmt, index: 10, value: session.dispatchTaskId?.uuidString)
                    sqlite3_bind_int(stmt, 11, session.archived ? 1 : 0)
                    Self.bindText(stmt, index: 12, value: SessionCapability.encode(session.capabilities))
                    Self.bindBlob(stmt, index: 13, value: session.folderBookmark)
                    Self.bindText(stmt, index: 14, value: session.folderPath)
                    sqlite3_bind_int(stmt, 15, session.pinned ? 1 : 0)
                    Self.bindText(stmt, index: 16, value: session.projectId?.uuidString)
                    Self.bindText(stmt, index: 17, value: session.workspace?.encodedJSON())
                    Self.bindText(stmt, index: 18, value: session.workspace?.agentAddress)
                    Self.bindText(stmt, index: 19, value: ParkedWorkflowCall.encodedJSON(session.parkedWorkflowRuns))
                    Self.bindText(stmt, index: 20, value: session.automationKind?.rawValue)
                    sqlite3_bind_int(stmt, 21, Int32(session.turns.count))
                    Self.bindText(
                        stmt, index: 22,
                        value: session.conversationSummary
                            .flatMap { try? JSONEncoder().encode($0) }
                            .flatMap { String(data: $0, encoding: .utf8) })
                }
                try Self.seedStep(db, "DELETE FROM turns WHERE session_id = ?1") { stmt in
                    Self.bindText(stmt, index: 1, value: session.id.uuidString)
                }
                for (seq, turn) in session.turns.enumerated() {
                    try Self.seedTurn(db, sessionId: session.id, seq: seq, turn: turn)
                }
                try Self.seedStep(db, "COMMIT")
            } catch {
                try? Self.seedStep(db, "ROLLBACK")
                throw error
            }
        }
    }

    /// One legacy net sandbox-workspace change row.
    func seedSandboxChangeForTesting(_ change: SandboxWorkspaceChange) throws {
        try queueRunForTest { db in
            try Self.seedStep(
                db,
                """
                INSERT OR REPLACE INTO sandbox_changes
                    (id, session_id, agent_name, root, relative_path, entry_type,
                     kind, state, baseline_signature, current_signature, source_tool,
                     first_changed_at, last_changed_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                """
            ) { stmt in
                Self.bindText(stmt, index: 1, value: change.id.uuidString)
                Self.bindText(stmt, index: 2, value: change.sessionId)
                Self.bindText(stmt, index: 3, value: change.agentName)
                Self.bindText(stmt, index: 4, value: change.root.rawValue)
                Self.bindText(stmt, index: 5, value: change.relativePath)
                Self.bindText(stmt, index: 6, value: change.entryType.rawValue)
                Self.bindText(stmt, index: 7, value: change.kind.rawValue)
                Self.bindText(stmt, index: 8, value: change.state.rawValue)
                Self.bindText(stmt, index: 9, value: change.baselineSignature)
                Self.bindText(stmt, index: 10, value: change.currentSignature)
                Self.bindText(stmt, index: 11, value: change.sourceTool)
                sqlite3_bind_double(stmt, 12, change.firstChangedAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 13, change.lastChangedAt.timeIntervalSince1970)
            }
        }
    }

    private static func seedTurn(_ db: OpaquePointer, sessionId: UUID, seq: Int, turn: ChatTurnData) throws {
        try seedStep(
            db,
            """
            INSERT INTO turns
                (id, session_id, seq, role, content, attachments, shared_artifacts,
                 tool_calls, tool_call_id, tool_results, thinking,
                 created_at, completed_at, generation_token_count, time_to_first_token,
                 tool_call_durations, thinking_duration, router_billing, terminal_stop_reason,
                 model_context_excluded, tool_call_logs, injected_context_prefix,
                 generation_tokens_per_second, model_load_seconds, last_output_at, requested_at,
                 reasoning_item_id, reasoning_encrypted, responses_output_items, anthropic_thinking_blocks,
                 input_token_count, cached_input_token_count, turn_generation_controls)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17,
                    ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30, ?31, ?32, ?33)
            """
        ) { stmt in
            bindText(stmt, index: 1, value: turn.id.uuidString)
            bindText(stmt, index: 2, value: sessionId.uuidString)
            sqlite3_bind_int(stmt, 3, Int32(seq))
            bindText(stmt, index: 4, value: turn.role.rawValue)
            bindText(stmt, index: 5, value: turn.content)
            bindText(stmt, index: 6, value: json(turn.attachments))
            bindText(stmt, index: 7, value: turn.sharedArtifacts.isEmpty ? nil : json(turn.sharedArtifacts))
            bindText(stmt, index: 8, value: turn.toolCalls.flatMap(json))
            bindText(stmt, index: 9, value: turn.toolCallId)
            bindText(stmt, index: 10, value: json(turn.toolResults))
            bindText(stmt, index: 11, value: turn.thinking)
            bindDouble(stmt, 12, turn.createdAt?.timeIntervalSince1970)
            bindDouble(stmt, 13, turn.completedAt?.timeIntervalSince1970)
            if let tokens = turn.generationTokenCount {
                sqlite3_bind_int64(stmt, 14, Int64(tokens))
            } else {
                sqlite3_bind_null(stmt, 14)
            }
            bindDouble(stmt, 15, turn.timeToFirstToken)
            bindText(stmt, index: 16, value: turn.toolCallDurations.isEmpty ? nil : json(turn.toolCallDurations))
            bindDouble(stmt, 17, turn.thinkingDuration)
            bindText(stmt, index: 18, value: turn.routerBilling.flatMap(json))
            bindText(stmt, index: 19, value: turn.terminalStopReason)
            sqlite3_bind_int(stmt, 20, turn.modelContextExcluded ? 1 : 0)
            bindText(stmt, index: 21, value: turn.toolCallLogs.isEmpty ? nil : json(turn.toolCallLogs))
            bindText(stmt, index: 22, value: turn.injectedContextPrefix)
            bindDouble(stmt, 23, turn.generationTokensPerSecond)
            bindDouble(stmt, 24, turn.modelLoadSeconds)
            bindDouble(stmt, 25, turn.lastOutputAt?.timeIntervalSince1970)
            bindDouble(stmt, 26, turn.requestedAt?.timeIntervalSince1970)
            bindText(stmt, index: 27, value: turn.reasoningItemId)
            bindText(stmt, index: 28, value: turn.reasoningEncrypted)
            bindText(stmt, index: 29, value: turn.responsesOutputItems.isEmpty ? nil : json(turn.responsesOutputItems))
            bindText(
                stmt, index: 30, value: turn.anthropicThinkingBlocks.isEmpty ? nil : json(turn.anthropicThinkingBlocks))
            bindInt(stmt, 31, turn.inputTokenCount)
            bindInt(stmt, 32, turn.cachedInputTokenCount)
            bindText(stmt, index: 33, value: turn.generationControls.flatMap(json))
        }
    }

    private static func seedStep(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void = { _ in }) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ChatHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ChatHistoryDatabaseError.failedToExecute(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func bindDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private static func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int64(stmt, index, Int64(value)) } else { sqlite3_bind_null(stmt, index) }
    }

    private static func json<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
