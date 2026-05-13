//
//  MCPOAuthCanonicalURL.swift
//  osaurus
//
//  Canonical resource URL normalization for RFC 8707 resource indicators.
//
//  The single highest-leverage gotcha when implementing MCP OAuth: every
//  authorization & token request must include the **same** canonical resource
//  URL so the server can validate audience binding. Skipping this works on
//  some servers and silently fails on Notion/Atlassian. Rules below match
//  the MCP authorization spec (`2025-06-18`) §3.3:
//
//  - lowercase scheme + host
//  - drop default ports (80/443)
//  - preserve the full path (specifically: keep `/mcp` if present)
//  - drop fragment, drop trailing slash
//  - drop query string
//

import Foundation

public enum MCPOAuthCanonicalURL {
    /// Returns the canonical resource string for a given MCP server URL, or `nil`
    /// if the input cannot be parsed as a usable HTTP(S) URL.
    public static func canonicalize(_ rawURL: String) -> String? {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return canonicalize(url)
    }

    public static func canonicalize(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }

        components.scheme = scheme
        components.host = host
        components.fragment = nil
        components.query = nil
        components.user = nil
        components.password = nil

        // Drop default ports per generic URI normalization (RFC 3986 §3.2.3).
        if let port = components.port,
            (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        {
            components.port = nil
        }

        // Preserve path verbatim except for collapsing a single trailing slash on
        // a non-root path. `/mcp` and `/mcp/` are treated as the *same* canonical
        // resource — pick the no-trailing-slash form.
        var path = components.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path

        return components.string
    }
}
