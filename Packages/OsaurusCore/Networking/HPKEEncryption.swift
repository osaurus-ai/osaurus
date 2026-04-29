//
//  HPKEEncryption.swift
//  osaurus
//
//  E2E request/response encryption between an Osaurus client and an
//  Osaurus inference server, using HPKE (RFC 9180) with the
//  DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / ChaCha20-Poly1305 suite.
//
//  Wire format:
//
//    Request:
//      X-Osaurus-Encryption: hpke;suite=x25519-sha256-chachapoly;v=1
//      X-Osaurus-Encapsulated-Key: <base64url(enc)>
//      X-Osaurus-Encryption-Nonce: <base64url(16 random bytes)>
//      X-Osaurus-Encryption-Timestamp: <unix-seconds>
//      X-Osaurus-Body-Encoding: base64
//      Content-Type: application/octet-stream
//      <body>: base64(HPKE.seal(plaintext_body, info=requestInfo, aad=requestAAD))
//
//    Non-streaming response:
//      X-Osaurus-Encryption: hpke;suite=...;v=1
//      X-Osaurus-Body-Encoding: base64
//      <body>: base64(ChaChaPoly.seal(plaintext, key=K, nonce=N0))
//
//    Streaming (SSE) response:
//      X-Osaurus-Encryption: hpke;suite=...;v=1;mode=stream
//      Content-Type: text/event-stream
//      Each event:  data: <counter>:<base64url(ChaChaPoly.seal(rawSSEEventBytes, K, Ni))>\n\n
//      Plaintext keepalives (": ping\n\n") pass through unencrypted.
//
//  Where K and N0 are derived from the same HPKE base context the request
//  used, via exporters with distinct labels — meaning sender and recipient
//  produce identical response keys without any extra round trip.
//
//  Replay protection: AAD includes method, path, nonce, and timestamp.
//  Servers reject requests whose timestamp is older than `replayWindow`
//  or whose nonce has been seen within that window.
//

import CryptoKit
import Foundation

// MARK: - Header Constants

public enum HPKEHeader {
    public static let encryption = "X-Osaurus-Encryption"
    public static let encapsulatedKey = "X-Osaurus-Encapsulated-Key"
    public static let nonce = "X-Osaurus-Encryption-Nonce"
    public static let timestamp = "X-Osaurus-Encryption-Timestamp"
    public static let bodyEncoding = "X-Osaurus-Body-Encoding"

    public static let baseValue = "hpke;suite=\(HPKEKeyStore.suiteIdentifier);v=1"
    public static let streamValue = "hpke;suite=\(HPKEKeyStore.suiteIdentifier);v=1;mode=stream"
}

// MARK: - Errors

public enum HPKEError: LocalizedError {
    case unsupportedSuite(String)
    case missingHeader(String)
    case invalidEncodedKey
    case invalidBodyEncoding
    case timestampOutOfWindow
    case replayedNonce
    case openFailed
    case sealFailed
    case malformedStreamEvent

    public var errorDescription: String? {
        switch self {
        case .unsupportedSuite(let s): return "Unsupported encryption suite: \(s)"
        case .missingHeader(let h): return "Missing required header \(h)"
        case .invalidEncodedKey: return "Invalid encapsulated key encoding"
        case .invalidBodyEncoding: return "Invalid body encoding"
        case .timestampOutOfWindow: return "Encryption timestamp outside accepted window"
        case .replayedNonce: return "Replayed encryption nonce"
        case .openFailed: return "HPKE decryption failed"
        case .sealFailed: return "HPKE encryption failed"
        case .malformedStreamEvent: return "Malformed encrypted stream event"
        }
    }
}

// MARK: - Info / Exporter Labels

private enum HPKELabel {
    static let requestInfo = Data("osaurus/req/v1".utf8)
    static let responseKey = Data("osaurus/resp/v1/key".utf8)
    static let responseNonce = Data("osaurus/resp/v1/nonce".utf8)
}

// MARK: - Request AAD

