//
//  SecureChannel.swift
//  osaurus
//
//  Osaurus Secure Channel v1 — end-to-end encryption for agent-to-agent
//  HTTP traffic (LAN Bonjour peers and the relay tunnel alike).
//
//  Design (SIGMA-style signed-ephemeral handshake):
//    1. Client sends an ephemeral X25519 public key + random nonce
//       (`ClientHello`, POST /secure/session).
//    2. Server replies with its own ephemeral X25519 key, a session id, an
//       expiry, and a secp256k1 agent-key signature over the full handshake
//       transcript (`ServerHello`). The client verifies the recovered signer
//       address against the agent address it pinned at pairing time, which
//       defeats man-in-the-middle servers (a MITM cannot sign the transcript
//       with the real agent key).
//    3. Both sides derive directional ChaCha20-Poly1305 keys via
//       HKDF-SHA256(X25519(eC, eS), salt: SHA256(transcript)).
//
//  Because both X25519 keys are ephemeral, the channel has forward secrecy:
//  compromising the long-term secp256k1 identity keys later never decrypts
//  recorded sessions. (This is why the channel is a handshake rather than
//  per-request HPKE base mode, which lacks forward secrecy.)
//
//  Framing:
//    - Each `/secure/call` request is one AEAD frame on the client→server key
//      with a session-monotonic sequence number; the server enforces a
//      sliding anti-replay window, so a captured call can never re-execute.
//    - Response frames (one for buffered JSON, many for SSE streams) use a
//      per-call key derived from the server→client key and the request
//      sequence, numbered 0,1,2,… with a strict in-order check and an
//      authenticated `fin` marker — reordering, replay, and silent
//      truncation are all detected.
//    - Sequence numbers double as AEAD nonces and are bound into the AAD
//      together with the session id and direction, so frames cannot be
//      transplanted between sessions, directions, or calls.
//
//  The plaintext of a call frame is an `InnerRequest` carrying the method,
//  path, body, and the `osk-v1` Bearer — so after pairing, credentials never
//  cross the LAN or the relay in cleartext.
//

import CryptoKit
import Foundation

// MARK: - Errors

public enum SecureChannelError: Error, Equatable {
    case unsupportedVersion
    case malformedHandshake
    case identityMismatch
    case sealFailed
    case openFailed
    case replayedFrame
    case outOfOrderFrame
    case sessionExpired
}

// MARK: - Protocol

public enum SecureChannel {
    public static let version = 1
    /// Absolute session lifetime. Sessions are cheap to re-establish (one
    /// round trip), so keep this short enough that key material never lives
    /// long on either side.
    public static let sessionTTL: TimeInterval = 3600

    private static let transcriptDomain = "osaurus-sc1"
    private static let aeadTagLength = 16

    // MARK: Wire Types

    /// POST /secure/session request body.
    public struct ClientHello: Codable, Sendable, Equatable {
        public let v: Int
        /// The agent address (0x…) the client expects to be talking to —
        /// pinned at pairing/discovery time. Selects which agent key the
        /// server signs with and is bound into the transcript.
        public let agentAddress: String
        /// Client ephemeral X25519 public key (base64url).
        public let encPub: String
        /// Client freshness nonce (base64url) — ensures the server signature
        /// cannot be replayed from an earlier exchange.
        public let nonce: String

        public init(v: Int, agentAddress: String, encPub: String, nonce: String) {
            self.v = v
            self.agentAddress = agentAddress
            self.encPub = encPub
            self.nonce = nonce
        }
    }

    /// POST /secure/session response body.
    public struct ServerHello: Codable, Sendable, Equatable {
        public let v: Int
        /// Opaque session id (base64url).
        public let sid: String
        /// Server ephemeral X25519 public key (base64url).
        public let encPub: String
        /// Unix seconds after which the session is invalid.
        public let expiresAt: Int
        /// Hex (0x…) secp256k1 agent-key signature over the transcript.
        public let signature: String

        public init(v: Int, sid: String, encPub: String, expiresAt: Int, signature: String) {
            self.v = v
            self.sid = sid
            self.encPub = encPub
            self.expiresAt = expiresAt
            self.signature = signature
        }
    }

