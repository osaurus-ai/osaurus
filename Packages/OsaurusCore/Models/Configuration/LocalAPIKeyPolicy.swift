//
//  LocalAPIKeyPolicy.swift
//  osaurus
//
//  Host-side, user-level switch: must callers on this Mac present an access
//  key to reach the routes that read chats, drive agents, run tools, or
//  rewrite configuration?
//
//  Off (the default) keeps today's contract: loopback callers are trusted
//  without a key. On, `/sessions`, `/agents`, `/mcp/*`, `/admin/config/*`
//  and `/admin/import/*` require a valid access key (or a harness token
//  where it already applies) even from 127.0.0.1, and browser requests to
//  those routes are refused unless their `Origin` is listed by name in
//  Allowed Origins (CORS).
//
//  The app's own in-process clients (App Intents via `OsaurusLocalClient`)
//  hold no access key; they present `appSessionToken`, a per-launch secret
//  that never leaves this process, and keep today's loopback behavior.
//

import Foundation

enum LocalAPIKeyPolicy {
    /// UserDefaults key. Absent = off, so every existing install upgrading to
    /// this build keeps key-less local access until the owner opts in.
    nonisolated static let defaultsKey = "ai.osaurus.server.requireLocalAccessKey"

    nonisolated static let appTokenHeaderName = "X-Osaurus-App-Token"

    /// Accepted only over a physical loopback connection.
    nonisolated static let appSessionToken: String = {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }()

    nonisolated static func isAppSessionToken(_ presented: String?) -> Bool {
        guard let presented else { return false }
        let lhs = Array(presented.utf8)
        let rhs = Array(appSessionToken.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in lhs.indices { diff |= lhs[index] ^ rhs[index] }
        return diff == 0
    }

    /// The routes the switch protects, matched on the normalized path (the
    /// `/v1` and `/api` prefixes already stripped).
    nonisolated static func isProtectedRoute(_ path: String) -> Bool {
        path == "/sessions" || path.hasPrefix("/sessions/")
            || path == "/agents" || path.hasPrefix("/agents/")
            || path.hasPrefix("/mcp/")
            || path.hasPrefix("/admin/config/")
            || path.hasPrefix("/admin/import/")
    }

    /// A browser origin is admitted to a protected route only when Allowed
    /// Origins names it verbatim; a `*` wildcard does not count.
    nonisolated static func isExplicitlyAllowedOrigin(_ origin: String, allowedOrigins: [String]) -> Bool {
        origin != "*" && allowedOrigins.contains(origin)
    }

    /// Live read — UserDefaults is thread-safe, so the NIO request gate can
    /// consult this per request without a server restart after a toggle.
    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    nonisolated static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        if enabled {
            defaults.set(true, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}
