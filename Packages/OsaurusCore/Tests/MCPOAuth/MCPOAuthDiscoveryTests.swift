//
//  MCPOAuthDiscoveryTests.swift
//  osaurusTests
//
//  Discovery flow coverage: candidate URL ordering, PRM hint precedence,
//  and JSON shape parsing for both RFC 8414 and OIDC discovery responses.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class MCPOAuthDiscoveryTests: XCTestCase {
    func testPRMHintTakesPrecedenceOverWellKnown() {
        let server = URL(string: "https://mcp.notion.com/mcp")!
        let hint = URL(string: "https://meta.notion.com/.well-known/oauth-protected-resource")!
        let resolved = MCPOAuthDiscovery.prmURL(forServer: server, hint: hint)
        XCTAssertEqual(resolved, hint)
    }

    func testPRMHintRejectsLocalTargetForPublicServer() {
        let server = URL(string: "https://mcp.example.com/mcp")!
        let hint = URL(string: "http://127.0.0.1:9090/.well-known/oauth-protected-resource")!

        let resolved = MCPOAuthDiscovery.prmURL(forServer: server, hint: hint)

        XCTAssertNil(resolved)
    }

    func testPRMHintAllowsLocalTargetForLocalServer() {
        let server = URL(string: "http://localhost:7331/mcp")!
        let hint = URL(string: "http://127.0.0.1:7331/.well-known/oauth-protected-resource")!

        let resolved = MCPOAuthDiscovery.prmURL(forServer: server, hint: hint)

        XCTAssertEqual(resolved, hint)
    }

    func testPRMHintAllowsHTTPSLocalTargetForHTTPSLocalServer() {
        let server = URL(string: "https://localhost:7331/mcp")!
        let hint = URL(string: "http://127.0.0.1:7331/.well-known/oauth-protected-resource")!

        let resolved = MCPOAuthDiscovery.prmURL(forServer: server, hint: hint)

        XCTAssertEqual(resolved, hint)
    }

    func testPRMHintRejectsPublicCleartextTargetForLocalServer() {
        let server = URL(string: "http://localhost:7331/mcp")!
        let hint = URL(string: "http://auth.example.com/.well-known/oauth-protected-resource")!

        let resolved = MCPOAuthDiscovery.prmURL(forServer: server, hint: hint)

        XCTAssertNil(resolved)
    }

    func testPRMHintRejectsUserInfoAndFragments() {
        let server = URL(string: "https://mcp.example.com/mcp")!
        let withUserInfo = URL(string: "https://user:pass@meta.example.com/.well-known/oauth-protected-resource")!
        let withFragment = URL(string: "https://meta.example.com/.well-known/oauth-protected-resource#token")!

        XCTAssertNil(MCPOAuthDiscovery.prmURL(forServer: server, hint: withUserInfo))
        XCTAssertNil(MCPOAuthDiscovery.prmURL(forServer: server, hint: withFragment))
    }

    func testPRMFallsBackToWellKnown() {
        let server = URL(string: "https://mcp.example.com/mcp")!
        let resolved = MCPOAuthDiscovery.prmURL(forServer: server, hint: nil)
        // RFC 9728 § the resource metadata is at /.well-known/oauth-protected-resource.
        XCTAssertEqual(resolved?.path, "/.well-known/oauth-protected-resource")
        XCTAssertEqual(resolved?.host, "mcp.example.com")
    }

    func testASMCandidatesIncludeRFC8414AndOIDC() {
        let asURL = URL(string: "https://auth.example.com/realms/mcp")!
        let candidates = MCPOAuthDiscovery.asmCandidateURLs(authServerURL: asURL).map(\.absoluteString)

        // First candidate must be RFC 8414 prefixed at the host.
        XCTAssertEqual(
            candidates.first,
            "https://auth.example.com/.well-known/oauth-authorization-server/realms/mcp"
        )
        // Path-suffixed RFC 8414 variant should also be present.
        XCTAssertTrue(candidates.contains("https://auth.example.com/realms/mcp/.well-known/oauth-authorization-server"))
        // OIDC discovery (path-suffixed) is the documented fallback.
        XCTAssertTrue(candidates.contains("https://auth.example.com/realms/mcp/.well-known/openid-configuration"))
    }

    func testASMCandidatesForRootIssuerAreSensible() {
        let asURL = URL(string: "https://auth.example.com")!
        let candidates = MCPOAuthDiscovery.asmCandidateURLs(authServerURL: asURL).map(\.absoluteString)
        XCTAssertTrue(candidates.contains("https://auth.example.com/.well-known/oauth-authorization-server"))
        XCTAssertTrue(candidates.contains("https://auth.example.com/.well-known/openid-configuration"))
    }

    func testDecodesPRM() throws {
        let json = """
            {
              "resource": "https://mcp.example.com/mcp",
              "authorization_servers": ["https://auth.example.com"],
              "scopes_supported": ["read", "write"],
              "bearer_methods_supported": ["header"]
            }
            """
        let prm = try JSONDecoder().decode(MCPProtectedResourceMetadata.self, from: Data(json.utf8))
        XCTAssertEqual(prm.authorizationServers, ["https://auth.example.com"])
        XCTAssertEqual(prm.scopesSupported, ["read", "write"])
        XCTAssertEqual(prm.bearerMethodsSupported, ["header"])
    }

    func testDecodesASM() throws {
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
        XCTAssertEqual(asm.issuer, "https://auth.example.com")
        XCTAssertEqual(asm.authorizationEndpoint, "https://auth.example.com/authorize")
        XCTAssertEqual(asm.tokenEndpoint, "https://auth.example.com/token")
        XCTAssertEqual(asm.registrationEndpoint, "https://auth.example.com/register")
        XCTAssertEqual(asm.codeChallengeMethodsSupported, ["S256"])
    }

    func testDiscoverUsesInjectedFetcher() async throws {
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
        XCTAssertEqual(prm.authorizationServers, ["https://auth.example.com"])
        XCTAssertEqual(asm.tokenEndpoint, "https://auth.example.com/token")
    }

    func testDiscoverDoesNotFetchLocalAuthorizationServerForPublicResource() async throws {
        let discovery = MCPOAuthDiscovery()
        let prmJSON = #"{"authorization_servers":["http://127.0.0.1:9090"]}"#
        let recorder = OAuthDiscoveryURLRecorder()
        await discovery._setFetcher { url in
            await recorder.append(url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(prmJSON.utf8), response)
        }

        do {
            _ = try await discovery.discover(
                serverURL: URL(string: "https://mcp.example.com/mcp")!,
                hint: nil
            )
            XCTFail("Expected unsafe local authorization server to throw")
        } catch is MCPOAuthDiscoveryError {
            // Expected: public resources must not be allowed to redirect discovery to localhost.
        }

        let fetchedURLs = await recorder.snapshot()
        XCTAssertEqual(fetchedURLs.count, 1)
        XCTAssertEqual(fetchedURLs.first?.host, "mcp.example.com")
    }

    func testValidateAuthorizationServerMetadataRejectsUnsafeTokenEndpoint() {
        let asm = MCPAuthorizationServerMetadata(
            issuer: "https://auth.example.com",
            authorizationEndpoint: "https://auth.example.com/authorize",
            tokenEndpoint: "http://169.254.169.254/latest/api/token",
            registrationEndpoint: "https://auth.example.com/register",
            scopesSupported: nil,
            codeChallengeMethodsSupported: nil,
            grantTypesSupported: nil,
            tokenEndpointAuthMethodsSupported: nil
        )

        XCTAssertThrowsError(
            try MCPOAuthDiscovery.validateAuthorizationServerMetadata(
                asm,
                origin: URL(string: "https://mcp.example.com/mcp")!
            )
        ) { error in
            XCTAssertTrue(error is MCPOAuthDiscoveryError)
        }
    }

    func testValidateAuthorizationServerMetadataAllowsLocalDevEndpointsForLocalResource() throws {
        let asm = MCPAuthorizationServerMetadata(
            issuer: "http://127.0.0.1:9090",
            authorizationEndpoint: "http://127.0.0.1:9090/authorize",
            tokenEndpoint: "http://127.0.0.1:9090/token",
            registrationEndpoint: "http://127.0.0.1:9090/register",
            scopesSupported: nil,
            codeChallengeMethodsSupported: nil,
            grantTypesSupported: nil,
            tokenEndpointAuthMethodsSupported: nil
        )

        try MCPOAuthDiscovery.validateAuthorizationServerMetadata(
            asm,
            origin: URL(string: "http://localhost:7331/mcp")!
        )
    }
}

private actor OAuthDiscoveryURLRecorder {
    private var urls: [URL] = []

    func append(_ url: URL) {
        urls.append(url)
    }

    func snapshot() -> [URL] {
        urls
    }
}