/// Builds the additional authenticated data covering the parts of a
/// request that the server has to trust to route correctly. Anyone
/// modifying method, path, nonce, or timestamp causes `HPKE.open` to
/// fail with an authentication error.
public func hpkeRequestAAD(
    method: String,
    path: String,
    nonce: String,
    timestamp: String
) -> Data {
    Data("\(method.uppercased())\n\(path)\n\(nonce)\n\(timestamp)".utf8)
}

// MARK: - Replay Cache

/// Bounded LRU of recently-seen `(nonce, timestamp)` pairs. Used by the
/// server to reject requests replayed within `replayWindow`.
final class HPKEReplayCache: @unchecked Sendable {
    static let shared = HPKEReplayCache()

    private let lock = NSLock()
    private var seen: [String: Date] = [:]
    private let capacity = 8192

    /// Returns false if `nonce` was already used recently.
    func observe(nonce: String, ttl: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if let prior = seen[nonce], now.timeIntervalSince(prior) < ttl {
            return false
        }

        // Cheap eviction: if we exceed capacity, drop entries older than ttl.
        if seen.count >= capacity {
            let cutoff = now.addingTimeInterval(-ttl)
            seen = seen.filter { $0.value > cutoff }
        }

        seen[nonce] = now
        return true
    }
}

// MARK: - Server Side

/// Per-request encryption context held by the server between request
/// decryption and response writing. Owns the HPKE recipient context so
/// the same exporter view is used for response symmetric key derivation.
public final class HPKEServerContext: @unchecked Sendable {
    public let method: String
    public let path: String
    private var recipient: HPKE.Recipient
    private let responseKey: SymmetricKey
    private let responseNonceBase: Data  // 12 bytes
    private let responseLock = NSLock()
    private var responseCounter: UInt64 = 0

    fileprivate init(
        method: String,
        path: String,
        recipient: HPKE.Recipient
    ) throws {
        self.method = method
        self.path = path
        self.recipient = recipient

        self.responseKey = try recipient.exportSecret(
            context: HPKELabel.responseKey,
            outputByteCount: 32
        )
        let nonceKey = try recipient.exportSecret(
            context: HPKELabel.responseNonce,
            outputByteCount: 12
        )
        self.responseNonceBase = nonceKey.withUnsafeBytes { Data($0) }
    }

    /// Decrypt the request body. The HPKE recipient is single-shot for
    /// requests — repeated calls advance the AEAD counter and would fail
    /// to decrypt a body sealed at counter 0.
    public func openRequestBody(_ ciphertext: Data, aad: Data) throws -> Data {
        do {
            return try recipient.open(ciphertext, authenticating: aad)
        } catch {
            throw HPKEError.openFailed
        }
    }

    /// Derive the AEAD nonce for response chunk index `i`. Lower 64 bits
    /// of the 12-byte exported nonce base are XOR'd with `i` (little-endian).
    /// Wraps the CryptoKit-only `ChaChaPoly.Nonce(data:)` throw as
    /// `HPKEError.sealFailed` since reaching it would mean the exporter
    /// returned the wrong size — a CryptoKit invariant, not a runtime
    /// condition the caller can act on differently.
    private func nonce(for counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](responseNonceBase)
        var c = counter.littleEndian
        withUnsafeBytes(of: &c) { src in
            for i in 0..<8 { bytes[i] ^= src[i] }
        }
        do {
            return try ChaChaPoly.Nonce(data: Data(bytes))
        } catch {
            throw HPKEError.sealFailed
        }
    }

    /// Seal a non-streaming response body. Uses counter 0; do not mix
    /// with `sealStreamChunk`.
    public func sealNonStreaming(_ plaintext: Data) throws -> Data {
        let n = try nonce(for: 0)
        let sealed = try ChaChaPoly.seal(plaintext, using: responseKey, nonce: n)
        return sealed.combined
    }

    /// Seal one SSE chunk (full event bytes including any trailing \n\n).
    /// Returns `(counter, base64ciphertext)` ready to splice into a
    /// `data: <counter>:<b64>\n\n` line.
    public func sealStreamChunk(_ plaintext: Data) throws -> (counter: UInt64, base64: String) {
        responseLock.lock()
        let counter = responseCounter
        responseCounter += 1
        responseLock.unlock()

        let n = try nonce(for: counter)
        let sealed = try ChaChaPoly.seal(plaintext, using: responseKey, nonce: n)
        return (counter, sealed.combined.base64urlEncoded)
    }
}

