//
//  GlobalProxySettings.swift
//  osaurus
//

import Foundation
import os

/// Disk-backed resolver for the global proxy endpoint that can be used from
/// background services without crossing the `@MainActor` settings store.
public enum GlobalProxySettings {
    private struct SharedSessionState {
        let proxyKey: String
        let session: URLSession
    }

    /// Cached one-shot session + the proxy key it was built for. Guarded so
    /// concurrent callers can't race two sessions into the box.
    private static let sharedSessionBox = OSAllocatedUnfairLock<SharedSessionState?>(initialState: nil)

    /// A process-wide `URLSession` for one-shot request/response calls (model
    /// metadata probes, provider connectivity checks, Hugging Face lookups).
    ///
    /// Previously each such call did `makeSession().data(for:)`, creating a
    /// fresh `URLSession` that was never invalidated — every call leaked a
    /// session (and its connection pool / delegate queue) for the lifetime of
    /// the process. Reusing one session removes that churn. The session is
    /// rebuilt (and the old one drained) only when the global proxy endpoint
    /// changes, so proxy edits still take effect.
    ///
    /// Only use this for delegate-less, transient request/response work. Calls
    /// that need a custom delegate (download progress, redirect policy) must
    /// build and own their own session.
    public static func sharedSession() -> URLSession {
        let key = currentProxyCacheKey()
        return sharedSessionBox.withLock { state in
            if let state, state.proxyKey == key {
                return state.session
            }
            // Proxy changed (or first use): drain the old session and build a
            // new one bound to the current endpoint.
            state?.session.finishTasksAndInvalidate()
            let session = makeSession()
            state = SharedSessionState(proxyKey: key, session: session)
            return session
        }
    }

    /// Cache key for shared network clients that need to rebuild when the
    /// persisted proxy endpoint changes, including clients with custom
    /// delegates that cannot use `sharedSession()`.
    static func currentProxyCacheKey() -> String {
        diskBackedServerConfiguration()?.globalProxyURL?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Read the persisted server configuration and return the validated proxy
    /// endpoint. Invalid or missing values fail closed to normal networking so
    /// a stale config file cannot break all outbound traffic.
    public static func currentConfiguration() -> GlobalProxyConfiguration? {
        configuration(from: diskBackedServerConfiguration())
    }

    /// Human-readable state for settings and provider diagnostics. Unlike
    /// `currentConfiguration()`, this distinguishes "not configured" from
    /// "configured but invalid and therefore ignored."
    public static func currentDiagnostic() -> GlobalProxyDiagnosticState {
        diagnostic(from: diskBackedServerConfiguration())
    }

    /// Shape a copied session configuration with the current proxy endpoint.
    public static func makeConfiguration(
        base: URLSessionConfiguration = .default
    ) -> URLSessionConfiguration {
        GlobalProxyURLSessionFactory.makeConfiguration(
            base: base,
            proxy: currentConfiguration()
        )
    }

    /// Build a URLSession that honors the global proxy endpoint while leaving
    /// the caller's delegate and TLS policy untouched.
    public static func makeSession(
        base: URLSessionConfiguration = .default,
        delegate: URLSessionDelegate? = nil,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        GlobalProxyURLSessionFactory.makeSession(
            base: base,
            proxy: currentConfiguration(),
            delegate: delegate,
            delegateQueue: delegateQueue
        )
    }

    /// Testable adapter from persisted settings to proxy configuration. This
    /// stays separate from disk I/O so validation can be pinned without
    /// mutating process-global storage roots.
    static func configuration(from serverConfiguration: ServerConfiguration?) -> GlobalProxyConfiguration? {
        guard
            let rawURL = serverConfiguration?.globalProxyURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty
        else {
            return nil
        }
        return try? GlobalProxyConfiguration(urlString: rawURL)
    }

    /// Testable adapter from persisted settings to a copyable diagnostic row.
    public static func diagnostic(from serverConfiguration: ServerConfiguration?) -> GlobalProxyDiagnosticState {
        guard
            let rawURL = serverConfiguration?.globalProxyURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty
        else {
            return .disabled
        }

        do {
            let proxy = try GlobalProxyConfiguration(urlString: rawURL)
            return .active(proxy.redactedDescription)
        } catch {
            let reason =
                (error as? LocalizedError)?.errorDescription
                ?? "Proxy URL could not be validated."
            return .invalid(reason)
        }
    }

    /// Network services are frequently initialized off the main actor, while
    /// `ServerConfigurationStore` is main-actor isolated because it is also
    /// used by SwiftUI state. Reading the same JSON file directly keeps
    /// session construction synchronous and side-effect free.
    static func diskBackedServerConfiguration() -> ServerConfiguration? {
        let url = OsaurusPaths.resolvePath(
            new: OsaurusPaths.serverConfigFile(),
            legacy: "ServerConfiguration.json"
        )
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ServerConfiguration.self, from: data)
    }
}

/// Safe, display-oriented summary of the persisted global proxy setting.
public enum GlobalProxyDiagnosticState: Equatable, Sendable {
    case disabled
    case active(String)
    case invalid(String)
}
