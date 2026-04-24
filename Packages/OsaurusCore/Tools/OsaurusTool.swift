//
//  OsaurusTool.swift
//  osaurus
//
//  Defines the standardized tool protocol and helpers to expose OpenAI-compatible tool specs.
//

import Foundation

protocol OsaurusTool: Sendable {
    /// Unique tool name exposed to the model
    var name: String { get }
    /// Human description for the model and UI
    var description: String { get }
    /// JSON schema for function parameters (OpenAI-compatible minimal subset)
    var parameters: JSONValue? { get }

    /// Execute the tool with arguments provided as a JSON string.
    ///
    /// **Cancellation contract:** the registry wraps every call with a
    /// `withThrowingTaskGroup` that races the body against a wall-clock
    /// timeout (`ToolRegistry.defaultToolTimeoutSeconds`). When the
    /// surrounding stream is cancelled by the client, the wrapping task
    /// is cancelled. Long-running tools (network, shell, file walk)
    /// SHOULD periodically check `Task.isCancelled` and short-circuit
    /// with a `ToolEnvelope.failure(kind: .executionError, …,
    /// retryable: false)` so resources are released promptly.
    func execute(argumentsJSON: String) async throws -> String
}

extension OsaurusTool {
    /// Build OpenAI-compatible Tool specification
    func asOpenAITool() -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(name: name, description: description, parameters: parameters)
        )
    }

    /// Parse JSON arguments string into a dictionary.
    func parseArguments(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    // MARK: - Argument Coercion

    func coerceStringArray(_ value: Any?) -> [String]? { ArgumentCoercion.stringArray(value) }
    func coerceInt(_ value: Any?) -> Int? { ArgumentCoercion.int(value) }
    func coerceBool(_ value: Any?) -> Bool? { ArgumentCoercion.bool(value) }

    // MARK: - Argument Requirement Helpers
    //
    // Each `require…` returns either the parsed value or a ready-to-return
    // envelope JSON. Callers unwrap with
    // `guard case .value(let x) = req else { return req.failureEnvelope ?? "" }`.
    // Replaces the opaque `guard let … else { return jsonResult(["error":
    // "Invalid arguments"]) }` pattern; every failure now points at the
    // specific field that was missing or malformed.

    /// Parse the JSON arguments string into a dictionary or build an
    /// `invalid_args` failure if it's malformed.
    func requireArgumentsDictionary(
        _ json: String,
        tool: String? = nil
    ) -> ArgumentRequirement<[String: Any]> {
        if let dict = parseArguments(json) { return .value(dict) }
        return .failure(
            ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Arguments could not be parsed as JSON. Pass an object literal, "
                    + "e.g. `{\"path\": \"foo.txt\"}`.",
                tool: tool
            )
        )
    }

    /// Require a string argument under `key`. `expected` is short prose
    /// shown to the model so it can self-correct on the next attempt.
    func requireString(
        _ args: [String: Any],
        _ key: String,
        expected: String,
        tool: String? = nil,
        allowEmpty: Bool = false
    ) -> ArgumentRequirement<String> {
        guard let raw = args[key] else {
            return .failure(missingArg(key, expected: expected, tool: tool))
        }
        guard let s = raw as? String else {
            return .failure(
                wrongType(key, expected: expected, gotType: "a JSON string", raw: raw, tool: tool)
            )
        }
        if !allowEmpty, s.isEmpty {
            return .failure(emptyArg(key, expected: expected, tool: tool))
        }
        return .value(s)
    }

    /// Require an integer argument under `key`. Accepts native int,
    /// `NSNumber`, or string-encoded integer (matches `coerceInt`).
    func requireInt(
        _ args: [String: Any],
        _ key: String,
        expected: String,
        tool: String? = nil
    ) -> ArgumentRequirement<Int> {
        guard let raw = args[key] else {
            return .failure(missingArg(key, expected: expected, tool: tool))
        }
        guard let n = ArgumentCoercion.int(raw) else {
            return .failure(
                wrongType(key, expected: expected, gotType: "an integer", raw: raw, tool: tool)
            )
        }
        return .value(n)
    }

    /// Require a `[String]` argument under `key`. Accepts a real array,
    /// JSON-encoded string array, or a single string (matches
    /// `coerceStringArray`).
    func requireStringArray(
        _ args: [String: Any],
        _ key: String,
        expected: String,
        tool: String? = nil,
        allowEmpty: Bool = false
    ) -> ArgumentRequirement<[String]> {
        guard let raw = args[key] else {
            return .failure(missingArg(key, expected: expected, tool: tool))
        }
        guard let arr = ArgumentCoercion.stringArray(raw) else {
            return .failure(
                wrongType(
                    key,
                    expected: expected,
                    gotType: "an array of strings",
                    raw: raw,
                    tool: tool
                )
            )
        }
        if !allowEmpty, arr.isEmpty {
            return .failure(emptyArg(key, expected: expected, tool: tool))
        }
        return .value(arr)
    }

    /// Optional string fetch — returns nil if missing or null, or a
    /// failure if present but the wrong type.
    func optionalString(
        _ args: [String: Any],
        _ key: String,
        expected: String,
        tool: String? = nil
    ) -> ArgumentRequirement<String?> {
        guard let raw = args[key], !(raw is NSNull) else { return .value(nil) }
        guard let s = raw as? String else {
            return .failure(
                wrongType(
                    key,
                    expected: expected,
                    gotType: "a JSON string",
                    raw: raw,
                    tool: tool
                )
            )
        }
        return .value(s)
    }

    // MARK: - Failure helpers (private)

    private func missingArg(_ key: String, expected: String, tool: String?) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Missing required argument `\(key)` (\(expected)).",
            field: key,
            expected: expected,
            tool: tool
        )
    }

    private func emptyArg(_ key: String, expected: String, tool: String?) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Argument `\(key)` must not be empty (\(expected)).",
            field: key,
            expected: expected,
            tool: tool
        )
    }

    private func wrongType(
        _ key: String,
        expected: String,
        gotType: String,
        raw: Any,
        tool: String?
    ) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message:
                "Argument `\(key)` must be \(gotType) (\(expected)). "
                + "Got \(jsonTypeName(raw)).",
            field: key,
            expected: expected,
            tool: tool
        )
    }

    /// Human-readable label for `Any` so failure messages describe what
    /// the model actually sent (e.g. "an array", "an integer").
    private func jsonTypeName(_ value: Any) -> String {
        switch value {
        case is String: return "a string"
        case is Bool: return "a boolean"
        case is Int, is Double, is NSNumber: return "a number"
        case is [Any]: return "an array"
        case is [String: Any]: return "an object"
        case is NSNull: return "null"
        default: return "\(type(of: value))"
        }
    }
}

