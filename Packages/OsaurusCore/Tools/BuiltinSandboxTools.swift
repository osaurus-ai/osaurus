//
//  BuiltinSandboxTools.swift
//  osaurus
//
//  Built-in sandbox tools that give agents filesystem, shell, and
//  package management access inside the shared Linux container.
//  All paths are validated on the host side before any container exec.
//

import Combine
import Containerization
import Foundation

// MARK: - Registration

enum BuiltinSandboxTools {
    /// Register sandbox tools for the given agent into the ToolRegistry.
    /// Respects autonomous_exec config to gate write/exec tools.
    ///
    /// The schema is deliberately lean so the model can keep the whole
    /// tool surface in working memory:
    ///   - reads/searches: `sandbox_read_file`, `sandbox_search_files`
    ///   - writes/edits: `sandbox_write_file` (whole-file write OR
    ///     in-place edit via `old_string`)
    ///   - exec: `sandbox_exec` (foreground; background via flag only when
    ///     the agent opts into `backgroundProcessEnabled`),
    ///     `sandbox_process` (poll/wait/kill background jobs; opt-in)
    ///   - installs: `sandbox_install` (one tool; `manager` selects
    ///     `apk` / `pip` / `npm`)
    ///
    /// Removed-by-design (use the consolidated alternative):
    ///   - `sandbox_list_directory` → `sandbox_search_files(target:"files")`
    ///   - `sandbox_find_files` → `sandbox_search_files(target:"files")`
    ///   - `sandbox_move` / `sandbox_delete` → `sandbox_exec("mv …" / "rm …")`
    ///   - `sandbox_exec_background` → `sandbox_exec(background:true)`
    ///   - `sandbox_pip_install` / `sandbox_npm_install` →
    ///     `sandbox_install(manager:"pip" / "npm")`
    ///   - `sandbox_run_script` / `sandbox_execute_code` →
    ///     `sandbox_write_file` the script then `sandbox_exec` to run it
    ///     (e.g. `python3 script.py`), or `sandbox_exec` with a heredoc
    ///     for short bash/node snippets.
    ///   - `sandbox_edit_file` → `sandbox_write_file` with `old_string` +
    ///     `new_string` (presence of `old_string` selects the edit path).
    @MainActor
    static func register(agentId: String, agentName: String, config: AutonomousExecConfig?) {
        let registry = ToolRegistry.shared
        let home = OsaurusPaths.inContainerAgentHome(agentName)

        // Capture the active agent identity so the combined-mode unified
        // `file_*` tools can route `/workspace/...` reads to this sandbox
        // without relying on `currentAgentId` being bound at the call site.
        registry.setActiveSandboxAgentContext(agentName: agentName, home: home)

        // Always available (read-only)
        registry.registerSandboxTool(
            SandboxReadFileTool(agentName: agentName, home: home),
            runtimeManaged: true
        )
        registry.registerSandboxTool(
            SandboxSearchFilesTool(agentName: agentName, home: home),
            runtimeManaged: true
        )

        // Gated by autonomous_exec.enabled
        guard let config = config, config.enabled else { return }

        let maxCmdsPerTurn = config.maxCommandsPerTurn

        registry.registerSandboxTool(
            SandboxWriteFileTool(agentName: agentName, home: home),
            runtimeManaged: true
        )
        registry.registerSandboxTool(
            SandboxExecTool(
                agentId: agentId,
                agentName: agentName,
                home: home,
                maxCommandsPerTurn: maxCmdsPerTurn,
                backgroundEnabled: config.backgroundProcessEnabled
            ),
            runtimeManaged: true
        )
        // Background-job management is opt-in (`backgroundProcessEnabled`).
        // When off, `sandbox_exec` hides its `background` flag and this
        // poll/wait/kill tool is never registered — there are no detached
        // jobs to manage, so it would only bloat the schema.
        if config.backgroundProcessEnabled {
            registry.registerSandboxTool(
                SandboxProcessTool(agentId: agentId, agentName: agentName, home: home),
                runtimeManaged: true
            )
        }
        registry.registerSandboxTool(
            SandboxInstallTool(agentId: agentId, agentName: agentName, home: home),
            runtimeManaged: true
        )

        // Secret management tools
        registry.registerSandboxTool(
            SandboxSecretCheckTool(agentId: agentId),
            runtimeManaged: true
        )
        registry.registerSandboxTool(
            SandboxSecretSetTool(agentId: agentId),
            runtimeManaged: true
        )

        // Plugin self-creation (gated by pluginCreate)
        if config.pluginCreate {
            registry.registerSandboxTool(
                SandboxPluginRegisterTool(agentId: agentId, agentName: agentName),
                runtimeManaged: true
            )
        }
    }

    /// Register a single transient placeholder when sandbox is enabled but
    /// the container isn't ready yet. Gives the model exactly one tool it
    /// can call and get a clear "still initialising" envelope back, instead
    /// of either having an empty schema or hallucinating sandbox names that
    /// will fail with `toolNotFound`. The placeholder is registered as a
    /// runtime-managed sandbox tool so it gets swept by
    /// `unregisterAllBuiltinSandboxTools()` the moment real sandbox tools
    /// come online.
    @MainActor
    static func registerInitPending(agentId: UUID) {
        ToolRegistry.shared.registerSandboxTool(
            SandboxInitPendingTool(agentId: agentId),
            runtimeManaged: true
        )
    }

    // No `unregisterAll()` here on purpose — tear-down goes through
    // `ToolRegistry.unregisterAllBuiltinSandboxTools()`, which uses the
    // registry's live `builtInSandboxToolNames` set so it can't drift
    // from what `register(...)` actually installed.
}

// MARK: - sandbox_init_pending (placeholder while sandbox boots)

extension BuiltinSandboxTools {
    /// Name of the placeholder tool registered while the sandbox container
    /// provisions. Exposed so the prompt composer can suppress it from
    /// snapshots / schemas without duplicating the literal.
    public static let initPendingToolName = "sandbox_init_pending"
}

/// Placeholder tool registered when sandbox is enabled but the container
/// isn't running yet. Calling it kicks the on-demand boot (the sandbox chip
/// defaults ON but a never-set-up sandbox stays un-provisioned until first
/// use) and returns a "still initialising" envelope. Designed to keep the
/// model's schema non-empty (so it has *something* to call) while the
/// container provisions; the real sandbox tools register automatically once
/// it's running.
private struct SandboxInitPendingTool: OsaurusTool, @unchecked Sendable {
    let agentId: UUID
    let name = BuiltinSandboxTools.initPendingToolName
    let description =
        "Sandbox isn't running yet. Calling this tool starts it (first use can take a "
        + "moment to provision) and confirms it isn't ready — then either reply without "
        + "sandbox tools or tell the user to wait. The real sandbox tools (file ops, "
        + "shell) appear in your schema once the container boots — do NOT invent or guess "
        + "sandbox tool names in the meantime."

    var parameters: JSONValue? {
        .object(["type": .string("object"), "properties": .object([:])])
    }

    func execute(argumentsJSON: String) async throws -> String {
        // First reach for a sandbox tool is the explicit signal to boot the
        // (default-ON, not-yet-provisioned) sandbox. Kick the on-demand
        // provision; the status publisher re-registers the real tools once the
        // container is running, so the model's next turn uses them.
        await MainActor.run { [agentId] in
            SandboxToolRegistrar.shared.provisionOnDemand(for: agentId)
        }
        return ToolErrorEnvelope(
            kind: .unavailable,
            reason:
                "Sandbox is starting up (first use) — this can take a moment while it "
                + "provisions. Real sandbox tools register automatically once it's "
                + "running. Reply without sandbox tools, or wait and try again.",
            toolName: name,
            retryable: true
        ).toJSONString()
    }
}

// MARK: - Path Validation

/// Back-compat path resolver used by call sites that already build their
/// own envelope. New tool bodies should use `requirePath(...)` so the
/// model gets a specific rejection reason.
private func validatePath(_ path: String, home: String) -> String? {
    SandboxPathSanitizer.sanitize(path, agentHome: home)
}

/// Validate a path argument; on rejection returns a fully-formed
/// `invalid_args` envelope carrying the sanitizer's reason (traversal,
/// dangerous char, outside roots, ...) so the model can self-correct.
private func requirePath(
    _ path: String,
    home: String,
    field: String = "path",
    tool: String
) -> ArgumentRequirement<String> {
    switch SandboxPathSanitizer.validate(path, agentHome: home) {
    case .success(let resolved):
        return .value(resolved)
    case .failure(let rejection):
        var message = "Argument `\(field)` rejected: \(rejection.reason). Got `\(path)`."
        if let redirect = hostPathRedirectHint(path: path) {
            message += " " + redirect
        }
        return .failure(
            ToolEnvelope.failure(
                kind: .invalidArgs,
                message: message,
                field: field,
                expected: "path under the agent home (relative or absolute under `\(home)`)",
                tool: tool
            )
        )
    }
}

/// macOS-distinctive absolute-path roots that cannot exist in the Linux
/// sandbox. Used to recognize a host path the model handed to a
/// `sandbox_*` tool by mistake. Excludes generic Linux roots
/// (`/etc`, `/usr`, `/var`, ...) so a legitimate sandbox read like
/// `/etc/os-release` is never misredirected.
private let macHostPathPrefixes = [
    "/Users/", "/Volumes/", "/Applications/", "/System/", "/Library/", "/private/",
]

/// When a `sandbox_*` path tool is handed a path that belongs to the
/// host filesystem (not the Linux sandbox), return a hint redirecting the
/// model to the read-only `file_*` host tools. Two signals, strongest
/// first:
///   1. The path is the combined-mode host workspace root or under it
///      (`ChatExecutionContext.hostReadOnlyScope`).
///   2. The path starts with a macOS-distinctive root the sandbox can't
///      have.
/// Returns nil for relative paths and for legitimate sandbox absolute
/// paths (under the agent home, `/workspace`, generic Linux roots).
internal func hostPathRedirectHint(path: String) -> String? {
    guard path.hasPrefix("/") else { return nil }

    if let scope = ChatExecutionContext.hostReadOnlyScope {
        let root = scope.path
        if path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            return
                "`\(path)` is on your read-only host workspace (`\(root)`), which the "
                + "Linux sandbox cannot see. Use `file_read` to list the directory or read "
                + "host files, or `file_search` to search them — not `sandbox_*` tools."
        }
    }

    if macHostPathPrefixes.contains(where: { path.hasPrefix($0) }) {
        return
            "`\(path)` looks like a macOS host path; the Linux sandbox cannot see the "
            + "host filesystem. If you meant a file in your host workspace, use "
            + "`file_read` / `file_search` instead."
    }

    return nil
}

/// `sandbox_read_file` was pointed at a directory, so `cat` fails with
/// "Is a directory". The model wanted to *list* it. Tell it how — and,
/// when a read-only host workspace is mounted (combined mode), that the
/// host workspace is listed with `file_read`, not `sandbox_*`. Catches
/// the "I tried to read my Desktop with sandbox_read_file" slip that
/// `hostPathRedirectHint` misses because the path is a valid sandbox
/// directory rather than a rejected host path.
internal func sandboxDirectoryReadHint(stderr: String) -> String? {
    guard stderr.lowercased().contains("is a directory") else { return nil }
    var hint =
        "That path is a directory, not a file. To list a directory inside the "
        + "sandbox, use `sandbox_search_files` with `target=\"files\"`."
    if ChatExecutionContext.hostReadOnlyScope != nil {
        hint +=
            " To list your read-only host workspace instead, use `file_read` — "
            + "the Linux sandbox cannot see the host workspace."
    }
    return hint
}

/// Combined host-read mode only: an empty `sandbox_search_files` rooted at
/// the sandbox home usually means the model searched the (separate, often
/// empty) Linux sandbox when it meant the host workspace — exactly the
/// "what's in my Desktop?" → `sandbox_search_files` slip. The sandbox
/// tools succeed emptily here, so there's no rejection to hook
/// `hostPathRedirectHint` onto; this soft warning provides the missing
/// signal. Narrowly gated (combined mode + home-root + empty result) so a
/// real, legitimately-empty sandbox search elsewhere is never nagged.
internal func hostWorkspaceSearchRedirectHint(resolvedPath: String, home: String) -> String? {
    guard ChatExecutionContext.hostReadOnlyScope != nil else { return nil }
    func normalize(_ p: String) -> String {
        var s = p
        if s.hasSuffix("/.") { s = String(s.dropLast(2)) }
        while s.count > 1 && s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }
    guard normalize(resolvedPath) == normalize(home) else { return nil }
    return
        "No matches — this searched your Linux sandbox home, which is separate "
        + "from (and usually empty compared to) your read-only host workspace. "
        + "If you meant your workspace, use `file_read` to list it or "
        + "`file_search` to search it."
}

