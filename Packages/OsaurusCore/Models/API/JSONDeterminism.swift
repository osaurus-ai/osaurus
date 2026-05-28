//
//  JSONDeterminism.swift
//  osaurus
//
//  Centralised canonical-encoding contract for any JSON Osaurus emits where
//  byte order matters: outbound HTTP bodies to remote model providers,
//  tool-result strings replayed into the next-turn prompt, server responses
//  to MCP / Anthropic / OpenAI / Ollama clients, and any payload hashed for
//  cache keys or sync digests.
//
//  Background and per-site rationale: see `docs/JSON_DETERMINISM.md`.
//  TL;DR: Swift `Dictionary` and `JSONValue.object` have no stable iteration
//  order, so `JSONEncoder()` / `JSONSerialization.data(withJSONObject:)`
//  produce different bytes for the same logical value across encode passes.
//  Without `.sortedKeys`, prompt-prefix caches (ds4, vLLM, sglang, MLX paged
//  KV, Anthropic prompt cache, ...) silently invalidate on every turn.
//

import Foundation

extension JSONEncoder {
    /// Canonical JSON encoder with stable key ordering. Always sets
    /// `.sortedKeys`; pass `prettyPrinted: true` only when the consumer
    /// (or replay tooling) expects pretty output.
    ///
    /// Use this instead of bare `JSONEncoder()` for any wire/server/tool
    /// path. Grep for `osaurusCanonical` to find existing call sites.
    static func osaurusCanonical(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            prettyPrinted
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONSerialization.WritingOptions {
    /// Canonical writing options for `JSONSerialization.data(withJSONObject:options:)`.
    /// Same determinism contract as `JSONEncoder.osaurusCanonical`.
    static let osaurusCanonical: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
}

/// Recursive normaliser used as the determinism-friendly fallback for
/// `Tool.canonicalize`. Walks an arbitrary JSON value and returns a deep
/// copy where every leaf is JSON-encodable, or `nil` if any leaf is not.
///
/// Why this exists: the previous fallback in `Tool.canonicalize` returned
/// the raw input dict if `JSONSerialization` round-trip threw, so a
/// downstream encoder could see an unsorted dict and emit non-deterministic
/// bytes. The walker never depends on `JSONSerialization`, so it cannot
/// throw away the determinism guarantee. Byte-stability is upheld at
/// encode time by `.osaurusCanonical`; the walker's job is to ensure every
/// leaf is a type the canonical encoder knows how to serialise.
public enum JSONCanonicalization {
    /// Returns a deep-copied JSON value with all leaves normalised to
    /// JSON-compatible types, or `nil` if any leaf is non-JSON-encodable.
    public static func normalize(_ value: Any) -> (any Sendable)? {
        switch value {
        case is NSNull:
            return NSNull()
        // `Bool` must come before `Int` / `Double` / `NSNumber` because
        // `true` / `false` boxed in `Any` will bridge to NSNumber and match
        // numeric casts.
        case let b as Bool:
            return b
        case let n as Int:
            return n
        case let n as Int64:
            return n
        case let n as Double:
            return n
        case let n as NSNumber:
            return n
        case let s as String:
            return s
        case let arr as [Any]:
            var out: [any Sendable] = []
            out.reserveCapacity(arr.count)
            for v in arr {
                guard let normalized = normalize(v) else { return nil }
                out.append(normalized)
            }
            return out
        case let dict as [String: Any]:
            var out: [String: any Sendable] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                guard let normalized = normalize(v) else { return nil }
                out[k] = normalized
            }
            return out
        default:
            return nil
        }
    }

    /// Top-level-object overload. Returns `nil` if the input contains any
    /// non-JSON leaf.
    public static func normalizeObject(_ value: [String: any Sendable]) -> [String: any Sendable]? {
        normalize(value) as? [String: any Sendable]
    }
}
