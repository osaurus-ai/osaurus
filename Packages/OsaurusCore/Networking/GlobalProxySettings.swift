//
//  GlobalProxySettings.swift
//  osaurus
//

import Foundation

/// Disk-backed resolver for the global proxy endpoint that can be used from
/// background services without crossing the `@MainActor` settings store.
public enum GlobalProxySettings {
    /// Read the persisted server configuration and return the validated proxy
    /// endpoint. Invalid or missing values fail closed to normal networking so
    /// a stale config file cannot break all outbound traffic.
    public static func currentConfiguration() -> GlobalProxyConfiguration? {
        configuration(from: diskBackedServerConfiguration())
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
