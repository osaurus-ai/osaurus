//
//  PKCE.swift
//  osaurus
//
//  Shared OAuth 2.1 PKCE + state helpers for both ChatGPT/Codex and MCP providers.
//
//  Implementation notes:
//  - The verifier is `BASE64URL(random[32])`, so it lands at 43 ASCII chars
//    (matches the RFC 7636 minimum). Some servers reject anything shorter.
//  - The challenge is `BASE64URL(SHA256(ASCII(verifier)))` — note we hash the
//    *encoded* verifier string's UTF-8 bytes, not the raw random bytes. The
//    Codex flow used the same convention; keep parity so both paths share
//    one implementation.
//

import CryptoKit
import Foundation
import Security

public enum PKCEError: Error, Sendable {
    case randomFailed
}

public struct PKCEPair: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }
}

public enum PKCE {
    /// Generates a (verifier, challenge) pair using S256.
    public static func makePair() throws -> PKCEPair {
        var random = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        guard status == errSecSuccess else { throw PKCEError.randomFailed }

        let verifier = base64URLEncoded(Data(random))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncoded(Data(digest))
        return PKCEPair(verifier: verifier, challenge: challenge)
    }

    /// 16 random bytes hex-encoded — used as the OAuth `state` value to defend against CSRF.
    public static func makeState() -> String {
        var random = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        return random.map { String(format: "%02x", $0) }.joined()
    }

    /// Standard OAuth base64url encoder (no padding).
    public static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url string back to bytes (handles missing padding).
    public static func decodeBase64URL(_ value: String) -> Data? {
        var base64 =
            value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: base64)
    }
}
