//
//  AccessKeyResolverTests.swift
//  osaurus
//
//  The shared access-key lookup `osaurus config` uses alongside
//  `osaurus mcp`, including stripping the key options before the
//  subcommand's strict option parser sees them.
//

import XCTest

@testable import OsaurusCLICore

final class AccessKeyResolverTests: XCTestCase {

    func testConfigArgsResolveKeyFromFlagOrEnvironment() {
        let flag = AccessKeyResolver.resolve(
            args: ["plan", "doc.yaml", "--access-key", "osk-v1.flag"],
            environment: ["OSAURUS_API_KEY": "osk-v1.env"]
        )
        XCTAssertEqual(flag, AccessKeyCredential(token: "osk-v1.flag", source: "--access-key"))

        let env = AccessKeyResolver.resolve(args: ["export"], environment: ["OSAURUS_API_KEY": "osk-v1.env"])
        XCTAssertEqual(env, AccessKeyCredential(token: "osk-v1.env", source: "OSAURUS_API_KEY"))

        XCTAssertNil(AccessKeyResolver.resolve(args: ["export"], environment: [:]))
    }

    func testRemovingAccessKeyOptionsKeepsEverythingElse() {
        XCTAssertEqual(
            AccessKeyResolver.removingAccessKeyOptions(
                from: ["doc.yaml", "--access-key", "osk-v1.a", "--prune", "--token=osk-v1.b", "--yes"]
            ),
            ["doc.yaml", "--prune", "--yes"]
        )
        XCTAssertEqual(
            AccessKeyResolver.removingAccessKeyOptions(from: ["-o", "out.yaml", "--format", "json"]),
            ["-o", "out.yaml", "--format", "json"]
        )
    }

    func testMCPCommandStillResolvesThroughSharedHelper() {
        let credential = MCPCommand.resolvedAccessKey(
            args: ["--tools", "osaurus_*"],
            environment: ["OSAURUS_MCP_ACCESS_KEY": "osk-v1.mcp"]
        )
        XCTAssertEqual(credential?.token, "osk-v1.mcp")
    }
}
