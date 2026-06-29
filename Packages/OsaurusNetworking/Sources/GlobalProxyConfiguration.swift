//
//  GlobalProxyConfiguration.swift
//  OsaurusNetworking
//

import CFNetwork
import Foundation
import Network

/// A validated global proxy endpoint that can be safely translated into
/// Foundation's `connectionProxyDictionary` without accepting arbitrary
/// URL-shaped input from settings or import paths.
public struct GlobalProxyConfiguration: Equatable, Sendable {
    /// The supported proxy families are intentionally limited to transports
    /// URLSession can express through `connectionProxyDictionary`.
    public enum Scheme: String, Sendable {
        case http
        case https
        case socks
    }

    /// Human-entered proxy URLs are often pasted from provider docs, so parsing
    /// keeps a typed reason for rejection instead of falling back silently.
    public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case empty
        case invalidURL
        case unsupportedScheme(String?)
        case missingHost
        case unsafeHost(String)
        case missingPort
        case invalidPort(Int)
        case unsupportedURLComponents
        case credentialsInURL

        public var errorDescription: String? {
            switch self {
            case .empty:
                "Proxy URL is empty."
            case .invalidURL:
                "Proxy URL could not be parsed."
            case .unsupportedScheme(let scheme):
                if let scheme {
                    "Proxy URL scheme '\(scheme)' is not supported."
                } else {
                    "Proxy URL must include a scheme."
                }
            case .missingHost:
                "Proxy URL must include a host."
            case .unsafeHost(let host):
                "Proxy host '\(host)' is reserved for local networking."
            case .missingPort:
                "Proxy URL must include an explicit port."
            case .invalidPort(let port):
                "Proxy port \(port) is out of range (must be 1–65535)."
            case .unsupportedURLComponents:
                "Proxy URL must only contain scheme, host, and port."
            case .credentialsInURL:
                "Proxy credentials must not be embedded in the URL."
            }
        }
    }

    public let scheme: Scheme
    public let host: String
    public let port: Int

    public init(urlString: String) throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard let components = URLComponents(string: trimmed) else {
            throw ValidationError.invalidURL
        }

        guard let scheme = Self.parseScheme(components.scheme) else {
            throw ValidationError.unsupportedScheme(components.scheme)
        }

        // Proxy credentials need a separate encrypted storage story. Accepting
        // URL userinfo here would make later redaction and Keychain boundaries
        // much harder to audit.
        if components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
            throw ValidationError.credentialsInURL
        }

        // The global proxy setting is an endpoint, not a PAC file, Unix socket,
        // or endpoint-specific override list. Rejecting extra URL components
        // keeps secrets out of query strings and avoids path-based surprises.
        let path = components.percentEncodedPath
        let hasUnsupportedPath = !path.isEmpty && path != "/"
        let hasURLDecorators =
            components.percentEncodedQuery != nil
            || components.percentEncodedFragment != nil
        if hasUnsupportedPath || hasURLDecorators {
            throw ValidationError.unsupportedURLComponents
        }

        guard let rawHost = components.host, !rawHost.isEmpty else {
            throw ValidationError.missingHost
        }
        let host = Self.normalizeHost(rawHost)
        guard !host.isEmpty else { throw ValidationError.missingHost }
        guard !Self.isLocalOnlyHost(host) else { throw ValidationError.unsafeHost(host) }
        guard let port = components.port else { throw ValidationError.missingPort }
        // `URLComponents` parses port 0 and values above 65535 verbatim; reject
        // them so an invalid port can't reach the CFNetwork proxy dictionary.
        guard (1 ... 65535).contains(port) else { throw ValidationError.invalidPort(port) }

        self.scheme = scheme
        self.host = host
        self.port = port
    }

    /// Foundation consumes proxy settings as CFNetwork key/value pairs; this
    /// computed dictionary is the single place that shapes those keys.
    public var connectionProxyDictionary: [AnyHashable: Any] {
        switch scheme {
        case .http, .https:
            [
                key(kCFNetworkProxiesHTTPEnable): 1,
                key(kCFNetworkProxiesHTTPProxy): host,
                key(kCFNetworkProxiesHTTPPort): port,
                key(kCFNetworkProxiesHTTPSEnable): 1,
                key(kCFNetworkProxiesHTTPSProxy): host,
                key(kCFNetworkProxiesHTTPSPort): port,
            ]
        case .socks:
            [
                key(kCFNetworkProxiesSOCKSEnable): 1,
                key(kCFNetworkProxiesSOCKSProxy): host,
                key(kCFNetworkProxiesSOCKSPort): port,
            ]
        }
    }

    /// Logs and PR evidence should be able to identify which endpoint was used
    /// without ever echoing rejected credential-bearing input.
    public var redactedDescription: String {
        "\(scheme.rawValue)://\(host):\(port)"
    }

    private static func parseScheme(_ scheme: String?) -> Scheme? {
        guard let scheme = scheme?.lowercased() else { return nil }
        switch scheme {
        case "http":
            return .http
        case "https":
            return .https
        case "socks", "socks5":
            return .socks
        default:
            return nil
        }
    }

    private static func normalizeHost(_ host: String) -> String {
        let normalized =
            host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            return String(normalized.dropFirst().dropLast())
        }
        return normalized
    }

    private static func isLocalOnlyHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        let isLocalDomain =
            normalized == "localhost"
            || normalized.hasSuffix(".localhost")
            || normalized.hasSuffix(".local")
        if isLocalDomain {
            return true
        }

        if let address = IPv4Address(normalized) {
            let octets = Array(address.rawValue)
            return octets[0] == 0
                || octets[0] == 127
                || (octets[0] == 169 && octets[1] == 254)
        }

        if let address = IPv6Address(normalized) {
            let octets = Array(address.rawValue)
            let isUnspecified = octets.allSatisfy { $0 == 0 }
            let isLoopback = octets.dropLast().allSatisfy { $0 == 0 } && octets.last == 1
            let isLinkLocal = octets[0] == 0xfe && (octets[1] & 0xc0) == 0x80
            return isUnspecified || isLoopback || isLinkLocal
        }

        return false
    }

    private func key(_ value: CFString) -> AnyHashable {
        AnyHashable(value as String)
    }
}

/// Factory helpers centralize proxy injection so call-site migrations can opt
/// into the same validation and rollback behavior one session at a time.
public enum GlobalProxyURLSessionFactory {
    /// Return a copied configuration so the proxy dictionary never mutates a
    /// caller-owned `URLSessionConfiguration` that may be reused elsewhere.
    public static func makeConfiguration(
        base: URLSessionConfiguration = .default,
        proxy: GlobalProxyConfiguration?
    ) -> URLSessionConfiguration {
        let configuration =
            base.copy() as? URLSessionConfiguration
            ?? URLSessionConfiguration.default
        if let proxy {
            configuration.connectionProxyDictionary = proxy.connectionProxyDictionary
        }
        return configuration
    }

    /// Build the session from the shaped configuration without touching TLS or
    /// delegate policy; certificate validation remains Foundation's default.
    public static func makeSession(
        base: URLSessionConfiguration = .default,
        proxy: GlobalProxyConfiguration?,
        delegate: URLSessionDelegate? = nil,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        let configuration = makeConfiguration(base: base, proxy: proxy)
        return URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
    }
}
