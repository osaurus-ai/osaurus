//
//  MCPOAuthRegistrationTests.swift
//  osaurusTests
//
//  RFC 7591 Dynamic Client Registration request/response shape.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("MCP OAuth dynamic client registration")
struct MCPOAuthRegistrationTests {
    @Test func registrationRequestHasNativePublicClientShape() async throws {
        var capturedURL: URL?
        var capturedBody: [String: Any]?
        MCPOAuthRegistration.registerOverride = { url, body in
            capturedURL = url
            capturedBody = body
            return MCPDynamicClientRegistration(clientId: "client_123")
        }
        defer { MCPOAuthRegistration.registerOverride = nil }

        let result = try await MCPOAuthRegistration.register(
            registrationEndpoint: "https://auth.example.com/register",
            redirectURI: "http://127.0.0.1:54321/callback",
            clientName: "Osaurus",
            scopes: ["read", "write"]
        )

        #expect(result.clientId == "client_123")
        #expect(capturedURL?.absoluteString == "https://auth.example.com/register")
        #expect(capturedBody?["client_name"] as? String == "Osaurus")
        #expect((capturedBody?["redirect_uris"] as? [String]) == ["http://127.0.0.1:54321/callback"])
        #expect((capturedBody?["grant_types"] as? [String]) == ["authorization_code", "refresh_token"])
        #expect((capturedBody?["response_types"] as? [String]) == ["code"])
        #expect(capturedBody?["token_endpoint_auth_method"] as? String == "none")
        #expect(capturedBody?["application_type"] as? String == "native")
        #expect(capturedBody?["scope"] as? String == "read write")
    }

    @Test func parsesRegistrationResponseWithAccessToken() throws {
        let json = """
            {
              "client_id": "abc123",
              "client_secret": "shhh",
              "client_id_issued_at": 1730000000,
              "registration_access_token": "rat_xyz"
            }
            """
        let registration = try MCPOAuthRegistration.parseRegistrationResponse(Data(json.utf8))
        #expect(registration.clientId == "abc123")
        #expect(registration.clientSecret == "shhh")
        #expect(registration.registrationAccessToken == "rat_xyz")
        #expect(registration.issuedAt == Date(timeIntervalSince1970: 1730000000))
    }

    @Test func rejectsResponseWithoutClientId() {
        let json = #"{"client_secret":"x"}"#
        #expect(throws: MCPOAuthRegistrationError.self) {
            _ = try MCPOAuthRegistration.parseRegistrationResponse(Data(json.utf8))
        }
    }
}
