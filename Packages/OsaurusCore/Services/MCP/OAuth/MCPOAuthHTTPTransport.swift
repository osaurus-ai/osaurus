//
//  MCPOAuthHTTPTransport.swift
//  osaurus
//
//  Shared transport and URL trust policy for MCP OAuth metadata and token traffic.
//

import Foundation
import os

enum MCPOAuthHTTPTransport {
    private struct NoRedirectSessionState {
        let proxyKey: String
        let session: URLSession
    }

    private static let noRedirectSessionBox = OSAllocatedUnfairLock<NoRedirectSessionState?>(initialState: nil)

    static func noRedirectSession() -> URLSession {
        let key = GlobalProxySettings.currentProxyCacheKey()
        return noRedirectSessionBox.withLock { state in
            if let state, state.proxyKey == key {
                return state.session
            }

            state?.session.finishTasksAndInvalidate()
            let session = makeNoRedirectSession()
            state = NoRedirectSessionState(proxyKey: key, session: session)
            return session
        }
    }

    private static func makeNoRedirectSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        return GlobalProxySettings.makeSession(
            base: configuration,
            delegate: MCPOAuthNoRedirectDelegate.shared,
            delegateQueue: nil
        )
    }

    /// OAuth endpoints carry code/token material, so redirects must be visible to the
    /// caller instead of followed by Foundation with the original request context.
    static func redirectionRequest(
        response: HTTPURLResponse,
        proposedRequest: URLRequest
    ) -> URLRequest? {
        nil
    }
}

final class MCPOAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = MCPOAuthNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            MCPOAuthHTTPTransport.redirectionRequest(
                response: response,
                proposedRequest: request
            )
        )
    }
}

enum MCPOAuthURLPolicy {
    /// Metadata discovered from a public server is untrusted input. Local MCP development
    /// remains possible, but a public server cannot redirect discovery toward local or
    /// cloud-metadata addresses.
    static func allowsDiscoveredURL(_ candidate: URL, from origin: URL) -> Bool {
        guard isAbsoluteHTTPURL(candidate), hasNoUserInfoOrFragment(candidate) else {
            return false
        }

        if isLocalDevelopmentURL(origin) {
            if isLocalOrPrivateHost(candidate.host) {
                return true
            }
            return candidate.scheme?.lowercased() == "https"
        }

        guard candidate.scheme?.lowercased() == "https" else {
            return false
        }
        return !isLocalOrPrivateHost(candidate.host)
    }

    static func isAbsoluteHTTPURL(_ url: URL) -> Bool {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            return false
        }
        return true
    }

    static func isLocalDevelopmentURL(_ url: URL) -> Bool {
        guard
            isAbsoluteHTTPURL(url),
            let host = url.host
        else {
            return false
        }
        return isLocalOrPrivateHost(host)
    }

    static func hasNoUserInfoOrFragment(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.user == nil && components.password == nil && components.fragment == nil
    }

    static func isLocalOrPrivateHost(_ host: String?) -> Bool {
        guard let host else { return true }
        let normalized =
            host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        guard !normalized.isEmpty else { return true }
        let isLocalDomain =
            normalized == "localhost"
            || normalized.hasSuffix(".localhost")
            || normalized.hasSuffix(".local")
        if isLocalDomain {
            return true
        }

        if let octets = ipv4Octets(normalized) {
            let first = octets[0]
            let second = octets[1]
            return first == 0
                || first == 10
                || first == 127
                || (first == 100 && second >= 64 && second <= 127)
                || (first == 169 && second == 254)
                || (first == 172 && second >= 16 && second <= 31)
                || (first == 192 && second == 168)
                || (first >= 224 && first <= 239)
        }

        if normalized.contains(":") {
            return isLocalOrPrivateIPv6Literal(normalized)
        }

        return false
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard
                !part.isEmpty,
                part.allSatisfy(\.isNumber),
                let value = UInt8(part)
            else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    private static func isLocalOrPrivateIPv6Literal(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        if lowercased == "::" || lowercased == "::1" {
            return true
        }

        guard
            let firstHextetText =
                lowercased
                .split(separator: ":", omittingEmptySubsequences: false)
                .first(where: { !$0.isEmpty }),
            let firstHextet = UInt16(firstHextetText, radix: 16)
        else {
            return false
        }

        let firstByte = UInt8(firstHextet >> 8)
        return (firstByte & 0xfe) == 0xfc
            || (firstHextet >= 0xfe80 && firstHextet <= 0xfebf)
            || firstByte == 0xff
    }
}