// MARK: - Combined-mode file routing
//
// In combined mode (`.sandbox(hostRead:)`) the host `file_*` tools are the
// single read family the model sees (the redundant `sandbox_read_file` /
// `sandbox_search_files` are hidden). They become path-routed: an absolute
// `/workspace/...` path is served from the Linux sandbox via the bridge
// below; everything else (relative or host-absolute) stays on the host
// workspace. The bridge is bound by `ToolRegistry.execute` only in
// combined mode, so plain folder and plain sandbox modes are untouched.

/// Sandbox identity needed to run read/list/search commands as the agent
/// for combined-mode `/workspace/...` requests routed from the host
/// `file_*` tools. Bound on `ChatExecutionContext.sandboxReadBridge`.
public struct SandboxReadBridge: Sendable {
    public let agentName: String
    public let home: String
    public init(agentName: String, home: String) {
        self.agentName = agentName
        self.home = home
    }
}

/// Which filesystem a combined-mode `file_*` call targets. Absolute
/// `/workspace/...` paths (agent home + `/workspace/shared`) are the Linux
/// sandbox; relative paths and host-absolute paths are the host workspace.
public enum CombinedFileRoute: Sendable {
    case host
    case sandbox
}

/// Classify a `file_*` path argument for combined-mode routing.
public func combinedFileRoute(path: String) -> CombinedFileRoute {
    path.hasPrefix("/workspace") ? .sandbox : .host
}

private func encodeBridgeArgs(_ dict: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
        let json = String(data: data, encoding: .utf8)
    else { return "{}" }
    return json
}

/// Read a sandbox file for a combined-mode `file_read("/workspace/...")`
/// call. Translates the host `start_line`/`end_line` range to the sandbox
/// `start_line`/`line_count` convention and threads through `tail_lines` /
/// `max_chars`. Normalizes the sandbox `{content}` payload into the
/// host-style text envelope so `file_read` has one shape on both routes.
/// When the path is a directory (the read fails with "Is a directory"),
/// falls back to a depth-bounded listing — the unified `file_read` reads
/// files and lists directories on the sandbox route too.
internal func sandboxBridgeRead(
    _ bridge: SandboxReadBridge,
    path: String,
    startLine: Int,
    endLine: Int,
    tailLines: Int,
    maxChars: Int,
    maxDepth: Int
) async throws -> String {
    var args: [String: Any] = ["path": path]
    if tailLines > 0 {
        args["tail_lines"] = tailLines
    } else if startLine > 0 {
        args["start_line"] = startLine
        if endLine >= startLine { args["line_count"] = endLine - startLine + 1 }
    }
    if maxChars > 0 { args["max_chars"] = maxChars }
    let raw = try await SandboxReadFileTool(agentName: bridge.agentName, home: bridge.home)
        .execute(argumentsJSON: encodeBridgeArgs(args))
    if ToolEnvelope.isError(raw), raw.lowercased().contains("is a directory") {
        return try await sandboxBridgeList(bridge, path: path, maxDepth: maxDepth > 0 ? maxDepth : 3)
    }
    return normalizedFileEnvelope(raw, tool: "file_read", payloadKey: "content", emptyText: "(empty file)")
}

/// List a sandbox directory for a combined-mode `file_read("/workspace/...")`
/// call on a directory path. Uses a depth-bounded `find` so `max_depth` is
/// honored (the filename-search tool can't bound depth) and returns a
/// host-style text envelope.
internal func sandboxBridgeList(
    _ bridge: SandboxReadBridge,
    path: String,
    maxDepth: Int
) async throws -> String {
    let resolvedReq = requirePath(path, home: bridge.home, tool: "file_read")
    guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }

    let depth = max(1, maxDepth)
    // `-printf '%y\t%p'` emits a type letter (`d`/`f`/...) + path per entry so
    // we can return a structured `{name, path, type}` listing instead of a
    // prose tree (GNU find on the Linux sandbox). The model copies an entry's
    // `path` straight into the next `file_read` call.
    let listCap = 500
    let command =
        "find '\(resolved)' -maxdepth \(depth) -printf '%y\\t%p\\n' 2>/dev/null | head -\(listCap)"
    let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
        bridge.agentName,
        command: command
    )
    guard result.succeeded else {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return sandboxExecutionFailure(
            tool: "file_read",
            message:
                "Failed to list `\(resolved)`: "
                + (stderr.isEmpty ? "exit code \(result.exitCode)" : stderr),
            retryable: false
        )
    }
    let rawLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
    var entries: [[String: Any]] = []
    for raw in rawLines {
        let line = String(raw)
        guard let tab = line.firstIndex(of: "\t") else { continue }
        let typeLetter = line[line.startIndex ..< tab]
        let entryPath = String(line[line.index(after: tab)...])
        // `find` lists the search root itself first; it is not a child entry.
        if entryPath == resolved { continue }
        let type = typeLetter == "d" ? "directory" : "file"
        let name = (entryPath as NSString).lastPathComponent
        entries.append(["name": name, "path": entryPath, "type": type])
    }
    return ToolEnvelope.listing(
        tool: "file_read",
        path: resolved,
        entries: entries,
        truncated: rawLines.count >= listCap
    )
}

/// Search a sandbox path for a combined-mode `file_search(..., path:"/workspace/...")`
/// call. Mirrors the host semantics: `target="content"` escapes the
/// pattern to a literal (case-insensitive) substring match and honors
/// `file_pattern` (-> sandbox `include`); `target="files"` is a filename
/// glob. Normalizes the sandbox `{matches}` payload into a host-style text
/// envelope.
internal func sandboxBridgeSearch(
    _ bridge: SandboxReadBridge,
    pattern: String,
    path: String,
    target: String,
    filePattern: String?,
    maxResults: Int
) async throws -> String {
    var args: [String: Any] = [
        "path": path,
        "max_results": max(maxResults, 1),
    ]
    if target == "files" {
        args["target"] = "files"
        args["pattern"] = pattern
    } else {
        args["target"] = "content"
        // Escape regex metacharacters so the sandbox `rg` route matches the
        // same literal substring the host route does.
        args["pattern"] = NSRegularExpression.escapedPattern(for: pattern)
        args["case_insensitive"] = true
        if let include = filePattern { args["include"] = include }
    }
    let raw = try await SandboxSearchFilesTool(agentName: bridge.agentName, home: bridge.home)
        .execute(argumentsJSON: encodeBridgeArgs(args))
    return normalizedFileEnvelope(
        raw,
        tool: "file_search",
        payloadKey: "matches",
        emptyText: "No matches found for '\(pattern)'"
    )
}

/// Re-shape a sandbox read/search success envelope into the host-style
/// text envelope the unified `file_*` tools return, so a given tool has
/// one output shape regardless of route. Sandbox failure envelopes (which
/// already carry the directory / host-path recovery hints) are forwarded
/// unchanged.
private func normalizedFileEnvelope(
    _ raw: String,
    tool: String,
    payloadKey: String,
    emptyText: String
) -> String {
    guard !ToolEnvelope.isError(raw) else { return raw }
    let value = (ToolEnvelope.successPayload(raw) as? [String: Any])?[payloadKey] as? String ?? ""
    let isEmpty = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return ToolEnvelope.success(tool: tool, text: isEmpty ? emptyText : value)
}

/// Sandbox-tool success envelope (thin wrapper around `ToolEnvelope.success`).
private func sandboxSuccess(
    tool: String,
    result: Any? = nil,
    warnings: [String]? = nil
) -> String {
    ToolEnvelope.success(tool: tool, result: result, warnings: warnings)
}

/// Sandbox-tool failure envelope with `kind: execution_error`. Use this
/// for runtime failures (process exited non-zero, etc.); use
/// `ToolEnvelope.failure(kind: .invalidArgs, ...)` directly for argument
/// validation so the `field` / `expected` fields are populated.
private func sandboxExecutionFailure(
    tool: String,
    message: String,
    retryable: Bool = true
) -> String {
    ToolEnvelope.failure(
        kind: .executionError,
        message: message,
        tool: tool,
        retryable: retryable
    )
}

/// Compute the per-call warning list for a foreground shell execution.
/// Two cases the model wants flagged:
///   - `exit 0 + empty stdout + empty stderr + pipeline / 2>/dev/null` →
///     loud "no output" warning. Pre-pipefail this was the silent
///     `head` masking pattern; with pipefail on we still surface the
///     warning because suppressed stderr (`2>/dev/null`) means any
///     genuine error is invisible to the model.
///   - `exit 141` → soft SIGPIPE note. Common and benign for
///     `cmd | head -n N` patterns where the upstream had more output;
///     captured stdout is still trustworthy.
///
/// Internal — shared by `SandboxExecTool` and `ShellRunTool` so both
/// tools speak the same vocabulary.
internal func diagnosticWarnings(
    command: String,
    exitCode: Int32,
    stdout: String,
    stderr: String
) -> [String] {
    var warnings: [String] = []
    let suspiciousEmpty =
        exitCode == 0
        && stdout.isEmpty
        && stderr.isEmpty
        && (command.contains("|") || command.contains("2>/dev/null"))
    if suspiciousEmpty {
        warnings.append(
            "Command exited 0 but produced no output. If you used `2>/dev/null` "
                + "in a pipeline, the upstream error was suppressed — re-run without "
                + "it to see what failed. (Pipefail is on, so a real upstream failure "
                + "would have set a non-zero exit; this looks like genuine empty "
                + "output OR redirected stderr.)"
        )
    }
    if exitCode == 141 {
        warnings.append(
            "A pipeline stage was terminated by SIGPIPE (exit 141). Usually safe "
                + "when piping into `head -n N` and the upstream had more data; the "
                + "captured stdout is still trustworthy."
        )
    }
    if let hint = shellCommandFailureHint(command: command, exitCode: exitCode, stderr: stderr) {
        warnings.append(hint)
    }
    if let hint = sandboxExecHostPathHint(command: command, exitCode: exitCode, stderr: stderr) {
        warnings.append(hint)
    }
    return warnings
}

/// Combined-mode backstop for the one read surface that can't be
/// path-routed: a raw `sandbox_exec` command (`ls`/`cat` a `/Users/...`
/// path) still hits the Linux sandbox, which has no copy of the host
/// workspace, so it fails or comes back empty. The unified `file_*` tools
/// cover everything else; this redirect catches the model that reached for
/// the shell anyway. Gated on combined mode + a macOS host path in the
/// command + a missing-file/empty signal so legitimate sandbox commands
/// are never nagged.
internal func sandboxExecHostPathHint(
    command: String,
    exitCode: Int32,
    stderr: String
) -> String? {
    guard ChatExecutionContext.hostReadOnlyScope != nil else { return nil }
    guard macHostPathPrefixes.contains(where: { command.contains($0) }) else { return nil }
    let lowered = stderr.lowercased()
    let looksMissing =
        exitCode != 0
        && (lowered.contains("no such file")
            || lowered.contains("not found")
            || lowered.contains("cannot access")
            || lowered.isEmpty)
    guard looksMissing else { return nil }
    return
        "That path looks like a macOS host path, which the Linux sandbox can't "
        + "see. To read your read-only host workspace, use `file_read` "
        + "(reads files, lists directories) / `file_search` — not `sandbox_exec`."
}

/// Lowercased stderr fragments that mark a shell-parse failure (as
/// opposed to an in-script runtime error). Matched case-insensitively.
private let shellParseSignatures = [
    "syntax error", "unexpected token", "unexpected eof", "unexpected end of file",
]

/// An interpreter followed by an inline-code flag — `python3 -c`,
/// `node -e`, `bash -c`, `sh -c`, `perl -e`, `ruby -e` — with flexible
/// whitespace. The signal that a command tried to inline a script.
private let interpreterInlineCodePattern = #"\b(python3?|node|bash|sh|perl|ruby)\s+-[ce]\b"#

/// Map a failed `sandbox_exec` to an actionable recovery hint for the
/// most common ways a local model mangles the `command` string. Returns
/// the single most-specific hint (branches are checked in priority order
/// so hints never stack or contradict), or nil when the failure isn't a
/// recognized shape — a raw runtime error or a syntax error the model
/// should just fix itself gets no hint.
///
/// Shapes, most-specific first:
///   1. Multi-line code mis-escaped into an interpreter `-c`/`-e` string.
///   2. Unterminated heredoc (`<<EOF` never closed).
///   3. Unbalanced / stray quote (the shell never found a closing quote).
public func shellCommandFailureHint(
    command: String,
    exitCode: Int32,
    stderr: String
) -> String? {
    guard exitCode != 0 else { return nil }
    let loweredStderr = stderr.lowercased()

    // Checked first: a failed bare package-manager install is a strong,
    // unambiguous signal regardless of the stderr shape, and the redirect
    // (use `sandbox_install`) is more valuable than any generic parse hint.
    if let hint = installRedirectHint(command: command) {
        return hint
    }
    if let hint = inlineCodeHint(command: command, stderr: loweredStderr) {
        return hint
    }
    if let hint = heredocHint(stderr: loweredStderr) {
        return hint
    }
    if let hint = unbalancedQuoteHint(stderr: loweredStderr) {
        return hint
    }
    return nil
}