    /// POST /secure/call request body — one sealed inner request.
    public struct CallRequest: Codable, Sendable, Equatable {
        public let v: Int
        public let sid: String
        public let seq: UInt64
        /// AEAD ciphertext || tag (base64url). Nonce is derived from `seq`.
        public let ct: String

        public init(v: Int, sid: String, seq: UInt64, ct: String) {
            self.v = v
            self.sid = sid
            self.seq = seq
            self.ct = ct
        }
    }

    /// One sealed response frame (the buffered response is a single frame
    /// with `fin == true`; SSE streams are a sequence of frames ending in
    /// one with `fin == true`).
    public struct Frame: Codable, Sendable, Equatable {
        public let seq: UInt64
        public let ct: String
        /// Authenticated end-of-stream marker (bound into the AAD).
        public let fin: Bool?

        public init(seq: UInt64, ct: String, fin: Bool? = nil) {
            self.seq = seq
            self.ct = ct
            self.fin = fin
        }

        public var isFin: Bool { fin == true }
    }

    /// Plaintext of a `CallRequest`: the real HTTP request, Bearer included.
    public struct InnerRequest: Codable, Sendable, Equatable {
        public let method: String
        public let path: String
        public let authorization: String?
        public let accept: String?
        public let contentType: String?
        /// Additional request headers (custom provider headers etc.).
        /// Hop-by-hop and transport headers are ignored by the receiver.
        public let headers: [String: String]?
        /// Request body (base64url) — binary-safe.
        public let body: String?

        public init(
            method: String,
            path: String,
            authorization: String?,
            accept: String? = nil,
            contentType: String? = nil,
            headers: [String: String]? = nil,
            body: String? = nil
        ) {
            self.method = method
            self.path = path
            self.authorization = authorization
            self.accept = accept
            self.contentType = contentType
            self.headers = headers
            self.body = body
        }
    }

    /// Plaintext of a buffered (non-streaming) response frame.
    public struct InnerResponse: Codable, Sendable, Equatable {
        public let status: Int
        public let contentType: String?
        /// Response body (base64url) — binary-safe.
        public let body: String?

