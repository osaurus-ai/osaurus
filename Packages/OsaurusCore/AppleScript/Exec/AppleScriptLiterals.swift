//
//  AppleScriptLiterals.swift
//  OsaurusCore — AppleScript Computer Use
//
//  Deterministic literal-placeholder substitution so the small on-device
//  AppleScript model never has to re-type verbatim / large content into a
//  script string. The parent passes the exact text out-of-band (the
//  `applescript` / `mac_query` `content` string or `contents` map arg); the
//  subagent references each by a
//  `{{name}}` token; `expand` replaces that token with a complete,
//  correctly-escaped AppleScript string literal BEFORE execution. This removes
//  both failure modes that make a small model "struggle heavily" on
//  transcription tasks: the bytes flow as DATA (not regenerated tokens, so
//  nothing is dropped / reordered / altered) and the escaping is handled in
//  code (so no compile errors from a mis-escaped literal).
//

import Foundation

/// A name → exact-text map of literals available to a single AppleScript run,
/// plus the substitution that injects them into a model-written script. Value
/// type so a run captures an immutable snapshot.
public struct AppleScriptLiterals: Sendable, Equatable {
    /// Token delimiters. `{{` / `}}` never appear in valid AppleScript (record
    /// literals use a single brace), so the token is a safe sentinel that can't
    /// collide with real script syntax.
    static let openDelimiter = "{{"
    static let closeDelimiter = "}}"

    private let values: [String: String]

    /// Drops empty names / values so a blank `content` arg never advertises an
    /// unusable placeholder.
    public init(_ values: [String: String] = [:]) {
        self.values = values.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    public var isEmpty: Bool { values.isEmpty }

    /// Available placeholder names, sorted for stable prompt rendering.
    public var names: [String] { values.keys.sorted() }

    /// The raw (un-escaped) text registered under `name`, if any.
    public func value(for name: String) -> String? { values[name] }

    // MARK: - Expansion

    /// Outcome of expanding a script's `{{…}}` tokens.
    public struct Expansion: Sendable, Equatable {
        /// The script with every KNOWN token replaced by an escaped literal.
        public let script: String
        /// The first token that referenced an UNKNOWN literal, if any. The loop
        /// turns this into a precise re-ask instead of running a script that is
        /// guaranteed to fail to compile.
        public let undefinedName: String?

        public init(script: String, undefinedName: String?) {
            self.script = script
            self.undefinedName = undefinedName
        }
    }

    /// Replace every `{{name}}` token in `source` with the matching literal as a
    /// complete, double-quoted AppleScript string literal. A token the model
    /// already wrapped in `"…"` has those surrounding quotes absorbed, so either
    /// `to {{content}}` or `to "{{content}}"` yields exactly one valid literal.
    /// Unknown tokens are left untouched and the first one is reported in
    /// `undefinedName`.
    public func expand(_ source: String) -> Expansion {
        guard source.contains(Self.openDelimiter) else {
            return Expansion(script: source, undefinedName: nil)
        }

        var result = ""
        result.reserveCapacity(source.count)
        var remainder = Substring(source)
        var undefinedName: String?

        while let open = remainder.range(of: Self.openDelimiter) {
            let beforeToken = remainder[..<open.lowerBound]
            guard
                let close = remainder.range(
                    of: Self.closeDelimiter,
                    range: open.upperBound ..< remainder.endIndex
                )
            else {
                // No closing delimiter — emit the rest verbatim and stop.
                break
            }

            let name = remainder[open.upperBound ..< close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let after = remainder[close.upperBound...]

            guard let literal = values[name] else {
                // Unknown placeholder: keep it verbatim, record the first one,
                // and continue past it.
                if undefinedName == nil { undefinedName = name }
                result += beforeToken
                result += remainder[open.lowerBound ..< close.upperBound]
                remainder = after
                continue
            }

            // Absorb the model's surrounding quotes when present so we don't
            // double-quote the substituted literal.
            if beforeToken.hasSuffix("\""), after.hasPrefix("\"") {
                result += beforeToken.dropLast()
                result += quotedLiteral(literal)
                remainder = after.dropFirst()
            } else {
                result += beforeToken
                result += quotedLiteral(literal)
                remainder = after
            }
        }

        result += remainder
        return Expansion(script: result, undefinedName: undefinedName)
    }

    /// `literal` → a complete double-quoted AppleScript string literal.
    private func quotedLiteral(_ literal: String) -> String {
        "\"" + Self.escapeForAppleScriptLiteral(literal) + "\""
    }

    /// Escape `text` for inclusion inside an AppleScript double-quoted string
    /// literal. Order matters: backslash first (so we don't double-escape the
    /// escapes we add next), then the quote, then the whitespace controls.
    /// Unicode (em dash, curly quotes, accents) is left as UTF-8 —
    /// `NSAppleScript` compiles UTF-8 string literals directly.
    static func escapeForAppleScriptLiteral(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        out = out.replacingOccurrences(of: "\t", with: "\\t")
        return out
    }
}
