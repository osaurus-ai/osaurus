//
//  SecureSessionStore.swift
//  osaurus
//
//  Server-side registry of established Secure Channel sessions, keyed by
//  session id. Sessions are capped in number and expire on the absolute TTL
//  baked into the handshake, so an attacker hammering `/secure/session`
//  (already rate-limited per IP) cannot grow memory without bound, and key
//  material never outlives its window.
//
//  Thread-safe: looked up on NIO event loops, populated from request tasks.
//

import Foundation

public final class SecureSessionStore: @unchecked Sendable {
    public static let shared = SecureSessionStore()

    private let lock = NSLock()
    private var sessions: [String: SecureChannelSession] = [:]
    private let maxSessions = 256

    private init() {}

    public func register(_ session: SecureChannelSession) {
        lock.lock()
        defer { lock.unlock() }
        pruneExpired()
        if sessions.count >= maxSessions {
            // Evict the session closest to expiry to stay bounded.
            if let oldest = sessions.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                sessions.removeValue(forKey: oldest)
            }
        }
        sessions[session.sid] = session
    }

    public func session(for sid: String) -> SecureChannelSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sid] else { return nil }
        if session.isExpired {
            sessions.removeValue(forKey: sid)
            return nil
        }
        return session
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeAll()
    }

    private func pruneExpired() {
        for (sid, session) in sessions where session.isExpired {
            sessions.removeValue(forKey: sid)
        }
    }
}
