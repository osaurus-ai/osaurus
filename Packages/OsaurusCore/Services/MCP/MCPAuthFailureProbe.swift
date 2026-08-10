//
//  MCPAuthFailureProbe.swift
//  osaurus
//
//  Pure helpers for interpreting an HTTP auth failure from a remote MCP
//  endpoint. The Swift MCP SDK doesn't expose response status or headers on
//  its error type, so after a failed connect we re-probe the endpoint
//  directly and classify the response here. Networking stays with the
//  callers; these functions only inspect a response so they stay
//  unit-testable.
//

import Foundation

/// Outcome of re-probing an MCP endpoint after a failed connect.
public struct MCPAuthFailureProbeResult: Sendable, Equatable {
    /// HTTP status of the probe response (401 or 403).
    public let statusCode: Int
    /// Parsed `WWW-Authenticate: Bearer` challenge, when the server sent one.
    /// Servers that only accept static API tokens often omit it, and some
    /// OAuth-capable servers (e.g. runalyze.com) send it even though they
    /// also accept a personal API token.
    public let challenge: MCPBearerChallenge?
    /// Error message extracted from a JSON-RPC error body, e.g.
    /// `{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Missing authentication token."}}`.
    public let serverMessage: String?
    /// Whether the probe request carried an `Authorization` header. Used to
    /// phrase "token rejected" vs "token required".
    public let sentAuthorization: Bool

    public init(
        statusCode: Int,
        challenge: MCPBearerChallenge?,
        serverMessage: String?,
        sentAuthorization: Bool
    ) {
        self.statusCode = statusCode
        self.challenge = challenge
        self.serverMessage = serverMessage
        self.sentAuthorization = sentAuthorization
    }
}

public enum MCPAuthFailureProbe {
    /// A spec-complete `initialize` request body for probing. Some servers
    /// reject a params-less shorthand before they even check auth, which
    /// would make the probe misclassify an auth failure as a protocol one.
    public static func handshakeBody() -> Data {
        Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"Osaurus","version":"1.0.0"}}}"#
                .utf8
        )
    }

    /// Interpret a probe response. Returns `nil` unless the status is 401 or
    /// 403 — anything else is not an auth failure and the caller should fall
    /// back to its generic error handling. Unlike the challenge parser alone,
    /// this classifies a bare 401/403 with no `WWW-Authenticate` header as an
    /// auth failure too.
    public static func evaluate(
        response: HTTPURLResponse,
        body: Data?,
        sentAuthorization: Bool
    ) -> MCPAuthFailureProbeResult? {
        guard response.statusCode == 401 || response.statusCode == 403 else { return nil }
        let header =
            response.value(forHTTPHeaderField: "WWW-Authenticate")
            ?? response.value(forHTTPHeaderField: "www-authenticate")
        return MCPAuthFailureProbeResult(
            statusCode: response.statusCode,
            challenge: MCPWWWAuthenticate.parseBearer(header),
            serverMessage: body.flatMap { jsonRPCErrorMessage(from: $0) },
            sentAuthorization: sentAuthorization
        )
    }

    /// Extract `error.message` (or a top-level string `error` / `message`)
    /// from a JSON response body, if present.
    public static func jsonRPCErrorMessage(from body: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        if let error = object["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.isEmpty
        {
            return message
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    /// Human-readable failure line for the provider row. Phrased per auth
    /// type: an API-key provider must never be told to "sign in" (that's the
    /// OAuth flow), and an OAuth challenge must not override an explicitly
    /// configured API key.
    public static func failureDescription(
        authType: MCPProviderAuthType,
        probe: MCPAuthFailureProbeResult
    ) -> String {
        let detail =
            probe.challenge?.errorDescription
            ?? probe.serverMessage
            ?? probe.challenge?.error
        let suffix = detail.map { ": \($0)" } ?? "."
        switch authType {
        case .bearerToken:
            if probe.sentAuthorization {
                return "The server rejected the saved API token (HTTP \(probe.statusCode))\(suffix)"
            }
            return "The server requires an API token (HTTP \(probe.statusCode))\(suffix)"
        case .oauth:
            return detail ?? "Server requires sign in"
        case .none:
            return "The server requires authentication (HTTP \(probe.statusCode))\(suffix)"
        }
    }
}
