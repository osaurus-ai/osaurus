//
//  MasterKeyMnemonic.swift
//  osaurus
//
//  BIP39-compatible 24-word mnemonic backup of the 32-byte secp256k1 Master Key.
//
//  This is the local restore path: the recovery code in `RecoveryManager` is a
//  one-shot server-side claim token and cannot rebuild the local master.
//  The mnemonic generated here CAN, because it round-trips the actual entropy.
//
//  The wordlist is the canonical English BIP39 wordlist (2048 words) shipped
//  as a bundle resource at `Resources/Identity/bip39-english.txt`.
//

import CryptoKit
import Foundation

public enum MasterKeyMnemonic {

    // MARK: - Encode

    /// Compute the 24-word BIP39 mnemonic for a 32-byte master key.
    ///
    /// Algorithm (BIP39 §3): 256 bits of entropy, then append the high 8 bits of
    /// SHA-256(entropy) as a checksum (256 + 8 = 264 bits = 24 × 11), split into
    /// 24 11-bit big-endian indices into the 2048-word wordlist.
    public static func mnemonic(forKey key: Data) throws -> [String] {
        guard key.count == 32 else {
            throw OsaurusIdentityError.signingFailed
        }

        let words = parsed.words
        var combined = Data(key)
        combined.append(checksumByte(of: key))

        return (0 ..< 24).map { chunk in
            words[extractBits(from: combined, bitOffset: chunk * 11, bitCount: 11)]
        }
    }

    // MARK: - Decode

    /// Recover the 32-byte master key from a 24-word BIP39 mnemonic. Validates
    /// word-list membership and the embedded SHA-256 checksum.
    public static func key(fromMnemonic words: [String]) throws -> Data {
        guard words.count == 24 else {
            throw OsaurusIdentityError.mnemonicInvalidWordCount
        }

        let lookup = parsed.lookup

        var combined = Data(count: 33)
        for (chunk, rawWord) in words.enumerated() {
            let word = rawWord.lowercased()
            guard let index = lookup[word] else {
                throw OsaurusIdentityError.mnemonicUnknownWord(rawWord)
            }
            insertBits(value: index, bitOffset: chunk * 11, bitCount: 11, into: &combined)
        }

        let entropy = Data(combined.prefix(32))
        let storedChecksum = combined[combined.startIndex + 32]
        guard storedChecksum == checksumByte(of: entropy) else {
            throw OsaurusIdentityError.mnemonicChecksumFailed
        }

        return entropy
    }

    /// Convenience: split a free-form user-entered phrase into normalized words.
    public static func words(fromPhrase phrase: String) -> [String] {
        phrase
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
    }

    /// Public for callers that want to validate against the wordlist (e.g. live
    /// per-word validation in the recovery sheet).
    public static func contains(_ word: String) -> Bool {
        parsed.lookup[word.lowercased()] != nil
    }

    public static var wordlist: [String] { parsed.words }

    // MARK: - Wordlist Loading

    /// Eagerly parsed once at first access. Loaded from the bundle and cached
    /// for the lifetime of the process. `static let` is concurrency-safe under
    /// Swift 6, so no extra synchronization is required.
    private static let parsed: (words: [String], lookup: [String: Int]) = {
        guard
            let url = Bundle.module.url(
                forResource: "bip39-english",
                withExtension: "txt",
                subdirectory: "Identity"
            )
                ?? Bundle.module.url(
                    forResource: "bip39-english",
                    withExtension: "txt"
                )
        else {
            fatalError("BIP39 wordlist resource missing from OsaurusCore bundle")
        }

        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Failed to read BIP39 wordlist: \(error)")
        }

        let words = raw.split(whereSeparator: \.isNewline).map(String.init)
        guard words.count == 2048 else {
            fatalError("BIP39 wordlist must contain exactly 2048 entries, got \(words.count)")
        }

        var lookup: [String: Int] = [:]
        lookup.reserveCapacity(2048)
        for (index, word) in words.enumerated() {
            lookup[word] = index
        }
        return (words, lookup)
    }()

    // MARK: - Bit Packing

    /// Read `bitCount` bits (≤ 11, big-endian) starting at `bitOffset` from `data`.
    private static func extractBits(from data: Data, bitOffset: Int, bitCount: Int) -> Int {
        var value = 0
        for i in 0 ..< bitCount {
            let bit = bitOffset + i
            let byte = data[data.startIndex + (bit / 8)]
            let on = (byte >> UInt8(7 - (bit % 8))) & 1
            value = (value << 1) | Int(on)
        }
        return value
    }

    /// Write the low `bitCount` bits of `value` (≤ 11, big-endian) starting at
    /// `bitOffset` in `data`. Caller is responsible for sizing `data`.
    private static func insertBits(value: Int, bitOffset: Int, bitCount: Int, into data: inout Data) {
        for i in 0 ..< bitCount {
            let bit = bitOffset + i
            let mask = UInt8(1 << (7 - (bit % 8)))
            let byteIndex = data.startIndex + (bit / 8)
            if (value >> (bitCount - 1 - i)) & 1 == 1 {
                data[byteIndex] |= mask
            } else {
                data[byteIndex] &= ~mask
            }
        }
    }

    /// First byte of SHA-256(entropy). The BIP39 checksum for a 256-bit entropy
    /// is exactly 8 bits, so we only need the high byte of the digest.
    private static func checksumByte(of entropy: Data) -> UInt8 {
        // SHA256Digest is a Sequence<UInt8>; drop into Array to index it.
        let digest = SHA256.hash(data: entropy)
        return Array(digest)[0]
    }
}
