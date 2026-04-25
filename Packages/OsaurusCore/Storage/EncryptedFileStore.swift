//
//  EncryptedFileStore.swift
//  osaurus
//
//  AES-GCM file encryption helper used for at-rest protection of JSON
//  configuration, archived sessions, attachment spillover blobs, and
//  any other small/medium artifact under `~/.osaurus/`.
//
//  Envelope format (binary):
//    [0]      — version byte (currently 0x01)
//    [1..12]  — 12-byte random nonce
//    [13..N]  — AES-GCM ciphertext + 16-byte tag
//
//  Encrypted files use the `.osec` extension so plaintext and ciphertext
//  cannot be confused during migration.
//
//  Threadsafe: stateless except for the shared `StorageKeyManager`
//  cached key. Reads/writes do their own atomic file IO.
//

import CryptoKit
import Foundation

public enum EncryptedFileStoreError: LocalizedError {
    case unsupportedVersion(UInt8)
    case truncatedEnvelope
    case decryptionFailed
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): return "Encrypted file uses unsupported envelope version \(v)"
        case .truncatedEnvelope: return "Encrypted file is too short to contain a valid envelope"
        case .decryptionFailed: return "Decryption failed (wrong key or tampered ciphertext)"
        case .encodingFailed: return "Failed to encode value to JSON"
        }
    }
}

/// AES-GCM based file store. All public methods are stateless wrappers
/// over the shared `StorageKeyManager`. Most callers should use the
/// extension that mirrors the JSON Codable read/write pattern.
public enum EncryptedFileStore {
    /// Encryption envelope version.
    public static let version: UInt8 = 0x01

    /// Standard suffix appended to plaintext file names.
    public static let suffix: String = ".osec"

    // MARK: - Raw bytes

    /// Encrypt and atomically write `data` to `url`. Caller owns the
    /// destination URL — extension should typically be `.osec`. Creates
    /// intermediate directories as needed.
    public static func write(_ data: Data, to url: URL, key: SymmetricKey? = nil) throws {
        let resolvedKey = try key ?? StorageKeyManager.shared.currentKey()
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(data, using: resolvedKey, nonce: nonce)
        var envelope = Data()
        envelope.reserveCapacity(1 + 12 + sealed.ciphertext.count + 16)
        envelope.append(version)
        envelope.append(contentsOf: nonce)
        envelope.append(sealed.ciphertext)
        envelope.append(sealed.tag)

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try envelope.write(to: url, options: [.atomic])
    }

    /// Read and decrypt `url`. Throws if the envelope is malformed or
    /// the tag doesn't validate (tamper detection).
    public static func read(_ url: URL, key: SymmetricKey? = nil) throws -> Data {
        let envelope = try Data(contentsOf: url)
        return try open(envelope: envelope, key: key)
    }

    /// Decrypt an in-memory envelope. Useful for tests and migration.
    public static func open(envelope: Data, key: SymmetricKey? = nil) throws -> Data {
        guard envelope.count >= 1 + 12 + 16 else {
            throw EncryptedFileStoreError.truncatedEnvelope
        }
        let v = envelope[envelope.startIndex]
        guard v == version else {
            throw EncryptedFileStoreError.unsupportedVersion(v)
        }
        let resolvedKey = try key ?? StorageKeyManager.shared.currentKey()

        let nonceStart = envelope.index(envelope.startIndex, offsetBy: 1)
        let nonceEnd = envelope.index(nonceStart, offsetBy: 12)
        let tagStart = envelope.index(envelope.endIndex, offsetBy: -16)

        let nonceData = envelope.subdata(in: nonceStart ..< nonceEnd)
        let ciphertext = envelope.subdata(in: nonceEnd ..< tagStart)
        let tag = envelope.subdata(in: tagStart ..< envelope.endIndex)

        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: resolvedKey)
        } catch {
            throw EncryptedFileStoreError.decryptionFailed
        }
    }

    /// Returns true when `data` looks like an EncryptedFileStore envelope
    /// (correct magic + sane length). Used by the migrator to skip
    /// already-encrypted files.
    public static func looksLikeEnvelope(_ data: Data) -> Bool {
        guard data.count >= 1 + 12 + 16 else { return false }
        return data.first == version
    }

    /// Returns true when `url` already points at an encrypted artifact
    /// (sniffs the first byte; doesn't validate the tag).
    public static func isEncryptedFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = try? handle.read(upToCount: 13)
        guard let bytes = head, bytes.count >= 13 else { return false }
        return bytes.first == version
    }

    // MARK: - JSON helpers

    /// Encode `value` as JSON and write encrypted to `url`.
    public static func writeJSON<T: Encodable>(_ value: T, to url: URL, key: SymmetricKey? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw EncryptedFileStoreError.encodingFailed
        }
        try write(data, to: url, key: key)
    }

    /// Read encrypted JSON and decode as `T`.
    public static func readJSON<T: Decodable>(_ url: URL, as type: T.Type, key: SymmetricKey? = nil) throws -> T {
        let plaintext = try read(url, key: key)
        return try JSONDecoder().decode(type, from: plaintext)
    }

    // MARK: - Path helpers

    /// Convert a plaintext URL to its encrypted twin (`foo.json` → `foo.json.osec`).
    public static func encryptedURL(for plaintextURL: URL) -> URL {
        plaintextURL.appendingPathExtension("osec")
    }

    /// Convert a `.osec` URL back to its plaintext analogue.
    public static func plaintextURL(for encryptedURL: URL) -> URL {
        guard encryptedURL.pathExtension == "osec" else { return encryptedURL }
        return encryptedURL.deletingPathExtension()
    }
}

// MARK: - Convenience: load preferring encrypted, fall back to plaintext

extension EncryptedFileStore {
    /// Try the `.osec` twin first; on failure, fall back to the
    /// plaintext file (used during migration when both may briefly
    /// coexist). Returns `nil` when neither is readable.
    public static func readWithLegacyFallback(plaintextURL: URL, key: SymmetricKey? = nil) -> Data? {
        let enc = encryptedURL(for: plaintextURL)
        if let data = try? read(enc, key: key) { return data }
        return try? Data(contentsOf: plaintextURL)
    }

    /// Try decoding from `.osec` first, then the plaintext file. Returns
    /// `nil` if neither is decodable as `T`.
    public static func readJSONWithLegacyFallback<T: Decodable>(
        _ plaintextURL: URL,
        as type: T.Type,
        key: SymmetricKey? = nil
    ) -> T? {
        let enc = encryptedURL(for: plaintextURL)
        if let value = try? readJSON(enc, as: type, key: key) { return value }
        guard let raw = try? Data(contentsOf: plaintextURL) else { return nil }
        return try? JSONDecoder().decode(type, from: raw)
    }
}
