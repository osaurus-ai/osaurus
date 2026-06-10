//
//  PairingChallengeStore.swift
//  osaurus
//
//  Server-issued, single-use challenge nonces for the LAN `/pair` flow. The
//  connector first fetches a nonce via `GET /pair/challenge`, signs it, and
//  POSTs it back to `/pair`. The server only accepts signatures over a nonce
//  it issued and not yet consumed, which prevents an attacker from replaying a
//  sniffed `/pair` body (the connector-chosen nonce of the old design was
//  replayable). Nonces expire after a short TTL and are consumed on first use.
//

import Foundation

public final class PairingChallengeStore: @unchecked Sendable {
    public static let shared = PairingChallengeStore()

    private let lock = NSLock()
    /// nonce -> expiry instant.
    private var challenges: [String: Date] = [:]
    private let ttl: TimeInterval = 120
    /// Cap outstanding challenges so an unauthenticated caller cannot grow
    /// memory without bound by spamming `GET /pair/challenge`.
    private let maxOutstanding = 256

    private init() {}

    /// Mint a fresh single-use challenge nonce (hex-encoded 32 random bytes).
    public func issue() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = bytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, ptr.count, ptr.baseAddress!)
        }
        let nonce = Data(bytes).hexEncodedString
        let now = Date()

        lock.lock()
        defer { lock.unlock() }
        pruneExpired(now: now)
        if challenges.count >= maxOutstanding,
            let oldest = challenges.min(by: { $0.value < $1.value })?.key
        {
            challenges.removeValue(forKey: oldest)
        }
        challenges[nonce] = now.addingTimeInterval(ttl)
        return nonce
    }

    /// Atomically validate and consume a challenge nonce. Returns `true` only
    /// if the nonce was outstanding and not expired. Single-use: a second call
    /// with the same nonce returns `false`.
    public func consume(_ nonce: String) -> Bool {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        pruneExpired(now: now)
        guard let expiry = challenges.removeValue(forKey: nonce) else { return false }
        return expiry > now
    }

    private func pruneExpired(now: Date) {
        challenges = challenges.filter { $0.value > now }
    }
}
