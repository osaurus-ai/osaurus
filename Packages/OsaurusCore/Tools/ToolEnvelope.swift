//
//  ToolEnvelope.swift
//  osaurus
//
//  Canonical envelope every tool returns. Two shapes:
//
//    Failure: {"ok": false, "kind": "<kind>", "message": "...",
//              "field"?, "expected"?, "tool"?, "retryable": true}
//    Success: {"ok": true, "tool"?, "result": <any>, "warnings"?: [...]}
//
//  See `docs/TOOL_CONTRACT.md` for the full spec. `isError(_:)` keeps
//  recognising the legacy `[REJECTED]` / `[TIMEOUT]` prefixes and the
//  legacy `ToolErrorEnvelope` JSON shape so partial migrations can't
//  mis-classify a failure as a success.
//

import Foundation

/// Standard envelope returned by every tool. All members are static — there
/// is no need to instantiate this type. Tool bodies call `success(...)` /
/// `failure(...)` and return the resulting JSON string.
public enum ToolEnvelope {

    // MARK: - Kinds

    /// Failure classification. Determines `retryable` default and gives the
    /// model a structured signal it can react to (retry vs pivot vs stop).
    public enum Kind: String, Sendable {
        /// User-facing arguments are missing, malformed, or invalid for the
        /// tool's contract. Carries `field` + `expected` whenever possible.
        case invalidArgs = "invalid_args"
        /// Policy refusal — the registry blocked the tool by configuration.
        /// Distinct from `userDenied` (interactive refusal).
        case rejected
        /// The tool ran but exceeded its time budget.
        case timeout
        /// The tool ran and failed for a runtime reason (process exit, file
        /// missing, network error). Default catch-all for thrown errors.
        case executionError = "execution_error"
        /// The model called a tool that does not exist in the registry.
        case toolNotFound = "tool_not_found"
        /// The tool exists but cannot run right now (e.g. sandbox still
        /// provisioning). Retryable next turn.
        case unavailable
        /// User clicked "Deny" on an interactive approval prompt.
        /// Distinct from `rejected` (configured policy refusal).
        case userDenied = "user_denied"
    }

    // MARK: - Construction

    /// Build a failure envelope as a JSON string ready to return from a tool
    /// body. `field` and `expected` are recommended for `.invalidArgs`.
    /// `retryable` defaults to a kind-appropriate value when unspecified.
    public static func failure(
        kind: Kind,
        message: String,
        field: String? = nil,
        expected: String? = nil,
        tool: String? = nil,
        retryable: Bool? = nil
    ) -> String {
        var dict: [String: Any] = [
            "ok": false,
            "kind": kind.rawValue,
            "message": message,
            "retryable": retryable ?? defaultRetryable(for: kind),
        ]
        if let field { dict["field"] = field }
        if let expected { dict["expected"] = expected }
        if let tool { dict["tool"] = tool }
        return encodeOrFallbackFailure(dict, kind: kind, message: message)
    }

    /// Build a success envelope around a structured `result` payload.
    /// `result` should be a JSON-serialisable value (`String`, `Int`, `Bool`,
    /// `[String: Any]`, `[Any]`, `NSNumber`, `NSNull`). `nil` is encoded as
    /// JSON `null`.
    public static func success(
        tool: String? = nil,
        result: Any? = nil,
        warnings: [String]? = nil
    ) -> String {
        var dict: [String: Any] = ["ok": true, "result": result ?? NSNull()]
        if let tool { dict["tool"] = tool }
        if let warnings, !warnings.isEmpty { dict["warnings"] = warnings }
        return encodeOrFallbackSuccess(dict, tool: tool)
    }

    /// Build a success envelope whose primary payload is a single string of
    /// human-readable prose. The chat UI's existing renderers (folder file
    /// trees, capability listings, search-memory hits) keep working because
    /// the prose is preserved verbatim under `result.text`.
    ///
    /// Convenience for tools that have no structured payload — equivalent to
    /// `success(tool:, result: ["text": text], warnings:)`.
    public static func success(
        tool: String? = nil,
        text: String,
        warnings: [String]? = nil
    ) -> String {
        success(tool: tool, result: ["text": text], warnings: warnings)
    }