/// Multi-line script embedded in a shell `-c` / `-e` string (e.g.
/// `python3 -c "…"`) whose escaping broke, so the shell mis-parsed the
/// code body. Requires BOTH a shell-parse signature AND an interpreter
/// inline-code flag, so a clean one-liner (`python3 -c 'print(1)'`) and
/// an in-script runtime error (`Traceback`) both stay silent.
private func inlineCodeHint(command: String, stderr loweredStderr: String) -> String? {
    guard shellParseSignatures.contains(where: { loweredStderr.contains($0) }) else { return nil }
    guard
        let regex = try? NSRegularExpression(pattern: interpreterInlineCodePattern, options: [.caseInsensitive]),
        regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    else { return nil }

    return
        "This looks like multi-line code embedded in a shell `-c` / `-e` "
        + "string whose escaping broke — the shell tried to parse your code "
        + "as commands (hence the syntax error). Don't re-escape it. "
        + "`sandbox_write_file` the script to a file (no shell escaping), "
        + "then `sandbox_exec` runs that file (e.g. `python3 script.py`)."
}

/// Unterminated heredoc: the `<<DELIM` body was never closed, so the
/// shell read to end-of-input. bash surfaces this as a `here-document …
/// delimited by end-of-file` warning.
private func heredocHint(stderr loweredStderr: String) -> String? {
    guard
        loweredStderr.contains("here-document"),
        loweredStderr.contains("delimited by end-of-file") || loweredStderr.contains("unexpected eof")
    else { return nil }

    return
        "This looks like an unterminated heredoc — the `<<` delimiter was "
        + "never closed, so the shell read to end-of-input. For multi-line "
        + "file content, prefer `sandbox_write_file` to create the file "
        + "directly instead of a shell heredoc."
}

/// Unbalanced / stray quote: the shell hit end-of-input still looking for
/// a closing quote (`bash: unexpected EOF while looking for matching `'`).
/// The common slip is wrapping the whole command in a quote.
private func unbalancedQuoteHint(stderr loweredStderr: String) -> String? {
    guard loweredStderr.contains("unexpected eof while looking for matching") else { return nil }

    // bash echoes the quote it wanted as the trailing token, e.g.
    // ``matching `"'`` (double) vs ``matching `''`` (single). Default to
    // single when we can't tell — it's the more common slip.
    let quote = loweredStderr.contains("matching `\"") ? "\"" : "'"
    return
        "Your command has an unbalanced \(quote) quote — the shell reached "
        + "end-of-input still looking for the closing \(quote). Check for a "
        + "stray or unclosed quote (a common slip is wrapping the WHOLE "
        + "command in quotes; pass it verbatim and quote only the arguments "
        + "that need it). For code or data with awkward quoting, "
        + "`sandbox_write_file` avoids shell quoting entirely."
}

/// A bare package-manager install run directly through `sandbox_exec`
/// (e.g. `apk add curl`, `pip install numpy`, `npm install express`) that
/// failed. These skip the dedicated `sandbox_install` tool's index
/// refresh, venv/workspace bootstrap, retry harness, and per-agent
/// serialization — `apk` always fails unprivileged, and bare pip/npm are
/// exactly what produced the historical venv/`idealTree` breakages. Redirect
/// the model to `sandbox_install` with the matching `manager`.
///
/// Matched at a statement boundary (start, or after `&&` / `||` / `;` / `|`)
/// so an install string buried in an argument doesn't false-fire, and only
/// on failure (`shellCommandFailureHint` already gates on a non-zero exit)
/// so a working install is never nagged.
private func installRedirectHint(command: String) -> String? {
    func matches(_ pattern: String) -> Bool {
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return false }
        return regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    let manager: String
    if matches(apkInstallPattern) {
        manager = "apk"
    } else if matches(pipInstallPattern) {
        manager = "pip"
    } else if matches(npmInstallPattern) {
        manager = "npm"
    } else {
        return nil
    }

    return
        "This is a bare `\(manager)` install run through `sandbox_exec`, which skips the "
        + "index refresh / venv / workspace bootstrap, retry harness, and per-agent "
        + "serialization (and `apk` needs root). Use `sandbox_install` with "
        + "`manager: \"\(manager)\"` and a `packages` array instead — e.g. "
        + "`{\"manager\": \"\(manager)\", \"packages\": [\"…\"]}`."
}

/// Statement-boundary prefix shared by the install detectors: start of
/// string or immediately after a shell separator, with optional `sudo`.
private let installStatementBoundary = #"(?:^|&&|\|\||;|\|)\s*(?:sudo\s+)?"#
private let apkInstallPattern = installStatementBoundary + #"apk\s+add\b"#
private let pipInstallPattern =
    installStatementBoundary + #"(?:pip3?|python3?\s+-m\s+pip)\s+install\b"#
private let npmInstallPattern =
    installStatementBoundary + #"(?:npm\s+(?:install|i|add)|yarn\s+add|pnpm\s+(?:add|install))\b"#

private let sandboxDefaultPATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

private func agentVenvPath(home: String) -> String {
    "\(home)/.venv"
}

/// Per-agent npm project workspace. `sandbox_npm_install` bootstraps a
/// `package.json` here and installs into `<workdir>/node_modules/`.
/// Isolating npm state under our namespace prevents leftover artefacts
/// from cross-contaminating the agent home and stops the well-known
/// "Tracker idealTree already exists" error that fires when `npm install`
/// runs over a stale `node_modules/.package-lock.json`.
private func agentNodeWorkdir(home: String) -> String {
    "\(home)/.osaurus/node_workspace"
}

/// The agent's raw secret env (key → value), for post-exec output
/// scrubbing. Same source `agentShellEnvironment` injects, minus the
/// non-secret additions (PATH / VIRTUAL_ENV).
private func agentSecretValues(agentId: String) -> [String: String] {
    guard let uuid = UUID(uuidString: agentId) else { return [:] }
    return AgentSecretsKeychain.getFilteredSecrets(agentId: uuid)
}

private func agentShellEnvironment(agentId: String, home: String, cwd: String? = nil) -> [String: String] {
    var env: [String: String] = [:]
    if let uuid = UUID(uuidString: agentId) {
        env = AgentSecretsKeychain.getFilteredSecrets(agentId: uuid)
    }
    let venvPath = agentVenvPath(home: home)
    let nodeWorkdir = agentNodeWorkdir(home: home)
    var pathEntries: [String] = []
    if let cwd, !cwd.isEmpty {
        pathEntries.append("\(cwd)/node_modules/.bin")
    }
    // The npm workdir's `node_modules/.bin` is always on PATH so installed
    // CLIs are reachable from any `sandbox_exec` cwd, mirroring how the
    // venv's `bin/` is unconditionally included below.
    pathEntries.append("\(nodeWorkdir)/node_modules/.bin")
    pathEntries.append("\(venvPath)/bin")
    pathEntries.append(sandboxDefaultPATH)
    env["VIRTUAL_ENV"] = venvPath
    env["PATH"] = pathEntries.joined(separator: ":")
    return env
}

private func jsonResult(_ dict: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .osaurusCanonical),
        let json = String(data: data, encoding: .utf8)
    else { return "{}" }
    return json
}

/// Cap a stream's worth of text before it lands in the model's context.
/// Keeps the first 40% of the budget and the last 60% — tail bias matters
/// because the final lines of a process (errors, summary prints) are
/// usually the most important.
///
/// Default budget is `ToolOutputCaps.execStdout` (~12.5K tokens). When
/// the input fits under the budget the text is returned untouched.
///
/// Internal — `SandboxPluginTool` shares this so user-created plugin
/// runs cap their stdout/stderr the same way the built-in shell tools do.
internal func truncateForModel(_ text: String, maxChars: Int = ToolOutputCaps.execStdout) -> String {
    HeadTailTruncation.apply(text, cap: maxChars, headFraction: 0.4)
}

protocol SandboxToolCommandRunning: Sendable {
    func exec(
        user: String?,
        command: String,
        env: [String: String],
        cwd: String?,
        timeout: TimeInterval?,
        streamToLogs: Bool,
        logSource: String?,
        stdoutTee: (any Writer)?,
        stderrTee: (any Writer)?,
        onProcessStarted: (@Sendable (ProcessHandle) -> Void)?
    ) async throws -> ContainerExecResult

    func execAsRoot(
        command: String,
        timeout: TimeInterval?,
        streamToLogs: Bool,
        logSource: String?,
        stdoutTee: (any Writer)?,
        stderrTee: (any Writer)?
    ) async throws -> ContainerExecResult

    func execAsAgent(
        _ agentName: String,
        command: String,
        pluginName: String?,
        env: [String: String],
        timeout: TimeInterval?,
        streamToLogs: Bool,
        logSource: String?,
        stdoutTee: (any Writer)?,
        stderrTee: (any Writer)?,
        onProcessStarted: (@Sendable (ProcessHandle) -> Void)?
    ) async throws -> ContainerExecResult
}

private struct LiveSandboxToolCommandRunner: SandboxToolCommandRunning {
    func exec(
        user: String?,
        command: String,
        env: [String: String] = [:],
        cwd: String? = nil,
        timeout: TimeInterval? = 30,
        streamToLogs: Bool = false,
        logSource: String? = nil,
        stdoutTee: (any Writer)? = nil,
        stderrTee: (any Writer)? = nil,
        onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
    ) async throws -> ContainerExecResult {
        try await SandboxManager.shared.exec(
            user: user,
            command: command,
            env: env,
            cwd: cwd,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource,
            stdoutTee: stdoutTee,
            stderrTee: stderrTee,
            onProcessStarted: onProcessStarted
        )
    }

    func execAsRoot(
        command: String,
        timeout: TimeInterval? = 60,
        streamToLogs: Bool = false,
        logSource: String? = nil,
        stdoutTee: (any Writer)? = nil,
        stderrTee: (any Writer)? = nil
    ) async throws -> ContainerExecResult {
        try await SandboxManager.shared.execAsRoot(
            command: command,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource,
            stdoutTee: stdoutTee,
            stderrTee: stderrTee
        )
    }

    func execAsAgent(
        _ agentName: String,
        command: String,
        pluginName: String? = nil,
        env: [String: String] = [:],
        timeout: TimeInterval? = 30,
        streamToLogs: Bool = false,
        logSource: String? = nil,
        stdoutTee: (any Writer)? = nil,
        stderrTee: (any Writer)? = nil,
        onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
    ) async throws -> ContainerExecResult {
        try await SandboxManager.shared.execAsAgent(
            agentName,
            command: command,
            pluginName: pluginName,
            env: env,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource,
            stdoutTee: stdoutTee,
            stderrTee: stderrTee,
            onProcessStarted: onProcessStarted
        )
    }
}

actor SandboxToolCommandRunnerRegistry {
    static let shared = SandboxToolCommandRunnerRegistry()

    private var runner: any SandboxToolCommandRunning = LiveSandboxToolCommandRunner()

    func setRunner(_ runner: any SandboxToolCommandRunning) {
        self.runner = runner
    }

    func reset() {
        runner = LiveSandboxToolCommandRunner()
    }

    func exec(
        user: String? = nil,
        command: String,
        env: [String: String] = [:],
        cwd: String? = nil,
        timeout: TimeInterval? = 30,
        streamToLogs: Bool = false,
        logSource: String? = nil,
        stdoutTee: (any Writer)? = nil,
        stderrTee: (any Writer)? = nil,
        onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
    ) async throws -> ContainerExecResult {
        try await runner.exec(
            user: user,
            command: command,
            env: env,
            cwd: cwd,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource,
            stdoutTee: stdoutTee,
            stderrTee: stderrTee,
            onProcessStarted: onProcessStarted
        )
    }

    func execAsRoot(
        command: String,
        timeout: TimeInterval? = 60,
        streamToLogs: Bool = false,
        logSource: String? = nil,
        stdoutTee: (any Writer)? = nil,
        stderrTee: (any Writer)? = nil
    ) async throws -> ContainerExecResult {
        try await runner.execAsRoot(
            command: command,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource,
            stdoutTee: stdoutTee,
            stderrTee: stderrTee
        )
    }

    func execAsAgent(
        _ agentName: String,
        command: String,
        pluginName: String? = nil,
        env: [String: String] = [:],
        timeout: TimeInterval? = 30,
        streamToLogs: Bool = false,
        logSource: String? = nil,
        stdoutTee: (any Writer)? = nil,
        stderrTee: (any Writer)? = nil,
        onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
    ) async throws -> ContainerExecResult {
        try await runner.execAsAgent(
            agentName,
            command: command,
            pluginName: pluginName,
            env: env,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource,
            stdoutTee: stdoutTee,
            stderrTee: stderrTee,
            onProcessStarted: onProcessStarted
        )
    }
}

