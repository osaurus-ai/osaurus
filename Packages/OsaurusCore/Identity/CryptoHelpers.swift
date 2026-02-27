//
//  CryptoHelpers.swift
//  osaurus
//
//  Low-level cryptographic helpers for Osaurus Identity:
//  Keccak-256, payload signing, and encoding utilities.
//

import CryptoKit
import Foundation
import P256K

// MARK: - Keccak-256

/// Pure-Swift Keccak-256 (pre-NIST variant, NOT SHA3-256).
/// Padding byte is 0x01, not 0x06.
enum Keccak256 {
    static let rate = 136
    static let outputLen = 32
    private static let rounds = 24

    static func hash(data: Data) -> Data {
        hash(bytes: [UInt8](data))
    }

    static func hash(bytes: [UInt8]) -> Data {
        var state = [UInt64](repeating: 0, count: 25)

        // Absorb
        var input = bytes
        // Pad: append 0x01, then zeros, then set high bit of last rate byte
        input.append(0x01)
        while input.count % rate != 0 {
            input.append(0x00)
        }
        input[input.count - 1] |= 0x80

        for offset in stride(from: 0, to: input.count, by: rate) {
            for i in 0 ..< (rate / 8) {
                let base = offset + i * 8
                var word: UInt64 = 0
                for b in 0 ..< 8 {
                    word |= UInt64(input[base + b]) << (b * 8)
                }
                state[i] ^= word
            }
            keccakF1600(&state)
        }

        // Squeeze
        var result = [UInt8](repeating: 0, count: outputLen)
        for i in 0 ..< (outputLen / 8) {
            let word = state[i]
            for b in 0 ..< 8 where i * 8 + b < outputLen {
                result[i * 8 + b] = UInt8((word >> (b * 8)) & 0xFF)
            }
        }
        return Data(result)
    }

    // MARK: Keccak-f[1600]

    private static let rotationOffsets: [Int] = [
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55,
        2, 14, 27, 41, 56, 8, 25, 43, 62, 18,
        39, 61, 20, 44,
    ]

    private static let piLane: [Int] = [
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21,
        24, 4, 15, 23, 19, 13, 12, 2, 20, 14,
        22, 9, 6, 1,
    ]

    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082,
        0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088,
        0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B,
        0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080,
        0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080,
        0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]

    private static func keccakF1600(_ state: inout [UInt64]) {
        for round in 0 ..< rounds {
            // θ (theta)
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0 ..< 5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            for x in 0 ..< 5 {
                let d = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1)
                for y in stride(from: 0, to: 25, by: 5) {
                    state[y + x] ^= d
                }
            }

            // ρ (rho) + π (pi)
            var current = state[1]
            for t in 0 ..< 24 {
                let j = piLane[t]
                let temp = state[j]
                state[j] = rotl64(current, rotationOffsets[t])
                current = temp
            }

            // χ (chi)
            for y in stride(from: 0, to: 25, by: 5) {
                var t = [UInt64](repeating: 0, count: 5)
                for x in 0 ..< 5 { t[x] = state[y + x] }
                for x in 0 ..< 5 {
                    state[y + x] = t[x] ^ (~t[(x + 1) % 5] & t[(x + 2) % 5])
                }
            }

            // ι (iota)
            state[0] ^= roundConstants[round]
        }
    }

    private static func rotl64(_ x: UInt64, _ n: Int) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }
}

// MARK: - Domain-Separated Hashing

/// Keccak-256 hash of a domain-prefixed payload: `\x19<prefix>:\n<len><payload>`.
/// Shared by signing and recovery so the envelope is constructed exactly once.
private func domainHash(payload: Data, prefix domainPrefix: String) throws -> Data {
    let header = "\u{19}\(domainPrefix):\n\(payload.count)"
    guard let headerData = header.data(using: .utf8) else {
        throw OsaurusIdentityError.signingFailed
    }
    return Keccak256.hash(data: headerData + payload)
}

// MARK: - Payload Signing