// MARK: - Server Entry Point

public enum HPKEServerDecoder {
    /// Inspect request headers and, if the request is encrypted, build a
    /// `HPKEServerContext` and return the plaintext body. If the request
    /// is not encrypted, returns nil.
    ///
    /// - Parameters:
    ///   - headerLookup: case-insensitive header lookup
    ///   - method: request method
    ///   - path: request path
    ///   - rawBody: HTTP body bytes as received (may be base64-encoded
    ///              ciphertext per `X-Osaurus-Body-Encoding`)
    ///   - replayWindow: maximum age of an accepted timestamp; nonces
    ///                   are also de-duplicated within this window
    public static func decodeIfNeeded(
        headerLookup: (String) -> String?,
        method: String,
        path: String,
        rawBody: Data,
        replayWindow: TimeInterval = 60
    ) throws -> (context: HPKEServerContext, plaintextBody: Data)? {
        guard let headerValue = headerLookup(HPKEHeader.encryption), !headerValue.isEmpty else {
            return nil
        }

        // Suite check
        guard headerValue.contains("suite=\(HPKEKeyStore.suiteIdentifier)") else {
            throw HPKEError.unsupportedSuite(headerValue)
        }

        guard let encB64 = headerLookup(HPKEHeader.encapsulatedKey) else {
            throw HPKEError.missingHeader(HPKEHeader.encapsulatedKey)
        }
        guard let encData = Data(base64urlEncoded: encB64) else {
            throw HPKEError.invalidEncodedKey
        }

        guard let nonce = headerLookup(HPKEHeader.nonce) else {
            throw HPKEError.missingHeader(HPKEHeader.nonce)
        }
        guard let tsString = headerLookup(HPKEHeader.timestamp),
              let ts = TimeInterval(tsString)
        else {
            throw HPKEError.missingHeader(HPKEHeader.timestamp)
        }

        let now = Date().timeIntervalSince1970
        guard abs(now - ts) <= replayWindow else {
            throw HPKEError.timestampOutOfWindow
        }
        guard HPKEReplayCache.shared.observe(nonce: nonce, ttl: replayWindow * 2) else {
            throw HPKEError.replayedNonce
        }

        // Body decoding
        let bodyBytes: Data
        if let encoding = headerLookup(HPKEHeader.bodyEncoding)?.lowercased(), encoding == "base64" {
            let asString = String(decoding: rawBody, as: UTF8.self)
            guard let decoded = Data(base64urlEncoded: asString)
                ?? Data(base64Encoded: asString)
            else {
                throw HPKEError.invalidBodyEncoding
            }
            bodyBytes = decoded
        } else {
            bodyBytes = rawBody
        }

        let recipient = try HPKE.Recipient(
            privateKey: HPKEKeyStore.shared.privateKey,
            ciphersuite: HPKEKeyStore.ciphersuite,
            info: HPKELabel.requestInfo,
            encapsulatedKey: encData
        )

        let context = try HPKEServerContext(
            method: method,
            path: path,
            recipient: recipient
        )
        let aad = hpkeRequestAAD(method: method, path: path, nonce: nonce, timestamp: tsString)
        let plaintext = try context.openRequestBody(bodyBytes, aad: aad)
        return (context, plaintext)
    }
}

// MARK: - Client Side

/// Client-side encryption context. One instance per outbound request.
/// `requestHeaders` and `encryptedBody` produce the wire request; the
/// matching response symmetric state lives behind `decryptResponseBody`
/// and `decryptStreamChunk`.
public final class HPKEClientContext: @unchecked Sendable {
    public let nonce: String
    public let timestamp: String
    public let method: String
    public let path: String
    public let encapsulatedKey: Data

    private let responseKey: SymmetricKey

