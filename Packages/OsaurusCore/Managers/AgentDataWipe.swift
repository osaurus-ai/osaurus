//
//  AgentDataWipe.swift
//  osaurus
//
//  Erases what an agent has gathered (its chats, pinned facts, episodes)
//  while the agent itself stays. Shared by the agent page's Delete Data
//  dialog and the phone's `POST /agents/{id}/data/delete`.
//

import Foundation

enum AgentDataWipe {
    struct Selection: Equatable {
        var chats: Bool
        var pinnedFacts: Bool
        var episodes: Bool

        var isEmpty: Bool { !chats && !pinnedFacts && !episodes }
    }

    @MainActor
    static func perform(agentId: UUID, _ selection: Selection) async {
        guard !selection.isEmpty else { return }
        let agentScope = agentId.uuidString
        if selection.chats {
            await ChatSessionsManager.shared.deleteAll(for: agentId)
        }
        // Memory DB deletes run off the main actor: these calls dispatch-sync
        // onto the DB's serial queue and can otherwise stall the main thread.
        await Task.detached(priority: .userInitiated) {
            let db = MemoryDatabase.shared
            if !db.isOpen { try? db.open() }
            if selection.pinnedFacts { try? db.deletePinnedFacts(forAgent: agentScope) }
            if selection.episodes { try? db.deleteEpisodes(forAgent: agentScope) }
            if selection.chats { try? db.deleteConversationMemory(forAgent: agentScope) }
        }.value
        if selection.pinnedFacts && selection.episodes && selection.chats {
            // Full wipe: the on-disk vector index has nothing left to serve,
            // so remove it rather than leaving deleted content in the store.
            await MemorySearchService.shared.deleteAgentIndex(agentId: agentScope)
        } else if selection.pinnedFacts || selection.episodes {
            // Partial wipe: drop the in-memory instance; stale on-disk vectors
            // resolve to missing SQL rows and are filtered on read.
            await MemorySearchService.shared.evictAgent(agentId: agentScope)
        }
    }
}
