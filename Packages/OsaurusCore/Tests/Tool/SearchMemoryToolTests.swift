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
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("scope"))
    }

    @Test
    func rejectsUnknownScope() async throws {
        let tool = SearchMemoryTool()
        // The cross-scope pre-validator fires first for any arg whose
        // allowed-scope set doesn't include the requested scope. The
        // registered allow-list for `scope` does not include "galaxy-brain",
        // so we expect an invalid_args failure pointing at `scope`.
        let result = try await tool.execute(
            argumentsJSON: #"{"scope":"galaxy-brain","query":"anything"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("scope=galaxy-brain") || result.contains("Unknown scope"))
    }

    @Test
    func workingScope_requiresQuery() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"working"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("query") && result.contains("working"))
    }

    @Test
    func conversationsScope_requiresQuery() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"conversations"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("query") && result.contains("conversations"))
    }

    @Test
    func summariesScope_requiresQuery() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"summaries"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("query") && result.contains("summaries"))
    }

    @Test
    func graphScope_requiresEntityOrRelation() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"graph"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("entity_name") && result.contains("relation"))
    }

    @Test
    func allScope_requiresQuery() async throws {
        let tool = SearchMemoryTool()
        let result = try await tool.execute(argumentsJSON: #"{"scope":"all"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("query") && result.contains("all"))
    }

    @Test
    func crossScopeParams_rejected() async throws {
        let tool = SearchMemoryTool()
        // `as_of` is working-only. Passing it with scope=conversations used
        // to be silently ignored; now it's a structured invalid_args failure.
        let result = try await tool.execute(
            argumentsJSON: #"{"scope":"conversations","query":"x","as_of":"2024-01-01T00:00:00Z"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("as_of") && result.contains("working"))
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
