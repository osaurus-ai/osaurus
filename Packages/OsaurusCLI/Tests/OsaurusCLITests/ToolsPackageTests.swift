//
//  ToolsPackageTests.swift
//  osaurus
//
//  Tests for plugin packaging logic (ToolsPackage).
//

import XCTest
@testable import OsaurusCLICore

final class ToolsPackageTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pkg-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Zip Name

    func testZipNameFormat() {
        XCTAssertEqual(ToolsPackage.zipName(pluginId: "com.example.foo", version: "1.2.3"), "com.example.foo-1.2.3.zip")
    }

    // MARK: - Companion Files

    func testCompanionFilesListIsCorrect() {
        XCTAssertEqual(ToolsPackage.companionFiles, ["SKILL.md", "README.md", "CHANGELOG.md"])
    }

    func testCompanionDirsListIsCorrect() {
        XCTAssertEqual(ToolsPackage.companionDirs, ["web"])
    }

    // MARK: - Collect Companion Entries

    func testCollectCompanionEntriesFindsNothing() {
        let entries = ToolsPackage.collectCompanionEntries(in: tempDir)
        XCTAssertTrue(entries.isEmpty)
    }

    func testCollectCompanionEntriesFindsReadme() throws {
        try "# Plugin".write(to: tempDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let entries = ToolsPackage.collectCompanionEntries(in: tempDir)
        XCTAssertEqual(entries, ["README.md"])
    }

    func testCollectCompanionEntriesFindsAllFiles() throws {
        for file in ToolsPackage.companionFiles {
            try "content".write(to: tempDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        let entries = ToolsPackage.collectCompanionEntries(in: tempDir)
        XCTAssertEqual(entries, ToolsPackage.companionFiles)
    }

    func testCollectCompanionEntriesFindsWebDirectory() throws {
        let webDir = tempDir.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        try "html".write(to: webDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let entries = ToolsPackage.collectCompanionEntries(in: tempDir)
        XCTAssertEqual(entries, ["web"])
    }

    func testCollectCompanionEntriesIgnoresWebFile() throws {
        try "not a directory".write(to: tempDir.appendingPathComponent("web"), atomically: true, encoding: .utf8)

        let entries = ToolsPackage.collectCompanionEntries(in: tempDir)
        XCTAssertTrue(entries.isEmpty, "A file named 'web' should not be included (must be a directory)")
    }

    func testCollectCompanionEntriesFindsAllTypes() throws {
        for file in ToolsPackage.companionFiles {
            try "content".write(to: tempDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let webDir = tempDir.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)

        let entries = ToolsPackage.collectCompanionEntries(in: tempDir)
        XCTAssertEqual(entries, ToolsPackage.companionFiles + ToolsPackage.companionDirs)
    }

    // MARK: - Find Dylibs

    func testFindDylibsInEmptyDirectory() throws {
        let dylibs = try ToolsPackage.findDylibs(in: tempDir)
        XCTAssertTrue(dylibs.isEmpty)
    }

    func testFindDylibsFindsOnlyDylibs() throws {
        try "".write(to: tempDir.appendingPathComponent("libplugin.dylib"), atomically: true, encoding: .utf8)
        try "".write(to: tempDir.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try "".write(to: tempDir.appendingPathComponent("libother.dylib"), atomically: true, encoding: .utf8)

        let dylibs = try ToolsPackage.findDylibs(in: tempDir)
        XCTAssertEqual(dylibs.sorted(), ["libother.dylib", "libplugin.dylib"])
    }

    func testFindDylibsIgnoresNonDylibExtensions() throws {
        try "".write(to: tempDir.appendingPathComponent("plugin.so"), atomically: true, encoding: .utf8)
        try "".write(to: tempDir.appendingPathComponent("plugin.a"), atomically: true, encoding: .utf8)
        try "".write(to: tempDir.appendingPathComponent("plugin.dylib.bak"), atomically: true, encoding: .utf8)

        let dylibs = try ToolsPackage.findDylibs(in: tempDir)
        XCTAssertTrue(dylibs.isEmpty)
    }
}
