//
//  PairingSPAKE2.swift
//  osaurus
//
//  Pairing v2: SPAKE2 (RFC 9382) over secp256k1, keyed by the 6-digit code.
//  The code never crosses the network. Both sides blind a fresh share with
//  it, agree on a key only if they used the same code, and prove so with
//  confirmation MACs before anything is handed over. Someone in the middle
//  of the exchange gets one guess per pairing attempt at the code and
//  nothing to test guesses against offline — unlike v1, where the code went
//  in the clear and the response was sealed to whatever key came with it.
//
//  Byte-for-byte twin of iOSaurus `Security/PairingSPAKE2.swift`; the same
//  exchange tests run against both. Wire format:
//  docs/MOBILE_PROTOCOL.md §11.
//
//  Notation (RFC 9382): the phone is A and blinds with M, the Mac is B and
//  blinds with N. pA = x·G + w·M, pB = y·G + w·N, and
//  K = x·(pB − w·N) = y·(pA − w·M) = x·y·G.
//

import CryptoKit
import Foundation
import P256K

enum PairingSPAKE2 {
    static let version = 2
    private static let domain = "osaurus-pair-v2"

    enum Failure: Error, Equatable {
        case invalidShare
        case invalidSealedPayload
    }

    enum Role {
        /// A in RFC 9382: starts the exchange, blinds with M.
        case phone
        /// B: answers, blinds with N.
        case mac
    }

    typealias Point = P256K.Signing.PublicKey

    /// What the exchange settles on.
    struct Keys {
        /// Seals the pairing payload (access key and agent roster).
        let sessionKey: SymmetricKey
        /// cA: the phone's proof it used the same code.
        let phoneConfirmation: Data
        /// cB: the Mac's.
        let macConfirmation: Data
    }

    // MARK: Fixed points

    /// M and N: points nobody knows the discrete log of, found by hashing a
    /// label to an x coordinate until it lands on the curve (even y). Kept
    /// as compressed bytes, which are Sendable where the key type isn't.
    static let pointM = hashToPoint("M")
    static let pointN = hashToPoint("N")

    static func hashToPoint(_ label: String) -> Data {
        var counter: UInt8 = 0
        while true {
            var input = Data("\(domain):point:\(label):".utf8)
            input.append(counter)
            let x = [UInt8](SHA256.hash(data: input))
            if (try? Point(dataRepresentation: [0x02] + x, format: .compressed)) != nil { return Data([0x02] + x) }
            counter &+= 1
        }
    }

    /// w: the code as a scalar. Hashed until it is a valid non-zero scalar,
    /// which a SHA-256 output almost always is the first time.
    static func passwordScalar(code: String) -> [UInt8] {
        var counter: UInt8 = 0
        while true {
            var input = Data("\(domain):password:".utf8)
            input.append(lengthPrefixed(Data(code.utf8)))
            input.append(counter)
            let w = [UInt8](SHA256.hash(data: input))
            if (try? P256K.Signing.PrivateKey(dataRepresentation: w)) != nil { return w }
            counter &+= 1
        }
    }

    /// The phone's identity as both sides bind it into the transcript, so a
    /// man in the middle can't swap the device the Mac records.
    static func phoneIdentity(deviceId: String, deviceName: String) -> Data {
        lengthPrefixed(Data(deviceId.utf8)) + lengthPrefixed(Data(deviceName.utf8))
    }

    // MARK: Exchange

    /// One side of an exchange: a fresh secret and the blinded share to send.
    struct Party {
        let role: Role
        let share: Data
        private let secret: P256K.Signing.PrivateKey
        private let w: [UInt8]

        init(role: Role, code: String, secret: P256K.Signing.PrivateKey? = nil) throws {
            self.role = role
            self.secret = try secret ?? P256K.Signing.PrivateKey()
            self.w = PairingSPAKE2.passwordScalar(code: code)
            let ownBase = role == .phone ? PairingSPAKE2.pointM : PairingSPAKE2.pointN
            let blind = try PairingSPAKE2.point(ownBase).multiply(w)
            self.share = try self.secret.publicKey.combine([blind]).dataRepresentation
        }

        /// Derives the keys from the peer's share. Throws on a share that
        /// isn't a curve point; a wrong code is only caught by confirmation.
        func finish(peerShare: Data, phoneIdentity: Data) throws -> Keys {
            guard peerShare.count == 33, peerShare.first == 0x02 || peerShare.first == 0x03,
                let peer = try? Point(dataRepresentation: peerShare, format: .compressed)
            else { throw Failure.invalidShare }
            let peerBase = role == .phone ? PairingSPAKE2.pointN : PairingSPAKE2.pointM
            let peerBlind = try PairingSPAKE2.point(peerBase).multiply(w)
            let unblinded = try peer.combine([PairingSPAKE2.negate(peerBlind)])
            let k = try unblinded.multiply([UInt8](secret.dataRepresentation)).dataRepresentation
            let (pA, pB) = role == .phone ? (share, peerShare) : (peerShare, share)
            return PairingSPAKE2.keys(phoneIdentity: phoneIdentity, pA: pA, pB: pB, k: k, w: Data(w))
        }
    }

    static func point(_ bytes: Data) throws -> Point {
        try Point(dataRepresentation: bytes, format: .compressed)
    }

    static func negate(_ point: Point) throws -> Point {
        var bytes = [UInt8](point.dataRepresentation)
        bytes[0] ^= 0x01  // 0x02 (even y) <-> 0x03 (odd y)
        return try Point(dataRepresentation: bytes, format: .compressed)
    }

    /// RFC 9382 §4: TT binds every input; Ke seals, KcA / KcB confirm.
    static func keys(phoneIdentity: Data, pA: Data, pB: Data, k: Data, w: Data) -> Keys {
        var transcript = Data()
        for part in [Data(domain.utf8), phoneIdentity, Data(), pA, pB, k, w] {
            transcript.append(lengthPrefixed(part))
        }
        let ikm = SymmetricKey(data: SHA256.hash(data: transcript))
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm,
                salt: Data(),
                info: Data("\(domain):\(label)".utf8),
                outputByteCount: 32
            )
        }
        func confirmation(_ label: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: transcript, using: derive(label)))
        }
        return Keys(
            sessionKey: derive("session"),
            phoneConfirmation: confirmation("confirm-phone"),
            macConfirmation: confirmation("confirm-mac")
        )
    }

    // MARK: Payload

    /// Seals the pairing payload under the session key, bound to the device.
    static func seal(_ plaintext: Data, key: SymmetricKey, deviceId: String) throws -> String {
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: payloadAAD(deviceId: deviceId))
        return box.combined.base64urlEncoded
    }

    static func open(_ sealed: String, key: SymmetricKey, deviceId: String) throws -> Data {
        guard let raw = Data(base64urlEncoded: sealed), let box = try? ChaChaPoly.SealedBox(combined: raw),
            let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: payloadAAD(deviceId: deviceId))
        else { throw Failure.invalidSealedPayload }
        return plaintext
    }

    private static func payloadAAD(deviceId: String) -> Data {
        Data("\(domain):payload:\(deviceId)".utf8)
    }

    // MARK: Helpers

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { diff |= a ^ b }
        return diff == 0
    }

    /// 8-byte little-endian length, then the bytes (RFC 9382's TT encoding).
    private static func lengthPrefixed(_ data: Data) -> Data {
        var length = UInt64(data.count).littleEndian
        return Data(bytes: &length, count: 8) + data
    }
}