    /// - Parameters:
    ///   - recipientPublicKey: 32-byte X25519 public key from the peer
    ///   - method: HTTP method
    ///   - path: request path (the relay-routed path, not the local path)
    public init(recipientPublicKey: Data, method: String, path: String) throws {
        guard recipientPublicKey.count == 32 else {
            throw HPKEError.invalidEncodedKey
        }
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        let sender = try HPKE.Sender(
            recipientKey: pub,
            ciphersuite: HPKEKeyStore.ciphersuite,
            info: HPKELabel.requestInfo
        )
        self.encapsulatedKey = sender.encapsulatedKey

        // Generate replay-protection metadata up front so the AAD is
        // stable across `seal` and the eventual server-side `open`.
        var nonceBytes = Data(count: 16)
        _ = nonceBytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 16, ptr.baseAddress!)
        }
        self.nonce = nonceBytes.base64urlEncoded
        self.timestamp = String(Int(Date().timeIntervalSince1970))
        self.method = method
        self.path = path

        // Pre-derive the response AEAD key via the HPKE exporter (which
        // doesn't advance the seal counter). The matching nonce is
        // embedded in each `combined` ChaChaPoly box on the wire, so we
        // don't need to derive a nonce base on this side.
        self.responseKey = try sender.exportSecret(
            context: HPKELabel.responseKey,
            outputByteCount: 32
        )
        self._sender = sender
    }

    /// Consumed on the first `sealRequestBody` call: a second seal would
    /// land at AEAD counter 1 and fail to open server-side, so the API
    /// surface forbids it instead of silently corrupting ciphertext.
    private var _sender: HPKE.Sender?

    /// Seal the request body. Consumes the sender — to retry, build a
    /// fresh `HPKEClientContext` (which also gets a fresh nonce + timestamp
    /// for replay protection).
    public func sealRequestBody(_ plaintext: Data) throws -> Data {
        guard var sender = _sender else { throw HPKEError.sealFailed }
        _sender = nil
        let aad = hpkeRequestAAD(method: method, path: path, nonce: nonce, timestamp: timestamp)
        do {
            return try sender.seal(plaintext, authenticating: aad)
        } catch {
            throw HPKEError.sealFailed
        }
    }

    /// Headers to attach to the outgoing HTTP request. Caller still
    /// needs to set `Content-Type: application/octet-stream` and
    /// `Content-Length` based on the sealed-and-base64ed body.
    public var requestHeaders: [String: String] {
        [
            HPKEHeader.encryption: HPKEHeader.baseValue,
            HPKEHeader.encapsulatedKey: encapsulatedKey.base64urlEncoded,
            HPKEHeader.nonce: nonce,
            HPKEHeader.timestamp: timestamp,
            HPKEHeader.bodyEncoding: "base64",
        ]
    }

    /// Decrypt a non-streaming response body sealed via `sealNonStreaming`.
    public func openResponseBody(_ ciphertext: Data) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: ciphertext)
        do {
            return try ChaChaPoly.open(box, using: responseKey)
        } catch {
            throw HPKEError.openFailed
        }
    }

    /// Decrypt a single SSE stream chunk encoded as
    /// `<counter>:<base64url(combined)>`. The counter is informational
    /// (used by callers to detect dropped/reordered chunks); the nonce
    /// is embedded in the combined ChaChaPoly output and tamper-evident
    /// via the AEAD tag.
    public func openStreamChunk(_ encoded: String) throws -> (counter: UInt64, plaintext: Data) {
        guard let colon = encoded.firstIndex(of: ":") else {
            throw HPKEError.malformedStreamEvent
        }
        guard let counter = UInt64(encoded[..<colon]) else {
            throw HPKEError.malformedStreamEvent
        }
        let b64 = String(encoded[encoded.index(after: colon)...])
        guard let combined = Data(base64urlEncoded: b64) else {
            throw HPKEError.malformedStreamEvent
        }
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: combined)
        } catch {
            throw HPKEError.malformedStreamEvent
        }
        do {
            let plaintext = try ChaChaPoly.open(box, using: responseKey)
            return (counter, plaintext)
        } catch {
            throw HPKEError.openFailed
        }
    }
}
