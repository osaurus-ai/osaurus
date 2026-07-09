//
//  ImageSourceValidationTests.swift
//  osaurusTests
//
//  Pins `ImageSubagentKind.loadSourceImages` input-error mapping: every bad
//  source path must surface as `NativeImageToolInputError` (→ the tool's
//  `invalid_args` envelope) — never a raw Cocoa error (→ `execution_error`),
//  which would tell the calling model the edit subsystem broke instead of
//  "fix your path". Observed live: a non-existent source path threw
//  NSCocoaErrorDomain 260 from `resourceValues` before the isRegularFile
//  guard could run, failing subagent.image-edit-routing.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Image edit source validation")
struct ImageSourceValidationTests {

    @Test("a non-existent source path maps to notAFile, not a Cocoa error")
    func missingFileIsInputError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-missing-\(UUID().uuidString).png").path
        #expect(throws: NativeImageToolInputError.self) {
            _ = try ImageSubagentKind.loadSourceImages(paths: [missing])
        }
    }

    @Test("a directory path maps to notAFile")
    func directoryIsInputError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dir-not-image-\(UUID().uuidString).png", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: NativeImageToolInputError.self) {
            _ = try ImageSubagentKind.loadSourceImages(paths: [dir.path])
        }
    }

    @Test("an existing valid image file loads")
    func validFileLoads() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiny-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let loaded = try ImageSubagentKind.loadSourceImages(paths: [file.path])
        #expect(loaded.count == 1)
    }
}