    /// Map any thrown error (or generic NSError from registry rejection)
    /// to a structured failure envelope. Used by the chat / HTTP / plugin
    /// tool-call catch sites so the model gets a meaningful `kind` instead
    /// of `executionError`-for-everything.
    ///
    /// Recognised input domains:
    ///   - `FolderToolError`            -> mapped per case (invalid_args /
    ///                                     execution_error)
    ///   - Registry permission NSError  -> `userDenied` (interactive deny)
    ///                                     or `rejected` (policy deny)
    ///   - Anything else                -> `executionError` with the
    ///                                     localizedDescription as message
    public static func fromError(_ error: Error, tool: String? = nil) -> String {
        // Folder tool errors come with rich enum cases — preserve them.
        if let folderErr = error as? FolderToolError {
            switch folderErr {
            case .invalidArguments(let msg):
                return failure(
                    kind: .invalidArgs,
                    message: msg,
                    tool: tool
                )
            case .pathOutsideRoot(let path):
                return failure(
                    kind: .invalidArgs,
                    message:
                        "Path '\(path)' is outside the working directory. "
                        + "Use a relative path under the working folder, e.g. `src/app.py`.",
                    field: "path",
                    expected: "relative path under the working folder",
                    tool: tool
                )
            case .fileNotFound(let path):
                return failure(
                    kind: .executionError,
                    message: "File not found: \(path)",
                    tool: tool,
                    retryable: false
                )
            case .directoryNotFound(let path):
                return failure(
                    kind: .executionError,
                    message: "Directory not found: \(path)",
                    tool: tool,
                    retryable: false
                )
            case .operationFailed(let msg):
                return failure(
                    kind: .executionError,
                    message: msg,
                    tool: tool
                )
            }
        }

        // Registry permission errors carry their reason in NSError.localizedDescription
        // and a stable code in the `ToolRegistry` NSError domain.
        let nserr = error as NSError
        if nserr.domain == "ToolRegistry" {
            switch nserr.code {
            case 4:  // user denied via interactive approval
                return failure(
                    kind: .userDenied,
                    message: nserr.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case 3, 6:  // policy deny
                return failure(
                    kind: .rejected,
                    message: nserr.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            case 7:  // missing system permissions
                return failure(
                    kind: .unavailable,
                    message: nserr.localizedDescription,
                    tool: tool,
                    retryable: false
                )
            default:
                break
            }
        }

        return failure(
            kind: .executionError,
            message: error.localizedDescription,
            tool: tool
        )
    }

    // MARK: - Detection

    /// True when `result` looks like a failure envelope (new shape) OR a
    /// legacy `ToolErrorEnvelope` JSON OR a legacy `[REJECTED]` /
    /// `[TIMEOUT]` prefix string. Used by UI / batch / accounting code that
    /// needs to count failures without a full parse.
    public static func isError(_ result: String) -> Bool {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("[REJECTED]") || trimmed.hasPrefix("[TIMEOUT]") {
            return true
        }
        guard trimmed.first == "{" else { return false }
        // New envelope: `"ok":false`. Cheap structural sniff before parse.
        if trimmed.contains("\"ok\":false") || trimmed.contains("\"ok\": false") {
            return true
        }
        // Legacy ToolErrorEnvelope shape.
        if trimmed.contains("\"error\":") && trimmed.contains("\"retryable\":") {
            return true
        }
        return false
    }

    /// True when `result` looks like a success envelope. Symmetric with
    /// `isError`.
    public static func isSuccess(_ result: String) -> Bool {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" else { return false }
        return trimmed.contains("\"ok\":true") || trimmed.contains("\"ok\": true")
    }

    /// Attempt to extract the `result` payload from a success envelope.
    /// Returns nil if the input is not a success envelope or cannot be
    /// parsed. Used by `BatchTool` to fold structured per-op results into
    /// its summary instead of treating every result as opaque text.
    public static func successPayload(_ result: String) -> Any? {
        guard isSuccess(result),
            let data = result.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict["result"]
    }

    /// Pull a short, model-readable failure message out of an error
    /// envelope. Falls back to the input string if parsing fails so the
    /// caller always has something to show.
    public static func failureMessage(_ result: String) -> String {
        guard isError(result),
            let data = result.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return result }
        if let msg = dict["message"] as? String { return msg }
        if let msg = dict["reason"] as? String { return msg }  // legacy envelope
        return result
    }

    // MARK: - Internals

    private static func defaultRetryable(for kind: Kind) -> Bool {
        switch kind {
        case .rejected, .toolNotFound, .userDenied: return false
        case .invalidArgs, .timeout, .executionError, .unavailable: return true
        }
    }

    private static func encodeOrFallbackFailure(
        _ dict: [String: Any],
        kind: Kind,
        message: String
    ) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        ),
            let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        // Hand-built fallback so we never return malformed output if the
        // caller passes something exotic. Only `kind` + `message` survive.
        let escaped = escape(message)
        return
            "{\"kind\":\"\(kind.rawValue)\",\"message\":\"\(escaped)\",\"ok\":false,\"retryable\":\(defaultRetryable(for: kind))}"
    }

    private static func encodeOrFallbackSuccess(
        _ dict: [String: Any],
        tool: String?
    ) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        ),
            let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        // Fallback should never trigger for well-typed inputs; if it does,
        // emit the bare success marker so detection still works.
        let toolField = tool.map { ",\"tool\":\"\(escape($0))\"" } ?? ""
        return "{\"ok\":true\(toolField),\"result\":null}"
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}