        public init(status: Int, contentType: String?, body: String?) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }
    }

    // MARK: Handshake — Client Side

    /// Step 1: mint the client's ephemeral key and hello message.
    public static func makeClientHello(agentAddress: String) -> (
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey, hello: ClientHello
    ) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        let hello = ClientHello(
            v: version,
            agentAddress: agentAddress.lowercased(),
            encPub: key.publicKey.rawRepresentation.base64urlEncoded,
            nonce: Data(nonceBytes).base64urlEncoded
        )
        return (key, hello)
    }

    /// Step 3 (client): verify the server's transcript signature against the
    /// pinned agent address and derive the session.
    public static func establishClientSession(
        hello: ClientHello,
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey,
        serverHello: ServerHello,
        expectedAgentAddress: String
    ) throws -> SecureChannelSession {
        guard serverHello.v == version else { throw SecureChannelError.unsupportedVersion }
        guard let serverPubRaw = Data(base64urlEncoded: serverHello.encPub),
            let serverPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPubRaw),
            !serverHello.sid.isEmpty
        else {
            throw SecureChannelError.malformedHandshake
        }

        // Authenticate the transcript: the signer must be the agent address
        // we pinned at pairing/discovery time. A MITM that substituted its
        // own ephemeral key cannot produce this signature.
        let transcript = transcriptPayload(hello: hello, serverHello: serverHello)
        let sigHex =
            serverHello.signature.hasPrefix("0x")
            ? String(serverHello.signature.dropFirst(2)) : serverHello.signature
        guard let sigBytes = Data(hexEncoded: sigHex),
            let recovered = try? recoverAddress(
                payload: transcript,
                signature: sigBytes,
                domainPrefix: "Osaurus Secure Channel"
            ),
            recovered.lowercased() == expectedAgentAddress.lowercased()
        else {
            throw SecureChannelError.identityMismatch
        }

        guard let shared = try? ephemeralKey.sharedSecretFromKeyAgreement(with: serverPub) else {
            throw SecureChannelError.malformedHandshake
        }
        let (c2s, s2c) = deriveKeys(sharedSecret: shared, transcript: transcript)
        return SecureChannelSession(
            role: .client,
            sid: serverHello.sid,
            sendKey: c2s,
            receiveKey: s2c,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(serverHello.expiresAt))
        )
    }

    // MARK: Handshake — Server Side

    /// Step 2 (server): derive the session and produce a signed `ServerHello`.
    /// `sign` receives the canonical transcript bytes and must return a
    /// 65-byte recoverable secp256k1 signature made with the *agent* key
    /// (see `signSecureChannelPayload`).
    public static func establishServerSession(
        hello: ClientHello,
        sign: (Data) throws -> Data
    ) throws -> (session: SecureChannelSession, serverHello: ServerHello) {
        guard hello.v == version else { throw SecureChannelError.unsupportedVersion }
        guard let clientPubRaw = Data(base64urlEncoded: hello.encPub),
            let clientPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPubRaw),
            !hello.nonce.isEmpty
        else {
            throw SecureChannelError.malformedHandshake
        }

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var sidBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, sidBytes.count, &sidBytes)
        let sid = Data(sidBytes).base64urlEncoded
        let expiresAt = Int(Date().addingTimeInterval(sessionTTL).timeIntervalSince1970)

        var serverHello = ServerHello(
            v: version,
            sid: sid,
            encPub: ephemeral.publicKey.rawRepresentation.base64urlEncoded,
            expiresAt: expiresAt,
            signature: ""
        )
        let transcript = transcriptPayload(hello: hello, serverHello: serverHello)
        let signature = try sign(transcript)
        serverHello = ServerHello(
            v: version,
            sid: sid,
            encPub: serverHello.encPub,
            expiresAt: expiresAt,
            signature: "0x" + signature.hexEncodedString
        )

        guard let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: clientPub) else {
            throw SecureChannelError.malformedHandshake
        }
        let (c2s, s2c) = deriveKeys(sharedSecret: shared, transcript: transcript)
        let session = SecureChannelSession(
            role: .server,
            sid: sid,
            sendKey: s2c,
            receiveKey: c2s,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt))
        )
        return (session, serverHello)
    }

    // MARK: Transcript and Key Schedule

    /// Canonical handshake transcript. The signature field is excluded (the
    /// signature is *over* these bytes); everything else both sides saw is
    /// bound in, so tampering with any handshake field breaks verification
    /// and yields mismatched keys.
    static func transcriptPayload(hello: ClientHello, serverHello: ServerHello) -> Data {
        let canonical =
            "\(transcriptDomain)|v=\(version)|aA=\(hello.agentAddress.lowercased())"
            + "|eC=\(hello.encPub)|nC=\(hello.nonce)"
            + "|sid=\(serverHello.sid)|eS=\(serverHello.encPub)|exp=\(serverHello.expiresAt)"
        return Data(canonical.utf8)
    }

    private static func deriveKeys(
        sharedSecret: SharedSecret,
        transcript: Data
    ) -> (clientToServer: SymmetricKey, serverToClient: SymmetricKey) {
        let salt = Data(SHA256.hash(data: transcript))
        let c2s = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("\(transcriptDomain):c2s".utf8),
            outputByteCount: 32
        )
        let s2c = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("\(transcriptDomain):s2c".utf8),
            outputByteCount: 32
        )
        return (c2s, s2c)
    }

    // MARK: AEAD Primitives (shared by session/sealer/opener)

    /// 12-byte ChaChaPoly nonce: 4 zero bytes || big-endian sequence number.
    /// Safe because each (key, seq) pair is used at most once: request seqs
    /// are session-monotonic with a replay window, and response seqs are
    /// strict-in-order under a per-call derived key.
    static func nonce(forSequence seq: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: seq.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    static func requestAAD(sid: String, seq: UInt64) -> Data {
        Data("\(transcriptDomain):req:\(sid):\(seq)".utf8)
    }

    static func responseAAD(sid: String, requestSeq: UInt64, seq: UInt64, fin: Bool) -> Data {
        Data("\(transcriptDomain):resp:\(sid):\(requestSeq):\(seq):\(fin ? 1 : 0)".utf8)
    }

    static func seal(
        _ plaintext: Data,
        key: SymmetricKey,
        seq: UInt64,
        aad: Data
    ) throws -> String {
        guard
            let box = try? ChaChaPoly.seal(
                plaintext,
                using: key,
                nonce: nonce(forSequence: seq),
                authenticating: aad
            )
        else {
            throw SecureChannelError.sealFailed
        }
        return (box.ciphertext + box.tag).base64urlEncoded
    }

    static func open(
        _ ciphertext: String,
        key: SymmetricKey,
        seq: UInt64,
        aad: Data
    ) throws -> Data {
        guard let raw = Data(base64urlEncoded: ciphertext), raw.count >= aeadTagLength else {
            throw SecureChannelError.openFailed
        }
        guard
            let box = try? ChaChaPoly.SealedBox(
                nonce: nonce(forSequence: seq),
                ciphertext: raw.dropLast(aeadTagLength),
                tag: raw.suffix(aeadTagLength)
            ),
            let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: aad)
        else {
            throw SecureChannelError.openFailed
        }
        return plaintext
    }

    /// Per-call response key: derived from the server→client session key and
    /// the request's sequence number, so response frames from one call can
    /// never be replayed into another even though both number from 0.
    static func responseKey(base: SymmetricKey, requestSeq: UInt64) -> SymmetricKey {
        SymmetricKey(
            data: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: base,
                salt: Data(),
                info: Data("\(transcriptDomain):respkey:\(requestSeq)".utf8),
                outputByteCount: 32
            ).withUnsafeBytes { Data($0) }
        )
    }
}

