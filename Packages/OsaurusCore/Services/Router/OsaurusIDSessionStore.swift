//
//  OsaurusIDSessionStore.swift
//  OsaurusCore
//
//  Keychain-backed storage for the router Osaurus ID session token
//  (`osk_…`). The token is returned exactly once at creation, so it must be
//  persisted immediately; with it, `/id/*` calls (profile refresh, display
//  name / bio edits) use a plain bearer header instead of re-touching the
//  master key on every request.
//

import Foundation
import os

/// Where the session blob lives. Production is the Keychain; tests install an
/// in-memory implementation so they never touch the login keychain and never
/// share the process-global `Keychain` backend override with other suites.
protocol OsaurusIDSessionStorage: Sendable {
    func read() -> KeychainReadOutcome
    func write(_ data: Data)
    func delete()
}

enum OsaurusIDSessionStore {
    private static let keychainService = OsaurusKeychainServices.osaurusID
    private static let keychainAccount = "session-token"

    struct StoredSession: Codable, Equatable, Sendable {
        var token: String
        var sessionID: String?
        /// Server-side expiry, kept so an expired token is dropped locally
        /// instead of burning a doomed request. Nil = trust the server 401.
        var expiresAt: Date?
    }

    private struct KeychainStorage: OsaurusIDSessionStorage {
        func read() -> KeychainReadOutcome {
            Keychain.readItem(service: keychainService, account: keychainAccount)
        }
        func write(_ data: Data) {
            Keychain.writeInBackground(service: keychainService, account: keychainAccount, data: data)
        }
        func delete() {
            Keychain.performInBackground {
                Keychain.delete(service: keychainService, account: keychainAccount)
            }
        }
    }

    private static let storageOverride = OSAllocatedUnfairLock<(any OsaurusIDSessionStorage)?>(initialState: nil)
    private static var storage: any OsaurusIDSessionStorage {
        storageOverride.withLock { $0 } ?? KeychainStorage()
    }

    /// Two-level optional cache: outer `nil` means "not read from the
    /// keychain yet", inner `nil` means "read, no session stored". Keeps the
    /// Security framework off the request path.
    private static let cached = OSAllocatedUnfairLock<StoredSession??>(initialState: nil)

    /// The bearer token, or nil when none is stored or the stored one has
    /// expired (expired tokens are cleared as a side effect).
    static func token(now: Date = Date()) -> String? {
        guard let session = load() else { return nil }
        if let expiresAt = session.expiresAt, expiresAt <= now {
            clear()
            return nil
        }
        return session.token
    }

    static func save(token: String, sessionID: String?, expiresAt: Date?) {
        let session = StoredSession(token: token, sessionID: sessionID, expiresAt: expiresAt)
        cached.withLock { $0 = .some(session) }
        guard let data = try? JSONEncoder().encode(session) else { return }
        storage.write(data)
    }

    /// Drop the stored session — on identity wipe, or when the server
    /// rejects the token (revoked/expired) with a 401.
    static func clear() {
        cached.withLock { $0 = .some(nil) }
        storage.delete()
    }

    private static func load() -> StoredSession? {
        cached.withLock { (state: inout StoredSession??) -> StoredSession? in
            if case .some(let loaded) = state { return loaded }
            let outcome = storage.read()
            let session = outcome.data.flatMap {
                try? JSONDecoder().decode(StoredSession.self, from: $0)
            }
            // Only latch definitive outcomes (found / not-found): a locked
            // keychain must not be cached as "no session" for the process
            // lifetime.
            if outcome.isDefinitive { state = .some(session) }
            return session
        }
    }

    /// Parse the server's ISO-8601 expiry string (with or without fractional
    /// seconds) into a Date for `save`.
    static func expiryDate(from iso8601: String?) -> Date? {
        guard let iso8601, !iso8601.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso8601) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso8601)
    }

    #if DEBUG
        /// Test hook: swap the backing storage (nil restores the Keychain)
        /// and forget the cache so the next read goes to `storage`.
        static func _setStorageForTesting(_ override: (any OsaurusIDSessionStorage)?) {
            storageOverride.withLock { $0 = override }
            cached.withLock { $0 = nil }
        }

        /// Test hook: reset the in-memory cache so a fresh storage read is
        /// observed.
        static func _resetCacheForTesting() {
            cached.withLock { $0 = nil }
        }
    #endif
}
