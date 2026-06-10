//
//  PairingKeyEnvelope.swift
//  osaurus
//
//  HPKE envelope for delivering freshly minted osk-v1 access keys through
//  untrusted transports. LAN `/pair` runs over cleartext HTTP and the relay
//  `/pair-invite` path terminates TLS at the relay operator, so without this
//  the long-lived credential is readable by any passive observer. The
//  connector generates an ephemeral X25519 key pair per pairing exchange,
//  sends the public half with its request, and the server seals the minted
//  key to it — only the connector can open the envelope.
//
//  On the LAN path the connector's public key is covered by its pairing
//  signature, so an active MITM cannot substitute their own key without also
//  changing the connector address shown in the approval prompt. On the invite
//  path the receiver is unauthenticated, so the envelope defeats passive
//  capture (relay logs, TLS termination) but not a fully active relay MITM;
//  that residual risk is documented in docs/SECURITY.md.
//

import CryptoKit
import Foundation

public enum PairingKeyEnvelopeError: Error {
    case invalidRecipientKey
    case sealFailed
    case openFailed
}

public enum PairingKeyEnvelope {
    /// X25519 + HKDF-SHA256 + ChaCha20-Poly1305.
    public static var ciphersuite: HPKE.Ciphersuite {
        HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .chaChaPoly)
    }

    /// Wire form of a sealed key: the encapsulated KEM key and ciphertext,
    /// both base64url.
    public struct Sealed: Codable, Sendable, Equatable {
        public let enc: String
        public let ct: String

        public init(enc: String, ct: String) {
            self.enc = enc
            self.ct = ct
        }
    }

    /// Context-binding info. Derived from values both sides already agree on
    /// (the agent's address and the single-use challenge/invite nonce) so a
    /// sealed envelope can't be transplanted between exchanges.
    public static func info(agentAddress: String, nonce: String) -> Data {
        Data("osaurus-pair-key-v1:\(agentAddress.lowercased()):\(nonce)".utf8)
    }

    /// Connector side: mint an ephemeral recipient key pair for one exchange.
    public static func generateRecipientKey() -> (
        privateKey: Curve25519.KeyAgreement.PrivateKey, publicKeyBase64url: String
    ) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (key, key.publicKey.rawRepresentation.base64urlEncoded)
    }

    /// Server side: seal `secret` to the connector's ephemeral public key.
    public static func seal(
        secret: String,
        recipientPublicKeyBase64url: String,
        info: Data
    ) throws -> Sealed {
        guard let raw = Data(base64urlEncoded: recipientPublicKeyBase64url),
            let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        else {
            throw PairingKeyEnvelopeError.invalidRecipientKey
        }
        do {
            var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: ciphersuite, info: info)
            let ciphertext = try sender.seal(Data(secret.utf8))
            return Sealed(
                enc: sender.encapsulatedKey.base64urlEncoded,
                ct: ciphertext.base64urlEncoded
            )
        } catch {
            throw PairingKeyEnvelopeError.sealFailed
        }
    }

    /// Connector side: open a sealed envelope with the ephemeral private key.
    public static func open(
        _ sealed: Sealed,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        info: Data
    ) throws -> String {
        guard let enc = Data(base64urlEncoded: sealed.enc),
            let ct = Data(base64urlEncoded: sealed.ct)
        else {
            throw PairingKeyEnvelopeError.openFailed
        }
        do {
            var recipient = try HPKE.Recipient(
                privateKey: privateKey,
                ciphersuite: ciphersuite,
                info: info,
                encapsulatedKey: enc
            )
            let plaintext = try recipient.open(ct)
            guard let secret = String(data: plaintext, encoding: .utf8) else {
                throw PairingKeyEnvelopeError.openFailed
            }
            return secret
        } catch {
            throw PairingKeyEnvelopeError.openFailed
        }
    }
}
