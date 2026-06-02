//
//  ResolvePathScopeTests.swift
//  osaurusTests
//
//  Pins the folder path contract in `FolderToolHelpers.resolvePath`. The
//  contract is load-bearing for combined sandbox + host-read mode: the
//  host read tools (`file_read` / `file_search`) must stay strictly
//  under the selected folder root. Lexical `..` containment was
//  already enforced; these tests lock in symlink-safe containment so a
//  symlink *inside* the root can't be followed out of scope on read.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ResolvePathScopeTests {

    private func makeRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-resolvepath-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func resolvesOrdinaryRelativePathUnderRoot() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("src/app.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "let x = 1".write(to: file, atomically: true, encoding: .utf8)

        let resolved = try FolderToolHelpers.resolvePath("src/app.swift", rootPath: root)
        #expect(resolved.lastPathComponent == "app.swift")
    }

    @Test func rejectsDotDotEscape() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: FolderToolError.self) {
            _ = try FolderToolHelpers.resolvePath("../../etc/passwd", rootPath: root)
        }
    }

    @Test func rejectsSymlinkEscapingRoot() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // A secret that lives OUTSIDE the selected folder.
        let outside = makeRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("id_rsa")
        try "PRIVATE KEY".write(to: secret, atomically: true, encoding: .utf8)

        // A benign-looking symlink INSIDE the root pointing at it.
        let link = root.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        // Lexical containment passes (the link path is under root), but the
        // real target escapes — so resolvePath must reject it.
        #expect(throws: FolderToolError.self) {
            _ = try FolderToolHelpers.resolvePath("notes.txt", rootPath: root)
        }
    }

    @Test func allowsSymlinkStayingWithinRoot() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("real.txt")
        try "hello".write(to: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // A symlink whose real target is still under the root is fine.
        let resolved = try FolderToolHelpers.resolvePath("alias.txt", rootPath: root)
        #expect(resolved.lastPathComponent == "alias.txt")
    }

    @Test func allowsNotYetCreatedFileUnderRealDirectory() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("out"),
            withIntermediateDirectories: true
        )

        // Write/edit targets that don't exist yet must still resolve as long
        // as their existing parent is under the root.
        let resolved = try FolderToolHelpers.resolvePath("out/new.txt", rootPath: root)
        #expect(resolved.lastPathComponent == "new.txt")
    }
}
