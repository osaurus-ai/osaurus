//
//  RemoteProviderMCPDetection.swift
//  osaurus
//
//  Pure classifier for a common misconfiguration: pasting an MCP server URL
//  (e.g. https://runalyze.com/mcp) into the API provider form. Model
//  discovery then GETs `<base>/models`, which fails with an unhelpful
//  "Not Found". After such a failure the service POSTs an MCP `initialize`
//  handshake at the base URL; these helpers decide whether the answer looks
//  like an MCP server so the error can point at Tools > Connections instead.
//  Networking stays with the caller so this stays unit-testable.
//

import Foundation

public enum RemoteProviderMCPDetection {
    /// Whether a response to an MCP `initialize` POST looks like it came from
    /// an MCP server rather than a chat completions API.
    ///
    /// Signals, any of which qualifies:
    /// - a JSON body with a `"jsonrpc": "2.0"` envelope (success or error —
    ///   chat APIs never speak JSON-RPC)
    /// - an SSE body carrying a JSON-RPC payload (streamable HTTP servers may
    ///   answer `initialize` over `text/event-stream`)
    /// - a 401/403 whose `WWW-Authenticate: Bearer` challenge advertises
    ///   RFC 9728 protected-resource metadata (MCP-style OAuth)
    public static func looksLikeMCPServer(response: HTTPURLResponse, body: Data?) -> Bool {
        if response.statusCode == 401 || response.statusCode == 403 {
            let header =
                response.value(forHTTPHeaderField: "WWW-Authenticate")
                ?? response.value(forHTTPHeaderField: "www-authenticate")
            if let challenge = MCPWWWAuthenticate.parseBearer(header),
                challenge.resourceMetadataURL != nil
            {
                return true
            }
        }
        guard let body, !body.isEmpty else { return false }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            object["jsonrpc"] as? String == "2.0"
        {
            return true
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.lowercased().contains("text/event-stream") {
            let prefix = String(decoding: body.prefix(4096), as: UTF8.self)
            return prefix.contains(#""jsonrpc""#)
        }
        return false
    }

    /// User-facing replacement for the generic discovery failure once the
    /// base URL has been identified as an MCP server.
    public static func guidance() -> String {
        L(
            "This URL answers like an MCP server, not a chat completions API. Add it under Tools > Connections instead of as an API provider."
        )
    }
}