// MARK: - Argument Requirement

/// Result of a `require…` check on a tool body. Either the parsed value
/// or a ready-to-return JSON failure envelope. Used linearly via
/// `guard case .value(let x) = req else { return req.failureEnvelope ?? "" }`.
/// (Lives at module scope because Swift doesn't allow type nesting in
/// protocol extensions.)
enum ArgumentRequirement<T> {
    case value(T)
    case failure(String)

    /// The parsed value if requirement passed, nil otherwise.
    var value: T? {
        if case .value(let v) = self { return v }
        return nil
    }

    /// The ready-to-return failure envelope JSON if requirement failed.
    /// Always non-nil after a `guard case .value(...) else { ... }`.
    var failureEnvelope: String? {
        if case .failure(let env) = self { return env }
        return nil
    }
}

// MARK: - Argument Coercion

/// Shared coercion helpers for tool arguments. Local/quantized models frequently
/// serialize values with wrong JSON types (arrays as strings, numbers as strings, etc.).
/// These helpers normalize common mistakes so tool execution succeeds.
public enum ArgumentCoercion {
    /// Coerce to `[String]`: actual array, JSON-encoded string (`"[\"a\"]"`),
    /// or bare string wrapped into a single-element array.
    public static func stringArray(_ value: Any?) -> [String]? {
        if let arr = value as? [String] { return arr }
        if let str = value as? String {
            if let data = str.data(using: .utf8),
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String]
            {
                return parsed
            }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return [trimmed] }
        }
        return nil
    }

    /// Coerce to `Int`: native int, `NSNumber`, or string-encoded integer (`"30"`).
    public static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = (value as? NSNumber)?.intValue { return n }
        if let s = value as? String, let n = Int(s) { return n }
        return nil
    }

    /// Coerce to `Bool`: native bool, string variants (`"true"`, `"1"`, `"yes"`), or `NSNumber`.
    public static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let s = value as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }
}
