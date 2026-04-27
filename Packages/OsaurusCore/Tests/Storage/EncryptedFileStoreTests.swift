//
//  EncryptedFileStoreTests.swift
//  osaurusTests
//
//  Round-trip + tamper detection for `EncryptedFileStore`. Uses an
//  inline-injected SymmetricKey via the DEBUG-only test hook so no
//  Keychain calls are needed.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

/// Intentionally NOT `@Suite(.serialized)`: every test allocates
/// its own UUID-named tempfile via `tempFile` and uses the inline
/// `makeKey()` constant — no `OsaurusPaths.overrideRoot` /
/// `StorageKeyManager.shared` access. Letting xcodebuild parallelize
/// these saves several seconds of wall-time on the macos-26 CI
/// runner, which is materially slower than local Apple Silicon.
struct EncryptedFileStoreTests {

    private func makeKey() -> SymmetricKey {
        // Stable test key — tests must be hermetic.
        SymmetricKey(data: Data((0 ..< 32).map { UInt8($0) }))
    }

    private func tempFile(_ name: String = "store-test.osec") -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-store-tests-\(UUID().uuidString)"
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    // MARK: - Round-trip

    @Test
    func writeAndReadRoundTripsBytes() throws {
        let url = tempFile()
        let key = makeKey()
        let payload = Data("hello osaurus encrypted store".utf8)

        try EncryptedFileStore.write(payload, to: url, key: key)
        let read = try EncryptedFileStore.read(url, key: key)

        #expect(read == payload)
    }

    @Test
    func writeAndReadJSONRoundTripsCodable() throws {
        struct Sample: Codable, Equatable { let id: Int; let name: String }
        let url = tempFile("sample.json.osec")
        let key = makeKey()
        let original = Sample(id: 7, name: "saurus")

        try EncryptedFileStore.writeJSON(original, to: url, key: key)
        let decoded = try EncryptedFileStore.readJSON(url, as: Sample.self, key: key)
        #expect(decoded == original)
    }

    @Test
    func envelopeIsRecognized() throws {
        let url = tempFile()
        let key = makeKey()
        try EncryptedFileStore.write(Data([0xAA, 0xBB]), to: url, key: key)
        #expect(EncryptedFileStore.isEncryptedFile(url))

        let plaintextURL = tempFile("plain.json")
        try Data("{\"x\":1}".utf8).write(to: plaintextURL)
        #expect(!EncryptedFileStore.isEncryptedFile(plaintextURL))
    }

    // MARK: - Tamper detection

    @Test
    func tamperedCiphertextThrows() throws {
        let url = tempFile()
        let key = makeKey()
        try EncryptedFileStore.write(Data("payload".utf8), to: url, key: key)

        var bytes = try Data(contentsOf: url)
        // Flip a byte deep in the ciphertext (after version + nonce).
        let target = bytes.startIndex + 13 + 4
        bytes[target] ^= 0xFF
        try bytes.write(to: url)

        #expect(throws: EncryptedFileStoreError.self) {
            _ = try EncryptedFileStore.read(url, key: key)
        }
    }

    @Test
    func wrongKeyFailsToDecrypt() throws {
        let url = tempFile()
        try EncryptedFileStore.write(Data("payload".utf8), to: url, key: makeKey())

        let wrongKey = SymmetricKey(data: Data(repeating: 0xFF, count: 32))
        #expect(throws: EncryptedFileStoreError.self) {
            _ = try EncryptedFileStore.read(url, key: wrongKey)
        }
    }

    @Test
    func truncatedFileThrows() throws {
        let url = tempFile()
        try Data([0x01, 0x02]).write(to: url)
        #expect(throws: EncryptedFileStoreError.self) {
            _ = try EncryptedFileStore.read(url, key: makeKey())
        }
    }

    @Test
    func legacyFallbackReadsPlaintextWhenEncryptedMissing() throws {
        let url = tempFile("config.json")
        let plaintext = Data("{\"v\":1}".utf8)
        try plaintext.write(to: url)
        let read = EncryptedFileStore.readWithLegacyFallback(plaintextURL: url, key: makeKey())
        #expect(read == plaintext)
    }
}
