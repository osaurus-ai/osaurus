// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Keychain round-trip")
struct KeychainTests {
    private static func packageRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Service/
        cursor.deleteLastPathComponent()  // Tests/
        return cursor.deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = packageRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Returns the body of `static func write(...)` up to the next `static func`.
    private static func writeFunctionBody(in source: String) throws -> String {
        let start = try #require(source.range(of: "static func write("))
        let rest = source[start.lowerBound...]
        let nextFunc = try #require(rest.range(of: "static func read("))
        return String(source[start.lowerBound ..< nextFunc.lowerBound])
    }

    // `write` upserts (SecItemUpdate then SecItemAdd) and must never delete:
    // a stray delete in the write path would wipe the value it just stored.
    @Test("write never deletes (so it cannot wipe the item it just wrote)")
    func writeDoesNotDelete() throws {
        let source = try Self.source("Services/Keychain/Keychain.swift")
        let body = try Self.writeFunctionBody(in: source)
        let code =
            body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex ..< comment.lowerBound]
            }
            .joined(separator: "\n")
        #expect(!code.contains("SecItemDelete"))
    }

    // A value written through the helper must read back unchanged. When no
    // keychain backend is writable — e.g. a barren CI runner — `write` returns
    // false and the round-trip assertion is skipped rather than failing.
    @Test("a written value survives and reads back")
    func valueSurvivesWrite() {
        let service = "ai.osaurus.test.keychain"
        let account = "roundtrip-\(UUID().uuidString)"
        let secret = Data("s3cr3t-\(UUID().uuidString)".utf8)
        defer { Keychain.delete(service: service, account: account) }

        guard Keychain.write(service: service, account: account, data: secret) else {
            return  // No writable keychain backend in this environment.
        }

        #expect(Keychain.read(service: service, account: account) == secret)
    }
}
