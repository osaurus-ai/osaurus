// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Keychain data-protection round-trip")
struct KeychainDataProtectionTests {
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

    // The regression: `write(...)` used to delete the legacy copy with a query
    // that wasn't scoped to the legacy keychain. On an entitled app that delete
    // matched and removed the data-protection item it had just written, so every
    // later read returned errSecItemNotFound. The write path must therefore never
    // issue a delete — a lingering legacy copy is harmless because `read` checks
    // the data-protection keychain first and `delete` clears both keychains.
    @Test("write never deletes (so it cannot wipe the item it just wrote)")
    func writeDoesNotDelete() throws {
        let source = try Self.source("Services/Keychain/KeychainDataProtection.swift")
        let body = try Self.writeFunctionBody(in: source)
        // Strip line comments so prose that mentions the call (e.g. the comment
        // explaining why it must not happen) doesn't trip the check.
        let code = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex ..< comment.lowerBound]
            }
            .joined(separator: "\n")
        #expect(!code.contains("SecItemDelete"))
    }

    // Behavioral guard: a value written through the helper must read back
    // unchanged. This exercises whichever backend is active in this process
    // (legacy when un-entitled, data-protection when entitled). When no keychain
    // backend is writable — e.g. a barren CI runner — `write` returns false and
    // the round-trip assertion is skipped rather than failing spuriously.
    @Test("a written value survives and reads back")
    func valueSurvivesWrite() {
        let service = "ai.osaurus.test.dp"
        let account = "roundtrip-\(UUID().uuidString)"
        let secret = Data("s3cr3t-\(UUID().uuidString)".utf8)
        defer { KeychainDataProtection.delete(service: service, account: account) }

        guard KeychainDataProtection.write(service: service, account: account, data: secret) else {
            return  // No writable keychain backend in this environment.
        }

        #expect(KeychainDataProtection.read(service: service, account: account) == secret)
    }
}
