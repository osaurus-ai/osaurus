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

// MARK: - Extended field coverage (added for plugin authoring v1)

/// Pins the validator coverage added when the plugin authoring surface
/// was hardened: secrets array, docs object, min_osaurus / min_macos
/// shape, instructions / license / authors typing, and per-config-field
/// validation (key / type / label, with `type` constrained to the
/// documented enum). Each sub-area lives in its own method so a future
/// regression maps to one concrete test.
final class ManifestValidateExtendedCoverageTests: XCTestCase {

    private func validate(_ json: String) -> ManifestValidate.Report {
        ManifestValidate.validate(data: Data(json.utf8))
    }

    // MARK: - secrets

    func testValidSecretsArrayPasses() {
        let report = validate(
            """
            {
              "plugin_id": "com.test",
              "capabilities": {},
              "secrets": [
                { "id": "api_key", "label": "API Key", "required": true },
                { "id": "endpoint", "label": "Endpoint", "url": "https://example.com" }
              ]
            }
            """
        )
        XCTAssertTrue(report.errors.isEmpty, "valid secrets must pass: \(report.errors)")
    }

    func testSecretMissingIdFails() {
        let report = validate(
            """
            {
              "plugin_id": "com.test", "capabilities": {},
              "secrets": [{ "label": "API Key" }]
            }
            """
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("secrets[0].id") }))
    }

    func testSecretMissingLabelFails() {
        let report = validate(
            """
            {
              "plugin_id": "com.test", "capabilities": {},
              "secrets": [{ "id": "api_key" }]
            }
            """
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("secrets[0].label") }))
    }

    func testSecretRequiredMustBeBool() {
        let report = validate(
            """
            {
              "plugin_id": "com.test", "capabilities": {},
              "secrets": [{ "id": "x", "label": "X", "required": "true" }]
            }
            """
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("required") && $0.contains("boolean") }))
    }

    func testSecretsMustBeArray() {
        let report = validate(
            """
            {
              "plugin_id": "com.test", "capabilities": {},
              "secrets": { "id": "x", "label": "X" }
            }
            """
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("`secrets`") && $0.contains("array") }))
    }

    // MARK: - docs

    func testValidDocsPasses() {
        let report = validate(
            """
            {
              "plugin_id": "com.test", "capabilities": {},
              "docs": {
                "readme": "README.md",
                "changelog": "CHANGELOG.md",
                "links": [{ "label": "Home", "url": "https://example.com" }]
              }
            }
            """
        )
        XCTAssertTrue(report.errors.isEmpty)
    }

    func testDocsLinkMissingFieldFails() {
        let report = validate(
            """
            {
              "plugin_id": "com.test", "capabilities": {},
              "docs": { "links": [{ "label": "Home" }] }
            }
            """
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("docs.links[0].url") }))
    }

    // MARK: - min_osaurus / min_macos

    func testValidMinOsaurusPasses() {
        let report = validate(
            #"{ "plugin_id": "com.test", "capabilities": {}, "min_osaurus": "0.18.0" }"#
        )
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testUnparseableMinOsaurusIsAWarning() {
        let report = validate(
            #"{ "plugin_id": "com.test", "capabilities": {}, "min_osaurus": "soon" }"#
        )
        XCTAssertTrue(report.errors.isEmpty, "unparseable should warn, not error: \(report.errors)")
        XCTAssertTrue(report.warnings.contains(where: { $0.contains("min_osaurus") && $0.contains("semver") }))
    }

    func testValidMinMacosVariantsPass() {
        for v in ["14", "14.5", "14.5.1"] {
            let report = validate(
                #"{ "plugin_id": "com.test", "capabilities": {}, "min_macos": "\#(v)" }"#
            )
            XCTAssertTrue(report.errors.isEmpty, "min_macos '\(v)' must pass: \(report.errors)")
            XCTAssertTrue(report.warnings.isEmpty, "min_macos '\(v)' should not warn: \(report.warnings)")
        }
    }

    func testUnparseableMinMacosIsAWarning() {
        let report = validate(
            #"{ "plugin_id": "com.test", "capabilities": {}, "min_macos": "sequoia" }"#
        )
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertTrue(report.warnings.contains(where: { $0.contains("min_macos") }))
    }

    // MARK: - instructions / license / authors

    func testInstructionsMustBeString() {
        let report = validate(
            #"{ "plugin_id": "com.test", "capabilities": {}, "instructions": ["multi","line"] }"#
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("instructions") }))
    }

    func testAuthorsMustBeArrayOfStrings() {
        let report = validate(
            #"{ "plugin_id": "com.test", "capabilities": {}, "authors": "Alice" }"#
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("authors") }))
    }

    func testAuthorsArrayWithNonStringFails() {
        let report = validate(
            #"{ "plugin_id": "com.test", "capabilities": {}, "authors": ["Alice", 42] }"#
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("authors[1]") }))
    }

    // MARK: - artifact_handler

    func testArtifactHandlerMustBeBool() {
        let report = validate(
            """
            {
              "plugin_id": "com.test",
              "capabilities": { "artifact_handler": "yes" }
            }
            """
        )
        XCTAssertTrue(report.errors.contains(where: { $0.contains("artifact_handler") }))
    }

    // MARK: - config field validation

    func testConfigFieldsRequireType() {
        let report = validate(
            """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "config": {
                  "sections": [
                    { "title": "Auth", "fields": [{ "key": "api_key", "label": "API Key" }] }
                  ]
                }
              }
            }
            """
        )
        XCTAssertTrue(
            report.errors.contains(where: { $0.contains("type") && $0.contains("required") }),
            "config field must require `type`: \(report.errors)"
        )
    }

    func testConfigFieldRejectsUnknownType() {
        let report = validate(
            """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "config": {
                  "sections": [{
                    "title": "Auth",
                    "fields": [{ "key": "k", "label": "L", "type": "checkbox" }]
                  }]
                }
              }
            }
            """
        )
        XCTAssertTrue(
            report.errors.contains(where: { $0.contains("checkbox") }),
            "unknown config field type must error, got: \(report.errors)"
        )
    }

    func testConfigFieldAcceptsAllValidTypes() {
        for t in ["text", "secret", "toggle", "select", "multiselect", "number", "readonly", "status"] {
            let report = validate(
                """
                {
                  "plugin_id": "com.test",
                  "capabilities": {
                    "config": {
                      "sections": [{
                        "title": "S",
                        "fields": [{ "key": "k", "label": "L", "type": "\(t)" }]
                      }]
                    }
                  }
                }
                """
            )
            XCTAssertTrue(
                report.errors.isEmpty,
                "type '\(t)' must validate, got \(report.errors)"
            )
        }
    }

    func testConfigSectionRequiresTitle() {
        let report = validate(
            """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "config": { "sections": [{ "fields": [] }] }
              }
            }
            """
        )
        XCTAssertTrue(
            report.errors.contains(where: { $0.contains("sections[0].title") }),
            "missing section title must error: \(report.errors)"
        )
    }

    func testConfigSectionRequiresFields() {
        let report = validate(
            """
            {
              "plugin_id": "com.test",
              "capabilities": {
                "config": { "sections": [{ "title": "Auth" }] }
              }
            }
            """
        )
        XCTAssertTrue(
            report.errors.contains(where: { $0.contains("sections[0].fields") }),
            "missing section fields must error: \(report.errors)"
        )
    }
}
