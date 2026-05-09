//
//  ManifestValidateTests.swift
//  osaurus
//
//  Tests for `osaurus manifest validate`. The validator is structural
//  rather than a full Codable decode, so we test:
//    - Valid manifests are accepted with a tools/routes count summary.
//    - Missing required fields surface as targeted errors.
//    - Malformed JSON surfaces as a single "not valid JSON" error.
//    - Optional-but-typed fields (auth, methods, tunnel_exposed) get
//      type-checked.
//

import XCTest
@testable import OsaurusCLICore

final class ManifestValidateTests: XCTestCase {

    // MARK: - Helpers

    private func validate(_ json: String) -> ManifestValidate.Report {
        ManifestValidate.validate(data: Data(json.utf8))
    }

    // MARK: - Valid manifests

    func testMinimalValidManifest() {
        let report = validate(
            """
            {
              "plugin_id": "com.test.plugin",
              "capabilities": {}
            }
            """
        )
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.summary?.pluginId, "com.test.plugin")
        XCTAssertEqual(report.summary?.toolsCount, 0)
        XCTAssertEqual(report.summary?.routesCount, 0)
    }

    func testFullManifestPasses() {
        let report = validate(
            """
            {
              "plugin_id": "com.test.full",
              "version": "0.1.0",
              "name": "Full",
              "capabilities": {
                "tools": [
                  {
                    "id": "hello",
                    "description": "Greets the user",
                    "parameters": {"type": "object"},
                    "permission_policy": "ask"
                  }
                ],
                "routes": [
                  {
                    "id": "callback",
                    "path": "/oauth/callback",
                    "methods": ["GET"],
                    "auth": "none",
                    "tunnel_exposed": true
                  }
                ],
                "web": {
                  "static_dir": "web",
                  "entry": "index.html",
                  "mount": "/ui",
                  "auth": "owner",
                  "tunnel_exposed": false,
                  "api_mount": "/v2"
                }
              }
            }
            """
        )
        XCTAssertTrue(report.errors.isEmpty, "unexpected errors: \(report.errors)")
        XCTAssertEqual(report.summary?.toolsCount, 1)
        XCTAssertEqual(report.summary?.routesCount, 1)
        XCTAssertEqual(report.summary?.hasWeb, true)
    }

    // MARK: - Missing required fields

    func testMissingPluginId() {
        let report = validate(
            """
            { "capabilities": {} }
            """
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("plugin_id") }))
    }

    func testEmptyPluginId() {
        let report = validate(
            """
            { "plugin_id": "", "capabilities": {} }
            """
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("plugin_id") && $0.contains("empty") }))
    }

    func testMissingCapabilities() {
        let report = validate(
            """
            { "plugin_id": "com.test" }
            """
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("capabilities") && $0.contains("required") }))
    }

    // MARK: - Type errors

    func testNotAnObjectAtTopLevel() {
        let report = validate("[]")
        XCTAssertTrue(report.errors.contains(where: { $0.contains("Top-level") }))
    }

    func testMalformedJSON() {
        let report = validate("{ this is not json")
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(report.errors[0].contains("Not valid JSON"))
    }

    func testToolMissingId() {
        let report = validate(
            """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "tools": [{ "description": "no id here" }]
              }
            }
            """
        )
        XCTAssertTrue(
            report.errors.contains(where: { $0.contains("tools[0].id") }),
            "expected error about tools[0].id, got \(report.errors)"
        )
    }

    func testRouteMethodsMustBeArray() {
        let report = validate(
            """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "routes": [
                  { "id": "x", "path": "/x", "methods": "GET" }
                ]
              }
            }
            """
        )
        XCTAssertTrue(
            report.errors.contains(where: { $0.contains("routes[0].methods") }),
            "expected methods type error, got \(report.errors)"
        )
    }

    func testTunnelExposedMustBeBool() {
        let report = validate(
            """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "routes": [
                  { "id": "x", "path": "/x", "methods": ["GET"], "tunnel_exposed": "yes" }
                ]
              }
            }
            """
        )
        XCTAssertTrue(
            report.errors.contains(where: { $0.contains("tunnel_exposed") && $0.contains("boolean") }),
            "expected tunnel_exposed type error, got \(report.errors)"
        )
    }

    func testWebRequiresAllCoreFields() {
        let report = validate(
            """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "web": { "static_dir": "web" }
              }
            }
            """
        )
        let missing = ["entry", "mount", "auth"]
        for field in missing {
            XCTAssertTrue(
                report.errors.contains(where: { $0.contains(field) }),
                "expected error about web.\(field), got \(report.errors)"
            )
        }
    }

    func testUnknownAuthLevelIsAWarning() {
        let report = validate(
            """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "routes": [
                  { "id": "x", "path": "/x", "methods": ["GET"], "auth": "magic" }
                ]
              }
            }
            """
        )
        XCTAssertTrue(report.errors.isEmpty, "auth typo should be a warning, not error: \(report.errors)")
        XCTAssertTrue(report.warnings.contains(where: { $0.contains("magic") }))
    }
}
