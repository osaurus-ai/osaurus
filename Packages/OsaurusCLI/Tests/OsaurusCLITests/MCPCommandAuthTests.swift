//
//  MCPCommandAuthTests.swift
//  osaurus
//
//  Tests the access-key plumbing used by the stdio MCP bridge before it
//  proxies to the local authenticated HTTP MCP endpoints.
//

import XCTest

@testable import OsaurusCLICore

final class MCPCommandAuthTests: XCTestCase {

    func testAccessKeyFlagWinsOverEnvironment() {
        let credential = MCPCommand.resolvedAccessKey(
            args: ["--access-key", "osk-v1.flag.token"],
            environment: ["OSAURUS_MCP_ACCESS_KEY": "osk-v1.env.token"]
        )

        XCTAssertEqual(credential?.token, "osk-v1.flag.token")
        XCTAssertEqual(credential?.source, "--access-key")
    }

    func testInlineAccessKeyStripsBearerPrefix() {
        let credential = MCPCommand.resolvedAccessKey(
            args: ["--access-key=Bearer osk-v1.inline.token"],
            environment: [:]
        )

        XCTAssertEqual(credential?.token, "osk-v1.inline.token")
        XCTAssertEqual(credential?.source, "--access-key")
    }

    func testEnvironmentAccessKeySupportsClaudeDesktopAuthorizationNames() {
        let credential = MCPCommand.resolvedAccessKey(
            args: [],
            environment: ["HTTP_AUTHORIZATION": "Bearer osk-v1.env.token"]
        )

        XCTAssertEqual(credential?.token, "osk-v1.env.token")
        XCTAssertEqual(credential?.source, "HTTP_AUTHORIZATION")
    }

    func testGenericAuthorizationEnvironmentRequiresBearerValue() {
        let credential = MCPCommand.resolvedAccessKey(
            args: [],
            environment: ["AUTHORIZATION": "Basic not-an-osaurus-key"]
        )

        XCTAssertNil(credential)
    }

    func testProxyRequestAddsAuthorizationWhenCredentialExists() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1337/mcp/tools"))
        let request = MCPCommand.makeProxyRequest(
            url: url,
            method: "GET",
            timeout: 5,
            credential: .init(token: "osk-v1.request.token", source: "test")
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer osk-v1.request.token")
    }

    func testProxyRequestLeavesAuthorizationEmptyWithoutCredential() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1337/mcp/tools"))
        let request = MCPCommand.makeProxyRequest(
            url: url,
            method: "GET",
            timeout: 5,
            credential: nil
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}
