//
//  MCPWWWAuthenticate.swift
//  osaurus
//
//  Minimal RFC 7235 `WWW-Authenticate` parser.
//
//  We only care about the `Bearer` challenge MCP servers emit on 401, but we
//  parse the param list strictly enough to extract `resource_metadata=`,
//  `scope=`, `error=`, and `error_description=`. Robustness rules:
//
//  - One challenge per response (the spec allows multiple; in practice MCP
//    servers send exactly one Bearer challenge).
//  - Tolerates either quoted (`name="value"`) or unquoted (`name=value`) params.
//  - Case-insensitive keys (`scheme` and parameter names).
//

import Foundation

/// Parsed `WWW-Authenticate: Bearer ...` challenge.
public struct MCPBearerChallenge: Sendable, Equatable {
    /// `realm` parameter, if any.
    public let realm: String?
    /// `scope` parameter — space-delimited per RFC 6750 §3.
    public let scope: String?
    /// `error` parameter (e.g. `invalid_token`, `insufficient_scope`).
    public let error: String?
    /// `error_description` parameter.
    public let errorDescription: String?
    /// `resource_metadata` parameter from the MCP `2025-06-18` spec — the URL
    /// of the protected-resource metadata document. When present, the client
    /// should fetch it directly instead of probing `/.well-known/...`.
    public let resourceMetadataURL: URL?

    public init(
        realm: String? = nil,
        scope: String? = nil,
        error: String? = nil,
        errorDescription: String? = nil,
        resourceMetadataURL: URL? = nil
    ) {
        self.realm = realm
        self.scope = scope
        self.error = error
        self.errorDescription = errorDescription
        self.resourceMetadataURL = resourceMetadataURL
    }
}

public enum MCPWWWAuthenticate {
    /// Parse a `WWW-Authenticate` header value. Returns `nil` if the header
    /// is missing or doesn't contain a `Bearer` challenge.
    public static func parseBearer(_ header: String?) -> MCPBearerChallenge? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
            return nil
        }

        // Strip leading scheme name. Bearer is the only one we handle.
        let lower = header.lowercased()
        guard lower.hasPrefix("bearer") else { return nil }

        let paramsString: String
        if header.count > "bearer".count {
            let idx = header.index(header.startIndex, offsetBy: "bearer".count)
            paramsString = String(header[idx...]).trimmingCharacters(in: .whitespaces)
        } else {
            paramsString = ""
        }

        let params = parseParams(paramsString)
        return MCPBearerChallenge(
            realm: params["realm"],
            scope: params["scope"],
            error: params["error"],
            errorDescription: params["error_description"],
            resourceMetadataURL: params["resource_metadata"].flatMap { URL(string: $0) }
        )
    }

    /// Parse a comma-separated `key=value` / `key="value"` list.
    private static func parseParams(_ input: String) -> [String: String] {
        var params: [String: String] = [:]
        var index = input.startIndex
        while index < input.endIndex {
            // Skip whitespace + commas.
            while index < input.endIndex, input[index].isWhitespace || input[index] == "," {
                index = input.index(after: index)
            }
            guard index < input.endIndex else { break }

            // Read key up to '='.
            let keyStart = index
            while index < input.endIndex, input[index] != "=", input[index] != "," {
                index = input.index(after: index)
            }
            let key = input[keyStart ..< index].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { break }

            if index >= input.endIndex || input[index] != "=" {
                // Token without value — store as empty.
                params[key] = ""
                continue
            }
            index = input.index(after: index)  // consume '='

            // Read value: either "..." (quoted, possibly with escapes) or token to next ','.
            if index < input.endIndex, input[index] == "\"" {
                index = input.index(after: index)
                var value = ""
                while index < input.endIndex {
                    let c = input[index]
                    if c == "\\" {
                        let next = input.index(after: index)
                        if next < input.endIndex {
                            value.append(input[next])
                            index = input.index(after: next)
                            continue
                        }
                    } else if c == "\"" {
                        index = input.index(after: index)
                        break
                    }
                    value.append(c)
                    index = input.index(after: index)
                }
                params[key] = value
            } else {
                let valStart = index
                while index < input.endIndex, input[index] != "," {
                    index = input.index(after: index)
                }
                let value = input[valStart ..< index].trimmingCharacters(in: .whitespaces)
                params[key] = String(value)
            }
        }
        return params
    }
}
