//
//  SQLCipherIntegrationTests.swift
//  osaurusTests
//
//  Confirms the vendored OsaurusSQLCipher target is alive and
//  behaves as expected under our `EncryptedSQLiteOpener`:
//
//  - Open with key, write a row, close, reopen with same key, read it back.
//  - Reopen with a wrong key fails the verification step.
//  - `cipher_version` reports a 4.x SQLCipher build.
//  - `isEncryptedDatabase` correctly distinguishes plaintext vs encrypted files.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SQLCipherIntegrationTests {

    private func tempDBPath(_ name: String = "sqlcipher-test.sqlite") -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-sqlcipher-tests-\(UUID().uuidString)"
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name).path
    }

    private func key(seed: UInt8) -> SymmetricKey {
        SymmetricKey(data: Data(repeating: seed, count: 32))
    }

    @Test
    func openWriteReadRoundTrip() throws {
        let path = tempDBPath()
        let k = key(seed: 0x42)

        let conn = try EncryptedSQLiteOpener.open(path: path, key: k)
        try execute(conn, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        try execute(conn, "INSERT INTO notes (body) VALUES ('the password is correct horse battery staple')")
        sqlite3_close(conn)

        let conn2 = try EncryptedSQLiteOpener.open(path: path, key: k)
        defer { sqlite3_close(conn2) }

        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(conn2, "SELECT body FROM notes ORDER BY id LIMIT 1", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        let body = String(cString: sqlite3_column_text(stmt, 0))
        #expect(body == "the password is correct horse battery staple")
    }

    @Test
    func wrongKeyFailsToOpen() throws {
        let path = tempDBPath()
        let goodKey = key(seed: 0x01)
        let badKey = key(seed: 0x02)

        let conn = try EncryptedSQLiteOpener.open(path: path, key: goodKey)
        try execute(conn, "CREATE TABLE x (a INTEGER)")
        sqlite3_close(conn)

        #expect(throws: EncryptedSQLiteError.self) {
            _ = try EncryptedSQLiteOpener.open(path: path, key: badKey)
        }
    }

    @Test
    func cipherVersionIsFourPointX() throws {
        let path = tempDBPath()
        let conn = try EncryptedSQLiteOpener.open(path: path, key: key(seed: 0x55))
        defer { sqlite3_close(conn) }

        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(conn, "PRAGMA cipher_version", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            Issue.record("cipher_version pragma returned no row — vendored SQLCipher missing?")
            return
        }
        let version = String(cString: sqlite3_column_text(stmt, 0))
        #expect(version.hasPrefix("4."), "cipher_version was '\(version)', expected 4.x")
    }

    @Test
    func plaintextVsEncryptedDetection() throws {
        // Write a plaintext sqlite by opening with key=nil.
        let plainPath = tempDBPath("plain.sqlite")
        let plainConn = try EncryptedSQLiteOpener.open(path: plainPath, key: nil)
        try execute(plainConn, "CREATE TABLE p (a INTEGER)")
        sqlite3_close(plainConn)
        #expect(!EncryptedSQLiteOpener.isEncryptedDatabase(path: plainPath))

        let encPath = tempDBPath("enc.sqlite")
        let encConn = try EncryptedSQLiteOpener.open(path: encPath, key: key(seed: 0x77))
        try execute(encConn, "CREATE TABLE e (a INTEGER)")
        sqlite3_close(encConn)
        #expect(EncryptedSQLiteOpener.isEncryptedDatabase(path: encPath))
    }

    // MARK: - Helpers

    private func execute(_ conn: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(conn, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw NSError(domain: "test", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