/// Domain-separated secp256k1 signing with recovery.
/// Returns a 65-byte recoverable signature (r || s || v).
private func signWithPrefix(_ payload: Data, privateKey: Data, prefix domainPrefix: String) throws -> Data {
    let hash = try domainHash(payload: payload, prefix: domainPrefix)
    let signingKey = try P256K.Recovery.PrivateKey(dataRepresentation: privateKey)
    let recoverySig = try signingKey.signature(for: HashDigest([UInt8](hash)))
    let compact = try recoverySig.compactRepresentation

    var result = compact.signature
    result.append(UInt8(compact.recoveryId + 27))
    return result
}

func signPayload(_ payload: Data, privateKey: Data) throws -> Data {
    try signWithPrefix(payload, privateKey: privateKey, prefix: "Osaurus Signed Message")
}

func signAccessPayload(_ payload: Data, privateKey: Data) throws -> Data {
    try signWithPrefix(payload, privateKey: privateKey, prefix: "Osaurus Signed Access")
}

// MARK: - Address Recovery (ecrecover)

/// Recover the signer's Osaurus address from a payload and its 65-byte recoverable signature.
/// The `domainPrefix` must match the prefix used during signing.
func recoverAddress(payload: Data, signature: Data, domainPrefix: String) throws -> OsaurusID {
    guard signature.count == 65 else {
        throw OsaurusIdentityError.signingFailed
    }

    let hash = try domainHash(payload: payload, prefix: domainPrefix)

    let compactSig = signature.prefix(64)
    let v = Int32(signature[signature.startIndex + 64]) - 27
    let recoverySig = try P256K.Recovery.ECDSASignature(
        compactRepresentation: compactSig,
        recoveryId: v
    )

    let pubKey = try P256K.Recovery.PublicKey(
        HashDigest([UInt8](hash)),
        signature: recoverySig,
        format: .uncompressed
    )

    let pubkeyBody = pubKey.dataRepresentation.dropFirst()
    let addressHash = Keccak256.hash(data: Data(pubkeyBody))
    let raw = addressHash.suffix(20).map { String(format: "%02x", $0) }.joined()
    return checksumEncode(raw: raw)
}

// MARK: - Address Derivation

/// Derive a checksummed Osaurus ID from a secp256k1 private key.
func deriveOsaurusId(from privateKey: Data) throws -> OsaurusID {
    let signingKey = try P256K.Signing.PrivateKey(
        dataRepresentation: privateKey,
        format: .uncompressed
    )
    let uncompressed = signingKey.publicKey.uncompressedRepresentation
    // Drop the 0x04 prefix, keccak256 the 64 remaining bytes, take last 20
    let pubkeyBody = uncompressed.dropFirst()
    let hash = Keccak256.hash(data: Data(pubkeyBody))
    let addressBytes = hash.suffix(20)
    let raw = addressBytes.map { String(format: "%02x", $0) }.joined()
    return checksumEncode(raw: raw)
}

/// Mixed-case checksum encoding for an Osaurus ID.
func checksumEncode(raw: String) -> String {
    let hashHex = Keccak256.hash(data: Data(raw.utf8))
        .map { String(format: "%02x", $0) }
        .joined()

    var result = "0x"
    for (i, char) in raw.enumerated() {
        let nibble = UInt8(hashHex[hashHex.index(hashHex.startIndex, offsetBy: i)].hexDigitValue ?? 0)
        result.append(nibble >= 8 ? char.uppercased() : String(char))
    }
    return result
}

// MARK: - Encoding Extensions

extension Data {
    /// Base64url encoding (no padding) per RFC 4648 §5.
    var base64urlEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url-encoded (no padding) string per RFC 4648 §5.
    init?(base64urlEncoded string: String) {
        var base64 =
            string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(contentsOf: String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }

    /// Initialize from a hex-encoded string.
    init?(hexEncoded string: String) {
        let chars = Array(string)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let high = chars[i].hexDigitValue,
                let low = chars[i + 1].hexDigitValue
            else { return nil }
            bytes.append(UInt8(high << 4 | low))
        }
        self.init(bytes)
    }

    /// Lowercase hex string.
    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
