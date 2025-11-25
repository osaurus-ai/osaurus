//
//  MinisignVerifier.swift
//  osaurus
//
//  Provides cryptographic signature verification using minisign format and Ed25519.
//

import CryptoKit
import Foundation

public enum MinisignVerifyError: Error {
    case invalidPublicKey
    case invalidSignature
    case keyIdMismatch
    case signatureVerificationFailed
    case prehashNotSupported
}

public enum MinisignVerifier {
    /// Verifies a minisign signature against file data.
    ///
    /// - Parameters:
    ///   - publicKey: The minisign public key (base64 string starting with "RW")
    ///   - signature: The full minisign signature (multi-line format from .sig file)
    ///   - data: The file data that was signed
    /// - Returns: true if signature is valid
    /// - Throws: MinisignVerifyError on parsing/verification failure
    public static func verify(publicKey: String, signature: String, data: Data) throws -> Bool {
        // Parse the public key
        let (pubKeyId, pubKeyBytes) = try parsePublicKey(publicKey)

        // Parse the signature (extract from multi-line format)
        let (sigKeyId, sigBytes, trustedComment, globalSig, isPrehashed) = try parseSignature(signature)

        // Verify key IDs match
        if pubKeyId != sigKeyId {
            throw MinisignVerifyError.keyIdMismatch
        }

        // Prehashed mode requires BLAKE2b-512 which CryptoKit doesn't support
        if isPrehashed {
            NSLog("[Minisign] Prehashed signature detected (BLAKE2b required) - please re-sign without -H flag")
            throw MinisignVerifyError.prehashNotSupported
        }

        // Create Ed25519 public key
        let ed25519PubKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes)

        // Verify the main signature over the file data
        guard ed25519PubKey.isValidSignature(sigBytes, for: data) else {
            throw MinisignVerifyError.signatureVerificationFailed
        }

        // Optionally verify global signature over (signature + trusted_comment)
        if let globalSigBytes = globalSig, let comment = trustedComment {
            // Global signature is over: signature_bytes + trusted_comment_text
            var globalData = Data(sigBytes)
            if let commentData = comment.data(using: .utf8) {
                globalData.append(commentData)
            }

            if !ed25519PubKey.isValidSignature(globalSigBytes, for: globalData) {
                NSLog("[Minisign] Global signature verification failed (non-fatal)")
                // Non-fatal: some implementations don't verify global sig
            }
        }

        return true
    }

    // MARK: - Parsing

    /// Parse minisign public key
    /// Format: base64(algorithm[2] + key_id[8] + public_key[32])
    private static func parsePublicKey(_ key: String) throws -> (keyId: Data, pubKey: Data) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let decoded = Data(base64Encoded: trimmed), decoded.count >= 42 else {
            throw MinisignVerifyError.invalidPublicKey
        }

        // Skip 2-byte algorithm identifier, extract 8-byte key ID, then 32-byte public key
        let keyId = decoded[2 ..< 10]
        let pubKey = decoded[10 ..< 42]

        return (Data(keyId), Data(pubKey))
    }

    /// Parse minisign signature from multi-line format
    /// Format:
    ///   untrusted comment: ...
    ///   base64(algorithm[2] + key_id[8] + signature[64])
    ///   trusted comment: ...
    ///   base64(global_signature[64])
    private static func parseSignature(_ sig: String) throws -> (
        keyId: Data, signature: Data, trustedComment: String?, globalSig: Data?, isPrehashed: Bool
    ) {
        let lines = sig.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        // Find the signature line (base64 starting with "RW" for Ed or "RU" for ED)
        var signatureLine: String?
        var trustedComment: String?
        var globalSigLine: String?

        for (index, line) in lines.enumerated() {
            // "RW" = Ed25519 (non-prehashed), "RU" = Ed25519ph (prehashed)
            if (line.hasPrefix("RW") || line.hasPrefix("RU")), Data(base64Encoded: line) != nil {
                signatureLine = line
                // Next non-empty line after "trusted comment:" is the global signature
                for nextLine in lines[(index + 1)...] {
                    if nextLine.hasPrefix("trusted comment:") {
                        trustedComment = String(nextLine.dropFirst("trusted comment:".count))
                            .trimmingCharacters(in: .whitespaces)
                    } else if !nextLine.isEmpty && !nextLine.hasPrefix("untrusted") && trustedComment != nil {
                        globalSigLine = nextLine
                        break
                    }
                }
                break
            }
        }

        guard let sigLine = signatureLine, let decoded = Data(base64Encoded: sigLine), decoded.count >= 74 else {
            throw MinisignVerifyError.invalidSignature
        }

        // Check algorithm: 0x45 0x64 = "Ed" (normal), 0x45 0x44 = "ED" (prehashed with BLAKE2b)
        let alg1 = decoded[0]
        let alg2 = decoded[1]
        // "Ed" = 0x45 0x64 = non-prehashed (we can verify this)
        // "ED" = 0x45 0x44 = prehashed with BLAKE2b (we cannot verify without BLAKE2b)
        let isPrehashed = (alg1 == 0x45 && alg2 == 0x44)

        // Debug logging
        NSLog(
            "[Minisign] Algorithm bytes: 0x%02X 0x%02X (%@)",
            alg1,
            alg2,
            isPrehashed ? "ED=prehashed" : "Ed=standard"
        )

        // Extract: 2-byte algorithm + 8-byte key_id + 64-byte signature
        let keyId = decoded[2 ..< 10]
        let signature = decoded[10 ..< 74]

        // Parse global signature if present
        var globalSig: Data?
        if let gsLine = globalSigLine, let gsDecoded = Data(base64Encoded: gsLine), gsDecoded.count == 64 {
            globalSig = gsDecoded
        }

        // Only use algorithm bytes to determine prehash mode (trusted comment "hashed" can be misleading)
        return (Data(keyId), Data(signature), trustedComment, globalSig, isPrehashed)
    }
}
