//
//  MCPToolFilter.swift
//  OsaurusCLICore
//
//  Optional allow-list for `osaurus mcp`.
//
//  Osaurus proxies its whole tool surface — 170+ tools once plugins, folder
//  tools, and MCP providers are loaded. That is roughly 31k tokens of tool
//  definitions in *every* turn for a client that only wants the handful of
//  `osaurus_*` configuration tools, and it hands the client dispatch tools that
//  can start further agent runs.
//
//  Filtering belongs here rather than in each client: the client then never
//  sees the excluded tools at all, so there is nothing to mis-trust and no
//  per-client duplication of the rule.
//

import Foundation

/// Parsed `--tools` allow-list. `nil` (absent flag) means "proxy everything",
/// preserving the previous behavior for existing users.
public struct MCPToolFilter: Equatable, Sendable {
    /// Exact tool names to admit.
    private let exact: Set<String>
    /// Prefixes from `name*` patterns, stored without the trailing `*`.
    private let prefixes: [String]

    /// Build from the raw flag value: comma-separated names, each optionally
    /// ending in `*` to match by prefix (`osaurus_*`). Blank entries are
    /// dropped so a trailing comma is harmless.
    ///
    /// An explicitly empty value admits nothing. That fail-closed distinction
    /// matters: treating `--tools ""` like an absent flag would turn a typo
    /// into access to the entire tool surface.
    public init(patterns raw: String) {
        var exact: Set<String> = []
        var prefixes: [String] = []
        for piece in raw.split(separator: ",") {
            let token = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if token.hasSuffix("*") {
                let prefix = String(token.dropLast())
                // A bare `*` means everything; keep it as an empty prefix so
                // `hasPrefix("")` admits all names.
                prefixes.append(prefix)
            } else {
                exact.insert(token)
            }
        }
        self.exact = exact
        self.prefixes = prefixes
    }

    /// Whether `name` is admitted by this filter.
    public func admits(_ name: String) -> Bool {
        if exact.contains(name) { return true }
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// Human-readable summary for the startup log, so a user who mistypes a
    /// pattern can see what was actually parsed.
    public var summary: String {
        let parts = exact.sorted() + prefixes.map { "\($0)*" }.sorted()
        return parts.isEmpty ? "(none)" : parts.joined(separator: ", ")
    }

    /// Extract the filter from an argument vector.
    ///
    /// Accepts both `--tools a,b` and `--tools=a,b`. Returns nil when the flag
    /// is absent or carries no usable patterns.
    public static func parse(args: [String]) -> MCPToolFilter? {
        for (index, arg) in args.enumerated() {
            if arg == "--tools", index + 1 < args.count {
                return MCPToolFilter(patterns: args[index + 1])
            }
            if arg == "--tools" {
                return MCPToolFilter(patterns: "")
            }
            if arg.hasPrefix("--tools=") {
                return MCPToolFilter(patterns: String(arg.dropFirst("--tools=".count)))
            }
        }
        return nil
    }
}