/// Build the standard envelope for an install-style tool. Success and
/// failure both carry the requested package list and the truncated combined
/// output — only the envelope kind differs so the model can branch cleanly.
/// `retried` is `true` when the recovery harness ran a cleanup + second
/// attempt; surfaced on BOTH the success and failure paths so the model
/// (or downstream tooling) can branch on retry status without parsing
/// prose. On the failure path it also rides the `metadata` bag.
private func installResultEnvelope(
    tool: String,
    packages: [String],
    result: ContainerExecResult,
    retried: Bool = false
) -> String {
    if result.succeeded {
        // Drop the verbose installer log on success — it's pure noise in
        // the model's context (resolved-dependency trees, progress bars).
        // The `installed` list + a one-line summary is all the model needs;
        // failures below still carry full output for debugging.
        var payload: [String: Any] = [
            "installed": packages,
            "exit_code": Int(result.exitCode),
            "summary": "Installed \(packages.count) package(s): \(packages.joined(separator: ", ")).",
        ]
        if retried { payload["retried"] = true }
        return ToolEnvelope.success(tool: tool, result: payload)
    }
    let combined = truncateForModel(
        result.stdout + result.stderr,
        maxChars: ToolOutputCaps.execRetryCombined
    )
    let stage = retried ? "after retry" : ""
    let header =
        stage.isEmpty
        ? "Install failed (exit \(result.exitCode))"
        : "Install failed \(stage) (exit \(result.exitCode))"
    return ToolEnvelope.failure(
        kind: .executionError,
        message:
            "\(header). Combined output: "
            + combined.trimmingCharacters(in: .whitespacesAndNewlines),
        tool: tool,
        retryable: true,
        metadata: retried ? ["retried": true] : nil
    )
}

/// Build a failure envelope for the rare case where the recovery
/// harness's own cleanup step threw. Carries both the original
/// install output and the cleanup error so the model has the full
/// "first attempt failed AND recovery couldn't even run" picture
/// instead of a generic `execution_error` from `ToolEnvelope.fromError`.
private func installCleanupFailureEnvelope(
    tool: String,
    packages: [String],
    firstAttempt: ContainerExecResult,
    cleanupError: Error
) -> String {
    let firstCombined = truncateForModel(
        firstAttempt.stdout + firstAttempt.stderr,
        maxChars: ToolOutputCaps.execFirstAttemptCombined
    )
    return ToolEnvelope.failure(
        kind: .executionError,
        message:
            "Install failed (exit \(firstAttempt.exitCode)) and recovery cleanup also "
            + "failed: \(cleanupError.localizedDescription). First attempt output: "
            + firstCombined.trimmingCharacters(in: .whitespacesAndNewlines),
        tool: tool,
        retryable: true,
        metadata: ["retried": false, "cleanup_failed": true, "packages": packages]
    )
}

/// Run an install operation; if its first failure matches a known
/// stale-state signature, run a tool-specific cleanup and retry once.
///
/// Centralised here so npm / pip / apk all get the same retry semantics
/// and the same `retried`-flag surface in their result envelope. The
/// caller supplies the signature predicate AND the cleanup body — both
/// run in the same exec context as the install (agent for npm/pip,
/// root for apk) so the cleanup can drop lockfiles or refresh caches
/// without escalating privilege.
///
/// If the cleanup body itself throws (rare — our cleanups all `|| true`
/// or run defensively), we wrap that as a structured failure envelope
/// rather than letting the throw propagate to a generic
/// `ToolEnvelope.fromError(...)`. That keeps the install context
/// (packages list, first-attempt output) reachable for the model.
///
/// Closure parameters are `@Sendable` so the helper can be invoked
/// from within a `@Sendable` context (which is what the install tools
/// do when wrapping themselves in `SandboxInstallLock.serialize`).
private func runInstallWithRecovery(
    tool: String,
    packages: [String],
    attempt: @Sendable () async throws -> ContainerExecResult,
    isRecoverable: @Sendable (ContainerExecResult) -> Bool,
    cleanup: @Sendable () async throws -> Void,
    onSuccess: (@Sendable ([String]) -> Void)? = nil
) async throws -> String {
    let first = try await attempt()
    if first.succeeded || !isRecoverable(first) {
        if first.succeeded { onSuccess?(packages) }
        return installResultEnvelope(tool: tool, packages: packages, result: first, retried: false)
    }
    do {
        try await cleanup()
    } catch {
        return installCleanupFailureEnvelope(
            tool: tool,
            packages: packages,
            firstAttempt: first,
            cleanupError: error
        )
    }
    let second = try await attempt()
    if second.succeeded { onSuccess?(packages) }
    return installResultEnvelope(tool: tool, packages: packages, result: second, retried: true)
}

/// Substring matchers for each installer's well-known stale-state errors.
/// Substrings (not regex) so the test surface stays readable; if a model
/// hits a third variant we widen the array rather than adding a new branch.
private enum InstallRecoverableErrors {
    static let npm: [String] = [
        // npm 9+ arborist tracker bug — fires when a previous install
        // left `node_modules/.package-lock.json` half-written.
        "Tracker \"idealTree\" already exists",
        "Tracker \"idealTree\" doesn't exist",
        // Filesystem layer signs of a previous interrupted install.
        "EEXIST: file already exists",
        "ENOTEMPTY",
        "ELOCKED",
    ]

    static let pip: [String] = [
        "Could not install packages due to an OSError",
        "ReadTimeoutError",
        // distutils-shaped legacy installs that pip refuses to remove
        // without `--ignore-installed`. Cleanup just clears cache so a
        // fresh download retries. Pinned to the full distutils marker
        // (not the looser `"Cannot uninstall"` prefix) so unrelated
        // pip errors that mention "Cannot uninstall" don't trigger an
        // unnecessary cache purge + retry.
        "distutils installed project",
    ]

    static let apk: [String] = [
        "temporary error (try again later)",
        "unable to lock database",
    ]

    /// True when `result`'s combined stdout+stderr contains any of the
    /// supplied known-recoverable signatures.
    static func contains(_ result: ContainerExecResult, anyOf needles: [String]) -> Bool {
        let haystack = result.stdout + result.stderr
        return needles.contains { haystack.contains($0) }
    }
}

// MARK: - sandbox_read_file

private struct SandboxReadFileTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_read_file"
    let description =
        "Read a file's contents from the sandbox. **Use this instead of `cat`/`head`/`tail` in `sandbox_exec`.** "
        + "Supports line ranges (`start_line` + `line_count`), log-style tails (`tail_lines`), and a per-call "
        + "character cap (`max_chars`). Pass either a path under the agent home (e.g. `notes.txt`) or an "
        + "absolute path inside the sandbox (e.g. `/workspace/shared/data.csv`). Surfaces stderr on failure."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string(
                        "File path, relative to agent home or absolute under `\(home)` / `/workspace/shared`."
                    ),
                ]),
                "start_line": .object([
                    "type": .string("integer"),
                    "description": .string("1-based starting line to read"),
                ]),
                "line_count": .object([
                    "type": .string("integer"),
                    "description": .string("Number of lines to read from start_line"),
                ]),
                "tail_lines": .object([
                    "type": .string("integer"),
                    "description": .string("Read the last N lines, useful for logs"),
                ]),
                "max_chars": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Cap returned characters after line selection (default \(ToolOutputCaps.fileRead))"
                    ),
                ]),
            ]),
            "required": .array([.string("path")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "file path under the agent home or absolute under `\(home)` / `/workspace/shared`",
            tool: name
        )
        guard case .value(let path) = pathReq else { return pathReq.failureEnvelope ?? "" }

        let resolvedReq = requirePath(path, home: home, tool: name)
        guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }

        let startLine = max(coerceInt(args["start_line"]) ?? 0, 0)
        let lineCount = max(coerceInt(args["line_count"]) ?? 0, 0)
        let tailLines = max(coerceInt(args["tail_lines"]) ?? 0, 0)
        // Default cap when the model omits `max_chars`: same budget as the
        // host `file_read`, so an unbounded `cat` of a generated artifact
        // can't blow the context in one call. An explicit `max_chars`
        // still overrides (already capped by the universal registry cap).
        let maxChars = coerceInt(args["max_chars"]).map { max($0, 0) } ?? ToolOutputCaps.fileRead

        let command: String
        if tailLines > 0 {
            command =
                maxChars > 0
                ? "tail -n \(tailLines) '\(resolved)' | head -c \(maxChars)"
                : "tail -n \(tailLines) '\(resolved)'"
        } else if startLine > 0 {
            let count = max(lineCount, 1)
            let endLine = startLine + count - 1
            command =
                maxChars > 0
                ? "sed -n '\(startLine),\(endLine)p' '\(resolved)' | head -c \(maxChars)"
                : "sed -n '\(startLine),\(endLine)p' '\(resolved)'"
        } else {
            command = maxChars > 0 ? "head -c \(maxChars) '\(resolved)'" : "cat '\(resolved)'"
        }

        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: command
        )
        guard result.succeeded else {
            // The model used to see this as `{path, content:"", size:0}` —
            // indistinguishable from an empty file. Surface the actual
            // stderr so it can react (file missing, permission denied, ...).
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "exit code \(result.exitCode)" : stderr
            var message = "Failed to read `\(resolved)`: \(detail)"
            if let hint = sandboxDirectoryReadHint(stderr: stderr) {
                message += " " + hint
            }
            return sandboxExecutionFailure(
                tool: name,
                message: message,
                retryable: false
            )
        }
        var payload: [String: Any] = [
            // `kind: "file"` so `AgentTaskState.classify` sees this as a
            // file read in plain-sandbox mode (progress signal + dedupe),
            // exactly like the folder `file_read` envelope.
            "kind": "file",
            "path": resolved,
            "content": result.stdout,
            "size": result.stdout.count,
        ]
        if startLine > 0 {
            payload["start_line"] = startLine
            payload["line_count"] = max(lineCount, 1)
        }
        if tailLines > 0 {
            payload["tail_lines"] = tailLines
        }
        if maxChars > 0 {
            payload["max_chars"] = maxChars
        }
        // Hitting the cap exactly almost always means the file continues —
        // flag it with a recovery path instead of a silent cut.
        if maxChars > 0, result.stdout.count >= maxChars {
            payload["truncated"] = true
            return sandboxSuccess(
                tool: name,
                result: payload,
                warnings: [
                    "Content truncated at \(maxChars) chars. Read the rest with `start_line`/`line_count`, `tail_lines`, or a larger `max_chars`."
                ]
            )
        }
        return sandboxSuccess(tool: name, result: payload)
    }
}

// MARK: - sandbox_search_files
//
// One tool, two targets: content (ripgrep) and filenames (find). Folded
// from the previously-separate `sandbox_search_files` + `sandbox_find_files`
// + `sandbox_list_directory` so the model has fewer tool names to pick
// between — less chance of "I called search_files when I wanted find_files".

