//
//  HuggingFaceAuth.swift
//  osaurus
//
//  Keychain-backed Hugging Face access token. Anonymous requests to
//  huggingface.co are aggressively rate-limited; sending a user token on
//  metadata and file requests raises those limits substantially and also
//  unlocks gated repos the user has been granted access to.
//

import Foundation
import os

enum HuggingFaceAuth {
    private static let keychainService = "com.dinoki.osaurus.huggingface"
    private static let keychainAccount = "access-token"

    /// Two-level optional: outer `nil` means "not read from the keychain
    /// yet", inner `nil` means "read, no token stored". Cached so the hot
    /// download/metadata paths never touch the Security framework after the
    /// first read.
    private static let cachedToken = OSAllocatedUnfairLock<String??>(initialState: nil)

    /// The stored token, or `nil` when none is configured. First access
    /// reads the keychain synchronously; call `preloadInBackground()` early
    /// so that read never lands on the main thread.
    static var token: String? {
        cachedToken.withLock { (state: inout String??) -> String? in
            if case .some(let loaded) = state { return loaded }
            let raw = Keychain.read(service: keychainService, account: keychainAccount)
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (raw?.isEmpty == false) ? raw : nil
            state = .some(value)
            return value
        }
    }

    /// Store (or clear, when empty/nil) the token. The in-memory cache is
    /// authoritative immediately; the keychain write runs off the caller's
    /// thread.
    static func setToken(_ newValue: String?) {
        let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
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

    // MARK: - Download-time prompt

    private static let promptDismissedDefaultsKey = "HuggingFaceTokenPromptDismissed"

    /// Whether starting a download should first offer the token prompt:
    /// only when no token is configured and the user hasn't already
    /// declined the offer once.
    static var shouldOfferTokenPrompt: Bool {
        !hasToken && !UserDefaults.standard.bool(forKey: promptDismissedDefaultsKey)
    }

    /// Remember that the user saw the download-time prompt (saved a token
    /// or chose to continue without one) so it never nags again.
    static func markPromptDismissed() {
        UserDefaults.standard.set(true, forKey: promptDismissedDefaultsKey)
    }

    /// Re-arm the download-time prompt. Called when a tokenless download
    /// fails with a rate-limit/auth error — the one moment the offer is
    /// clearly worth repeating.
    static func resetPromptDismissal() {
        UserDefaults.standard.removeObject(forKey: promptDismissedDefaultsKey)
    }

    /// Attach `Authorization: Bearer <token>` when a token is configured.
    static func authorize(_ request: inout URLRequest) {
        guard let token else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}
