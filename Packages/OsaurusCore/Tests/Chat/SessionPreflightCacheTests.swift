//
//  SessionPreflightCacheTests.swift
//  osaurusTests
//
//  Validates the `SessionToolState` contract used by ChatWindowState to
//  memoize per-session `capabilities_load` additions across composes.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SessionPreflightCacheTests {

    @Test
    func sessionToolState_loadedNamesAreAdditive() {
        var state = SessionToolState()
        #expect(state.loadedToolNames.isEmpty)

        state.loadedToolNames.insert("pdf_extract")
        state.loadedToolNames.insert("pdf_render")
        state.loadedToolNames.insert("pdf_extract")  // dedup

        #expect(state.loadedToolNames == ["pdf_extract", "pdf_render"])
    }

    @Test
    func sessionToolStateStore_appendLoadedToolsPersistsIdempotently() async {
        let sessionId = "same-turn-load-\(UUID().uuidString)"
        await SessionToolStateStore.shared.appendLoadedTools(
            sessionId,
            names: ["miyo_search", "miyo_search"],
            fallbackAlwaysLoadedNames: ["capabilities_load"]
        )
        await SessionToolStateStore.shared.appendLoadedTools(
            sessionId,
            names: ["calendar_lookup"],
            fallbackAlwaysLoadedNames: nil
        )

        let state = await SessionToolStateStore.shared.get(sessionId)
        #expect(state?.loadedToolNames == ["miyo_search", "calendar_lookup"])
        #expect(state?.initialAlwaysLoadedNames == ["capabilities_load"])

        await SessionToolStateStore.shared.invalidate(sessionId)
    }

    @Test
    func resolveTools_includesAdditionalToolNames() async {
        await withSessionPreflightAgent { agentId in

            // The agent's `capabilities_load` union must inflate the
            // resolved schema even when no folder/sandbox tools are present.
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                additionalToolNames: ["search_memory"]
            )
            let names = tools.map { $0.function.name }
            #expect(names.contains("search_memory"))
        }
    }

    @Test
    func composeChatContext_keepsUnloadedToolsOutOfSchema() async {
        await withSessionPreflightAgent { agentId in

            // search_memory must be registered in this environment for the
            // assertion to be meaningful; otherwise skip.
            let memorySpec = ToolRegistry.shared.specs(forTools: ["search_memory"]).first
            guard memorySpec != nil else { return }

            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                query: "this query mentions memory but nothing is loaded yet"
            )

            // Design C: the tools array is the fixed hot set plus
            // `capabilities_load` picks. A tool the agent has NOT loaded
            // must stay out of the schema — capability breadth lives in the
            // static manifest instead.
            let resolvedNames = ctx.tools.map { $0.function.name }
            #expect(!resolvedNames.contains("search_memory"))
        }
    }

    @Test
    func composeChatContext_returnsMemorySectionSeparately() async {
        await withSessionPreflightAgent { agentId in

            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none
            )

            // Even when memory has no content for a brand-new agent, the
            // rendered system prompt must NOT contain a [Memory] block — the
            // helper is the only writer of that marker, and it goes onto the
            // user message instead.
            #expect(ctx.prompt.contains("[Memory]") == false)
        }
    }

    private func withSessionPreflightAgent(
        _ body: @MainActor @Sendable (UUID) async -> Void
    ) async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let agent = Agent(
                name: "SessionPreflightCacheTestAgent-\(UUID().uuidString.prefix(6))",
                agentAddress: "test-session-preflight-\(UUID().uuidString)"
            )
            manager.add(agent)
            await body(agent.id)
            _ = await manager.delete(id: agent.id)
        }
    }
}