// MARK: - Session

/// An established Secure Channel session. One instance lives on each side;
/// the client seals calls and opens response frames, the server opens calls
/// and seals response frames. Thread-safe (NSLock) because the server uses
/// it from NIO event loops and detached request tasks concurrently.
public final class SecureChannelSession: @unchecked Sendable {
    enum Role { case client, server }

    public let sid: String
    public let expiresAt: Date

    private let role: Role
    /// Key for frames this side emits (client: c2s; server: s2c).
    private let sendKey: SymmetricKey
    /// Key for frames this side consumes.
    private let receiveKey: SymmetricKey

    private let lock = NSLock()
    /// Client: next request sequence to use (starts at 1; the server's
    /// replay window treats 0 as already seen).
    private var nextRequestSeq: UInt64 = 1
    /// Server anti-replay sliding window over request sequence numbers.
    private var highestSeenSeq: UInt64 = 0
    private var replayWindow: UInt64 = 0
    private static let replayWindowSize: UInt64 = 64

    init(role: Role, sid: String, sendKey: SymmetricKey, receiveKey: SymmetricKey, expiresAt: Date) {
        self.role = role
        self.sid = sid
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool { Date() >= expiresAt }

    // MARK: Client Side

    /// Seal one inner request into a `/secure/call` body. Returns the call
    /// and its sequence number (needed to open the matching response frames).
    public func sealCall(innerRequest: Data) throws -> (call: SecureChannel.CallRequest, requestSeq: UInt64) {
        guard !isExpired else { throw SecureChannelError.sessionExpired }
        lock.lock()
        let seq = nextRequestSeq
        nextRequestSeq += 1
        lock.unlock()
        let ct = try SecureChannel.seal(
            innerRequest,
            key: sendKey,
            seq: seq,
            aad: SecureChannel.requestAAD(sid: sid, seq: seq)
        )
        return (SecureChannel.CallRequest(v: SecureChannel.version, sid: sid, seq: seq, ct: ct), seq)
    }

    /// Opener for the response frames of one call (client side).
    public func makeResponseOpener(requestSeq: UInt64) -> SecureResponseOpener {
        SecureResponseOpener(
            sid: sid,
            requestSeq: requestSeq,
            key: SecureChannel.responseKey(base: receiveKey, requestSeq: requestSeq)
        )
    }

    // MARK: Server Side

    /// Open a `/secure/call` body. Enforces the anti-replay window: each
    /// request sequence number is accepted at most once per session, so a
    /// captured call cannot be re-executed.
    public func openCall(_ call: SecureChannel.CallRequest) throws -> (plaintext: Data, requestSeq: UInt64) {
        guard call.v == SecureChannel.version else { throw SecureChannelError.unsupportedVersion }
        guard !isExpired else { throw SecureChannelError.sessionExpired }
        let plaintext = try SecureChannel.open(
            call.ct,
            key: receiveKey,
            seq: call.seq,
            aad: SecureChannel.requestAAD(sid: sid, seq: call.seq)
        )
        // Mark the sequence only AFTER authentication succeeds, so garbage
        // frames can't burn sequence numbers.
        guard markRequestSeq(call.seq) else { throw SecureChannelError.replayedFrame }
        return (plaintext, call.seq)
    }

    /// Sealer for the response frames of one call (server side).
    public func makeResponseSealer(requestSeq: UInt64) -> SecureResponseSealer {
        SecureResponseSealer(
            sid: sid,
            requestSeq: requestSeq,
            key: SecureChannel.responseKey(base: sendKey, requestSeq: requestSeq)
        )
    }

    /// Sliding-window anti-replay check (IPsec/DTLS style): accept any
    /// never-seen sequence within `replayWindowSize` of the highest, so
    /// moderately concurrent calls may land out of order without opening a
    /// replay hole.
    private func markRequestSeq(_ seq: UInt64) -> Bool {
        guard seq > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        if seq > highestSeenSeq {
            let shift = seq - highestSeenSeq
            replayWindow = shift >= Self.replayWindowSize ? 0 : replayWindow << shift
            replayWindow |= 1
            highestSeenSeq = seq
            return true
        }
        let offset = highestSeenSeq - seq
        guard offset < Self.replayWindowSize else { return false }
        let bit: UInt64 = 1 << offset
        guard replayWindow & bit == 0 else { return false }
        replayWindow |= bit
        return true
    }
}

// MARK: - Per-Call Response Framing

/// Seals the response frames of one call, numbering them 0,1,2,… under the
/// call's derived key. The final frame must be sealed with `fin: true`.
public final class SecureResponseSealer: @unchecked Sendable {
    private let sid: String
    private let requestSeq: UInt64
    private let key: SymmetricKey
    private let lock = NSLock()
    private var nextSeq: UInt64 = 0
    private var finished = false

