//
//  OpenFolderPathTests.swift
//  OsaurusCoreTests — Computer Use
//
//  `open` accepts a folder path and opens it in a new front Finder window,
//  replacing sidebar/icon navigation that failed with several Finder windows
//  open. Only real, non-package directories resolve: a file would launch its
//  default app (and a script would run), and app names keep their old path.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class OpenFolderPathTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAbsoluteDirectoryResolves() {
        let url = openableFolderURL(forOpenIdentifier: tempDir.path)
        XCTAssertEqual(url?.standardizedFileURL.path, tempDir.standardizedFileURL.path)
    }

    func testFileURLDirectoryResolves() {
        XCTAssertNotNil(openableFolderURL(forOpenIdentifier: tempDir.absoluteString))
    }

    func testTildePathResolvesToHome() {
        let url = openableFolderURL(forOpenIdentifier: "~")
        XCTAssertEqual(url?.standardizedFileURL.path, (NSHomeDirectory() as NSString).standardizingPath)
    }

    func testFileIsNotOpenedAsFolder() throws {
        let script = tempDir.appendingPathComponent("run.command")
        try "echo hi".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertNil(openableFolderURL(forOpenIdentifier: script.path))
    }

    func testAppNamesAndMissingPathsDoNotResolve() {
        XCTAssertNil(openableFolderURL(forOpenIdentifier: "Finder"))
        XCTAssertNil(openableFolderURL(forOpenIdentifier: "com.apple.finder"))
        XCTAssertNil(openableFolderURL(forOpenIdentifier: tempDir.appendingPathComponent("missing").path))
    }
}
