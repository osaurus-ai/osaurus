//
//  MCPOAuthDiscoveryTests.swift
//  osaurusTests
//
//  Discovery flow coverage: candidate URL ordering, PRM hint precedence,
//  and JSON shape parsing for both RFC 8414 and OIDC discovery responses.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("MCP OAuth discovery")
struct MCPOAuthDiscoveryTests {
    @Test func prmHintTakesPrecedenceOverWellKnown() {
        let server = URL(string: "https://mcp.notion.com/mcp")!
        let hint = URL(string: "https://meta.notion.com/.well-known/oauth-protected-resource")!
        let resolved = MCPOAuthDiscovery.prmURL(forServer: server, hint: hint)
        #expect(resolved == hint)
    }

    @Test func prmFallsBackToWellKnown() {
        let server = URL(string: "https://mcp.example.com/mcp")!
        let resolved = MCPOAuthDiscovery.prmURL(forServer: server, hint: nil)
        // RFC 9728 § the resource metadata is at /.well-known/oauth-protected-resource.
        #expect(resolved?.path == "/.well-known/oauth-protected-resource")
        #expect(resolved?.host == "mcp.example.com")
    }

    @Test func asmCandidatesIncludeRFC8414AndOIDC() {
        let asURL = URL(string: "https://auth.example.com/realms/mcp")!
        let candidates = MCPOAuthDiscovery.asmCandidateURLs(authServerURL: asURL).map { $0.absoluteString }

        // First candidate must be RFC 8414 prefixed at the host.
        #expect(candidates.first == "https://auth.example.com/.well-known/oauth-authorization-server/realms/mcp")
        // Path-suffixed RFC 8414 variant should also be present.
        #expect(candidates.contains("https://auth.example.com/realms/mcp/.well-known/oauth-authorization-server"))
        // OIDC discovery (path-suffixed) is the documented fallback.
        #expect(candidates.contains("https://auth.example.com/realms/mcp/.well-known/openid-configuration"))
    }

    @Test func asmCandidatesForRootIssuerAreSensible() {
        let asURL = URL(string: "https://auth.example.com")!
        let candidates = MCPOAuthDiscovery.asmCandidateURLs(authServerURL: asURL).map { $0.absoluteString }
        #expect(candidates.contains("https://auth.example.com/.well-known/oauth-authorization-server"))
        #expect(candidates.contains("https://auth.example.com/.well-known/openid-configuration"))
    }

    @Test func decodesPRM() throws {
        let json = """
            {
              "resource": "https://mcp.example.com/mcp",
              "authorization_servers": ["https://auth.example.com"],
              "scopes_supported": ["read", "write"],
              "bearer_methods_supported": ["header"]
            }
            """
        let prm = try JSONDecoder().decode(MCPProtectedResourceMetadata.self, from: Data(json.utf8))
        #expect(prm.authorizationServers == ["https://auth.example.com"])
        #expect(prm.scopesSupported == ["read", "write"])
        #expect(prm.bearerMethodsSupported == ["header"])
    }

    @Test func decodesASM() throws {
        let json = """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token",
              "registration_endpoint": "https://auth.example.com/register",
              "scopes_supported": ["openid", "offline_access"],
              "code_challenge_methods_supported": ["S256"],
              "grant_types_supported": ["authorization_code", "refresh_token"],
              "token_endpoint_auth_methods_supported": ["none"]
            }
            """
        let asm = try JSONDecoder().decode(MCPAuthorizationServerMetadata.self, from: Data(json.utf8))
        #expect(asm.issuer == "https://auth.example.com")
        #expect(asm.authorizationEndpoint == "https://auth.example.com/authorize")
        #expect(asm.tokenEndpoint == "https://auth.example.com/token")
        #expect(asm.registrationEndpoint == "https://auth.example.com/register")
        #expect(asm.codeChallengeMethodsSupported == ["S256"])
    }

    @Test func discoverUsesInjectedFetcher() async throws {
        let discovery = MCPOAuthDiscovery()
        let prmJSON = #"{"authorization_servers":["https://auth.example.com"]}"#
        let asmJSON = """
            {
              "issuer": "https://auth.example.com",
              "authorization_endpoint": "https://auth.example.com/authorize",
              "token_endpoint": "https://auth.example.com/token",
              "registration_endpoint": "https://auth.example.com/register"
            }
            """
        await discovery._setFetcher { url in
            let body: String
            if url.path.contains("oauth-protected-resource") {
                body = prmJSON
            } else if url.path.contains("oauth-authorization-server") {
                body = asmJSON
            } else {
                throw URLError(.fileDoesNotExist)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(body.utf8), response)
        }

        let (prm, asm) = try await discovery.discover(
            serverURL: URL(string: "https://mcp.example.com/mcp")!,
            hint: nil
        )
        #expect(prm.authorizationServers == ["https://auth.example.com"])
        #expect(asm.tokenEndpoint == "https://auth.example.com/token")
    }
}