private struct SandboxSearchFilesTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_search_files"
    let description =
        "Search file contents OR find files by name. **Use this instead of `grep`/`rg`/`find`/`ls` "
        + "in `sandbox_exec`.** Pass `target=\"content\"` (default) for a regex search inside file "
        + "bodies, or `target=\"files\"` to find files by name (case-insensitive substring, e.g. `q4`; "
        + "use `*`/`?` for a glob like `*.py`, `test_*`). Cap output "
        + "with `max_results` (default 100, max 500). Returns `{matches: \"...\"}` for both targets."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string(
                        "When `target=\"content\"`: ripgrep regex (e.g. `TODO|FIXME`). "
                            + "When `target=\"files\"`: filename to find (case-insensitive substring, "
                            + "e.g. `q4`; use `*`/`?` for a glob like `*.py`, `test_*`)."
                    ),
                ]),
                "target": .object([
                    "type": .string("string"),
                    "enum": .array([.string("content"), .string("files")]),
                    "description": .string(
                        "`content` searches inside file bodies (rg); `files` finds files by "
                            + "name (find). Default: `content`."
                    ),
                    "default": .string("content"),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Directory to search (default: agent home)"),
                    "default": .string("."),
                ]),
                "include": .object([
                    "type": .string("string"),
                    "description": .string(
                        "File glob filter for content searches (e.g. `*.py`). Ignored when "
                            + "`target=\"files\"` — use `pattern` directly."
                    ),
                ]),
                "context_lines": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Lines of context before/after each match (max 10). Content target only."
                    ),
                ]),
                "case_insensitive": .object([
                    "type": .string("boolean"),
                    "description": .string("Enable case-insensitive search. Content target only."),
                    "default": .bool(false),
                ]),
                "max_results": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum lines of output (default 100, max 500)."),
                    "default": .number(100),
                ]),
            ]),
            "required": .array([.string("pattern")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let target = (args["target"] as? String)?.lowercased() ?? "content"
        let expectedPattern =
            target == "files"
            ? "filename glob (e.g. `*.py`, `test_*`)"
            : "ripgrep regex (e.g. `TODO|FIXME`)"

        let patternReq = requireString(args, "pattern", expected: expectedPattern, tool: name)
        guard case .value(let pattern) = patternReq else { return patternReq.failureEnvelope ?? "" }

        let path = args["path"] as? String ?? "."
        let resolvedReq = requirePath(path, home: home, tool: name)
        guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }

        let maxResults = coerceInt(args["max_results"]) ?? 100
        let cappedMax = max(1, min(maxResults, ToolOutputCaps.searchMaxResults))

        switch target {
        case "files":
            // A bare word becomes a case-insensitive substring (`*word*`); a
            // pattern with `*`/`?` is passed through as a case-insensitive
            // glob. Mirrors the host `findFilesByName` matching rule. A
            // pattern carrying `/` can never match a basename, so it matches
            // the path instead (`-ipath`) — same rule as the host route.
            let namePattern =
                FolderToolHelpers.patternHasGlobMetacharacters(pattern) ? pattern : "*\(pattern)*"
            let escapedPattern = shellEscapeSingleQuoted(namePattern)
            let findPredicate = pattern.contains("/") ? "-ipath" : "-iname"
            let cmd =
                "find '\(resolved)' -type f \(findPredicate) '\(escapedPattern)' 2>/dev/null | head -\(cappedMax)"
            let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
                agentName,
                command: cmd
            )
            return searchSuccess(
                pattern: pattern,
                target: "files",
                resolved: resolved,
                matches: result.stdout,
                cappedMax: cappedMax
            )

        case "content":
            var cmd = "rg -n --no-heading"
            if coerceBool(args["case_insensitive"]) == true {
                cmd += " -i"
            }
            if let contextLines = coerceInt(args["context_lines"]), contextLines > 0 {
                cmd += " -C \(min(contextLines, 10))"
            }
            if let include = args["include"] as? String {
                cmd += " --glob '\(shellEscapeSingleQuoted(include))'"
            }
            // Single-quote-escape the pattern before shell interpolation.
            // Without this the model could pass `'; rm -rf $HOME; '` and
            // break out of the quotes (the path sanitizer doesn't apply
            // to free-form regex).
            cmd +=
                " '\(shellEscapeSingleQuoted(pattern))' '\(resolved)'"
                + " 2>/dev/null | head -\(cappedMax)"

            let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
                agentName,
                command: cmd
            )
            return searchSuccess(
                pattern: pattern,
                target: "content",
                resolved: resolved,
                matches: result.stdout,
                cappedMax: cappedMax
            )

        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Unsupported `target`: `\(target)`. Use `content` (search file bodies with rg) "
                    + "or `files` (find files by name).",
                field: "target",
                expected: "one of `content`, `files`",
                tool: name
            )
        }
    }

    /// When a search comes back empty, surface the combined-mode
    /// host-workspace redirect (if applicable) as a soft warning.
    private func emptySearchWarnings(matches: String, resolved: String) -> [String]? {
        guard matches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let hint = hostWorkspaceSearchRedirectHint(resolvedPath: resolved, home: home) else {
            return nil
        }
        return [hint]
    }

    /// Shared success shaping for both search targets: flags a result set
    /// that hit the `head -N` cut with `truncated: true` plus a narrowing
    /// hint, so the model knows the match list is incomplete instead of
    /// treating the cap as the full universe.
    private func searchSuccess(
        pattern: String,
        target: String,
        resolved: String,
        matches: String,
        cappedMax: Int
    ) -> String {
        let lineCount = matches.split(separator: "\n", omittingEmptySubsequences: true).count
        let truncated = lineCount >= cappedMax
        var payload: [String: Any] = [
            "pattern": pattern,
            "target": target,
            "path": resolved,
            "matches": matches,
        ]
        var warnings = emptySearchWarnings(matches: matches, resolved: resolved) ?? []
        if truncated {
            payload["truncated"] = true
            warnings.append(
                "Results truncated at \(cappedMax) lines — more matches exist. Narrow with a more specific `pattern`, a deeper `path`, or "
                    + (target == "content" ? "an `include` glob." : "a tighter glob.")
            )
        }
        return sandboxSuccess(
            tool: name,
            result: payload,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }
}

/// Escape a string for safe interpolation inside a single-quoted shell
/// argument. Replaces every `'` with the standard `'\''` end-then-begin
/// trick. Used for free-form arguments (regex, glob) that the path
/// sanitizer does NOT cover.
private func shellEscapeSingleQuoted(_ s: String) -> String {
    s.replacingOccurrences(of: "'", with: "'\\''")
}

// MARK: - sandbox_write_file

private struct SandboxWriteFileTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_write_file"
    let description =
        "Write a file, or edit it in place. Provide `content` to write/replace the whole file; "
        + "provide `old_string` (+`new_string`) to replace one exact match. **Use this instead of "
        + "`echo`/`cat` heredoc / `sed` / `awk` in `sandbox_exec`.** Creates parent directories as "
        + "needed. For an edit, `old_string` must uniquely match one location — include surrounding "
        + "context lines if needed; it fails if `old_string` is missing or matches multiple locations."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string(
                        "File path, relative to agent home or absolute under `\(home)` / `/workspace/shared`."
                    ),
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Whole-file contents (string). Pass `\"\"` for an empty file. Omit when editing via `old_string`. Binary / NUL bytes are not safe — they ride a `printf` shell pipeline."
                    ),
                ]),
                "old_string": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Exact text to find and replace (must match exactly one location in the file). Present ⇒ in-place edit instead of whole-file write."
                    ),
                ]),
                "new_string": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Replacement text for the `old_string` edit. Use `\"\"` to delete the match."
                    ),
                ]),
            ]),
            "required": .array([.string("path")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "file path under the agent home or absolute under `\(home)` / `/workspace/shared`",
            tool: name
        )
        guard case .value(let path) = pathReq else { return pathReq.failureEnvelope ?? "" }

        let resolvedReq = requirePath(path, home: home, tool: name)
        guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }

        // The presence of `old_string` decides edit vs whole-file write —
        // the model picks the behavior from an argument it already holds,
        // not a separate tool name. (Decision-elimination test.)
        if args["old_string"] != nil {
            return try await editInPlace(args: args, resolved: resolved)
        }

        // Neither `content` nor `old_string`: nothing to write. Point the
        // model at the two valid shapes rather than failing opaquely.
        guard args["content"] != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Provide `content` to write the whole file, or `old_string` (+`new_string`) to "
                    + "edit one exact match in place.",
                field: "content",
                expected: "`content` (whole-file write) or `old_string` + `new_string` (in-place edit)",
                tool: name
            )
        }

        return try await writeWhole(args: args, resolved: resolved)
    }

    /// Whole-file write branch. Empty content is legitimate (truncate-to-zero).
    private func writeWhole(args: [String: Any], resolved: String) async throws -> String {
        let contentReq = requireString(
            args,
            "content",
            expected: "string of file contents (use `\"\"` for an empty file)",
            tool: name,
            allowEmpty: true
        )
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }

        // Capture the pre-write content so the chat can render a diff card.
        let before = await readForDiff(resolved: resolved)

        let dir = (resolved as NSString).deletingLastPathComponent
        _ = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: "mkdir -p '\(dir)'"
        )

        let escaped = shellEscapeSingleQuoted(content)
        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: "printf '%s' '\(escaped)' > '\(resolved)'"
        )
        guard result.succeeded else {
            return sandboxExecutionFailure(
                tool: name,
                message:
                    "Failed to write `\(resolved)`: "
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return sandboxSuccess(
            tool: name,
            result: writeResult(
                resolved: resolved,
                before: before,
                after: content,
                extra: ["size": content.count]
            )
        )
    }

    /// In-place edit branch: replace one exact `old_string` match with
    /// `new_string`. `old_string` is already known present; `new_string`
    /// is required here (its absence is the merge's only new validation).
    private func editInPlace(args: [String: Any], resolved: String) async throws -> String {
        let oldReq = requireString(
            args,
            "old_string",
            expected: "non-empty exact text that uniquely matches one location in the file",
            tool: name
        )
        guard case .value(let oldString) = oldReq else { return oldReq.failureEnvelope ?? "" }

        guard args["new_string"] != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`old_string` given without `new_string` — an in-place edit needs both. Use "
                    + "`\"\"` for `new_string` to delete the match.",
                field: "new_string",
                expected: "replacement text (use `\"\"` to delete the match)",
                tool: name
            )
        }
        // Allow empty new_string (used to delete the matched text).
        let newReq = requireString(
            args,
            "new_string",
            expected: "replacement text (use `\"\"` to delete the match)",
            tool: name,
            allowEmpty: true
        )
        guard case .value(let newString) = newReq else { return newReq.failureEnvelope ?? "" }

        // Capture pre-edit content for the diff card (best-effort).
        let before = await readForDiff(resolved: resolved)

        let tmpDir = "\(home)/.tmp"
        _ = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: "mkdir -p '\(tmpDir)'"
        )

        let suffix = String(UUID().uuidString.prefix(8))
        let oldFile = "\(tmpDir)/.edit_old_\(suffix)"
        let newFile = "\(tmpDir)/.edit_new_\(suffix)"

        let escapedOld = shellEscapeSingleQuoted(oldString)
        let escapedNew = shellEscapeSingleQuoted(newString)
        _ = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: "printf '%s' '\(escapedOld)' > '\(oldFile)'"
        )
        _ = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: "printf '%s' '\(escapedNew)' > '\(newFile)'"
        )

        let script = """
            import sys
            target = sys.argv[1]
            old_file = sys.argv[2]
            new_file = sys.argv[3]
            with open(target, 'r') as f:
                content = f.read()
            with open(old_file, 'r') as f:
                old = f.read()
            with open(new_file, 'r') as f:
                new = f.read()
            count = content.count(old)
            if count == 0:
                print('ERROR: old_string not found in file', file=sys.stderr)
                sys.exit(1)
            if count > 1:
                print(f'ERROR: old_string matches {count} locations — include more context to make it unique', file=sys.stderr)
                sys.exit(1)
            content = content.replace(old, new, 1)
            with open(target, 'w') as f:
                f.write(content)
            old_lines = old.count('\\n') + (0 if old.endswith('\\n') else 1)
            new_lines = new.count('\\n') + (0 if new.endswith('\\n') else 1)
            print(f'replaced {old_lines} line(s) with {new_lines} line(s)')
            """

        let escapedScript = shellEscapeSingleQuoted(script)
        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command:
                "python3 -c '\(escapedScript)' '\(resolved)' '\(oldFile)' '\(newFile)'; EC=$?; rm -f '\(oldFile)' '\(newFile)'; exit $EC"
        )

        guard result.succeeded else {
            return sandboxExecutionFailure(
                tool: name,
                message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                retryable: false
            )
        }

        // Read the applied result so the diff reflects what's actually on disk.
        let after = await readForDiff(resolved: resolved)?.content
        return sandboxSuccess(
            tool: name,
            result: writeResult(
                resolved: resolved,
                before: before,
                after: after,
                extra: ["summary": result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        )
    }

    /// Best-effort read of the current file for diffing. Returns nil on any exec
    /// failure — the diff is non-essential and must never block a write. The
    /// command prints a `1`/`0` existence marker line, then the raw contents.
    private func readForDiff(resolved: String) async -> (existed: Bool, content: String)? {
        let command = "if [ -f '\(resolved)' ]; then echo 1; cat '\(resolved)'; else echo 0; fi"
        guard
            let result = try? await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
                agentName,
                command: command
            ),
            result.succeeded,
            let newline = result.stdout.firstIndex(of: "\n")
        else { return nil }
        let existed = String(result.stdout[..<newline]) == "1"
        let content = String(result.stdout[result.stdout.index(after: newline)...])
        return (existed, content)
    }

    /// Assembles the success-result dict, attaching a unified diff when both the
    /// before and after contents were captured. Keeps the existing model-facing
    /// fields (`size` / `summary`) via `extra`.
    private func writeResult(
        resolved: String,
        before: (existed: Bool, content: String)?,
        after: String?,
        extra: [String: Any]
    ) -> [String: Any] {
        var dict: [String: Any] = ["path": resolved]
        dict.merge(extra) { _, new in new }
        if let before, let after {
            let diff = WorkspaceWriteSafety.unifiedDiffText(
                old: before.content,
                new: after,
                path: resolved,
                existed: before.existed
            )
            dict["diff"] = diff.text
            dict["diff_truncated"] = diff.truncated
            dict["dry_run"] = false
            dict["action"] = before.existed ? "update" : "create"
        }
        return dict
    }
}

