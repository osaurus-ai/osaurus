//
//  LoginWithOsaurusRequest.swift
//  OsaurusCore
//
//  Parses and validates a "Log in with Osaurus" deep link:
//
//    osaurus://auth/authorize?client_id=<origin>&redirect_uri=<url>
//        &state=<opaque>&nonce=<opaque>[&response_mode=fragment|query]
//
//  Only first-party origins may ask for a login. The answer is always
//  delivered to `redirect_uri`, which must sit on the `client_id` origin, so
//  an assertion can only ever reach the site it was issued for.
//
//  See docs/LOGIN_WITH_OSAURUS.md for the protocol.
//

import Foundation

// MARK: - Errors

/// Failures, named after the OAuth 2.0 error codes the website receives.
public enum LoginWithOsaurusError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case unauthorizedClient(String)
    case accessDenied
    case loginRequired
    case temporarilyUnavailable
    case serverError(String)

    /// The `error` value sent back to `redirect_uri`.
    public var oauthCode: String {
        switch self {
        case .invalidRequest: return "invalid_request"
        case .unauthorizedClient: return "unauthorized_client"
        case .accessDenied: return "access_denied"
        case .loginRequired: return "login_required"
        case .temporarilyUnavailable: return "temporarily_unavailable"
        case .serverError: return "server_error"
        }
    }

    /// Developer-facing detail, sent as `error_description`.
    public var detail: String? {
        switch self {
        case .invalidRequest(let detail), .unauthorizedClient(let detail), .serverError(let detail):
            return detail
        case .accessDenied: return "The user declined the sign-in."
        case .loginRequired: return "This Mac has no Osaurus identity yet."
        case .temporarilyUnavailable: return "Another sign-in is already waiting for the user."
        }
    }
}

// MARK: - Clients

/// The website origins allowed to request a login.
public struct LoginWithOsaurusClients: Sendable, Equatable {
    public static let firstPartyOrigins: Set<String> = [
        "https://store.osaurus.ai",
        "https://osaurus.ai",
        "https://www.osaurus.ai",
    ]

    /// DEBUG builds only: extra origins (array of strings, or one
    /// comma-separated string) for staging and local development.
    public static let extraOriginsDefaultsKey = "ai.osaurus.loginWithOsaurus.extraClientOrigins"

    public let origins: Set<String>
    /// Plain-http loopback origins (`http://localhost:3000`) are accepted
    /// only when this is on, and still only when listed in `origins`.
    public let allowsLoopbackHTTP: Bool

    public init(origins: Set<String>, allowsLoopbackHTTP: Bool = false) {
        self.allowsLoopbackHTTP = allowsLoopbackHTTP
        self.origins = Set(origins.compactMap { Self.canonicalOrigin($0, allowsLoopbackHTTP: allowsLoopbackHTTP) })
    }

    public static let firstParty = LoginWithOsaurusClients(origins: firstPartyOrigins)

    /// First-party origins, plus the developer override in DEBUG builds.
    /// Release builds ignore the override entirely.
    public static func current(defaults: UserDefaults = .standard) -> LoginWithOsaurusClients {
        #if DEBUG
            let extras: [String]
            if let list = defaults.stringArray(forKey: extraOriginsDefaultsKey) {
                extras = list
            } else if let raw = defaults.string(forKey: extraOriginsDefaultsKey) {
                extras = raw.split(separator: ",").map(String.init)
            } else {
                extras = []
            }
            let trimmed = extras.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return LoginWithOsaurusClients(origins: firstPartyOrigins.union(trimmed), allowsLoopbackHTTP: true)
        #else
            return .firstParty
        #endif
    }

    public func allows(_ canonicalOrigin: String) -> Bool {
        origins.contains(canonicalOrigin)
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1"]

    /// `scheme://host[:port]` lowercased with the default port dropped, or
    /// nil when `raw` is not a bare origin (any path other than `/`, query,
    /// fragment, or credentials disqualifies it).
    public static func canonicalOrigin(_ raw: String, allowsLoopbackHTTP: Bool) -> String? {
        guard let components = URLComponents(string: raw),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(), !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/"
        else { return nil }
        return origin(scheme: scheme, host: host, port: components.port, allowsLoopbackHTTP: allowsLoopbackHTTP)
    }

    /// The canonical origin a URL is served from, under the same scheme rules.
    static func origin(of url: URL, allowsLoopbackHTTP: Bool) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        return origin(scheme: scheme, host: host, port: components.port, allowsLoopbackHTTP: allowsLoopbackHTTP)
    }

