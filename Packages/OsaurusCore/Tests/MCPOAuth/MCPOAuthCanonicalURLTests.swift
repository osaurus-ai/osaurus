//
//  MCPOAuthCanonicalURLTests.swift
//  osaurusTests
//
//  RFC 8707 canonical resource URL normalization for MCP OAuth `resource=`.
//  These rules are the single highest-leverage gotcha in MCP OAuth — drift
//  here breaks Notion / Atlassian out of the box.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("MCP OAuth canonical resource URL")
struct MCPOAuthCanonicalURLTests {
    @Test func preservesMCPPath() {
        // /mcp must survive verbatim — it's how Notion-style servers segment tools.
        let canonical = MCPOAuthCanonicalURL.canonicalize("https://mcp.notion.com/mcp")
        #expect(canonical == "https://mcp.notion.com/mcp")
    }

    @Test func collapsesTrailingSlashOnNonRootPath() {
        let canonical = MCPOAuthCanonicalURL.canonicalize("https://mcp.notion.com/mcp/")
        #expect(canonical == "https://mcp.notion.com/mcp")
    }

    @Test func keepsRootPathSlash() {
        let canonical = MCPOAuthCanonicalURL.canonicalize("https://mcp.example.com/")
        #expect(canonical == "https://mcp.example.com/")
    }

    @Test func lowercasesSchemeAndHost() {
        let canonical = MCPOAuthCanonicalURL.canonicalize("HTTPS://MCP.Example.COM/MCP")
        #expect(canonical == "https://mcp.example.com/MCP")
    }

    @Test func dropsDefaultPorts() {
        let https = MCPOAuthCanonicalURL.canonicalize("https://mcp.example.com:443/mcp")
        let http = MCPOAuthCanonicalURL.canonicalize("http://mcp.example.com:80/mcp")
        #expect(https == "https://mcp.example.com/mcp")
        #expect(http == "http://mcp.example.com/mcp")
    }

    @Test func keepsCustomPort() {
        let canonical = MCPOAuthCanonicalURL.canonicalize("https://mcp.example.com:8443/mcp")
        #expect(canonical == "https://mcp.example.com:8443/mcp")
    }

    @Test func dropsFragmentAndQuery() {
        let canonical = MCPOAuthCanonicalURL.canonicalize("https://mcp.example.com/mcp?x=1#frag")
        #expect(canonical == "https://mcp.example.com/mcp")
    }

    @Test func rejectsNonHTTPScheme() {
        #expect(MCPOAuthCanonicalURL.canonicalize("ftp://mcp.example.com/") == nil)
        #expect(MCPOAuthCanonicalURL.canonicalize("custom://x") == nil)
    }

    @Test func rejectsHostlessURL() {
        #expect(MCPOAuthCanonicalURL.canonicalize("https:///mcp") == nil)
    }
}
