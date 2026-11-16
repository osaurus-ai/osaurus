import Foundation
import XCTest

@testable import OsaurusCLICore

final class LegacyModelsDiagnosticTests: XCTestCase {
    func testLegacyModelDirectoriesAreReportedWithoutChangingFilesOrActiveRoot() throws {
        try withHome { home in
            let legacy = home.appendingPathComponent(".osaurus/models/org/model")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            let config = legacy.appendingPathComponent("config.json")
            let bytes = Data("original".utf8)
            try bytes.write(to: config)
            let current = home.appendingPathComponent("MLXModels")
            let result = InstallationDiagnostics.strandedLegacyModelDirectories(activeRoot: current, home: home)
            XCTAssertEqual(result?.path, home.appendingPathComponent(".osaurus/models").path)
            XCTAssertEqual(result?.count, 1)
            XCTAssertEqual(result?.complete, true)
            XCTAssertEqual(try Data(contentsOf: config), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        }
    }

    func testEmptyHiddenAndUnrelatedLegacyFilesDoNotWarn() throws {
        try withHome { home in
            let legacy = home.appendingPathComponent(".osaurus/models")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data().write(to: legacy.appendingPathComponent(".DS_Store"))
            try Data().write(to: legacy.appendingPathComponent("notes.txt"))
            XCTAssertNil(InstallationDiagnostics.strandedLegacyModelDirectories(
                activeRoot: home.appendingPathComponent("MLXModels"), home: home))
        }
    }

    func testExplicitLegacyRootAndItsAliasDoNotWarn() throws {
        try withHome { home in
            let legacy = home.appendingPathComponent(".osaurus/models")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data().write(to: legacy.appendingPathComponent("config.json"))
            let alias = home.appendingPathComponent("selected")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: legacy)
            for active in [legacy, alias] {
                XCTAssertNil(InstallationDiagnostics.strandedLegacyModelDirectories(activeRoot: active, home: home))
            }
        }
    }

    func testBoundedLegacyInventoryKeepsIncompleteCountExplicit() throws {
        try withHome { home in
            let legacy = home.appendingPathComponent(".osaurus/models")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data().write(to: legacy.appendingPathComponent("config.json"))
            try Data().write(to: legacy.appendingPathComponent("model.safetensors"))
            let result = InstallationDiagnostics.strandedLegacyModelDirectories(
                activeRoot: home.appendingPathComponent("MLXModels"), home: home, maximumEntries: 1)
            XCTAssertEqual(result?.count, 1)
            XCTAssertEqual(result?.complete, false)
        }
    }

    func testLegacyWarningIsRedactedAndOptionalForOldJSONReports() throws {
        let home = "/Users/fixture-user"
        let report = InstallationDiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 0), cliPath: "\(home)/bin/osaurus",
            cliVersion: "1", cliBuild: "1", requestedPort: 1337, configuredPort: 1337,
            serverHealthy: false, portOwner: nil, modelRoot: "\(home)/MLXModels", modelRootSource: "app_default",
            modelRootReadable: true, modelCount: 0, modelCountComplete: true, apps: [],
            diagnosis: .serverNotRunning, recommendation: "Start the server.")
        let oldJSON = try JSONEncoder().encode(report)
        XCTAssertNil(try JSONDecoder().decode(InstallationDiagnosticReport.self, from: oldJSON).strandedLegacyModels)
        var withLegacy = report
        withLegacy.strandedLegacyModels = .init(path: "\(home)/.osaurus/models", count: 2, complete: false)
        let decoded = try JSONDecoder().decode(
            InstallationDiagnosticReport.self, from: JSONEncoder().encode(withLegacy))
        XCTAssertEqual(decoded.strandedLegacyModels, withLegacy.strandedLegacyModels)
        let redacted = decoded.redacted(homeDirectory: home)
        XCTAssertEqual(redacted.strandedLegacyModels?.path, "~/.osaurus/models")
        let output = DoctorCommand.render(redacted)
        XCTAssertTrue(output.contains("Warning: at least 2 model directory/directories"))
        XCTAssertTrue(output.contains("No files were changed."))
        XCTAssertFalse(output.contains(home))
        XCTAssertEqual(redacted.diagnosis, .serverNotRunning)
    }

    private func withHome(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
