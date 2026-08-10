//
//  KnowledgeToolsTests.swift
//  osaurusTests
//
//  Argument-validation and scoping-boundary tests for the knowledge
//  retrieval tools. All three tools resolve the calling agent's grants
//  at execution time; with no agent context they must refuse, never
//  fall back to "all collections".
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct KnowledgeToolsTests {

    // MARK: - search_knowledge

    @Test
    func searchRejectsMissingQuery() async throws {
        let tool = SearchKnowledgeTool()
        let result = try await tool.execute(argumentsJSON: #"{}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("query"))
    }

    @Test
    func searchRejectsWhitespaceQuery() async throws {
        let tool = SearchKnowledgeTool()
        let result = try await tool.execute(argumentsJSON: #"{"query":"   "}"#)
        #expect(ToolEnvelope.isError(result))
    }

    @Test
    func searchWithoutAgentContextIsRejected() async throws {
        let tool = SearchKnowledgeTool()
        let result = try await tool.execute(argumentsJSON: #"{"query":"wordpress"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("agent"))
    }

    // MARK: - read_knowledge

    @Test
    func readRejectsPathTraversal() async throws {
        let tool = ReadKnowledgeTool()
        let result = try await tool.execute(argumentsJSON: #"{"path":"../outside/secret.md"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("path"))
    }

    @Test
    func readRejectsEmbeddedTraversal() async throws {
        let tool = ReadKnowledgeTool()
        let result = try await tool.execute(argumentsJSON: #"{"path":"docs/../../etc/passwd"}"#)
        #expect(ToolEnvelope.isError(result))
    }

    @Test
    func readRejectsAbsolutePath() async throws {
        let tool = ReadKnowledgeTool()
        let result = try await tool.execute(argumentsJSON: #"{"path":"/etc/hosts"}"#)
        #expect(ToolEnvelope.isError(result))
    }

    @Test
    func readRejectsTildePath() async throws {
        let tool = ReadKnowledgeTool()
        let result = try await tool.execute(argumentsJSON: #"{"path":"~/notes.md"}"#)
        #expect(ToolEnvelope.isError(result))
    }

    @Test
    func readRejectsMissingPath() async throws {
        let tool = ReadKnowledgeTool()
        let result = try await tool.execute(argumentsJSON: #"{}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("path"))
    }

    @Test
    func readWithoutAgentContextIsRejected() async throws {
        let tool = ReadKnowledgeTool()
        let result = try await tool.execute(argumentsJSON: #"{"path":"guides/setup.md"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("agent"))
    }

    // MARK: - list_knowledge

    @Test
    func listWithoutAgentContextIsRejected() async throws {
        let tool = ListKnowledgeTool()
        let result = try await tool.execute(argumentsJSON: #"{}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("agent"))
    }

    // MARK: - Tag matching helper

    @Test
    func tagFilterMatchesAnyCaseInsensitively() {
        #expect(KnowledgeToolScope.matchesTags("wordpress,php", filter: ["PHP"]))
        #expect(KnowledgeToolScope.matchesTags("wordpress,php", filter: ["ops", "wordpress"]))
        #expect(!KnowledgeToolScope.matchesTags("wordpress,php", filter: ["ops"]))
        // No filter → everything matches.
        #expect(KnowledgeToolScope.matchesTags("", filter: []))
        // Exact tag match, not substring.
        #expect(!KnowledgeToolScope.matchesTags("wordpress", filter: ["word"]))
    }
}
