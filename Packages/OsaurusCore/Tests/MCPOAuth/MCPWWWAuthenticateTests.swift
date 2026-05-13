//
//  MCPWWWAuthenticateTests.swift
//  osaurusTests
//
//  Parser coverage for MCP `2025-06-18` `WWW-Authenticate: Bearer ...` challenges.
//  We need to extract `resource_metadata=` (RFC 9728) and `scope=` reliably even
//  with mixed quoting / case.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("WWW-Authenticate Bearer parser")
struct MCPWWWAuthenticateTests {
    @Test func parsesQuotedResourceMetadata() {
        let header =
            "Bearer realm=\"mcp\", error=\"invalid_token\", "
            + "resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\""
        let parsed = MCPWWWAuthenticate.parseBearer(header)
        #expect(parsed?.realm == "mcp")
        #expect(parsed?.error == "invalid_token")
        #expect(
            parsed?.resourceMetadataURL
                == URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource")
        )
    }

    @Test func parsesUnquotedScope() {
        let header = "Bearer realm=\"mcp\", scope=read write"
        let parsed = MCPWWWAuthenticate.parseBearer(header)
        // unquoted token reads up to the next ',' which isn't present — treat full tail as scope.
        #expect(parsed?.scope == "read write")
    }

    @Test func caseInsensitiveScheme() {
        let header = "bearer resource_metadata=\"https://x/.well-known/oauth-protected-resource\""
        let parsed = MCPWWWAuthenticate.parseBearer(header)
        #expect(parsed?.resourceMetadataURL?.host == "x")
    }

    @Test func returnsNilForNonBearerScheme() {
        #expect(MCPWWWAuthenticate.parseBearer("Basic realm=\"x\"") == nil)
    }

    @Test func returnsNilForEmptyHeader() {
        #expect(MCPWWWAuthenticate.parseBearer(nil) == nil)
        #expect(MCPWWWAuthenticate.parseBearer("") == nil)
        #expect(MCPWWWAuthenticate.parseBearer("   ") == nil)
    }

    @Test func parsesErrorDescription() {
        let header =
            "Bearer error=\"insufficient_scope\", error_description=\"Need scope: tools.read\""
        let parsed = MCPWWWAuthenticate.parseBearer(header)
        #expect(parsed?.error == "insufficient_scope")
        #expect(parsed?.errorDescription == "Need scope: tools.read")
    }
}
