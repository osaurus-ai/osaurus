//
//  SyncContextUsage.swift
//  osaurus
//
//  How full a chat's context is, for the user's other devices: conversation
//  app data `ai.osaurus.context-usage/1`, the `/sessions/{id}/context` body.
//  This Mac writes it after each run it hosts, and when an iPhone asks
//  (`contextUsage` on the manage conversation).
//

import Foundation
import OsaurusSync
import os

enum SyncContextUsage {
    static let namespace = "ai.osaurus.context-usage/1"

    private static let log = Logger(subsystem: "ai.osaurus", category: "sync.context")

    struct Record: Encodable {
        var v = 1
        var usage: PhoneContextUsage.Response
        /// The agent and model it was priced for.
        var agentId: String
        var model: String?
        var updatedMs: Int64
    }

    static func write(_ usage: PhoneContextUsage.Response, scope: String, agentId: UUID, model: String?) {
        let record = Record(
            usage: usage, agentId: agentId.uuidString.lowercased(), model: model, updatedMs: SyncHostedRunContract.nowMs())
        guard let bytes = try? JSONEncoder.osaurusCanonical().encode(record), bytes.count <= SyncConversationMapper.maxAppDataBytes
        else { return }
        Task.detached(priority: .utility) {
            do {
                try SyncConversationStore.shared.performWrite { core in
                    try core.setConversationAppData(scope: scope, namespace: namespace, bytes: bytes)
                    core.syncNow()
                }
            } catch {
                log.error("context usage write failed: \(error.syncLogDetail, privacy: .public)")
            }
        }
    }

    /// Prices a chat after a run this Mac hosted and writes it on the chat.
    @MainActor
    static func refresh(scope: String, sessionId: UUID) async {
        guard let session = SyncConversationStore.shared.loadSession(id: sessionId) else { return }
        let agentId = session.agentId ?? Agent.defaultId
        let usage = await PhoneContextUsage.compute(sessionId: sessionId, agentId: agentId, model: session.selectedModel)
        write(usage, scope: scope, agentId: agentId, model: session.selectedModel)
    }
}