// MARK: - sandbox_exec
//
// One shell tool, foreground OR background via the `background` flag.
// Folded the previously-separate `sandbox_exec_background` in here so
// the model picks "run a command" and toggles a flag, rather than
// picking between two near-identical tool names.

private struct SandboxExecTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_exec"
    let agentId: String
    let agentName: String
    let home: String
    let maxCommandsPerTurn: Int
    /// When false, the `background` flag is hidden from the schema, the
    /// background paragraph is dropped from the description, and a
    /// `background:true` call is rejected at runtime.
    let backgroundEnabled: Bool

    /// Built conditionally: the "Background (`background:true`)" paragraph
    /// only appears when the agent has opted into background jobs, so a
    /// background-off agent never sees an affordance it can't use.
    var description: String {
        let backgroundParagraph =
            backgroundEnabled
            ? """


            Background (`background:true`): returns a `pid` + `log_file` \
            immediately; the user can also tail and terminate via the chat card. \
            Use for servers, watchers, daemons that should outlive your call. \
            Then call `sandbox_process` to poll/wait/kill. Do NOT shell-background \
            yourself with `&` / `nohup` / `disown` — pass `background:true` so \
            the runtime can track it.
            """
            : ""
        return """
            Run a shell command (bash) in the agent's sandbox. **Reserve this for \
            builds, installs, git, processes, network calls, package managers, \
            and anything else that needs a shell.** For file IO, search, edit, \
            and write, prefer the dedicated `sandbox_*` tools (see the sandbox \
            tool dispatch in your instructions).

            Foreground (default): runs to completion; output streams live to the \
            chat and the user can press [Terminate] (surfaces `killed_by: "user"`). \
            Prefer ONE rich invocation (chained with `&&` / `;` / pipes) over many \
            round-trips.\(backgroundParagraph)

            Takes a single command LINE, passed verbatim — quote individual \
            arguments only, never the whole command. Multi-line scripts: \
            `sandbox_write_file` the script, then run the file. No built-in \
            timeout; pass `timeout: <seconds>` ONLY for a hard idle ceiling \
            (killed after N silent seconds). Output truncated at ~50KB \
            (head + tail kept). Per-turn command count is capped — chain inside \
            one call. Avoid `2>/dev/null` — pipefail is on and suppressed stderr \
            triggers an empty-output warning.
            """
    }

    /// Streaming exec opts out of the registry's wall-clock cap. Long
    /// commands rely on the user's [Terminate] button + the optional
    /// `timeout` (idle ceiling) as the safety net.
    var bypassRegistryTimeout: Bool { true }

    var parameters: JSONValue? {
        // The "Ignored when `background:true`" caveat only makes sense when
        // the background flag is actually advertised.
        let timeoutDescription =
            "Optional idle-timeout in seconds. When set, the command is killed if it "
            + "produces no stdout/stderr output for this many seconds (resets on every "
            + "byte). When omitted, the command runs to completion — the user terminates "
            + "from the chat card if needed."
            + (backgroundEnabled ? " Ignored when `background:true`." : "")
        var properties: [String: JSONValue] = [
            "command": .object([
                "type": .string("string"),
                "description": .string("Shell command to run (single string, e.g. `wc -l src/*.swift`)."),
            ]),
            "cwd": .object([
                "type": .string("string"),
                "description": .string(
                    "Working directory. Defaults to your home (`\(home)`) — OMIT unless you "
                        + "need a different directory. Use a path relative to home (e.g. `src`) "
                        + "or absolute under your home; system paths like `/root` are rejected."
                ),
            ]),
            "timeout": .object([
                "type": .string("integer"),
                "description": .string(timeoutDescription),
            ]),
        ]
        // Background is opt-in: only advertise the flag when the agent has
        // `backgroundProcessEnabled`. Otherwise it never enters the schema.
        if backgroundEnabled {
            properties["background"] = .object([
                "type": .string("boolean"),
                "description": .string(
                    "When true, the command runs detached with stdout+stderr redirected to "
                        + "a per-job log under the agent home; the tool returns the pid + log "
                        + "path immediately. Use for long-lived processes (servers, watchers). "
                        + "Pair with `sandbox_process`."
                ),
                "default": .bool(false),
            ])
        }
        return .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
            "required": .array([.string("command")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard
            SandboxExecLimiter.shared.checkAndIncrement(
                agentName: agentName,
                limit: maxCommandsPerTurn
            )
        else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "Per-turn command limit reached (\(maxCommandsPerTurn) commands). "
                    + "Wait until the next turn or chain steps inside one `sandbox_exec` call.",
                tool: name,
                retryable: false
            )
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let cmdReq = requireString(
            args,
            "command",
            expected: "shell command string (e.g. `ls -la`)",
            tool: name
        )
        guard case .value(let command) = cmdReq else { return cmdReq.failureEnvelope ?? "" }

        // Resolve `cwd` strictly: if the model passed something, the path
        // sanitizer must accept it. Silent fallback to home (the previous
        // behaviour) ran the command in the wrong directory without telling
        // the model — caused subtle bugs that looked like missing files.
        let cwd: String
        if let cwdArg = args["cwd"] as? String, !cwdArg.isEmpty {
            let cwdReq = requirePath(cwdArg, home: home, field: "cwd", tool: name)
            guard case .value(let resolvedCwd) = cwdReq else { return cwdReq.failureEnvelope ?? "" }
            cwd = resolvedCwd
        } else {
            cwd = home
        }

        let background = coerceBool(args["background"]) ?? false

        // Defense in depth: the schema strip is advisory, so a model that
        // passes `background:true` anyway when the agent hasn't opted in
        // gets a clear refusal instead of a silently-detached job.
        if background, !backgroundEnabled {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "Background execution is disabled for this agent. Run the command in the "
                    + "foreground (omit `background`), or enable Background Processes in the "
                    + "agent's sandbox settings.",
                tool: name,
                retryable: false
            )
        }

        if background {
            // Detached job: start it, return pid + log path right away. The
            // 10s timeout here is just for the spawn shim — the spawned
            // process itself can run as long as it likes.
            //
            // `set -o pipefail` is wrapped around the user's command via a
            // nested `bash -c` so a real upstream pipeline failure
            // surfaces as the rightmost non-zero exit instead of being
            // masked by `head` / `tee` / `cat`. The user's command is
            // single-quoted; we escape any internal `'` per shell rules.
            let logFile = "\(home)/bg-\(UUID().uuidString.prefix(8)).log"
            let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
            // `setsid` makes the wrapper a session/process-group leader so a
            // later `kill -- -<pid>` can take down the whole job tree —
            // signalling only the wrapper pid leaves its children (the actual
            // workload) running as orphans.
            let fullCmd =
                "cd '\(cwd)' && nohup setsid bash -c 'set -o pipefail; \(escaped)' "
                + "> \(logFile) 2>&1 & echo $!"

            let result = try await SandboxToolCommandRunnerRegistry.shared.exec(
                user: "agent-\(agentName)",
                command: fullCmd,
                env: agentShellEnvironment(agentId: agentId, home: home, cwd: cwd),
                cwd: cwd,
                timeout: 10,
                streamToLogs: true,
                logSource: agentName
            )
            let pid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pid.isEmpty {
                await SandboxBackgroundJobs.shared.register(
                    agentName: agentName,
                    pid: pid,
                    logFile: logFile,
                    command: command
                )
                // Tee the log file into the chat UI so background jobs
                // get the same Cursor-style live tail as foreground
                // ones. Terminate maps to `kill -<sig> <pid>` via
                // execAsRoot so the user can stop a runaway server
                // without leaving the chat.
                let toolCallId = ChatExecutionContext.currentToolCallId ?? UUID().uuidString
                await registerBackgroundLiveExec(
                    toolCallId: toolCallId,
                    pid: pid,
                    command: command,
                    inContainerLogPath: logFile,
                    agentName: agentName
                )
            }
            return sandboxSuccess(
                tool: name,
                result: [
                    "pid": pid,
                    "log_file": logFile,
                    "cwd": cwd,
                    "background": true,
                ]
            )
        }

        // Foreground timeout: optional inactivity ceiling. When the
        // model omits `timeout`, we pass nil all the way down so
        // `waitWithInactivityTimeout` falls back to `process.wait()`
        // with no idle check. The user's [Terminate] button is the
        // primary control for runaway commands.
        let idleTimeout: TimeInterval? = coerceInt(args["timeout"]).map(TimeInterval.init)

        // Live streaming wiring: register a LiveExecRegistry entry
        // BEFORE the runner blocks. The chat layer observes the
        // registry, attaches the handle to the matching tool-call
        // item, and the row mounts a TerminalDisplayView that subscribes
        // to the sink's publishers. The user's [Terminate] button
        // calls back through the entry's `terminate` closure, which
        // signals SIGTERM via the captured ProcessHandle.
        let toolCallId = ChatExecutionContext.currentToolCallId ?? UUID().uuidString
        let sink = LiveExecSink()
        let processBox = ProcessHandleBox()

        let terminate: @Sendable (Int) async -> Void = { graceSeconds in
            sink.requestTerminate()
            await processBox.terminateWithGrace(graceSeconds: graceSeconds)
        }

        await LiveExecRegistry.shared.register(
            LiveExecRegistry.Entry(
                toolCallId: toolCallId,
                pid: "",
                command: command,
                startedAt: Date(),
                outputPublisher: sink.outputPublisher,
                statusPublisher: sink.statusPublisher,
                currentStatus: { sink.currentStatus },
                seed: { await sink.bufferedSnapshot() },
                terminate: terminate
            )
        )

        // `set -o pipefail` so a real upstream pipeline failure
        // surfaces as the rightmost non-zero exit rather than being
        // masked by `head` / `tee` / `cat`. The downstream
        // `set -o pipefail` only affects the shell that runs the
        // model's command, NOT the various built-in sandbox helpers
        // (which compose their own pipelines and call SandboxManager
        // directly without going through this entry point).
        let prefixedCommand = "set -o pipefail; \(command)"

        let result: ContainerExecResult
        do {
            result = try await SandboxToolCommandRunnerRegistry.shared.exec(
                user: "agent-\(agentName)",
                command: prefixedCommand,
                env: agentShellEnvironment(agentId: agentId, home: home, cwd: cwd),
                cwd: cwd,
                timeout: idleTimeout,
                streamToLogs: true,
                logSource: agentName,
                stdoutTee: sink,
                stderrTee: sink,
                onProcessStarted: { handle in
                    Task { await processBox.set(handle) }
                }
            )
        } catch {
            // Synthetic exit code surfaces the underlying error to live
            // subscribers (the chat row's status pill flips to "exited
            // (-1)") before we re-throw for the model.
            sink.markExited(code: -1)
            await LiveExecRegistry.shared.unregister(toolCallId: toolCallId)
            throw error
        }
        sink.markExited(code: result.exitCode)
        await LiveExecRegistry.shared.unregister(toolCallId: toolCallId)

        // Secrets ride into the exec env, so `echo $KEY` would exfiltrate
        // them into model context — scrub known values before anything
        // lands in the envelope.
        let secrets = agentSecretValues(agentId: agentId)
        let stdout = SecretScrubber.scrub(result.stdout, secrets: secrets)
        let stderr = SecretScrubber.scrub(result.stderr, secrets: secrets)

        var payload: [String: Any] = [
            "stdout": truncateForModel(stdout),
            "stderr": truncateForModel(stderr, maxChars: ToolOutputCaps.execStderr),
            "exit_code": Int(result.exitCode),
            "cwd": cwd,
        ]
        if sink.terminationReason == .user {
            payload["killed_by"] = "user"
        }
        let warnings = diagnosticWarnings(
            command: command,
            exitCode: result.exitCode,
            stdout: stdout,
            stderr: stderr
        )
        return sandboxSuccess(
            tool: name,
            result: payload,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }
}

/// Holds the `ProcessHandle` once the underlying foreground exec
/// process is up. Used so the LiveExecRegistry entry's `terminate`
/// closure (registered BEFORE the process exists) can later signal
/// the running process.
private actor ProcessHandleBox {
    private var handle: ProcessHandle?

    func set(_ handle: ProcessHandle) {
        self.handle = handle
    }

    /// SIGTERM → grace → SIGKILL. Idempotent against a process that's
    /// already exited (signal failures are swallowed by `try?`). The
    /// grace lets a well-behaved program flush stdout / clean up.
    func terminateWithGrace(graceSeconds: Int) async {
        guard let handle else { return }
        try? await handle.kill(15)
        if graceSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(graceSeconds) * 1_000_000_000)
        }
        try? await handle.kill(9)
    }
}

