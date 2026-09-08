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

    // MARK: - Collection argument resolution (0.24.7 Discord report)

    private func collection(_ name: String) -> KnowledgeCollection {
        KnowledgeCollection(name: name, folderPath: "/tmp/\(name)")
    }

    /// The reported call: one granted collection, "Obsidian Vault"; the
    /// model passed `collection: "knowledge"`. Must resolve, not reject.
    @Test
    func genericAliasResolvesToAllGranted() {
        let vault = collection("Obsidian Vault")
        #expect(KnowledgeToolScope.match(collectionName: "knowledge", in: [vault]) == .all)
        #expect(KnowledgeToolScope.match(collectionName: "Knowledge", in: [vault]) == .all)
        #expect(KnowledgeToolScope.match(collectionName: "default", in: [vault]) == .all)
        #expect(KnowledgeToolScope.match(collectionName: "knowledge_base", in: [vault]) == .all)
        // Two grants: the alias still means "everything granted", never a
        // guess between them.
        let ops = collection("Runbooks")
        #expect(KnowledgeToolScope.match(collectionName: "knowledge", in: [vault, ops]) == .all)
    }

    @Test
    func exactNameWinsOverAlias() {
        // A collection literally named "Knowledge" is addressed by name.
        let named = collection("Knowledge")
        let other = collection("Runbooks")
        #expect(KnowledgeToolScope.match(collectionName: "knowledge", in: [named, other]) == .one(named))
        #expect(KnowledgeToolScope.match(collectionName: "RUNBOOKS", in: [named, other]) == .one(other))

        // The broad aliases (`docs`, `project`, `vault`, `library`) are
        // plausible real collection names. Exact name is rule 1 and the alias
        // rule 2, so a collection literally called "Docs" or "Project" is
        // addressed, never widened to "all granted". Pinned here so a future
        // reordering cannot silently change the precedence.
        for name in ["Docs", "Project", "Vault", "Library"] {
            let real = collection(name)
            let sibling = collection("Runbooks")
            #expect(
                KnowledgeToolScope.match(collectionName: name.lowercased(), in: [real, sibling]) == .one(real),
                "'\(name)' is a granted collection: exact name must beat the generic alias")
            #expect(KnowledgeToolScope.match(collectionName: name, in: [sibling]) == .all,
                "'\(name)' with no such collection granted is still the generic alias")
        }
    }

    @Test
    func punctuationInsensitiveNameResolves() {
        let vault = collection("Obsidian Vault")
        let ops = collection("Runbooks")
        #expect(KnowledgeToolScope.match(collectionName: "obsidian_vault", in: [vault, ops]) == .one(vault))
        #expect(KnowledgeToolScope.match(collectionName: "ObsidianVault", in: [vault, ops]) == .one(vault))
        #expect(KnowledgeToolScope.match(collectionName: "obsidian-vault", in: [vault, ops]) == .one(vault))
    }

    @Test
    func unambiguousPartialNameResolves() {
        let vault = collection("Obsidian Vault")
        let ops = collection("Runbooks")
        #expect(KnowledgeToolScope.match(collectionName: "obsidian", in: [vault, ops]) == .one(vault))
        #expect(KnowledgeToolScope.match(collectionName: "my runbooks", in: [vault, ops]) == .one(ops))
    }

    @Test
    func singleGrantAcceptsAnyName() {
        let vault = collection("Obsidian Vault")
        #expect(KnowledgeToolScope.match(collectionName: "notes", in: [vault]) == .one(vault))
    }

    @Test
    func ambiguousNameWithSeveralGrantsStillFails() {
        let a = collection("Design Docs")
        let b = collection("Ops Docs")
        // "docs" is a generic alias → all; a non-alias substring shared by
        // both is ambiguous → none (the envelope lists the names).
        #expect(KnowledgeToolScope.match(collectionName: "docs", in: [a, b]) == .all)
        #expect(KnowledgeToolScope.match(collectionName: "Shared Docs", in: [a, b]) == .unmatched)
        #expect(KnowledgeToolScope.match(collectionName: "Recipes", in: [a, b]) == .unmatched)
    }

    @Test
    func emptyNameMeansAllGranted() {
        let vault = collection("Obsidian Vault")
        #expect(KnowledgeToolScope.match(collectionName: "   ", in: [vault]) == .all)
    }

    // MARK: - list_knowledge limit / offset

    /// The reported call sent `"limit":"20"` (a string). The tool body
    /// coerces it; so does the registry preflight against the schema.
    @Test
    func limitCoercesNumericStringAndClamps() {
        #expect(ListKnowledgeTool.effectiveLimit("20") == 20)
        #expect(ListKnowledgeTool.effectiveLimit(20) == 20)
        #expect(ListKnowledgeTool.effectiveLimit(nil) == ListKnowledgeTool.defaultLimit)
        #expect(ListKnowledgeTool.effectiveLimit("not a number") == ListKnowledgeTool.defaultLimit)
        #expect(ListKnowledgeTool.effectiveLimit(0) == 1)
        #expect(ListKnowledgeTool.effectiveLimit(-5) == 1)
        #expect(ListKnowledgeTool.effectiveLimit(10_000) == ListKnowledgeTool.maxLimit)
        #expect(ListKnowledgeTool.defaultLimit == 100)
        #expect(ListKnowledgeTool.maxLimit == 500)
    }

    @Test
    func offsetCoercesAndNeverGoesNegative() {
        #expect(ListKnowledgeTool.effectiveOffset(nil) == 0)
        #expect(ListKnowledgeTool.effectiveOffset("50") == 50)
        #expect(ListKnowledgeTool.effectiveOffset(50) == 50)
        #expect(ListKnowledgeTool.effectiveOffset(-1) == 0)
    }

    /// The registry preflight (`SchemaValidator.coerceArguments` then
    /// `validate`) accepts the exact reported arguments: a string `limit`
    /// against the `integer` schema is unwrapped, and the new `offset`
    /// property is declared (the schema is `additionalProperties: false`,
    /// so an undeclared `offset` would have been rejected as invalid_args).
    @Test
    func schemaPreflightAcceptsStringLimitAndOffset() throws {
        let tool = ListKnowledgeTool()
        let schema = try #require(tool.parameters)
        let raw: [String: Any] = ["collection": "knowledge", "limit": "20", "offset": "100"]
        let coerced = SchemaValidator.coerceArguments(raw, against: schema)
        let validation = SchemaValidator.validate(arguments: coerced, against: schema)
        #expect(validation.isValid, "\(validation.errorMessage ?? "")")
        let dict = try #require(coerced as? [String: Any])
        #expect(ArgumentCoercion.int(dict["limit"]) == 20)
        #expect(ArgumentCoercion.int(dict["offset"]) == 100)
    }

    @Test
    func listingHeaderStatesTotalWhenPaged() {
        #expect(
            ListKnowledgeTool.listingHeader(total: 3, returned: 3, offset: 0)
                == "Found 3 knowledge document(s):")
        #expect(
            ListKnowledgeTool.listingHeader(total: 312, returned: 100, offset: 0)
                == "Found 312 knowledge document(s) in total; showing 1–100 (offset 0):")
        #expect(
            ListKnowledgeTool.listingHeader(total: 312, returned: 12, offset: 300)
                == "Found 312 knowledge document(s) in total; showing 301–312 (offset 300):")
    }

    @Test
    func listingFooterNamesNextOffsetOnlyWhenMoreRemain() {
        #expect(ListKnowledgeTool.listingFooter(total: 3, returned: 3, offset: 0, limit: 100) == nil)
        #expect(ListKnowledgeTool.listingFooter(total: 312, returned: 12, offset: 300, limit: 100) == nil)
        let footer = ListKnowledgeTool.listingFooter(total: 312, returned: 100, offset: 0, limit: 100)
        #expect(footer?.contains("total=312") == true)
        #expect(footer?.contains("returned=100") == true)
        #expect(footer?.contains("next_offset=100") == true)
        #expect(footer?.contains("212 more") == true)
        // A partial last-but-one page: 7 docs, limit 3, offset 3 → next 6.
        let odd = ListKnowledgeTool.listingFooter(total: 7, returned: 3, offset: 3, limit: 3)
        #expect(odd?.contains("next_offset=6") == true)
        #expect(odd?.contains("1 more") == true)
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
    // MARK: - list_knowledge paging offset

    /// `offset: 2147483648` used to reach `sqlite3_bind_int` as `Int32(offset)` and
    /// terminate the process ("Not enough bits"). The tool clamps at Int32.max and
    /// the binding itself is clamping, so a giant offset is an empty page, not a crash.
    @Test
    func listOffsetPastInt32IsClampedNotCrashing() {
        #expect(ListKnowledgeTool.effectiveOffset(2_147_483_648) == Int(Int32.max))
        #expect(ListKnowledgeTool.effectiveOffset(Int.max) == Int(Int32.max))
        #expect(ListKnowledgeTool.effectiveOffset(-5) == 0)
        #expect(ListKnowledgeTool.effectiveOffset("12") == 12)
        #expect(ListKnowledgeTool.effectiveOffset(nil) == 0)
    }
}
