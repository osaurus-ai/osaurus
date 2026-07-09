//
//  GitHubAuth.swift
//  osaurus
//
//  Keychain-backed GitHub API token. Unauthenticated requests to
//  api.github.com are capped at 60 req/hour per IP, so browsing, importing,
//  or updating a plugin repo (which fans out many Contents-API calls) trips a
//  403 mid-flight. Sending a user token raises the limit to 5,000/hr. A token
//  with no scopes is enough for the public plugin repos Osaurus reads.
//

import Foundation
import os

enum GitHubAuth {
    private static let keychainService = "com.dinoki.osaurus.github"
    private static let keychainAccount = "api-token"

    /// Two-level optional: outer `nil` means "not read from the keychain
    /// yet", inner `nil` means "read, no token stored". Cached so the hot
    /// fetch paths never touch the Security framework after the first read.
    private static let cachedToken = OSAllocatedUnfairLock<String??>(initialState: nil)

    /// The stored token, or `nil` when none is configured. First access reads
    /// the keychain synchronously; call `preloadInBackground()` early so that
    /// read never lands on the main thread.
    static var token: String? {
        cachedToken.withLock { (state: inout String??) -> String? in
            if case .some(let loaded) = state { return loaded }
            let raw = Keychain.read(service: keychainService, account: keychainAccount)
                .flatMap { String(data: $0, encoding: .utf8) }
            let value = normalize(raw)
            state = .some(value)
            return value
        }
    }

    /// Normalize a raw token: trim surrounding whitespace and treat a blank or
    /// nil value as "no token". Pure so the trimming/blank rules are
    /// unit-testable without touching the keychain.
    static func normalize(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Store (or clear, when empty/nil) the token. The in-memory cache is
    /// authoritative immediately; the keychain write runs off the caller's
    /// thread.
    static func setToken(_ newValue: String?) {
        let value = normalize(newValue)
        cachedToken.withLock { $0 = .some(value) }
        if let value, let data = value.data(using: .utf8) {
            Keychain.writeInBackground(service: keychainService, account: keychainAccount, data: data)
        } else {
            Task.detached(priority: .utility) {
                Keychain.delete(service: keychainService, account: keychainAccount)
            }
        }
    }

    static var hasToken: Bool { token != nil }

    /// Warm the token cache off the main thread so the first authorized
    /// request doesn't pay a synchronous keychain read.
    static func preloadInBackground() {
        Task.detached(priority: .utility) { _ = token }
    }
}
