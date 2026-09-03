//
//  ConfigSampleDocumentTests.swift
//  OsaurusCoreTests
//
//  Pins the shipped sample configuration documents
//  (docs/examples/osaurus-config.sample.{yaml,json}) to the live schema:
//  both must decode through the same strict `ConfigYAML` pipeline the
//  tool/CLI/HTTP surfaces use, and both must declare EVERY section — so
//  schema drift (a renamed key, a removed section) breaks CI instead of
//  silently rotting the docs.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ConfigSampleDocumentTests {

    /// Repo root resolved from this source file's location.
    private static var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // -> Tests/Configuration
            .deletingLastPathComponent()  // -> Tests
            .deletingLastPathComponent()  // -> OsaurusCore
            .deletingLastPathComponent()  // -> Packages
            .deletingLastPathComponent()  // -> repo root
            .appendingPathComponent("docs/examples")
    }

    private static func sample(_ name: String) throws -> String {
        let url = examplesDirectory.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test(arguments: ["osaurus-config.sample.yaml", "osaurus-config.sample.json"])
    func sampleDecodesAndDeclaresEverySection(fileName: String) throws {
        let document = try ConfigYAML.decode(try Self.sample(fileName))
        #expect(document.version == ConfigManifest.version)
        let declared = Set(document.declaredSections)
        for section in ConfigSectionID.allCases {
            #expect(declared.contains(section), "\(fileName) is missing `\(section.rawValue)`")
        }
    }

    @Test
    func yamlAndJSONSamples_describeTheSameDocument() throws {
        let yaml = try ConfigYAML.decode(try Self.sample("osaurus-config.sample.yaml"))
        let json = try ConfigYAML.decode(try Self.sample("osaurus-config.sample.json"))
        #expect(yaml == json, "the YAML and JSON samples must stay in sync")
    }
}