    private static func origin(scheme: String, host: String, port: Int?, allowsLoopbackHTTP: Bool) -> String? {
        switch scheme {
        case "https":
            break
        case "http":
            guard allowsLoopbackHTTP, loopbackHosts.contains(host) else { return nil }
        default:
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        if let port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

// MARK: - Request

/// A validated login request. Every field has passed the checks in `parse`.
public struct LoginWithOsaurusRequest: Equatable, Sendable {
    public enum ResponseMode: String, Sendable {
        case fragment
        case query
    }

    public static let deepLinkHost = "auth"
    public static let deepLinkPath = "/authorize"

    static let stateLength = 1 ... 512
    static let nonceLength = 16 ... 128
    static let maxRedirectURILength = 2048

    /// Canonical origin, e.g. `https://store.osaurus.ai`.
    public let clientID: String
    public let redirectURI: URL
    public let state: String
    public let nonce: String
    public let responseMode: ResponseMode

    /// The host shown to the user in the consent panel.
    public var displayHost: String {
        URLComponents(string: clientID)?.host ?? clientID
    }

    public var replyTarget: LoginWithOsaurusReplyTarget {
        LoginWithOsaurusReplyTarget(redirectURI: redirectURI, state: state, responseMode: responseMode)
    }

    /// True for `osaurus://auth/authorize`, whether or not it is well formed,
    /// so a malformed login link never falls through to another router.
    public static func claims(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "osaurus" && url.host?.lowercased() == deepLinkHost
    }

    public static func parse(
        _ url: URL,
        clients: LoginWithOsaurusClients
    ) -> Result<LoginWithOsaurusRequest, LoginWithOsaurusRejection> {
        func reject(_ error: LoginWithOsaurusError, _ reply: LoginWithOsaurusReplyTarget? = nil)
            -> Result<LoginWithOsaurusRequest, LoginWithOsaurusRejection>
        {
            .failure(LoginWithOsaurusRejection(error: error, reply: reply))
        }

        guard claims(url), url.path == deepLinkPath,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return reject(.invalidRequest("Not an osaurus://auth/authorize link.")) }

        // A repeated parameter makes the request ambiguous, so it is refused
        // before anything is trusted (RFC 6749 §3.1).
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard params[item.name] == nil else {
                return reject(.invalidRequest("Parameter \(item.name) appears more than once."))
            }
            params[item.name] = item.value ?? ""
        }

        guard let rawClient = params["client_id"],
            let clientID = LoginWithOsaurusClients.canonicalOrigin(
                rawClient, allowsLoopbackHTTP: clients.allowsLoopbackHTTP)
        else { return reject(.invalidRequest("client_id must be a bare https origin.")) }
        guard clients.allows(clientID) else {
            return reject(.unauthorizedClient("\(clientID) is not allowed to use Log in with Osaurus."))
        }

        guard let rawRedirect = params["redirect_uri"], rawRedirect.count <= maxRedirectURILength,
            let redirectComponents = URLComponents(string: rawRedirect),
            redirectComponents.fragment == nil,
            redirectComponents.user == nil, redirectComponents.password == nil,
            let redirectURI = redirectComponents.url,
            LoginWithOsaurusClients.origin(of: redirectURI, allowsLoopbackHTTP: clients.allowsLoopbackHTTP)
                == clientID
        else { return reject(.invalidRequest("redirect_uri must be a URL on the client_id origin.")) }

        // From here on errors can be reported back to the website.
        let responseMode: ResponseMode
        switch params["response_mode"] {
        case nil: responseMode = .fragment
        case let raw?:
            guard let mode = ResponseMode(rawValue: raw) else {
                let reply = LoginWithOsaurusReplyTarget(redirectURI: redirectURI, state: nil, responseMode: .fragment)
                return reject(.invalidRequest("response_mode must be fragment or query."), reply)
            }
            responseMode = mode
        }

        guard let state = params["state"], isOpaqueToken(state, length: stateLength) else {
            let reply = LoginWithOsaurusReplyTarget(redirectURI: redirectURI, state: nil, responseMode: responseMode)
            return reject(.invalidRequest("state must be 1-512 URL-safe characters."), reply)
        }
        let reply = LoginWithOsaurusReplyTarget(redirectURI: redirectURI, state: state, responseMode: responseMode)

        guard let nonce = params["nonce"], isOpaqueToken(nonce, length: nonceLength) else {
            return reject(.invalidRequest("nonce must be 16-128 URL-safe characters."), reply)
        }

        return .success(
            LoginWithOsaurusRequest(
                clientID: clientID, redirectURI: redirectURI, state: state, nonce: nonce,
                responseMode: responseMode))
    }

    /// RFC 3986 unreserved characters only, so the value survives any
    /// query/fragment encoding unchanged.
    static func isOpaqueToken(_ value: String, length: ClosedRange<Int>) -> Bool {
        guard length.contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"),
                UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                UInt8(ascii: "_"), UInt8(ascii: "~"):
                return true
            default:
                return false
            }
        }
    }
}

/// Where an answer may be delivered: only ever built from a `redirect_uri`
/// that already passed origin validation.
public struct LoginWithOsaurusReplyTarget: Equatable, Sendable {
    public let redirectURI: URL
    /// Nil when the request's own `state` was invalid.
    public let state: String?
    public let responseMode: LoginWithOsaurusRequest.ResponseMode
}

public struct LoginWithOsaurusRejection: Error, Equatable, Sendable {
    public let error: LoginWithOsaurusError
    /// Nil when the request can't be answered safely (unknown client or bad
    /// `redirect_uri`): the user sees an in-app error instead.
    public let reply: LoginWithOsaurusReplyTarget?
}
