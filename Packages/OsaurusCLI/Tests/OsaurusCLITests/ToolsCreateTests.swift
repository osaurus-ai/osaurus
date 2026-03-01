//
//  ToolsCreateTests.swift
//  osaurus
//
//  Tests for plugin scaffold generation (ToolsCreate).
//

import XCTest
@testable import OsaurusCLICore

final class ToolsCreateTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Name Helpers

    func testModuleNameReplacesHyphens() {
        XCTAssertEqual(ToolsCreate.moduleName(from: "my-cool-plugin"), "my_cool_plugin")
    }

    func testModuleNamePassesThroughSimpleName() {
        XCTAssertEqual(ToolsCreate.moduleName(from: "myplugin"), "myplugin")
    }

    func testDisplayNameCapitalizes() {
        XCTAssertEqual(ToolsCreate.displayName(from: "my-cool-plugin"), "My Cool Plugin")
    }

    func testDisplayNameSingleWord() {
        XCTAssertEqual(ToolsCreate.displayName(from: "myplugin"), "Myplugin")
    }

    // MARK: - Swift Scaffold

    func testSwiftScaffoldCreatesExpectedFiles() {
        ToolsCreate.scaffoldPlugin(name: "test-plugin", language: "swift", rootDirectory: tempDir)

        let pluginDir = tempDir.appendingPathComponent("test-plugin")
        let fm = FileManager.default

        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent("Package.swift").path))
        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent("Sources/test_plugin/Plugin.swift").path))
        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent("web/index.html").path))
        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent(".github/workflows/release.yml").path))
        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent("README.md").path))
        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent("CLAUDE.md").path))
    }

    func testSwiftPackageSwiftContainsCorrectModuleName() throws {
        ToolsCreate.scaffoldPlugin(name: "test-plugin", language: "swift", rootDirectory: tempDir)

        let packagePath =
            tempDir
            .appendingPathComponent("test-plugin")
            .appendingPathComponent("Package.swift")
        let content = try String(contentsOf: packagePath, encoding: .utf8)

        XCTAssertTrue(content.contains("name: \"test-plugin\""))
        XCTAssertTrue(content.contains("\"test_plugin\""))
        XCTAssertTrue(content.contains("swift-tools-version: 6.0"))
        XCTAssertTrue(content.contains(".dynamic"))
    }

    func testSwiftPluginContainsV2EntryPoint() throws {
        ToolsCreate.scaffoldPlugin(name: "test-plugin", language: "swift", rootDirectory: tempDir)

        let pluginPath =
            tempDir
            .appendingPathComponent("test-plugin")
            .appendingPathComponent("Sources/test_plugin/Plugin.swift")
        let content = try String(contentsOf: pluginPath, encoding: .utf8)

        XCTAssertTrue(content.contains("osaurus_plugin_entry_v2"))
        XCTAssertTrue(content.contains("osaurus_plugin_entry"))
        XCTAssertTrue(content.contains("osr_host_api"))
        XCTAssertTrue(content.contains("api.version = 2"))
    }

    func testSwiftManifestContainsPluginId() throws {
        ToolsCreate.scaffoldPlugin(name: "my-tool", language: "swift", rootDirectory: tempDir)

        let pluginPath =
            tempDir
            .appendingPathComponent("my-tool")
            .appendingPathComponent("Sources/my_tool/Plugin.swift")
        let content = try String(contentsOf: pluginPath, encoding: .utf8)

        XCTAssertTrue(content.contains("dev.example.my-tool"))
        XCTAssertTrue(content.contains("hello_world"))
        XCTAssertTrue(content.contains("/health"))
    }

    func testSwiftWebPlaceholderContainsDisplayName() throws {
        ToolsCreate.scaffoldPlugin(name: "my-tool", language: "swift", rootDirectory: tempDir)

        let htmlPath =
            tempDir
            .appendingPathComponent("my-tool")
            .appendingPathComponent("web/index.html")
        let content = try String(contentsOf: htmlPath, encoding: .utf8)

        XCTAssertTrue(content.contains("<title>My Tool</title>"))
        XCTAssertTrue(content.contains("<h1>My Tool</h1>"))
    }

    // MARK: - Rust Scaffold

    func testRustScaffoldCreatesExpectedFiles() {
        ToolsCreate.scaffoldPlugin(name: "test-plugin", language: "rust", rootDirectory: tempDir)

        let pluginDir = tempDir.appendingPathComponent("test-plugin")
        let fm = FileManager.default

        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent("Cargo.toml").path))
        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent("src/lib.rs").path))
        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent("web/index.html").path))
        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent(".github/workflows/release.yml").path))
        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent("README.md").path))
        XCTAssertTrue(fm.fileExists(atPath: pluginDir.appendingPathComponent("CLAUDE.md").path))
    }

    func testRustCargoTomlContainsCorrectConfig() throws {
        ToolsCreate.scaffoldPlugin(name: "test-plugin", language: "rust", rootDirectory: tempDir)

        let cargoPath =
            tempDir
            .appendingPathComponent("test-plugin")
            .appendingPathComponent("Cargo.toml")
        let content = try String(contentsOf: cargoPath, encoding: .utf8)

        XCTAssertTrue(content.contains("name = \"test_plugin\""))
        XCTAssertTrue(content.contains("cdylib"))
        XCTAssertTrue(content.contains("serde"))
        XCTAssertTrue(content.contains("serde_json"))
    }

    func testRustLibContainsV2EntryPoint() throws {
        ToolsCreate.scaffoldPlugin(name: "test-plugin", language: "rust", rootDirectory: tempDir)

        let libPath =
            tempDir
            .appendingPathComponent("test-plugin")
            .appendingPathComponent("src/lib.rs")
        let content = try String(contentsOf: libPath, encoding: .utf8)

        XCTAssertTrue(content.contains("osaurus_plugin_entry_v2"))
        XCTAssertTrue(content.contains("osaurus_plugin_entry"))
        XCTAssertTrue(content.contains("OsrHostApi"))
        XCTAssertTrue(content.contains("OsrPluginApi"))
        XCTAssertTrue(content.contains("version: 2"))
    }

    func testRustManifestContainsPluginId() throws {
        ToolsCreate.scaffoldPlugin(name: "my-tool", language: "rust", rootDirectory: tempDir)

        let libPath =
            tempDir
            .appendingPathComponent("my-tool")
            .appendingPathComponent("src/lib.rs")
        let content = try String(contentsOf: libPath, encoding: .utf8)

        XCTAssertTrue(content.contains("dev.example.my-tool"))
        XCTAssertTrue(content.contains("hello_world"))
        XCTAssertTrue(content.contains("/health"))
    }

    // MARK: - Release Workflow

    func testReleaseWorkflowIsIdenticalBetweenLanguages() throws {
        ToolsCreate.scaffoldPlugin(name: "swift-plugin", language: "swift", rootDirectory: tempDir)
        ToolsCreate.scaffoldPlugin(name: "rust-plugin", language: "rust", rootDirectory: tempDir)

        let swiftYml = try String(
            contentsOf: tempDir.appendingPathComponent("swift-plugin/.github/workflows/release.yml"),
            encoding: .utf8
        )
        let rustYml = try String(
            contentsOf: tempDir.appendingPathComponent("rust-plugin/.github/workflows/release.yml"),
            encoding: .utf8
        )

        XCTAssertEqual(swiftYml, rustYml)
        XCTAssertTrue(swiftYml.contains("build-plugin.yml@master"))
    }

    // MARK: - Default Language

    func testDefaultLanguageIsSwift() {
        ToolsCreate.scaffoldPlugin(name: "default-plugin", language: "unknown", rootDirectory: tempDir)

        let pluginDir = tempDir.appendingPathComponent("default-plugin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("Package.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("Cargo.toml").path))
    }
}
