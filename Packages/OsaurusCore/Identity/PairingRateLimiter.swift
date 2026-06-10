//
//  PairingRateLimiter.swift
//  osaurus
//
//  Per-source-IP rate limiting for the unauthenticated pairing endpoints
//  (`GET /pair/challenge`, `POST /pair`). Without this an attacker on the LAN
//  could spam approval prompts on the advertiser's Mac or brute the challenge
//  store. A short cooldown is applied after a denial so a rejected device
//  cannot immediately retry in a tight loop.
//

import Foundation

public final class PairingRateLimiter: @unchecked Sendable {
    public static let shared = PairingRateLimiter()

    private let lock = NSLock()
    private var hits: [String: [Date]] = [:]
    private var cooldownUntil: [String: Date] = [:]

    private let window: TimeInterval = 60
    private let maxPerWindow = 5
    private let denialCooldown: TimeInterval = 30

    private init() {}

    /// Record an attempt from `ip`. Returns `false` when the caller is inside a
    /// denial cooldown or has exceeded `maxPerWindow` attempts in the trailing
    /// `window`.
    public func allow(ip: String) -> Bool {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }

        if let until = cooldownUntil[ip] {
            if until > now { return false }
            cooldownUntil.removeValue(forKey: ip)
        }

        var recent = (hits[ip] ?? []).filter { now.timeIntervalSince($0) < window }
        guard recent.count < maxPerWindow else {
            hits[ip] = recent
            return false
        }
        recent.append(now)
        hits[ip] = recent
        return true
    }

    /// Apply a cooldown after an explicit denial so a rejected peer backs off.
    public func penalize(ip: String) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        cooldownUntil[ip] = now.addingTimeInterval(denialCooldown)
    }
}
