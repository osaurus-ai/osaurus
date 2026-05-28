//
//  MCPOAuthRegistrationTests.swift
//  osaurusTests
//
//  RFC 7591 Dynamic Client Registration request/response shape.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class MCPOAuthRegistrationTests: XCTestCase {
    func testOAuthTransportDoesNotFollowRedirects() {
        let response = HTTPURLResponse(
            url: URL(string: "https://auth.example.com/register")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://other.example.com/register"]
        )!
        let redirected = URLRequest(url: URL(string: "https://other.example.com/register")!)

        let request = MCPOAuthHTTPTransport.redirectionRequest(
            response: response,
            proposedRequest: redirected
        )

        XCTAssertNil(request)
    }

    func testRegistrationRequestHasNativePublicClientShape() async throws {
        let capture = OAuthRegistrationCapture()
        MCPOAuthRegistration.registerOverride = { url, body in
            capture.record(url: url, body: body)
            return MCPDynamicClientRegistration(clientId: "client_123")
        }
        defer { MCPOAuthRegistration.registerOverride = nil }

        let result = try await MCPOAuthRegistration.register(
            registrationEndpoint: "https://auth.example.com/register",
            redirectURI: "http://127.0.0.1:54321/callback",
            clientName: "Osaurus",
            scopes: ["read", "write"]
        )

        XCTAssertEqual(result.clientId, "client_123")
        XCTAssertEqual(capture.url?.absoluteString, "https://auth.example.com/register")
        XCTAssertEqual(capture.value(for: "client_name"), "Osaurus")
        XCTAssertEqual(capture.value(for: "redirect_uris"), ["http://127.0.0.1:54321/callback"])
        XCTAssertEqual(capture.value(for: "grant_types"), ["authorization_code", "refresh_token"])
        XCTAssertEqual(capture.value(for: "response_types"), ["code"])
        XCTAssertEqual(capture.value(for: "token_endpoint_auth_method"), "none")
        XCTAssertEqual(capture.value(for: "application_type"), "native")
        XCTAssertEqual(capture.value(for: "scope"), "read write")
    }

    func testParsesRegistrationResponseWithAccessToken() throws {
        let json = """
            {
              "client_id": "abc123",
              "client_secret": "shhh",
              "client_id_issued_at": 1730000000,
              "registration_access_token": "rat_xyz"
            }
            """
        let registration = try MCPOAuthRegistration.parseRegistrationResponse(Data(json.utf8))
        XCTAssertEqual(registration.clientId, "abc123")
        XCTAssertEqual(registration.clientSecret, "shhh")
        XCTAssertEqual(registration.registrationAccessToken, "rat_xyz")
        XCTAssertEqual(registration.issuedAt, Date(timeIntervalSince1970: 1_730_000_000))
    }

    func testRejectsResponseWithoutClientID() {
        let json = #"{"client_secret":"x"}"#
        XCTAssertThrowsError(try MCPOAuthRegistration.parseRegistrationResponse(Data(json.utf8))) { error in
            XCTAssertTrue(error is MCPOAuthRegistrationError)
        }
    }
}

private final class OAuthRegistrationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedURL: URL?
    private var capturedBody: [String: Any]?

    var url: URL? {
        lock.lock()
        defer { lock.unlock() }
        return capturedURL
    }

    func record(url: URL, body: [String: Any]) {
        lock.lock()
        capturedURL = url
        capturedBody = body
        lock.unlock()
    }

    func value<T>(for key: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBody?[key] as? T
    }
}
