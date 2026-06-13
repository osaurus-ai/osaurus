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
        /// A referenced path (file or directory) does not exist. Distinct
        /// from `executionError` so the harness can classify it as a
        /// not-found transition and steer the next step (pick from the
        /// last listing / list the parent) instead of letting the model
        /// re-derive it. Not retryable as-is — the path must change.
        case notFound = "not_found"
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
    /// `metadata` is merged in at the top level — used by tools that need
    /// to surface extra structured context the standard fields don't
    /// cover (e.g. `retried: true` on the install-tool retry-then-fail
    /// path so callers can branch on it without parsing prose).
    /// Reserved keys (`ok`, `kind`, `message`, `retryable`, `field`,
    /// `expected`, `tool`) are NOT overwritten by metadata so a sloppy
    /// caller can't reshape the contract.
    /// Top-level keys the failure envelope reserves. `metadata` callers
    /// can't shadow these — a sloppy `metadata: ["kind": "explosion"]`
    /// would otherwise silently rewrite the envelope's contract.
    private static let reservedFailureKeys: Set<String> = [
        "ok", "kind", "message", "retryable", "field", "expected", "tool",
    ]

    public static func failure(
        kind: Kind,
        message: String,
        field: String? = nil,
        expected: String? = nil,
        tool: String? = nil,
        retryable: Bool? = nil,
        metadata: [String: Any]? = nil
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
        if let metadata {
            for (key, value) in metadata where !reservedFailureKeys.contains(key) {
                dict[key] = value
            }
        }
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

    /// Build a directory-listing success envelope: a structured, actionable
    /// shape (NOT prose). `entries` is a list of `{name, path, type}` dicts
    /// where each `path` is a ready-to-use argument for the next `file_read`
    /// call — the model copies a field instead of parsing a glyph tree. The
    /// `kind: "listing"` tag lets the harness branch on result type (listing
    /// vs file content vs not-found) without the model interpreting anything.
    /// Pretty trees are a presentation concern rendered from `entries` in the
    /// UI; they are never handed to the model.
    public static func listing(
        tool: String? = nil,
        path: String,
        entries: [[String: Any]],
        truncated: Bool,
        warnings: [String]? = nil
    ) -> String {
        let result: [String: Any] = [
            "kind": "listing",
            "path": path,
            "entries": entries,
            "entry_count": entries.count,
            "truncated": truncated,
        ]
        // A truncated listing is incomplete, so it must NOT be used as a
        // find-by-name substrate: concluding "absent" from a partial dump is a
        // silent data-loss bug. Steer find-by-name to `file_search` at the
        // result level (route-agnostic, visible on the same turn) when the
        // caller hasn't supplied its own warnings.
        let effectiveWarnings = (truncated && (warnings?.isEmpty ?? true)) ? [Self.truncatedListingWarning] : warnings
        return success(tool: tool, result: result, warnings: effectiveWarnings)
    }

    /// Steer attached to a truncated listing: the entries are incomplete, so a
    /// specific file must be found via `file_search`, not by scanning the
    /// partial set.
    public static let truncatedListingWarning =
        "Listing truncated; entries are incomplete. To find a specific file by name, call "
        + "`file_search` with `target:\"files\"` and a token from the name — do not conclude a "
        + "file is absent from this partial list."

    /// Build a filename-search success envelope: the same structured,
    /// actionable `entries[]` shape as `listing` (so the model copies a
    /// `path`), tagged `kind: "search"` so it is distinguishable from a
    /// directory listing. `query` echoes what was actually matched (post mode
    /// correction / broadening). The tool returns ALL candidates and never
    /// picks among them — which match satisfies the request is the model's
    /// judgement.
    public static func search(
        tool: String? = nil,
        query: String,
        entries: [[String: Any]],
        truncated: Bool,
        warnings: [String]? = nil
    ) -> String {
        let result: [String: Any] = [
            "kind": "search",
            "query": query,
            "entries": entries,
            "match_count": entries.count,
            "truncated": truncated,
        ]
        return success(tool: tool, result: result, warnings: warnings)
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
                    kind: .notFound,
                    message:
                        "File not found: \(path). Check the exact path with "
                        + "`file_search(target=\"files\", pattern=\"\((path as NSString).lastPathComponent)\")` "
                        + "or list the parent directory with `file_read` before retrying.",
                    field: "path",
                    expected: "path to an existing file under the working folder",
                    tool: tool,
                    retryable: false
                )
            case .directoryNotFound(let path):
                return failure(
                    kind: .notFound,
                    message:
                        "Directory not found: \(path). List the parent directory with "
                        + "`file_read` (a directory path returns a listing) to find the right name before retrying.",
                    field: "path",
                    expected: "path to an existing directory under the working folder",
                    tool: tool,
                    retryable: false
                )
            case .operationFailed(let msg):
                return failure(
                    kind: .executionError,
                    message: msg,
                    tool: tool
                )
            case .binaryContent(let path, let ext, let detail):
                let extLabel = ext.map { " (.\($0))" } ?? ""
                let pivotTail = detail.pivotHint.map { " \($0)" } ?? ""
                return failure(
                    kind: .executionError,
                    message:
                        "file_read only supports text. '\(path)' looks like a binary file\(extLabel) — pivot to shell_run with an appropriate tool (e.g. `unzip`, `pdftotext`, `file`) instead of retrying.\(pivotTail)",
                    tool: tool,
                    retryable: false
                )
            }
        }

        // MCP provider errors map to their honest kinds so the model can
        // branch (retry on timeout, pivot on unavailable) instead of
        // treating every remote failure as a generic execution error.
        if let mcpErr = error as? MCPProviderError {
            switch mcpErr {
            case .timeout:
                return failure(
                    kind: .timeout,
                    message: "MCP provider call timed out.",
                    tool: tool,
                    retryable: true
                )
            case .notConnected, .providerDisabled, .providerNotFound, .invalidURL:
                return failure(
                    kind: .unavailable,
                    message: mcpErr.localizedDescription
                        + " — the MCP provider is not reachable right now.",
                    tool: tool,
                    retryable: false
                )
            case .connectionFailed(let detail):
                return failure(
                    kind: .unavailable,
                    message: "MCP provider connection failed: \(detail)",
                    tool: tool,
                    retryable: true
                )
            case .toolExecutionFailed(let detail):
                return failure(
                    kind: .executionError,
                    message: detail,
                    tool: tool
                )
            }
        }

        // Sandbox runtime errors: the idle-ceiling timeout gets its honest
        // `timeout` kind (with wording that explains it's an inactivity
        // kill, not a wall-clock cap), and "sandbox not ready" states map
        // to `unavailable` so the model retries instead of pivoting.
        #if os(macOS)
            if let sandboxErr = error as? SandboxError {
                switch sandboxErr {
                case .timeout:
                    return failure(
                        kind: .timeout,
                        message:
                            "Command killed by the idle timeout: it produced no output for the configured ceiling. Re-run with a longer `timeout`, or restructure it to emit progress output.",
                        tool: tool,
                        retryable: true
                    )
                case .unavailable, .containerNotRunning:
                    return failure(
                        kind: .unavailable,
                        message: sandboxErr.localizedDescription
                            + " — wait a moment and retry, or check the Sandbox settings panel.",
                        tool: tool,
                        retryable: true
                    )
                default:
                    return failure(
                        kind: .executionError,
                        message: sandboxErr.localizedDescription,
                        tool: tool
                    )
                }
            }
        #endif

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
    /// `[TIMEOUT]` prefix string. Used by UI / accounting code that
    /// needs to count failures without a full parse.
    /// Leading window used for envelope detection.
    ///
    /// `isError`/`isSuccess` only need the head of the payload: the canonical
    /// envelope emits `ok`/`error`/`retryable` as leading top-level keys, and
    /// the `[REJECTED]`/`[TIMEOUT]` tags are prefixes. Tool outputs can be
    /// hundreds of megabytes (file reads, base64 blobs) and these checks run
    /// on the main-actor registry path, so trimming and scanning the whole
    /// string could hang the UI. Skipping leading whitespace and bounding the
    /// scan to a small head keeps detection O(1) in the payload size while
    /// still covering every real envelope (the markers sit in the first bytes).
    private static let sniffWindow = 2048

    private static func envelopeHead(_ result: String) -> Substring {
        guard let start = result.firstIndex(where: { !$0.isWhitespace }) else {
            return ""
        }
        let end =
            result.index(start, offsetBy: sniffWindow, limitedBy: result.endIndex)
            ?? result.endIndex
        return result[start ..< end]
    }

    public static func isError(_ result: String) -> Bool {
        let head = envelopeHead(result)
        if head.isEmpty { return false }
        if head.hasPrefix("[REJECTED]") || head.hasPrefix("[TIMEOUT]") {
            return true
        }
        guard head.first == "{" else { return false }
        // New envelope: `"ok":false`. Cheap structural sniff before parse.
        if head.contains("\"ok\":false") || head.contains("\"ok\": false") {
            return true
        }
        // Legacy ToolErrorEnvelope shape.
        if head.contains("\"error\":") && head.contains("\"retryable\":") {
            return true
        }
        return false
    }

    /// True when `result` looks like a success envelope. Symmetric with
    /// `isError`.
    public static func isSuccess(_ result: String) -> Bool {
        let head = envelopeHead(result)
        guard head.first == "{" else { return false }
        return head.contains("\"ok\":true") || head.contains("\"ok\": true")
    }

    /// Attempt to extract the `result` payload from a success envelope.
    /// Returns nil if the input is not a success envelope or cannot be
    /// parsed. Used by the chat layer / tests to fold structured per-op
    /// results into a richer summary instead of treating every result as
    /// opaque text.
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
        case .rejected, .toolNotFound, .userDenied, .notFound: return false
        case .invalidArgs, .timeout, .executionError, .unavailable: return true
        }
    }

    /// Serialize `dict` canonically but with `ok` guaranteed as the FIRST key.
    ///
    /// `isError`/`isSuccess` detect the envelope from a bounded head window to
    /// stay O(1) on huge payloads (see `sniffWindow`). With plain `.sortedKeys`
    /// the `ok` marker sorts after `content`/`message`/`kind`, so a large field
    /// could push it past that window — which let an oversized failure get
    /// mis-detected as a success. Forcing `ok` to the front makes the marker
    /// always sit in the first bytes, restoring detection regardless of size.
    /// The remaining keys keep their canonical sorted order, so output stays
    /// deterministic.
    private static func canonicalJSONLeadingOK(_ dict: [String: Any], ok: Bool) -> String? {
        var rest = dict
        rest.removeValue(forKey: "ok")
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: rest,
                options: .osaurusCanonical
            ),
            let restJSON = String(data: data, encoding: .utf8)
        else { return nil }
        // `restJSON` is a canonical object string ("{...}" with no `ok`). Splice
        // the marker to the front: "{" + "\"ok\":<bool>," + <sorted rest>.
        if restJSON == "{}" { return "{\"ok\":\(ok)}" }
        return "{\"ok\":\(ok)," + restJSON.dropFirst()
    }

    private static func encodeOrFallbackFailure(
        _ dict: [String: Any],
        kind: Kind,
        message: String
    ) -> String {
        if let json = canonicalJSONLeadingOK(dict, ok: false) {
            return json
        }
        // Hand-built fallback so we never return malformed output if the
        // caller passes something exotic. Only `kind` + `message` survive.
        let escaped = escape(message)
        return
            "{\"ok\":false,\"kind\":\"\(kind.rawValue)\",\"message\":\"\(escaped)\",\"retryable\":\(defaultRetryable(for: kind))}"
    }

    private static func encodeOrFallbackSuccess(
        _ dict: [String: Any],
        tool: String?
    ) -> String {
        if let json = canonicalJSONLeadingOK(dict, ok: true) {
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
