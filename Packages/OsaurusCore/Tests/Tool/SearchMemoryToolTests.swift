//
//  SearchMemoryToolTests.swift
//  osaurusTests
//
//  Argument-validation tests for the unified `search_memory(scope, query)`
//  tool. The actual backend lookups are exercised by `MemorySearchService`
//  tests; here we just pin down the contract the model sees:
//
//    - `scope` is required
//    - per-scope required arguments are enforced (query / entity_name+relation)
//    - unknown scopes are rejected with a clear message
//    - the tool is registered as a single global built-in so the four legacy
//      memory-search tools are gone from the schema
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
        #expect(result.contains("'scope' is required"))
    }

    @Test
    func rejectsUnknownScope() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(
            argumentsJSON: #"{"scope":"galaxy-brain","query":"anything"}"#
        )
        #expect(result.contains("unknown scope"))
    }

    @Test
    func workingScope_requiresQuery() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"working"}"#)
        #expect(result.contains("'query' is required for scope=working"))
    }

    @Test
    func conversationsScope_requiresQuery() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"conversations"}"#)
        #expect(result.contains("'query' is required for scope=conversations"))
    }

    @Test
    func summariesScope_requiresQuery() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"summaries"}"#)
        #expect(result.contains("'query' is required for scope=summaries"))
    }

    @Test
    func graphScope_requiresEntityOrRelation() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"graph"}"#)
        #expect(result.contains("requires at least one of 'entity_name' or 'relation'"))
    }

    @Test
    func allScope_requiresQuery() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"all"}"#)
        #expect(result.contains("'query' is required for scope=all"))
    }

    // MARK: - Registry shape

    @Test @MainActor
    func legacyMemoryToolsAreNotRegistered() {
        let toolNames = Set(ToolRegistry.shared.listTools().map { $0.name })
        // The unified tool replaces the four legacy ones — they should be
        // absent from the schema entirely so the model isn't tempted to
        // guess at names that no longer exist.
        #expect(toolNames.contains("search_memory"))
        #expect(!toolNames.contains("search_working_memory"))
        #expect(!toolNames.contains("search_conversations"))
        #expect(!toolNames.contains("search_summaries"))
        #expect(!toolNames.contains("search_graph"))
    }
}
