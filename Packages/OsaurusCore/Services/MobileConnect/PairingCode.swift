//
//  PairingCode.swift
//  osaurus
//
//  Pure state for one Osaurus Connect pairing code: a 6-digit, single-use,
//  short-lived secret the user reads off the Mac and types on their phone.
//  Six digits is only a million guesses, so the code is (a) LAN-only,
//  (b) dead after `maxFailedAttempts` wrong guesses from ANY source (the
//  per-IP `PairingRateLimiter` alone would let a botnet-free attacker rotate
//  addresses), and (c) valid for `ttl` seconds. Kept free of I/O so the
//  lockout and expiry rules are unit-testable with an injected clock.
//

import Foundation
import Security

struct PairingCode: Equatable, Sendable {
    static let digitCount = 6
    static let ttl: TimeInterval = 300
    static let maxFailedAttempts = 5

    let code: String
    let issuedAt: Date
    private(set) var failedAttempts = 0

    var expiresAt: Date { issuedAt.addingTimeInterval(Self.ttl) }

    enum AttemptResult: Equatable {
        case accepted
        /// Wrong code; the session is still live.
        case rejected
        /// Wrong code and the attempt budget is now spent; the caller must
        /// discard this session.
        case lockedOut
        case expired
    }

    init(code: String, issuedAt: Date) {
        self.code = code
        self.issuedAt = issuedAt
    }

    func isExpired(at now: Date) -> Bool { now >= expiresAt }

    mutating func attempt(_ candidate: String, at now: Date) -> AttemptResult {
        guard !isExpired(at: now) else { return .expired }
        if Self.constantTimeEquals(candidate, code) { return .accepted }
        failedAttempts += 1
        return failedAttempts >= Self.maxFailedAttempts ? .lockedOut : .rejected
    }

    /// Uniformly random `digitCount`-digit code (leading zeros allowed),
    /// via rejection sampling so no digit string is favoured by modulo bias.
    static func generate() -> String {
        let modulus: UInt32 = 1_000_000
        let limit = UInt32.max - (UInt32.max % modulus)
        var value: UInt32 = 0
        repeat {
            _ = withUnsafeMutableBytes(of: &value) { ptr in
                SecRandomCopyBytes(kSecRandomDefault, ptr.count, ptr.baseAddress!)
            }
        } while value >= limit
        let digits = String(value % modulus)
        return String(repeating: "0", count: digitCount - digits.count) + digits
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
