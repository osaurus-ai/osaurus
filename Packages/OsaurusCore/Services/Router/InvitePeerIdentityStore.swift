//
//  InvitePeerIdentityStore.swift
//  osaurus
//
//  The verified wallet behind an invite-link access key. An invite redeem
//  may carry an EIP-191 proof over
//  `osaurus-invite:redeem:<agent address>:<invite nonce>`; when it does, the
//  recovered wallet is remembered against the minted key's nonce so the
//  peer's runs are named by their Osaurus ID (`ParticipantFormatter`)
//  instead of by the key label. Not a secret; JSON at
//  `~/.osaurus/workspaces/invite-peers.json`.
//

import Foundation

enum InvitePeerIdentity {
    static func redeemMessage(agentAddress: String, inviteNonce: String) -> String {
        "osaurus-invite:redeem:\(agentAddress.lowercased()):\(inviteNonce)"
    }

    /// The wallet the proof recovers to, when it matches `claimedAddress`.
    static func verifiedWallet(
        claimedAddress: String,
        signatureHex: String,
        agentAddress: String,
        inviteNonce: String
    ) -> String? {
        let hex = signatureHex.hasPrefix("0x") || signatureHex.hasPrefix("0X") ? String(signatureHex.dropFirst(2)) : signatureHex
        guard let signature = Data(hexEncoded: hex), signature.count == 65,
            let recovered = try? recoverAddress(
                payload: Data(redeemMessage(agentAddress: agentAddress, inviteNonce: inviteNonce).utf8),
                signature: signature,
                domainPrefix: "Ethereum Signed Message"
            ),
            recovered.lowercased() == claimedAddress.lowercased()
        else { return nil }
        return recovered.lowercased()
    }
}

/// Every read-modify-write runs under one lock, so concurrent redeems can't
/// drop each other's entries. A failed write keeps the previous map, and a
/// file that doesn't decode is moved aside instead of overwritten.
enum InvitePeerIdentityStore {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: [String: String]?
    private nonisolated(unsafe) static var overrideURL: URL?

    static func setOverrideFileURL(_ url: URL?) {
        lock.withLock {
            overrideURL = url
            cached = nil
        }
    }

    /// Verified wallet for an access key nonce.
    static func wallet(forKeyNonce nonce: String) -> String? {
        lock.withLock { loadLocked()[nonce] }
    }

    static func record(wallet: String, forKeyNonce nonce: String) {
        update { $0[nonce] = wallet.lowercased() }
    }

    /// The key was revoked or deleted: forget who redeemed it.
    static func remove(keyNonce nonce: String) {
        remove(keyNonces: [nonce])
    }

    static func remove(keyNonces nonces: [String]) {
        guard !nonces.isEmpty else { return }
        update { map in for nonce in nonces { map.removeValue(forKey: nonce) } }
    }

    private static func update(_ mutate: (inout [String: String]) -> Void) {
        lock.withLock {
            let current = loadLocked()
            var next = current
            mutate(&next)
            guard next != current else { return }
            if AttentionFileIO.write(next, to: fileURLLocked()) { cached = next }
        }
    }

    private static func fileURLLocked() -> URL {
        overrideURL
            ?? OsaurusPaths.root().appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent("invite-peers.json")
    }

    private static func loadLocked() -> [String: String] {
        if let cached { return cached }
        let map: [String: String]
        switch AttentionFileIO.read([String: String].self, from: fileURLLocked()) {
        case .loaded(let value): map = value
        case .missing, .corrupt: map = [:]
        }
        cached = map
        return map
    }
}
