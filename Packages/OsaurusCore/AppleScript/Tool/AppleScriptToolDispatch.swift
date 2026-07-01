//
//  AppleScriptToolDispatch.swift
//  OsaurusCore — AppleScript Computer Use
//
//  Shared argument parsing + dispatch for the two AppleScript subagent tools:
//  `applescript` (state-changing automation) and `mac_query` (read-only info).
//  They differ only in the argument name, the default step cap, and the run
//  mode; the parse → validate → clamp → hand-to-`SubagentSession` flow is
//  identical, so it lives here once instead of being copied into both tools.
//

import Foundation

enum AppleScriptToolDispatch {
    /// Hard ceiling on `max_steps` regardless of what the model requests.
    private static let maxStepCap = 50

    /// Parse the single natural-language argument (`field`) + optional
    /// `max_steps` + optional verbatim literals (`content` and/or `contents`),
    /// then run a configured `AppleScriptKind` on the subagent host. Returns the
    /// tool envelope (success payload or `invalid_args`).
    static func run(
        tool: OsaurusTool,
        argumentsJSON: String,
        field: String,
        expected: String,
        emptyMessage: String,
        defaultMaxSteps: Int,
        mode: AppleScriptRunMode
    ) async -> String {
        let argsReq = tool.requireArgumentsDictionary(argumentsJSON, tool: tool.name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let textReq = tool.requireString(args, field, expected: expected, tool: tool.name)
        guard case .value(let rawText) = textReq else { return textReq.failureEnvelope ?? "" }
        let request = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: emptyMessage,
                field: field,
                expected: expected,
                tool: tool.name
            )
        }

        var limits = RunLimits(maxSteps: defaultMaxSteps)
        if let raw = args["max_steps"], !(raw is NSNull) {
            guard let n = tool.coerceInt(raw) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`max_steps` must be an integer.",
                    field: "max_steps",
                    expected: "integer step cap",
                    tool: tool.name
                )
            }
            limits = RunLimits(maxSteps: min(max(n, 1), maxStepCap))
        }

        return await SubagentSession.run(
            AppleScriptKind(
                task: request,
                limits: limits,
                mode: mode,
                literals: literals(from: args)
            ),
            tool: tool.name
        )
    }

    /// Build the literal store from the optional `content` string and/or the
    /// optional `contents` object map. Both are optional; when both define the
    /// reserved `content` key the `contents` entry wins (so a map author is
    /// never overridden by the single-block convenience). The exact bytes are
    /// preserved (NOT trimmed) so verbatim payloads survive; a whitespace-only
    /// value is skipped so it can't advertise an empty `{{name}}` placeholder.
    ///
    /// Values are read defensively: a literal that arrived as a non-`String`
    /// (e.g. an upstream normalization pass re-parsed a JSON-looking payload
    /// like `{"a":1}` into a dictionary) is recovered back to its string form
    /// rather than dropped, so verbatim JSON-looking content still reaches the
    /// script.
    static func literals(from args: [String: Any]) -> AppleScriptLiterals {
        var merged: [String: String] = [:]

        if let raw = args["contents"], !(raw is NSNull), let map = raw as? [String: Any] {
            for (name, value) in map {
                guard let text = stringLiteralValue(value),
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                merged[name] = text
            }
        }

        if merged["content"] == nil, let raw = args["content"], !(raw is NSNull),
            let text = stringLiteralValue(raw),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            merged["content"] = text
        }

        return AppleScriptLiterals(merged)
    }

    /// Recover the verbatim string for one literal value. A `String` passes
    /// through unchanged; a scalar (`Bool`/number) renders to its literal text;
    /// a collection an upstream JSON re-parse produced from a JSON-looking
    /// literal (`"{…}"` / `"[…]"`) is re-serialized so its content still
    /// reaches the script. `nil` when nothing textual can be recovered.
    private static func stringLiteralValue(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            // Distinguish a bool-tagged NSNumber (JSON `true`/`false`) from a
            // numeric one via the CFBoolean type id — the NSNumber ⇄ Bool
            // bridging would otherwise coerce every non-zero number to `true`.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value),
            let s = String(data: data, encoding: .utf8)
        {
            return s
        }
        return nil
    }
}