/// Register a `LiveExecRegistry.Entry` for a background sandbox job.
/// The output publisher is backed by a `LogFileTailer` reading the
/// host-side bind-mount of the agent's workspace; terminate maps to
/// `kill -<sig> <pid>` issued as root inside the container.
///
/// The entry's status moves to `.exited(0)` when `kill -0` reports the
/// process is gone — a detached task polls once a second and unwinds
/// when the pid dies. On `terminate`, we send SIGTERM, wait
/// `graceSeconds`, then SIGKILL via execAsRoot.
private func registerBackgroundLiveExec(
    toolCallId: String,
    pid: String,
    command: String,
    inContainerLogPath: String,
    agentName: String
) async {
    // /workspace/agents/<name>/bg-XXX.log → host bind-mount path.
    let prefix = OsaurusPaths.inContainerAgentHome(agentName) + "/"
    guard inContainerLogPath.hasPrefix(prefix) else { return }
    let relative = String(inContainerLogPath.dropFirst(prefix.count))
    let hostLogURL = OsaurusPaths.containerAgentDir(agentName)
        .appendingPathComponent(relative)

    let tailer = LogFileTailer(path: hostLogURL.path)
    tailer.start()

    let statusBox = StatusSubjectBox()
    let userTerminated = UserTerminatedFlag()

    // Poll the in-VM pid every second; flip to .exited when it's gone.
    // We hold the Task handle so the registry's `onDrop` can cancel it if
    // the entry is evicted while still polling (e.g. a long background job
    // whose row was torn down), and so the loop can't outlive the entry.
    let pollTask = Task.detached { @Sendable in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            let alive = await BackgroundExecLiveness.isPidAlive(pid: pid, agentName: agentName)
            if !alive {
                let killedByUser = await userTerminated.value
                statusBox.send(killedByUser ? .killed(reason: "user") : .exited(0))
                tailer.stop()
                // Pid is gone — release the registry entry (after its grace
                // tail) so it doesn't leak for the lifetime of the process.
                // The grace window keeps the terminal status observable for a
                // late-mounting UI row.
                await LiveExecRegistry.shared.unregister(toolCallId: toolCallId)
                return
            }
        }
    }

    let terminate: @Sendable (Int) async -> Void = { graceSeconds in
        await userTerminated.set(true)
        await BackgroundExecLiveness.kill(pid: pid, signal: "TERM")
        if graceSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(graceSeconds) * 1_000_000_000)
        }
        await BackgroundExecLiveness.kill(pid: pid, signal: "KILL")
    }

    await LiveExecRegistry.shared.register(
        LiveExecRegistry.Entry(
            toolCallId: toolCallId,
            pid: pid,
            command: command,
            startedAt: Date(),
            outputPublisher: tailer.publisher,
            statusPublisher: statusBox.publisher,
            currentStatus: { statusBox.current },
            seed: { tailer.snapshot() },
            terminate: terminate,
            onDrop: {
                pollTask.cancel()
                tailer.stop()
            }
        )
    )
}

private actor UserTerminatedFlag {
    private var _value = false
    var value: Bool { _value }
    func set(_ v: Bool) { _value = v }
}

/// Sendable wrapper around `CurrentValueSubject` for cross-task use.
/// `CurrentValueSubject` is thread-safe internally but doesn't have a
/// formal Sendable conformance; this thin wrapper closes the gap.
private final class StatusSubjectBox: @unchecked Sendable {
    private let subject = CurrentValueSubject<LiveExecRegistry.LiveExecStatus, Never>(.running)

    var publisher: AnyPublisher<LiveExecRegistry.LiveExecStatus, Never> {
        subject.eraseToAnyPublisher()
    }

    var current: LiveExecRegistry.LiveExecStatus { subject.value }

    func send(_ status: LiveExecRegistry.LiveExecStatus) {
        subject.send(status)
    }
}

/// Container-side process lifecycle helpers for background jobs. Keep
/// the in-VM `kill` invocations in one place so the polling watcher,
/// `sandbox_process`, and the user-terminate path can't drift in their
/// command shape.
///
/// Liveness must be zombie-aware: the background wrapper is reparented
/// to the container's init when its launching shell exits, and if it
/// dies before being reaped it lingers as a zombie. `kill -0` succeeds
/// on zombies, so a bare probe reports a killed job as alive forever —
/// the exact loop frontier models got stuck in during sandbox evals.
internal enum BackgroundExecLiveness {
    /// Shell snippet that exits 0 iff `pid` exists and is NOT a zombie.
    static func aliveCondition(pid: String) -> String {
        "kill -0 \(pid) 2>/dev/null && ! grep -q '^State:[[:space:]]*Z' /proc/\(pid)/status 2>/dev/null"
    }

    static func isPidAlive(pid: String, agentName: String) async -> Bool {
        guard
            let result = try? await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
                agentName,
                command: "{ \(aliveCondition(pid: pid)); } && echo a || echo d"
            )
        else { return false }
        return result.stdout.contains("a")
    }

    /// Signal the job's whole process group (the launch wraps jobs in
    /// `setsid`, making the wrapper a group leader) so children — the
    /// actual workload — die with it. Falls back to the bare pid for
    /// jobs that predate the `setsid` launch shape. Fire-and-forget:
    /// `|| true` so an already-exited process doesn't surface as a
    /// runner error.
    static func killCommand(pid: String, signal: String) -> String {
        "kill -\(signal) -- -\(pid) 2>/dev/null || kill -\(signal) \(pid) 2>/dev/null || true"
    }

    /// Used to signal background jobs when the user presses [Terminate].
    static func kill(pid: String, signal: String) async {
        _ = try? await SandboxToolCommandRunnerRegistry.shared.execAsRoot(
            command: killCommand(pid: pid, signal: signal),
            timeout: 5
        )
    }
}

// MARK: - sandbox_process
//
// Manage background jobs spawned via `sandbox_exec(background:true)`.
// `poll` returns whether the process is still alive plus a tail of the
// log; `wait` blocks until exit (capped at the supplied timeout); `kill`
// sends SIGTERM (and SIGKILL on `force:true`).

private struct SandboxProcessTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_process"
    let description =
        "Manage background jobs started by `sandbox_exec(background:true)`. `action=\"poll\"` "
        + "returns whether the pid is still alive plus a tail of the log; `\"wait\"` blocks "
        + "until exit (or `timeout` seconds); `\"kill\"` sends SIGTERM (`force:true` for SIGKILL). "
        + "Pass the `pid` returned by the launching `sandbox_exec` call."
    let agentId: String
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "enum": .array([.string("poll"), .string("wait"), .string("kill")]),
                    "description": .string("`poll`, `wait`, or `kill`."),
                ]),
                "pid": .object([
                    "type": .string("string"),
                    "description": .string("Process id returned by `sandbox_exec(background:true)`."),
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string("Seconds to block on `wait` (default 60, max 300)."),
                    "default": .number(60),
                ]),
                "tail_lines": .object([
                    "type": .string("integer"),
                    "description": .string("Lines of the job log to include in the result (default 40, max 200)."),
                    "default": .number(40),
                ]),
                "force": .object([
                    "type": .string("boolean"),
                    "description": .string("Send SIGKILL instead of SIGTERM on `kill`."),
                    "default": .bool(false),
                ]),
            ]),
            "required": .array([.string("action"), .string("pid")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let actionReq = requireString(
            args,
            "action",
            expected: "one of `poll`, `wait`, `kill`",
            tool: name
        )
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        let pidReq = requireString(
            args,
            "pid",
            expected: "process id returned by `sandbox_exec(background:true)`",
            tool: name
        )
        guard case .value(let pid) = pidReq else { return pidReq.failureEnvelope ?? "" }

        // Reject non-numeric pids early — agents have been observed passing
        // job names ("server") or descriptions when a numeric pid was wanted.
        guard Int(pid) != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`pid` must be the numeric pid string returned by `sandbox_exec(background:true)`. Got `\(pid)`.",
                field: "pid",
                expected: "numeric pid string",
                tool: name
            )
        }

        let job = await SandboxBackgroundJobs.shared.lookup(agentName: agentName, pid: pid)
        let tailLines = min(max(coerceInt(args["tail_lines"]) ?? 40, 0), 200)

        switch action {
        case "poll":
            let aliveResult = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
                agentName,
                command:
                    "{ \(BackgroundExecLiveness.aliveCondition(pid: pid)); } && echo alive || echo dead"
            )
            let alive = aliveResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "alive"
            let tail = await tailIfTracked(job: job, lines: tailLines)
            if !alive {
                await SandboxBackgroundJobs.shared.unregister(agentName: agentName, pid: pid)
            }
            return sandboxSuccess(
                tool: name,
                result: [
                    "pid": pid,
                    "alive": alive,
                    "log_file": job?.logFile ?? "",
                    "log_tail": tail,
                ]
            )

        case "wait":
            let timeoutSec = min(max(coerceInt(args["timeout"]) ?? 60, 1), 300)
            // Tight poll loop inside the container — cheaper than rebuilding
            // an ssh round-trip every second.
            let cmd =
                "for i in $(seq 1 \(timeoutSec)); do "
                + "{ \(BackgroundExecLiveness.aliveCondition(pid: pid)); } || { echo exited; exit 0; }; "
                + "sleep 1; "
                + "done; echo timeout"
            let waitResult = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
                agentName,
                command: cmd,
                pluginName: nil,
                env: agentShellEnvironment(agentId: agentId, home: home),
                timeout: TimeInterval(timeoutSec + 5)
            )
            let exited = waitResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "exited"
            let tail = await tailIfTracked(job: job, lines: tailLines)
            if exited {
                await SandboxBackgroundJobs.shared.unregister(agentName: agentName, pid: pid)
            }
            return sandboxSuccess(
                tool: name,
                result: [
                    "pid": pid,
                    "exited": exited,
                    "timed_out": !exited,
                    "log_file": job?.logFile ?? "",
                    "log_tail": tail,
                ]
            )

        case "kill":
            let force = coerceBool(args["force"]) ?? false
            let signal = force ? "9" : "15"
            let killResult = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
                agentName,
                command: "\(BackgroundExecLiveness.killCommand(pid: pid, signal: signal)); sleep 0.2; "
                    + "{ \(BackgroundExecLiveness.aliveCondition(pid: pid)); } && echo alive || echo dead"
            )
            let dead = killResult.stdout.contains("dead")
            if dead {
                await SandboxBackgroundJobs.shared.unregister(agentName: agentName, pid: pid)
            }
            return sandboxSuccess(
                tool: name,
                result: [
                    "pid": pid,
                    "killed": dead,
                    "signal": force ? "SIGKILL" : "SIGTERM",
                ]
            )

        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unsupported `action`: `\(action)`. Use `poll`, `wait`, or `kill`.",
                field: "action",
                expected: "one of `poll`, `wait`, `kill`",
                tool: name
            )
        }
    }

    /// Read up to `lines` from the job's log file. Returns `""` when
    /// either we don't have a tracked job (host restarted between the
    /// launch and this poll, or `pid` was never registered) or the
    /// caller asked for zero lines. Errors are swallowed — a missing
    /// log file is not worth bubbling up to the model.
    private func tailIfTracked(
        job: SandboxBackgroundJobs.Job?,
        lines: Int
    ) async -> String {
        guard let job, lines > 0 else { return "" }
        let result = try? await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: "tail -n \(lines) '\(job.logFile)' 2>/dev/null"
        )
        // Background jobs run with the same secret-bearing env as
        // foreground execs, so their logs need the same scrubbing.
        return SecretScrubber.scrub(
            result?.stdout ?? "",
            secrets: agentSecretValues(agentId: agentId)
        )
    }
}

/// Tracks pid → log-file mappings for background jobs spawned by
/// `sandbox_exec(background:true)`, keyed by agent name. Pure in-memory;
/// agents that lose this mapping (e.g. across an app restart) can still
/// poll using the log path the launching call returned. Cleared
/// automatically when `sandbox_process` confirms a job has exited.
actor SandboxBackgroundJobs {
    static let shared = SandboxBackgroundJobs()

    struct Job: Sendable {
        let pid: String
        let logFile: String
        let command: String
        let startedAt: Date
    }

    private var jobs: [String: [String: Job]] = [:]  // agentName -> pid -> Job

    func register(agentName: String, pid: String, logFile: String, command: String) {
        var perAgent = jobs[agentName] ?? [:]
        perAgent[pid] = Job(pid: pid, logFile: logFile, command: command, startedAt: Date())
        jobs[agentName] = perAgent
    }

    func lookup(agentName: String, pid: String) -> Job? {
        jobs[agentName]?[pid]
    }

    func unregister(agentName: String, pid: String) {
        jobs[agentName]?.removeValue(forKey: pid)
        if jobs[agentName]?.isEmpty == true {
            jobs.removeValue(forKey: agentName)
        }
    }

    func clear(agentName: String) {
        jobs.removeValue(forKey: agentName)
    }
}

