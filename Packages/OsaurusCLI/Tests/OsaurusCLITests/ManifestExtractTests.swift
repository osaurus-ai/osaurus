//
//  ManifestExtractTests.swift
//  osaurus
//
//  Tests for manifest extraction from plugin dylibs (ManifestExtract).
//

import XCTest
@testable import OsaurusCLICore

final class ManifestExtractTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-manifest-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Error Cases

    func testExtractFromNonexistentFileThrowsFileNotFound() {
        let fakePath = tempDir.appendingPathComponent("nonexistent.dylib").path

        XCTAssertThrowsError(try ManifestExtract.extractManifest(from: fakePath)) { error in
            guard let extractionError = error as? ManifestExtract.ExtractionError else {
                XCTFail("Expected ExtractionError, got \(type(of: error))")
                return
            }
            if case .fileNotFound(let path) = extractionError {
                XCTAssertTrue(path.contains("nonexistent.dylib"))
            } else {
                XCTFail("Expected .fileNotFound, got \(extractionError)")
            }
        }
    }

    func testExtractFromInvalidFileThrowsLoadFailed() throws {
        let fakeDylib = tempDir.appendingPathComponent("fake.dylib")
        try "not a real dylib".write(to: fakeDylib, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ManifestExtract.extractManifest(from: fakeDylib.path)) { error in
            guard let extractionError = error as? ManifestExtract.ExtractionError else {
                XCTFail("Expected ExtractionError, got \(type(of: error))")
                return
            }
            if case .loadFailed = extractionError {
                // Expected
            } else {
                XCTFail("Expected .loadFailed, got \(extractionError)")
            }
        }
    }

    func testExtractFromDylibWithoutEntryPointThrowsMissingEntryPoint() throws {
        let candidates = ["/usr/lib/libgmalloc.dylib", "/usr/lib/libffi-trampolines.dylib", "/usr/lib/libz.dylib"]
        guard let systemDylib = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("No suitable system dylib found for testing")
        }

        XCTAssertThrowsError(try ManifestExtract.extractManifest(from: systemDylib)) { error in
            guard let extractionError = error as? ManifestExtract.ExtractionError else {
                XCTFail("Expected ExtractionError, got \(type(of: error))")
                return
            }
            if case .missingEntryPoint = extractionError {
                // Expected
            } else {
                XCTFail("Expected .missingEntryPoint, got \(extractionError)")
            }
        }
    }

    // MARK: - Error Descriptions

    func testErrorDescriptions() {
        let cases: [(ManifestExtract.ExtractionError, String)] = [
            (.fileNotFound("/path/to/file"), "Файл не найден: /path/to/file"),
            (.loadFailed("bad format"), "Не удалось загрузить dylib: bad format"),
            (.missingEntryPoint, "Не найдена точка входа плагина (osaurus_plugin_entry или osaurus_plugin_entry_v2)"),
            (.entryReturnedNull, "Точка входа плагина вернула null"),
            (.initFailed, "Не удалось инициализировать плагин"),
            (.manifestFailed, "Не удалось получить манифест"),
        ]

        for (error, expected) in cases {
            XCTAssertEqual(error.description, expected)
        }
    }
}
