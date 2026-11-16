//
//  MCPCanonicalToolNameTests.swift
//  osaurusTests
//
//  MCP tools are exposed provider-prefixed (`xyz_abc`), but the server's own
//  instructions and tool descriptions cite the canonical name (`abc`). A
//  model following them used to dead-end on tool_not_found (#2856). Pins:
//  the registry resolves a canonical name within the originating provider,
//  refuses to guess between providers unless exactly one is exposed, and the
//  description hint names the exposed tool and maps cited siblings.
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct MCPCanonicalToolNameTests {

    private func envelope(_ result: String) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: result.data(using: .utf8)!) as? [String: Any]
    }

    private func mcpTool(_ name: String, description: String = "fixture") -> MCP.Tool {
        MCP.Tool(name: name, description: description, inputSchema: ["type": "object"])
    }

    private func register(
        _ tool: MCPProviderTool
    ) {
        ToolRegistry.shared.registerMCPTool(tool)
        ToolRegistry.shared.setEnabled(true, for: tool.name)
    }

    private func cleanup(_ tools: [MCPProviderTool]) {
        for tool in tools {
            ToolRegistry.shared.setEnabled(false, for: tool.name)
        }
        ToolRegistry.shared.unregister(names: tools.map(\.name))
    }

    // MARK: - Registry resolution

    @Test
    func canonicalNameResolvesToTheSoleProvidersExposedName() async throws {
        let tool = MCPProviderTool(
            mcpTool: mcpTool("canonical_probe_abc"),
            providerId: UUID(),
            providerName: "Xyz Server"
        )
        register(tool)
        defer { cleanup([tool]) }
        #expect(tool.name == "xyz_server_canonical_probe_abc")

        #expect(
            ToolRegistry.shared.uniqueMCPToolName(forCanonical: "canonical_probe_abc")
                == tool.name
        )

        // Resolution happens before the scope gate, so an unexposed canonical
        // call is refused or hinted under the EXPOSED name — proof the call
        // was mapped into the originating provider without being run.
        let scope = ToolExecutionScope(exposed: [])
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
            try await ToolRegistry.shared.execute(name: "canonical_probe_abc", argumentsJSON: "{}")
        }
        let parsed = try envelope(result)
        #expect(parsed?["kind"] as? String == "tool_not_found")
        #expect((parsed?["message"] as? String ?? "").contains(tool.name))
    }

    @Test
    func shortCanonicalNameStillResolves() {
        // The prefix-dropped steer requires 6+ characters; canonical
        // resolution keys on the stored server name and has no such floor.
        let tool = MCPProviderTool(
            mcpTool: mcpTool("read"),
            providerId: UUID(),
            providerName: "Canonical Probe"
        )
        register(tool)
        defer { cleanup([tool]) }
        #expect(ToolRegistry.shared.uniqueMCPToolName(forCanonical: "read") == "canonical_probe_read")
    }

    @Test
    func siblingWithLongerSuffixDoesNotBlockResolution() {
        // `get_canonical_probe_item` also ends in `_canonical_probe_item`, which
        // made the suffix steer ambiguous; the canonical match is exact.
        let item = MCPProviderTool(
            mcpTool: mcpTool("canonical_probe_item"),
            providerId: UUID(),
            providerName: "Cp"
        )
        let getter = MCPProviderTool(
            mcpTool: mcpTool("get_canonical_probe_item"),
            providerId: item.providerId,
            providerName: "Cp"
        )
        register(item)
        register(getter)
        defer { cleanup([item, getter]) }
        #expect(
            ToolRegistry.shared.uniqueMCPToolName(forCanonical: "canonical_probe_item")
                == "cp_canonical_probe_item"
        )
    }

    @Test
    func twoProvidersPublishingTheSameName_resolveOnlyWhenOneIsExposed() async throws {
        let a = MCPProviderTool(
            mcpTool: mcpTool("canonical_probe_dup"),
            providerId: UUID(),
            providerName: "Alpha Srv"
        )
        let b = MCPProviderTool(
            mcpTool: mcpTool("canonical_probe_dup"),
            providerId: UUID(),
            providerName: "Beta Srv"
        )
        register(a)
        register(b)
        defer { cleanup([a, b]) }

        // No scope: nothing to disambiguate with, no guess.
        #expect(ToolRegistry.shared.uniqueMCPToolName(forCanonical: "canonical_probe_dup") == nil)

        // Exactly one exposed: that one.
        let onlyA = ToolExecutionScope(exposed: ToolRegistry.shared.specs(forTools: [a.name]))
        let resolved = ChatExecutionContext.$toolExecutionScope.withValue(onlyA) {
            ToolRegistry.shared.uniqueMCPToolName(forCanonical: "canonical_probe_dup")
        }
        #expect(resolved == a.name)

        // Both exposed: name both by provider, run neither.
        let both = ToolExecutionScope(exposed: ToolRegistry.shared.specs(forTools: [a.name, b.name]))
        let result = try await ChatExecutionContext.$toolExecutionScope.withValue(both) {
            try await ToolRegistry.shared.execute(name: "canonical_probe_dup", argumentsJSON: "{}")
        }
        let parsed = try envelope(result)
        #expect(parsed?["kind"] as? String == "tool_not_found")
        #expect(parsed?["retryable"] as? Bool == true)
        let message = parsed?["message"] as? String ?? ""
        #expect(message.contains(a.name) && message.contains(b.name))
        #expect(message.contains("Alpha Srv") && message.contains("Beta Srv"))
    }

    @Test
    func registeredNameAlwaysWinsOverCanonicalMatch() {
        // A tool literally registered as `canonical_probe_plain` must not be
        // hijacked by an MCP wrapper whose server name happens to match.
        let mcp = MCPProviderTool(
            mcpTool: mcpTool("canonical_probe_plain"),
            providerId: UUID(),
            providerName: "Cp"
        )
        register(mcp)
        defer { cleanup([mcp]) }
        #expect(ToolRegistry.shared.mcpTools(forCanonical: "canonical_probe_plain").count == 1)
        // `uniqueMCPToolName` is only consulted for unregistered names; the
        // registered-name guard lives in `resolvedRegisteredName`, exercised
        // by the execute path above. Here pin the lookup itself is exact.
        #expect(ToolRegistry.shared.mcpTools(forCanonical: "canonical_probe_plai").isEmpty)
    }

    @Test
    func namesWithDedicatedHandlingAreNeverResolvedIntoAProvider() {
        // `file_write` unregistered means "attach a folder"; a remote server
        // publishing a tool of that name must not swallow that message.
        let fileWrite = MCPProviderTool(
            mcpTool: mcpTool("file_write"),
            providerId: UUID(),
            providerName: "Cp"
        )
        let sandbox = MCPProviderTool(
            mcpTool: mcpTool("sandbox_exec"),
            providerId: fileWrite.providerId,
            providerName: "Cp"
        )
        register(fileWrite)
        register(sandbox)
        defer { cleanup([fileWrite, sandbox]) }
        #expect(ToolRegistry.shared.uniqueMCPToolName(forCanonical: "file_write") == nil)
        #expect(ToolRegistry.shared.uniqueMCPToolName(forCanonical: "sandbox_exec") == nil)
        // The exposed names themselves are untouched.
        #expect(ToolRegistry.shared.isMCPTool("cp_file_write"))
    }

    @Test
    func universalFetchNameResolvesOnlyWhenTheServersToolIsExposed() {
        let fetch = MCPProviderTool(
            mcpTool: mcpTool("web_fetch"),
            providerId: UUID(),
            providerName: "Cp"
        )
        register(fetch)
        defer { cleanup([fetch]) }

        let unexposed = ToolExecutionScope(exposed: [])
        let steered = ChatExecutionContext.$toolExecutionScope.withValue(unexposed) {
            ToolRegistry.shared.uniqueMCPToolName(forCanonical: "web_fetch")
        }
        #expect(steered == nil, "keeps the search_and_extract steer")

        let exposed = ToolExecutionScope(exposed: ToolRegistry.shared.specs(forTools: [fetch.name]))
        let resolved = ChatExecutionContext.$toolExecutionScope.withValue(exposed) {
            ToolRegistry.shared.uniqueMCPToolName(forCanonical: "web_fetch")
        }
        #expect(resolved == fetch.name)
    }

    // MARK: - Description hint

    @Test
    func descriptionNamesTheExposedToolAndMapsCitedSiblings() {
        let providerId = UUID()
        let tool = MCPProviderTool(
            mcpTool: mcpTool(
                "create_page",
                description: "Creates a page. Call search first to find the parent; then use get_page to verify."
            ),
            providerId: providerId,
            providerName: "Notion",
            siblingToolNames: ["search", "get_page", "create_page", "searchable_index"]
        )
        #expect(tool.description.hasPrefix("Exposed as `notion_create_page` (server name `create_page`)."))
        #expect(tool.description.contains("`search` is `notion_search`"))
        #expect(tool.description.contains("`get_page` is `notion_get_page`"))
        // Self is never listed as a sibling; an uncited sibling is not listed.
        #expect(!tool.description.contains("`create_page` is"))
        #expect(!tool.description.contains("searchable_index"))
        // The original text survives after the hint.
        #expect(tool.description.hasSuffix("then use get_page to verify."))
    }

    @Test
    func descriptionHintSurvivesTruncationAndIsAbsentWhenUnprefixed() {
        let long = String(repeating: "x", count: MCPProviderTool.maxDescriptionLength + 50)
        let prefixed = MCPProviderTool(
            mcpTool: mcpTool("big", description: long),
            providerId: UUID(),
            providerName: "Srv"
        )
        #expect(prefixed.description.hasPrefix("Exposed as `srv_big` (server name `big`). "))
        #expect(prefixed.description.hasSuffix("..."))

        let bare = MCPProviderTool(
            mcpTool: mcpTool("big", description: "plain"),
            providerId: UUID(),
            providerName: "Srv",
            prefixWithProvider: false
        )
        #expect(bare.description == "plain")
    }

    @Test
    func wholeWordSiblingMatchIgnoresSubstrings() {
        #expect(MCPProviderTool.mentionsWholeWord("search", in: "run search then stop"))
        #expect(MCPProviderTool.mentionsWholeWord("search", in: "search"))
        #expect(MCPProviderTool.mentionsWholeWord("search", in: "call `search`."))
        #expect(!MCPProviderTool.mentionsWholeWord("search", in: "use search_issues"))
        #expect(!MCPProviderTool.mentionsWholeWord("search", in: "well researched"))
        #expect(!MCPProviderTool.mentionsWholeWord("", in: "anything"))
    }
}