/// Per-agent serialization for install operations (`sandbox_npm_install`,
/// `sandbox_pip_install`, `sandbox_install`). Two concurrent installs on
/// the same agent collide on the same `node_modules/` / venv / apk db,
/// which is exactly the kind of race that produces npm's "Tracker
/// idealTree already exists" error. This actor queues each new call
/// behind the previous one for the same `agentName`; calls on different
/// agents still run concurrently.
///
/// `apk` is global to the container, so all sandbox_install calls share
/// the synthetic key `__sandbox_apk__`.
actor SandboxInstallLock {
    static let shared = SandboxInstallLock()

    /// Synthetic agent key for `sandbox_install` (apk). All apk calls
    /// across every agent serialize through this same slot.
    static let apkSerializationKey = "__sandbox_apk__"

    /// The tail of each agent's queue. New callers chain themselves
    /// after this Task and replace it as the new tail before running.
    private var tail: [String: Task<Void, Never>] = [:]

    /// Run `body` such that any other `serialize(agentName:)` call with
    /// the same key has finished first. Concurrent calls on different
    /// keys do not block each other.
    ///
    /// The new task waits on `tail[agentName]` (if any) before running
    /// `body`, then publishes a Void-shaped view of itself as the new
    /// tail — that's how heterogeneous `T`'s compose into a single
    /// `Task<Void, Never>` queue. Errors and successes both release the
    /// lock so a thrown body can't wedge subsequent callers.
    func serialize<T: Sendable>(
        agentName: String,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let previous = tail[agentName]
        let task = Task<T, Error> {
            await previous?.value
            return try await body()
        }
        tail[agentName] = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Drop the queue tail for `agentName` so a re-provisioned agent
    /// starts with a clean slate. Mirrors `SandboxBackgroundJobs.clear`
    /// — called from `SandboxAgentProvisioner.unprovision` so the
    /// in-memory map can't grow unbounded across long-lived sessions.
    /// Calling on an unknown key is a no-op.
    func clear(agentName: String) {
        tail.removeValue(forKey: agentName)
    }
}

// MARK: - sandbox_install

/// Single install entry point. One tool, one `manager` switch — replaces
/// the former `sandbox_install` / `sandbox_pip_install` / `sandbox_npm_install`
/// trio so the model has one obvious dependency tool instead of three
/// near-identical ones to disambiguate. Each manager keeps its original
/// command body, exec context (root for apk, agent for pip/npm), recovery
/// signatures, and serialization key — the consolidation is purely at the
/// dispatch layer.
private struct SandboxInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_install"
    let description =
        "Install packages into the sandbox. Pass `manager`: `apk` for system packages "
        + "(runs as root, e.g. `ffmpeg`), `pip` for Python packages (into the agent venv at "
        + "`~/.venv/`), or `npm` for Node packages (into a per-agent workspace). "
        + "**Use this instead of `sandbox_exec(\"apk add …\" / \"pip install …\" / \"npm install …\")`** "
        + "so the index refresh, venv/workspace bootstrap, retry harness, and per-agent "
        + "serialization apply. Installed `python3`/CLI binaries land on your PATH — call them "
        + "from any `sandbox_exec` cwd. Example: `{\"manager\": \"pip\", \"packages\": [\"numpy\", \"flask\"]}`."
    let agentId: String
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "manager": .object([
                    "type": .string("string"),
                    "enum": .array([.string("apk"), .string("pip"), .string("npm")]),
                    "description": .string(
                        "Package manager: `apk` (system, root-wide), `pip` (Python venv), `npm` (Node workspace)."
                    ),
                ]),
                "packages": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Package names, e.g. `[\"ffmpeg\"]` (apk), `[\"numpy\"]` (pip), `[\"express\"]` (npm)."
                    ),
                ]),
            ]),
            "required": .array([.string("manager"), .string("packages")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let managerReq = requireString(
            args,
            "manager",
            expected: "one of `apk`, `pip`, `npm`",
            tool: name
        )
        guard case .value(let managerRaw) = managerReq else { return managerReq.failureEnvelope ?? "" }

        let pkgsReq = requireStringArray(
            args,
            "packages",
            expected: "non-empty array of package names",
            tool: name
        )
        guard case .value(let packages) = pkgsReq else { return pkgsReq.failureEnvelope ?? "" }

        switch managerRaw.lowercased() {
        case "apk":
            return try await installApk(packages: packages)
        case "pip":
            return try await installPip(packages: packages)
        case "npm":
            return try await installNpm(packages: packages)
        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unknown `manager` \"\(managerRaw)\". Use one of `apk`, `pip`, `npm`.",
                tool: name,
                retryable: false
            )
        }
    }

    // MARK: apk (system, root-wide)

    private func installApk(packages: [String]) async throws -> String {
        let pkgList = packages.joined(separator: " ")
        // `apk update` first refreshes the package index — cheap when the
        // cache is fresh, and eliminates "no such package" errors caused
        // by a stale index. `|| true` so a transient network blip on the
        // index refresh doesn't poison the install. Recovery harness
        // catches the rest.
        let installCmd = "apk update --quiet || true; apk add --no-cache \(pkgList)"

        let toolName = self.name
        let id = agentId
        // apk is global to the container — every agent's install hits
        // the same package database and apk's own lockfile. Serialize
        // through a single synthetic key so cross-agent calls don't
        // race each other.
        return try await SandboxInstallLock.shared.serialize(
            agentName: SandboxInstallLock.apkSerializationKey
        ) {
            @Sendable func runAsRoot(_ cmd: String, timeout: TimeInterval) async throws
                -> ContainerExecResult
            {
                try await SandboxToolCommandRunnerRegistry.shared.execAsRoot(
                    command: cmd,
                    timeout: timeout,
                    streamToLogs: true,
                    logSource: "apk"
                )
            }

            return try await runInstallWithRecovery(
                tool: toolName,
                packages: packages,
                attempt: { try await runAsRoot(installCmd, timeout: 120) },
                isRecoverable: { result in
                    InstallRecoverableErrors.contains(result, anyOf: InstallRecoverableErrors.apk)
                },
                cleanup: {
                    // Force-refresh the index — the most common apk recovery
                    // signal is a stale cache or transient lock.
                    _ = try await runAsRoot("apk update", timeout: 60)
                },
                onSuccess: { installed in
                    SandboxPackageManifest.shared.record(
                        agentId: id,
                        manager: .apk,
                        packages: installed
                    )
                }
            )
        }
    }

    // MARK: pip (Python venv)

    private func installPip(packages: [String]) async throws -> String {
        let venvPath = agentVenvPath(home: home)
        let checkResult = try await SandboxToolCommandRunnerRegistry.shared.execAsRoot(
            command: "test -x /usr/bin/python3",
            timeout: 10
        )
        guard checkResult.succeeded else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "python3 is not installed in the sandbox image",
                tool: name,
                retryable: false
            )
        }

        let pkgList = packages.joined(separator: " ")
        // `--disable-pip-version-check` cuts a stdout warning that
        // confuses small models; `--no-input` prevents pip from blocking
        // on a credential prompt for private indexes.
        let installCmd =
            "test -x '\(venvPath)/bin/python3'"
            + " || /usr/bin/python3 -m venv '\(venvPath)'"
            + " && '\(venvPath)/bin/python3' -m pip install"
            + " --disable-pip-version-check --no-input \(pkgList)"

        // Local snapshots so the @Sendable closures don't capture `self`.
        let id = agentId, name = self.name, agent = agentName, root = home
        return try await SandboxInstallLock.shared.serialize(agentName: agentName) {
            @Sendable func runAsAgent(_ cmd: String, timeout: TimeInterval) async throws
                -> ContainerExecResult
            {
                try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
                    agent,
                    command: cmd,
                    env: agentShellEnvironment(agentId: id, home: root),
                    timeout: timeout,
                    streamToLogs: true,
                    logSource: "pip"
                )
            }

            return try await runInstallWithRecovery(
                tool: name,
                packages: packages,
                // 240s covers cold-cache installs of large packages (torch,
                // pandas, transformers) that routinely cross 60s on first install.
                attempt: { try await runAsAgent(installCmd, timeout: 240) },
                isRecoverable: { result in
                    InstallRecoverableErrors.contains(result, anyOf: InstallRecoverableErrors.pip)
                },
                cleanup: {
                    // Guard the purge on the venv actually existing — a
                    // first-attempt failure that died before `python3 -m venv`
                    // finished would leave us with no `pip` binary to invoke.
                    // The `[ -x ]` test makes the cleanup a no-op in that
                    // case so the retry can re-create the venv from scratch.
                    let cleanupCmd =
                        "[ -x '\(venvPath)/bin/pip' ]"
                        + " && '\(venvPath)/bin/pip' cache purge >/dev/null 2>&1"
                        + " || true"
                    _ = try await runAsAgent(cleanupCmd, timeout: 30)
                },
                onSuccess: { installed in
                    SandboxPackageManifest.shared.record(
                        agentId: id,
                        manager: .pip,
                        packages: installed
                    )
                }
            )
        }
    }

    // MARK: npm (Node workspace)

    private func installNpm(packages: [String]) async throws -> String {
        let checkResult = try await SandboxToolCommandRunnerRegistry.shared.execAsRoot(
            command: "test -x /usr/bin/node && test -x /usr/bin/npm",
            timeout: 10
        )
        guard checkResult.succeeded else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "node/npm is not installed in the sandbox image",
                tool: name,
                retryable: false
            )
        }

        let nodeWorkdir = agentNodeWorkdir(home: home)
        let pkgList = packages.joined(separator: " ")
        // Bootstrap an isolated npm workspace under our namespace and
        // ensure a `package.json` exists before running install. The
        // `[ -f package.json ] || npm init -y` step is idempotent — once
        // a manifest exists it short-circuits — and gives npm a stable
        // anchor so `npm install <pkg>` doesn't synth a new manifest on
        // every call (which is what produced the "Tracker idealTree
        // already exists" error when a previous synth was interrupted).
        // `--no-audit --no-fund --no-update-notifier` keeps the install
        // narrow on network use and stdout noise.
        let installCmd =
            "mkdir -p '\(nodeWorkdir)'"
            + " && cd '\(nodeWorkdir)'"
            + " && [ -f package.json ] || npm init -y --silent"
            + " && npm install --no-audit --no-fund --no-update-notifier \(pkgList)"

        // Local snapshots so the @Sendable closures don't capture `self`.
        let id = agentId, name = self.name, agent = agentName, root = home

        // `cwd: nil` is deliberate — `SandboxManager.exec` prepends
        // `cd '<cwd>' && …` when its `cwd` arg is non-nil, which would
        // run before our own `mkdir -p` and fail on a first-install
        // case. The command itself owns its `mkdir -p && cd` sequence.
        // (Pinned by `sandboxNpmInstall_bootstrapsPackageJsonAndUsesWorkdir`.)
        return try await SandboxInstallLock.shared.serialize(agentName: agentName) {
            @Sendable func runAsAgent(_ cmd: String, timeout: TimeInterval) async throws
                -> ContainerExecResult
            {
                try await SandboxToolCommandRunnerRegistry.shared.exec(
                    user: "agent-\(agent)",
                    command: cmd,
                    env: agentShellEnvironment(agentId: id, home: root, cwd: nodeWorkdir),
                    cwd: nil,
                    timeout: timeout,
                    streamToLogs: true,
                    logSource: "npm"
                )
            }

            return try await runInstallWithRecovery(
                tool: name,
                packages: packages,
                attempt: { try await runAsAgent(installCmd, timeout: 240) },
                isRecoverable: { result in
                    InstallRecoverableErrors.contains(result, anyOf: InstallRecoverableErrors.npm)
                },
                cleanup: {
                    // Drop the half-written lockfile + clear the npm cache.
                    // `mkdir -p` first so a first-attempt failure that died
                    // before `mkdir` succeeded doesn't trip up `cd`.
                    let cleanupCmd =
                        "mkdir -p '\(nodeWorkdir)'"
                        + " && cd '\(nodeWorkdir)'"
                        + " && rm -rf node_modules/.package-lock.json .package-lock.json"
                        + " && npm cache clean --force >/dev/null 2>&1 || true"
                    _ = try await runAsAgent(cleanupCmd, timeout: 60)
                },
                onSuccess: { installed in
                    SandboxPackageManifest.shared.record(
                        agentId: id,
                        manager: .npm,
                        packages: installed
                    )
                }
            )
        }
    }
}
