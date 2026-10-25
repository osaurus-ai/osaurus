import CryptoKit
import Darwin
import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct EncryptedSQLiteOpenerOwnershipTests {
    private func withDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-opener-ownership-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("test.sqlite"))
    }

    // Restrict observations to this test's unique file, including WAL/SHM.
    // Other concurrently running suites can open unrelated descriptors.
    private func descriptors(for database: URL) throws -> Int {
        let prefix = database.resolvingSymlinksInPath().path
        return (0 ..< getdtablesize()).filter { descriptor in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = path.withUnsafeMutableBufferPointer {
                fcntl(descriptor, F_GETPATH, $0.baseAddress!)
            }
            guard result == 0 else { return false }
            let value = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
            return value == prefix || value == prefix + "-wal" || value == prefix + "-shm"
        }.count
    }

    private func seed(_ path: URL, key: SymmetricKey?) throws {
        let connection = try EncryptedSQLiteOpener.open(path: path.path, key: key)
        defer { sqlite3_close(connection) }
        #expect(
            sqlite3_exec(connection, "CREATE TABLE value(x); INSERT INTO value VALUES(42)", nil, nil, nil) == SQLITE_OK
        )
        #expect(try descriptors(for: path) > 0, "Descriptor oracle must see a live connection")
    }

    @Test func wrongKeyFailuresReleaseConnectionsAndPermitRecovery() throws {
        try withDatabase { path in
            let good = SymmetricKey(data: Data(repeating: 0x42, count: 32))
            let bad = SymmetricKey(data: Data(repeating: 0x43, count: 32))
            try seed(path, key: good)
            #expect(try descriptors(for: path) == 0)
            for _ in 0 ..< 25 {
                do {
                    let unexpected = try EncryptedSQLiteOpener.open(path: path.path, key: bad)
                    sqlite3_close(unexpected)
                    Issue.record("Wrong key unexpectedly passed verification")
                } catch EncryptedSQLiteError.keyVerificationFailed {
                    // Verify the failure stage as well as connection ownership.
                }
            }
            #expect(try descriptors(for: path) == 0)
            let recovered = try EncryptedSQLiteOpener.open(path: path.path, key: good)
            #expect(try descriptors(for: path) > 0)
            #expect(sqlite3_close(recovered) == SQLITE_OK)
            #expect(try descriptors(for: path) == 0)
        }
    }

    @Test func plaintextWithKeyFailuresReleaseConnections() throws {
        try withDatabase { path in
            try seed(path, key: nil)
            let key = SymmetricKey(data: Data(repeating: 0x44, count: 32))
            for _ in 0 ..< 25 {
                do {
                    let unexpected = try EncryptedSQLiteOpener.open(path: path.path, key: key)
                    sqlite3_close(unexpected)
                    Issue.record("Plaintext input unexpectedly passed key verification")
                } catch EncryptedSQLiteError.keyVerificationFailed {
                }
            }
            #expect(try descriptors(for: path) == 0)
            let recovered = try EncryptedSQLiteOpener.open(path: path.path, key: nil)
            #expect(sqlite3_close(recovered) == SQLITE_OK)
        }
    }

    @Test func pragmaFailuresReleaseConnections() throws {
        try withDatabase { path in
            try Data(repeating: 0xA5, count: 4096).write(to: path)
            for _ in 0 ..< 25 {
                do {
                    let unexpected = try EncryptedSQLiteOpener.open(path: path.path, key: nil)
                    sqlite3_close(unexpected)
                    Issue.record("Corrupt input unexpectedly passed WAL setup")
                } catch EncryptedSQLiteError.pragmaFailed {
                    // This specifically exercises post-open PRAGMA cleanup.
                }
            }
            #expect(try descriptors(for: path) == 0)
        }
    }

    @Test func successfulConnectionsStayOwnedByCaller() throws {
        try withDatabase { path in
            for pragmas in [false, true] {
                for foreignKeys in [false, true] {
                    let connection = try EncryptedSQLiteOpener.open(
                        path: path.path,
                        key: nil,
                        applyPerfPragmas: pragmas,
                        applyForeignKeys: foreignKeys
                    )
                    #expect(try descriptors(for: path) > 0)
                    #expect(sqlite3_exec(connection, "SELECT 1", nil, nil, nil) == SQLITE_OK)
                    #expect(sqlite3_close(connection) == SQLITE_OK)
                    #expect(try descriptors(for: path) == 0)
                }
            }
        }
    }
}
