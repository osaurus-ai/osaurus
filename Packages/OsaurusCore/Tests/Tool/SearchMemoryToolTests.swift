//
//  SearchMemoryToolTests.swift
//  osaurusTests
//
//  Argument-validation tests for the v2 unified `search_memory(scope, query)`
//  tool. v2 collapses the v1 five-scope tool to three: pinned, episodes,
//  transcript. The legacy `working`, `summaries`, `all`, and `graph`
//  scopes are no longer registered.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SearchMemoryToolTests {

    @Test
    func rejectsMissingScope() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"query":"anything"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("scope"))
    }

    @Test
    func rejectsUnknownScope() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(
            argumentsJSON: #"{"scope":"galaxy-brain","query":"anything"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("scope=galaxy-brain") || result.contains("Unknown scope"))
    }

    @Test
    func pinnedScope_requiresQuery() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"pinned"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("query"))
    }

    @Test
    func episodesScope_requiresQuery() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"episodes"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("query"))
    }

    @Test
    func transcriptScope_requiresQuery() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"transcript"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("query"))
    }

    @Test
    func crossScopeParams_rejected() async throws {
        let tool = SearchMemoryTool()
        // `days` is transcript-only. Passing it with scope=pinned should be
        // rejected with a structured invalid_args failure.
        let result = try await tool.execute(
            argumentsJSON: #"{"scope":"pinned","query":"x","days":7}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("days") && result.contains("transcript"))
    }

    // MARK: - Registry shape

    @Test @MainActor
    func legacyMemoryToolsAreNotRegistered() {
        let toolNames = Set(ToolRegistry.shared.listTools().map { $0.name })
        #expect(toolNames.contains("search_memory"))
        // Legacy scope-specific tool names from earlier versions stay gone.
        #expect(!toolNames.contains("search_working_memory"))
        #expect(!toolNames.contains("search_conversations"))
        #expect(!toolNames.contains("search_summaries"))
        #expect(!toolNames.contains("search_graph"))
    }
}