    init(sid: String, requestSeq: UInt64, key: SymmetricKey) {
        self.sid = sid
        self.requestSeq = requestSeq
        self.key = key
    }

    public func seal(_ plaintext: Data, fin: Bool = false) throws -> SecureChannel.Frame {
        lock.lock()
        guard !finished else {
            lock.unlock()
            throw SecureChannelError.sealFailed
        }
        let seq = nextSeq
        nextSeq += 1
        if fin { finished = true }
        lock.unlock()
        let ct = try SecureChannel.seal(
            plaintext,
            key: key,
            seq: seq,
            aad: SecureChannel.responseAAD(sid: sid, requestSeq: requestSeq, seq: seq, fin: fin)
        )
        return SecureChannel.Frame(seq: seq, ct: ct, fin: fin ? true : nil)
    }
}

/// Opens the response frames of one call in strict order. Reordered,
/// replayed, or post-`fin` frames throw; the consumer must verify that the
/// stream ended with `fin == true` to detect truncation.
public final class SecureResponseOpener: @unchecked Sendable {
    private let sid: String
    private let requestSeq: UInt64
    private let key: SymmetricKey
    private let lock = NSLock()
    private var expectedSeq: UInt64 = 0
    private var sawFin = false

    init(sid: String, requestSeq: UInt64, key: SymmetricKey) {
        self.sid = sid
        self.requestSeq = requestSeq
        self.key = key
    }

    public var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawFin
    }

    public func open(_ frame: SecureChannel.Frame) throws -> (plaintext: Data, fin: Bool) {
        lock.lock()
        guard !sawFin else {
            lock.unlock()
            throw SecureChannelError.outOfOrderFrame
        }
        guard frame.seq == expectedSeq else {
            lock.unlock()
            throw SecureChannelError.outOfOrderFrame
        }
        lock.unlock()

        let fin = frame.isFin
        let plaintext = try SecureChannel.open(
            frame.ct,
            key: key,
            seq: frame.seq,
            aad: SecureChannel.responseAAD(sid: sid, requestSeq: requestSeq, seq: frame.seq, fin: fin)
        )

        lock.lock()
        expectedSeq += 1
        if fin { sawFin = true }
        lock.unlock()
        return (plaintext, fin)
    }
}
