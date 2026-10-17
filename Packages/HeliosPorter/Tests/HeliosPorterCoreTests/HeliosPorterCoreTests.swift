import Foundation
import XCTest
@testable import HeliosPorterCore

final class HeliosPorterCoreTests: XCTestCase {
    func testAnalyzerClassifiesRealManagementSliceSources() throws {
        let repoRoot = try makeFixtureRepository()
        let report = try PortabilityAnalyzer(repoRoot: repoRoot).analyze(slice: .management_settings)

        XCTAssertEqual(report.slice, .management_settings)
        XCTAssertEqual(report.summary.totalFiles, SliceDefinition.management_settings.sourcePaths.count)
        XCTAssertTrue(report.findings.contains(where: {
            $0.sourcePath.hasSuffix("ManagementTab.swift") && $0.classification == .portable
        }))
        XCTAssertTrue(report.findings.contains(where: {
            $0.sourcePath.hasSuffix("ManagementView.swift") && $0.classification == .adapter_needed
        }))
        let serverView = try XCTUnwrap(report.findings.first(where: { $0.sourcePath.hasSuffix("ServerView.swift") }))
        XCTAssertEqual(serverView.classification, .rewrite)
        XCTAssertEqual(serverView.bridgeCapabilities, [.clipboard, .externalLink, .filePicker])
    }

    func testPortabilityManifestMatchesGoldenFile() throws {
        let repoRoot = try makeFixtureRepository()
        let report = try PortabilityAnalyzer(repoRoot: repoRoot).analyze(slice: .management_settings)
        let data = try HeliosPorterSupport.makeEncoder().encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(json, try fixture(named: "management-settings.portability.json"))
    }

    func testArchitectureReportMatchesGoldenFile() throws {
        let repoRoot = try makeFixtureRepository()
        let portability = try PortabilityAnalyzer(repoRoot: repoRoot).analyze(slice: .management_settings)
        let architecture = ArchitectureDecisionEngine().decide(
            slice: .management_settings,
            report: portability
        )
        let markdown = ArchitectureDecisionRenderer().render(portability: portability, architecture: architecture)

        XCTAssertEqual(markdown, try fixture(named: "swiftcrossui-winrt-architecture.md"))
    }

    func testAppCommandsGenerateArtifactsUnderHeliosAndBridgePackage() throws {
        let repoRoot = try makeFixtureRepository()
        let console = BufferedConsole()
        let app = HeliosPorterApp(console: console)

        let scan = app.run(arguments: ["scan", "--slice", "management_settings"], currentDirectory: repoRoot)
        XCTAssertEqual(scan.exitCode, 0)

        let scaffold = app.run(arguments: ["scaffold", "--slice", "management_settings"], currentDirectory: repoRoot)
        XCTAssertEqual(scaffold.exitCode, 0)

        let report = app.run(arguments: ["report"], currentDirectory: repoRoot)
        XCTAssertEqual(report.exitCode, 0)

        let expectedPaths = [
            "Helios/reports/management-settings.portability.json",
            "Helios/reports/swiftcrossui-winrt-architecture.md",
            "Helios/reports/helios-bootstrap.md",
            "Helios/shared/management-settings.slice.json",
            "Helios/swiftcrossui/Sources/HeliosSwiftCrossUIApp/PlatformServices.swift",
            "Packages/HeliosWindowsBridge/Package.swift",
            "Packages/HeliosWindowsBridge/Sources/HeliosWindowsBridge/PlatformServices.swift",
            "Packages/HeliosWindowsBridge/Sources/HeliosWindowsBridge/WinRTBackedServices.swift",
            "Packages/HeliosWindowsBridge/projections/swift-winrt-scope.json",
        ]

        for relativePath in expectedPaths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(relativePath).path), relativePath)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Helios/shaft").path))

        let swiftCrossPlatformServices = try String(
            contentsOf: repoRoot.appendingPathComponent("Helios/swiftcrossui/Sources/HeliosSwiftCrossUIApp/PlatformServices.swift"),
            encoding: .utf8
        )
        let bridgePlatformServices = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/HeliosWindowsBridge/Sources/HeliosWindowsBridge/PlatformServices.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(swiftCrossPlatformServices, bridgePlatformServices)
        XCTAssertTrue(swiftCrossPlatformServices.contains("protocol FilePickerService"))

        let swiftCrossSlice = try String(
            contentsOf: repoRoot.appendingPathComponent("Helios/swiftcrossui/Sources/HeliosSwiftCrossUIApp/ManagementSettingsSlice.swift"),
            encoding: .utf8
        )
        let bridgeImplementation = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/HeliosWindowsBridge/Sources/HeliosWindowsBridge/WinRTBackedServices.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(swiftCrossSlice.contains("../../shared/management-settings.slice.json"))
        XCTAssertTrue(swiftCrossSlice.contains("PlatformServices.placeholder.filePicker.pickFile"))
        XCTAssertTrue(swiftCrossSlice.contains("TODO(Helios): Replace NSOpenPanel-driven endpoint tester flows"))
        XCTAssertFalse(swiftCrossSlice.contains("WinRT"))
        XCTAssertTrue(bridgeImplementation.contains("swift-winrt"))

        let bootstrapReport = try String(
            contentsOf: repoRoot.appendingPathComponent("Helios/reports/helios-bootstrap.md"),
            encoding: .utf8
        )
        XCTAssertTrue(bootstrapReport.contains("chat_surface"))
        XCTAssertTrue(bootstrapReport.contains("app_shell"))
        XCTAssertTrue(bootstrapReport.contains("platform_services"))

        let architectureReport = try String(
            contentsOf: repoRoot.appendingPathComponent("Helios/reports/swiftcrossui-winrt-architecture.md"),
            encoding: .utf8
        )
        XCTAssertTrue(architectureReport.contains("Packages/HeliosWindowsBridge"))
        XCTAssertTrue(architectureReport.contains("Windows.Storage.Pickers"))
    }

    func testHelpCommandReflectsSingleFrameworkWorkflow() throws {
        let repoRoot = try makeFixtureRepository()
        let output = HeliosPorterApp(console: BufferedConsole()).run(arguments: [], currentDirectory: repoRoot)

        XCTAssertNotEqual(output.exitCode, 0)
        XCTAssertTrue(output.stdout.contains("helios-porter scan"))
        XCTAssertTrue(output.stdout.contains("helios-porter scaffold"))
        XCTAssertTrue(output.stdout.contains("helios-porter report"))
        XCTAssertFalse(output.stdout.contains("compare"))
        XCTAssertFalse(output.stdout.contains("--targets"))
    }

    private func makeFixtureRepository() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("helios-porter-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)

        for relativePath in SliceDefinition.management_settings.sourcePaths {
            let destination = base.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try Data(contentsOf: liveRepositoryRoot().appendingPathComponent(relativePath)).write(to: destination)
        }

        return base
    }

    private func fixture(named name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        let resolved = try XCTUnwrap(url)
        return try String(contentsOf: resolved, encoding: .utf8)
    }

    private func liveRepositoryRoot() -> URL {
        var cursor = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            cursor.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: cursor.appendingPathComponent("Packages/OsaurusCore").path
            ) {
                return cursor
            }
        }
        XCTFail("Unable to resolve live repository root")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}
