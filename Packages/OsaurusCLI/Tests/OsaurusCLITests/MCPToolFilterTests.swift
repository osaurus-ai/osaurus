//
//  MCPToolFilterTests.swift
//  OsaurusCLITests
//
//  Allow-list parsing and matching for `osaurus mcp --tools`. Pure logic —
//  no server, no subprocess.
//

import Foundation
import Testing

@testable import OsaurusCLICore

@Suite("MCP tool filter")
struct MCPToolFilterTests {

    // MARK: - Matching

    @Test func exactNamesMatchOnlyThemselves() throws {
        let filter = MCPToolFilter(patterns: "osaurus_status,osaurus_list")

        #expect(filter.admits("osaurus_status"))
        #expect(filter.admits("osaurus_list"))
        #expect(!filter.admits("osaurus_agent"))
        // Exact means exact: a longer name sharing the prefix is not admitted.
        #expect(!filter.admits("osaurus_status_extra"))
    }

    @Test func trailingStarMatchesByPrefix() throws {
        let filter = MCPToolFilter(patterns: "osaurus_*")

        #expect(filter.admits("osaurus_status"))
        #expect(filter.admits("osaurus_agent"))
        // The prefix is stripped of the star, so the bare stem still matches.
        #expect(filter.admits("osaurus_"))
        #expect(!filter.admits("shell_run"))
        #expect(!filter.admits("prefix_osaurus_status"))
    }

    @Test func mixesExactAndPrefixPatterns() throws {
        let filter = MCPToolFilter(patterns: "osaurus_*,shell_run")

        #expect(filter.admits("osaurus_describe"))
        #expect(filter.admits("shell_run"))
        #expect(!filter.admits("read_file"))
    }

    @Test func bareStarAdmitsEverything() throws {
        let filter = MCPToolFilter(patterns: "*")

        #expect(filter.admits("anything"))
        #expect(filter.admits(""))
    }

    // MARK: - Parsing hygiene

    @Test func whitespaceAndEmptyEntriesAreIgnored() throws {
        let filter = MCPToolFilter(patterns: " osaurus_status , , osaurus_list ,")

        #expect(filter.admits("osaurus_status"))
        #expect(filter.admits("osaurus_list"))
        #expect(!filter.admits(""))
    }

    @Test func explicitEmptyPatternsFailClosed() {
        #expect(!MCPToolFilter(patterns: "").admits("osaurus_status"))
        #expect(!MCPToolFilter(patterns: "   ").admits("osaurus_status"))
        #expect(!MCPToolFilter(patterns: ",,,").admits("osaurus_status"))
    }

    // MARK: - Argument extraction

    @Test func parsesSpaceSeparatedForm() throws {
        let filter = try #require(MCPToolFilter.parse(args: ["mcp", "--tools", "osaurus_*"]))
        #expect(filter.admits("osaurus_status"))
    }

    @Test func parsesEqualsForm() throws {
        let filter = try #require(MCPToolFilter.parse(args: ["mcp", "--tools=osaurus_status"]))
        #expect(filter.admits("osaurus_status"))
        #expect(!filter.admits("osaurus_agent"))
    }

    @Test func absentFlagMeansProxyEverything() {
        #expect(MCPToolFilter.parse(args: ["mcp"]) == nil)
        #expect(MCPToolFilter.parse(args: ["mcp", "--access-key", "osk-v1"]) == nil)
        // A dangling explicit filter is a typo, so it fails closed.
        #expect(MCPToolFilter.parse(args: ["mcp", "--tools"])?.admits("osaurus_status") == false)
    }

    @Test func summaryListsParsedPatterns() throws {
        let filter = MCPToolFilter(patterns: "osaurus_status,osaurus_*")
        #expect(filter.summary.contains("osaurus_status"))
        #expect(filter.summary.contains("osaurus_*"))
    }
}

// MARK: - Bridge grant

@Suite("MCP bridge grant header")
struct MCPBridgeGrantTests {
    /// Pins both literals. `ClaudeCodeBridgeGrantStore` in OsaurusCore declares
    /// the same two strings; the CLI cannot import Core, so a rename on either
    /// side silently breaks the bridge unless something asserts the values.
    @Test("constants match the OsaurusCore contract")
    func constantsMatchCore() {
        #expect(MCPCommand.bridgeGrantEnvironmentKey == "OSAURUS_MCP_BRIDGE_GRANT")
        #expect(MCPCommand.bridgeGrantHeaderName == "X-Osaurus-Bridge-Grant")
    }

    @Test("grant header is absent when the environment does not carry one")
    func absentWithoutEnvironment() throws {
        // A user-configured MCP client is spawned without the variable, and must
        // stay unattributed rather than inheriting some other turn's identity.
        let request = MCPCommand.makeProxyRequest(
            url: try #require(URL(string: "http://127.0.0.1:1337/mcp/call")),
            method: "POST",
            timeout: 30,
            credential: nil
        )
        #expect(request.value(forHTTPHeaderField: MCPCommand.bridgeGrantHeaderName) == nil)
    }
}
