//
//  BuiltinSandboxTools.swift
//  osaurus
//
//  Built-in sandbox tools that give agents filesystem, shell, and
//  package management access inside the shared Linux container.
//  All paths are validated on the host side before any container exec.
//

import Foundation

// MARK: - Registration

enum BuiltinSandboxTools {
    /// Register sandbox tools for the given agent into the ToolRegistry.
    /// Respects autonomous_exec config to gate write/exec tools.
    @MainActor
    static func register(agentId: String, agentName: String, config: AutonomousExecConfig?) {
        let registry = ToolRegistry.shared
        let home = OsaurusPaths.inContainerAgentHome(agentName)

        // Always available (read-only)
        registry.registerSandboxTool(
            SandboxReadFileTool(agentName: agentName, home: home),
            runtimeManaged: true
        )
        registry.registerSandboxTool(
            SandboxListDirectoryTool(agentName: agentName, home: home),
            runtimeManaged: true
        )
        registry.registerSandboxTool(
            SandboxSearchFilesTool(agentName: agentName, home: home),
            runtimeManaged: true
        )
        registry.registerSandboxTool(
            SandboxFindFilesTool(agentName: agentName, home: home),
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
            SandboxEditFileTool(agentName: agentName, home: home),
            runtimeManaged: true
        )
        registry.registerSandboxTool(SandboxMoveTool(agentName: agentName, home: home), runtimeManaged: true)
        registry.registerSandboxTool(
            SandboxDeleteTool(agentName: agentName, home: home),
            runtimeManaged: true
        )
        registry.registerSandboxTool(
            SandboxExecTool(
                agentId: agentId,
                agentName: agentName,
                home: home,
                maxTimeout: config.commandTimeout,
                maxCommandsPerTurn: maxCmdsPerTurn
            ),
            runtimeManaged: true
        )
        registry.registerSandboxTool(
            SandboxExecBackgroundTool(
                agentId: agentId,
                agentName: agentName,
                home: home,
                maxCommandsPerTurn: maxCmdsPerTurn
            ),
            runtimeManaged: true
        )
        registry.registerSandboxTool(SandboxInstallTool(agentName: agentName), runtimeManaged: true)
        registry.registerSandboxTool(
            SandboxPipInstallTool(agentId: agentId, agentName: agentName, home: home),
            runtimeManaged: true
        )
        registry.registerSandboxTool(
            SandboxNpmInstallTool(agentId: agentId, agentName: agentName, home: home),
            runtimeManaged: true
        )
        registry.registerSandboxTool(
            SandboxRunScriptTool(
                agentId: agentId,
                agentName: agentName,
                home: home,
                maxTimeout: config.commandTimeout,
                maxCommandsPerTurn: maxCmdsPerTurn
            ),
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
    static func registerInitPending() {
        ToolRegistry.shared.registerSandboxTool(
            SandboxInitPendingTool(),
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
/// isn't running yet. Always returns the same "still initialising" envelope.
/// Designed to keep the model's schema non-empty (so it has *something*
/// to call) while the container provisions in the background.
private struct SandboxInitPendingTool: OsaurusTool, @unchecked Sendable {
    let name = BuiltinSandboxTools.initPendingToolName
    let description =
        "Sandbox is starting in the background. Call this tool to confirm it isn't ready, "
        + "then either reply without sandbox tools or tell the user to wait. The real "
        + "sandbox tools (file ops, shell) appear in your schema once the container boots — "
        + "do NOT invent or guess sandbox tool names in the meantime."

    var parameters: JSONValue? {
        .object(["type": .string("object"), "properties": .object([:])])
    }

    func execute(argumentsJSON: String) async throws -> String {
        ToolErrorEnvelope(
            kind: .unavailable,
            reason:
                "Sandbox is still initializing. Real sandbox tools will register on "
                + "the next turn. Reply without sandbox tools, or wait and try again.",
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
        return .failure(
            ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `\(field)` rejected: \(rejection.reason). Got `\(path)`.",
                field: field,
                expected: "path under the agent home (relative or absolute under `\(home)`)",
                tool: tool
            )
        )
    }
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

private let sandboxDefaultPATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

private func agentVenvPath(home: String) -> String {
    "\(home)/.venv"
}

private func agentShellEnvironment(agentId: String, home: String, cwd: String? = nil) -> [String: String] {
    var env: [String: String] = [:]
    if let uuid = UUID(uuidString: agentId) {
        env = AgentSecretsKeychain.getFilteredSecrets(agentId: uuid)
    }
    let venvPath = agentVenvPath(home: home)
    var pathEntries: [String] = []
    if let cwd, !cwd.isEmpty {
        pathEntries.append("\(cwd)/node_modules/.bin")
    }
    pathEntries.append("\(venvPath)/bin")
    pathEntries.append(sandboxDefaultPATH)
    env["VIRTUAL_ENV"] = venvPath
    env["PATH"] = pathEntries.joined(separator: ":")
    return env
}

private func jsonResult(_ dict: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
        let json = String(data: data, encoding: .utf8)
    else { return "{}" }
    return json
}

/// Cap a stream's worth of text before it lands in the model's context.
/// Uses a head + tail strategy: keep the first 40% of the budget and the
/// last 60%, with a marker in the middle so the model knows truncation
/// happened. Tail bias matters because the final lines of a process
/// (errors, summary prints) are usually the most important.
///
/// Default budget is 50_000 chars (~12.5K tokens). When the input fits
/// under the budget the text is returned untouched.
private func truncateForModel(_ text: String, maxChars: Int = 50_000) -> String {
    if text.count <= maxChars { return text }
    let headChars = Int(Double(maxChars) * 0.4)
    let tailChars = maxChars - headChars
    let head = String(text.prefix(headChars))
    let tail = String(text.suffix(tailChars))
    let omitted = text.count - headChars - tailChars
    return
        head
        + "\n\n... [output truncated — \(omitted) chars omitted out of \(text.count) total] ...\n\n"
        + tail
}

protocol SandboxToolCommandRunning: Sendable {
    func exec(
        user: String?,
        command: String,
        env: [String: String],
        cwd: String?,
        timeout: TimeInterval,
        streamToLogs: Bool,
        logSource: String?
    ) async throws -> ContainerExecResult

    func execAsRoot(
        command: String,
        timeout: TimeInterval,
        streamToLogs: Bool,
        logSource: String?
    ) async throws -> ContainerExecResult

    func execAsAgent(
        _ agentName: String,
        command: String,
        pluginName: String?,
        env: [String: String],
        timeout: TimeInterval,
        streamToLogs: Bool,
        logSource: String?
    ) async throws -> ContainerExecResult
}

private struct LiveSandboxToolCommandRunner: SandboxToolCommandRunning {
    func exec(
        user: String?,
        command: String,
        env: [String: String] = [:],
        cwd: String? = nil,
        timeout: TimeInterval = 30,
        streamToLogs: Bool = false,
        logSource: String? = nil
    ) async throws -> ContainerExecResult {
        try await SandboxManager.shared.exec(
            user: user,
            command: command,
            env: env,
            cwd: cwd,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource
        )
    }

    func execAsRoot(
        command: String,
        timeout: TimeInterval = 60,
        streamToLogs: Bool = false,
        logSource: String? = nil
    ) async throws -> ContainerExecResult {
        try await SandboxManager.shared.execAsRoot(
            command: command,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource
        )
    }

    func execAsAgent(
        _ agentName: String,
        command: String,
        pluginName: String? = nil,
        env: [String: String] = [:],
        timeout: TimeInterval = 30,
        streamToLogs: Bool = false,
        logSource: String? = nil
    ) async throws -> ContainerExecResult {
        try await SandboxManager.shared.execAsAgent(
            agentName,
            command: command,
            pluginName: pluginName,
            env: env,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource
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
        timeout: TimeInterval = 30,
        streamToLogs: Bool = false,
        logSource: String? = nil
    ) async throws -> ContainerExecResult {
        try await runner.exec(
            user: user,
            command: command,
            env: env,
            cwd: cwd,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource
        )
    }

    func execAsRoot(
        command: String,
        timeout: TimeInterval = 60,
        streamToLogs: Bool = false,
        logSource: String? = nil
    ) async throws -> ContainerExecResult {
        try await runner.execAsRoot(
            command: command,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource
        )
    }

    func execAsAgent(
        _ agentName: String,
        command: String,
        pluginName: String? = nil,
        env: [String: String] = [:],
        timeout: TimeInterval = 30,
        streamToLogs: Bool = false,
        logSource: String? = nil
    ) async throws -> ContainerExecResult {
        try await runner.execAsAgent(
            agentName,
            command: command,
            pluginName: pluginName,
            env: env,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource
        )
    }
}

/// Build the standard envelope for an install-style tool. Success and
/// failure both carry the requested package list and the truncated combined
/// output — only the envelope kind differs so the model can branch cleanly.
private func installResultEnvelope(
    tool: String,
    packages: [String],
    result: ContainerExecResult
) -> String {
    let combined = truncateForModel(result.stdout + result.stderr, maxChars: 20_000)
    if result.succeeded {
        return ToolEnvelope.success(
            tool: tool,
            result: [
                "installed": packages,
                "exit_code": Int(result.exitCode),
                "output": combined,
            ]
        )
    }
    return ToolEnvelope.failure(
        kind: .executionError,
        message:
            "Install failed (exit \(result.exitCode)). Combined output: "
            + combined.trimmingCharacters(in: .whitespacesAndNewlines),
        tool: tool,
        retryable: true
    )
}

// MARK: - sandbox_read_file

private struct SandboxReadFileTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_read_file"
    let description =
        "Read a file's contents from the sandbox. Supports line ranges (`start_line` + `line_count`), "
        + "log-style tails (`tail_lines`), and a per-call character cap (`max_chars`). "
        + "Pass either a path under the agent home (e.g. `notes.txt`) or an absolute path inside "
        + "the sandbox (e.g. `/workspace/shared/data.csv`). Surfaces stderr on failure."
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
                    "description": .string("Cap returned characters after line selection"),
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
        let maxChars = max(coerceInt(args["max_chars"]) ?? 0, 0)

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
            return sandboxExecutionFailure(
                tool: name,
                message: "Failed to read `\(resolved)`: \(detail)",
                retryable: false
            )
        }
        var payload: [String: Any] = [
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
        return sandboxSuccess(tool: name, result: payload)
    }
}

// MARK: - sandbox_list_directory

private struct SandboxListDirectoryTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_list_directory"
    let description =
        "List files and directories in the sandbox. Default lists agent home with `ls -la`. "
        + "Pass `recursive: true` for a `tree -L 3` overview (capped at 200 lines)."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Directory path (default: agent home)"),
                    "default": .string("."),
                ]),
                "recursive": .object([
                    "type": .string("boolean"),
                    "description": .string("Include subdirectories"),
                    "default": .bool(false),
                ]),
            ]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        // No required args — `path` defaults to ".".
        let args = parseArguments(argumentsJSON) ?? [:]
        let path = args["path"] as? String ?? "."
        let recursive = coerceBool(args["recursive"]) ?? false

        let resolvedReq = requirePath(path, home: home, tool: name)
        guard case .value(let resolved) = resolvedReq else {
            return resolvedReq.failureEnvelope ?? ""
        }

        let cmd =
            recursive
            ? "tree -L 3 --dirsfirst '\(resolved)' 2>/dev/null | head -200"
            : "ls -la '\(resolved)' 2>/dev/null"

        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: cmd
        )
        return sandboxSuccess(
            tool: name,
            result: ["path": resolved, "entries": result.stdout]
        )
    }
}

// MARK: - sandbox_search_files

private struct SandboxSearchFilesTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_search_files"
    let description =
        "Search file contents with ripgrep. Returns matching lines with file paths and line numbers. "
        + "Searches inside file bodies — for filename matches use `sandbox_find_files`. "
        + "`pattern` is a regex; cap output with `max_results` (default 100, max 500)."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string("Regex pattern to search for, e.g. `TODO|FIXME`."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Directory to search (default: agent home)"),
                    "default": .string("."),
                ]),
                "include": .object([
                    "type": .string("string"),
                    "description": .string("File glob filter (e.g. `*.py`)"),
                ]),
                "context_lines": .object([
                    "type": .string("integer"),
                    "description": .string("Lines of context before/after each match (max 10)."),
                ]),
                "case_insensitive": .object([
                    "type": .string("boolean"),
                    "description": .string("Enable case-insensitive search"),
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

        let patternReq = requireString(
            args,
            "pattern",
            expected: "ripgrep regex (e.g. `TODO|FIXME`)",
            tool: name
        )
        guard case .value(let pattern) = patternReq else { return patternReq.failureEnvelope ?? "" }

        let path = args["path"] as? String ?? "."
        let resolvedReq = requirePath(path, home: home, tool: name)
        guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }

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
        let maxResults = coerceInt(args["max_results"]) ?? 100
        let cappedMax = max(1, min(maxResults, 500))
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
        return sandboxSuccess(
            tool: name,
            result: ["pattern": pattern, "path": resolved, "matches": result.stdout]
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

// MARK: - sandbox_find_files

private struct SandboxFindFilesTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_find_files"
    let description =
        "Find files by name pattern. Use a glob like `*.py`, `test_*`, `*.ts`. Matches file names only "
        + "— for content search use `sandbox_search_files`. Output capped at 200 lines."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string("File name glob pattern (e.g. `*.py`, `test_*`, `*.ts`)."),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Directory to search (default: agent home)"),
                    "default": .string("."),
                ]),
            ]),
            "required": .array([.string("pattern")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let patternReq = requireString(
            args,
            "pattern",
            expected: "filename glob (e.g. `*.py`, `test_*`, `*.ts`)",
            tool: name
        )
        guard case .value(let pattern) = patternReq else { return patternReq.failureEnvelope ?? "" }

        let path = args["path"] as? String ?? "."
        let resolvedReq = requirePath(path, home: home, tool: name)
        guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }

        let escapedPattern = shellEscapeSingleQuoted(pattern)
        let cmd =
            "find '\(resolved)' -type f -name '\(escapedPattern)' 2>/dev/null | head -200"

        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: cmd
        )
        return sandboxSuccess(
            tool: name,
            result: ["pattern": pattern, "path": resolved, "files": result.stdout]
        )
    }
}

// MARK: - sandbox_write_file

private struct SandboxWriteFileTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_write_file"
    let description =
        "Write `content` to `path` in the sandbox, replacing any existing file. Creates parent "
        + "directories as needed. Both arguments are required — passing only `path` returns an "
        + "`invalid_args` failure pointing at the missing field."
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
                        "File contents (string). Pass `\"\"` for an empty file. Binary / NUL bytes are not safe — they ride a `printf` shell pipeline."
                    ),
                ]),
            ]),
            "required": .array([.string("path"), .string("content")]),
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

        // Empty content is legitimate (truncate-to-zero), so allow it.
        let contentReq = requireString(
            args,
            "content",
            expected: "string of file contents (use `\"\"` for an empty file)",
            tool: name,
            allowEmpty: true
        )
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }

        let resolvedReq = requirePath(path, home: home, tool: name)
        guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }

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
            result: ["path": resolved, "size": content.count]
        )
    }
}

// MARK: - sandbox_edit_file

private struct SandboxEditFileTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_edit_file"
    let description =
        "Edit a file by replacing an exact string match. `old_string` must uniquely match one location "
        + "— include surrounding context lines if needed. Fails if `old_string` is not found or "
        + "matches multiple locations. Prefer this over `sandbox_write_file` for targeted in-place edits."
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
                "old_string": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Exact text to find and replace (must match exactly one location in the file)."
                    ),
                ]),
                "new_string": .object([
                    "type": .string("string"),
                    "description": .string("Replacement text. Use `\"\"` to delete the match."),
                ]),
            ]),
            "required": .array([.string("path"), .string("old_string"), .string("new_string")]),
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

        let oldReq = requireString(
            args,
            "old_string",
            expected: "non-empty exact text that uniquely matches one location in the file",
            tool: name
        )
        guard case .value(let oldString) = oldReq else { return oldReq.failureEnvelope ?? "" }

        // Allow empty new_string (used to delete the matched text).
        let newReq = requireString(
            args,
            "new_string",
            expected: "replacement text (use `\"\"` to delete the match)",
            tool: name,
            allowEmpty: true
        )
        guard case .value(let newString) = newReq else { return newReq.failureEnvelope ?? "" }

        let resolvedReq = requirePath(path, home: home, tool: name)
        guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }

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

        return sandboxSuccess(
            tool: name,
            result: [
                "path": resolved,
                "summary": result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        )
    }
}

// MARK: - sandbox_move

private struct SandboxMoveTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_move"
    let description =
        "Move or rename a file/directory in the sandbox. Both `source` and `destination` are paths "
        + "under the agent home or absolute under allowed roots. Fails if source does not exist."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "source": .object(["type": .string("string"), "description": .string("Source path")]),
                "destination": .object(["type": .string("string"), "description": .string("Destination path")]),
            ]),
            "required": .array([.string("source"), .string("destination")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let srcReq = requireString(
            args,
            "source",
            expected: "source path",
            tool: name
        )
        guard case .value(let source) = srcReq else { return srcReq.failureEnvelope ?? "" }

        let dstReq = requireString(
            args,
            "destination",
            expected: "destination path",
            tool: name
        )
        guard case .value(let dest) = dstReq else { return dstReq.failureEnvelope ?? "" }

        let srcResolvedReq = requirePath(source, home: home, field: "source", tool: name)
        guard case .value(let resolvedSrc) = srcResolvedReq else {
            return srcResolvedReq.failureEnvelope ?? ""
        }
        let dstResolvedReq = requirePath(dest, home: home, field: "destination", tool: name)
        guard case .value(let resolvedDst) = dstResolvedReq else {
            return dstResolvedReq.failureEnvelope ?? ""
        }

        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: "mv '\(resolvedSrc)' '\(resolvedDst)'"
        )
        guard result.succeeded else {
            return sandboxExecutionFailure(
                tool: name,
                message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                retryable: false
            )
        }
        return sandboxSuccess(
            tool: name,
            result: ["source": resolvedSrc, "destination": resolvedDst]
        )
    }
}

// MARK: - sandbox_delete

private struct SandboxDeleteTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_delete"
    let description =
        "Delete a file or directory in the sandbox. Pass `recursive: true` for directories — "
        + "without it, deleting a non-empty directory fails with a clear error."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("Path to delete")]),
                "recursive": .object([
                    "type": .string("boolean"),
                    "description": .string("Required true for directories. Defaults to false."),
                    "default": .bool(false),
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
            expected: "file or directory path under the agent home or absolute under allowed roots",
            tool: name
        )
        guard case .value(let path) = pathReq else { return pathReq.failureEnvelope ?? "" }

        let resolvedReq = requirePath(path, home: home, tool: name)
        guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }

        let recursive = coerceBool(args["recursive"]) ?? false
        let cmd = recursive ? "rm -rf '\(resolved)'" : "rm -f '\(resolved)'"
        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: cmd
        )
        guard result.succeeded else {
            return sandboxExecutionFailure(
                tool: name,
                message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                retryable: false
            )
        }
        return sandboxSuccess(
            tool: name,
            result: ["deleted": resolved, "recursive": recursive]
        )
    }
}

// MARK: - sandbox_exec

private struct SandboxExecTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_exec"
    let description = """
        Run a shell command (bash) in the agent's sandbox. This is your \
        most powerful tool — `bash` is a programming language. Prefer ONE \
        rich invocation over many round-trips.

        WHEN TO USE:
        - Three or more shell operations that depend on each other — chain \
          them with `&&`, `;`, or pipes in a single call instead of N tool \
          calls.
        - Batch file work — `for f in src/*.swift; do wc -l "$f"; done`.
        - Output you'll want to filter before reading — `grep`, `awk`, `head`, \
          `tail`, `jq`, `sed` keep the result small enough to reason over.
        - Conditional logic — `if [ -f config.json ]; then ...; else ...; fi`.
        - One-off processing — `python3 -c '...'` or `node -e '...'` inline \
          for parsing, JSON manipulation, math.
        - Network calls (`curl`, `wget`) when you need data the model doesn't have.

        WHEN NOT TO USE:
        - You need to reason over a result and only THEN decide what to run \
          next — make the smaller call, look at the result, then continue.
        - You need user input or interactive prompts (none are available).

        LIMITS:
        - Default timeout 30s, max 300s (set via `timeout`).
        - Stdout is truncated at ~50KB (40% head + 60% tail). If you expect \
          a lot of output, pipe through `head`, `tail`, `grep`, or `wc` to \
          keep what matters.
        - Per-turn command count is capped — chain inside one call rather \
          than burning the cap on N small ones.

        Pass the command as a single string in `command`. Use `cwd` to run \
        in a different directory; default is the agent home.
        """
    let agentId: String
    let agentName: String
    let home: String
    let maxTimeout: Int
    let maxCommandsPerTurn: Int

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Shell command to run (single string, e.g. `wc -l src/*.swift`)."),
                ]),
                "cwd": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Working directory (default: agent home). Rejected if outside allowed roots."
                    ),
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string("Timeout in seconds (default 30, max 300)."),
                    "default": .number(30),
                ]),
            ]),
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

        let timeout = min(
            coerceInt(args["timeout"]) ?? 30,
            min(maxTimeout, 300)
        )

        let result = try await SandboxToolCommandRunnerRegistry.shared.exec(
            user: "agent-\(agentName)",
            command: command,
            env: agentShellEnvironment(agentId: agentId, home: home, cwd: cwd),
            cwd: cwd,
            timeout: TimeInterval(timeout),
            streamToLogs: true,
            logSource: agentName
        )

        return sandboxSuccess(
            tool: name,
            result: [
                "stdout": truncateForModel(result.stdout),
                "stderr": truncateForModel(result.stderr, maxChars: 10_000),
                "exit_code": Int(result.exitCode),
                "cwd": cwd,
            ]
        )
    }
}

// MARK: - sandbox_exec_background

private struct SandboxExecBackgroundTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_exec_background"
    let description =
        "Start a background process in the sandbox. Stdout+stderr stream to a log file in the agent "
        + "home; the tool returns the PID and log path immediately. Use for servers, watchers, or "
        + "any long-running process. Spawn-side timeout is fixed at 10s — the spawned process itself "
        + "runs for as long as it likes."
    let agentId: String
    let agentName: String
    let home: String
    let maxCommandsPerTurn: Int

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Command to start (e.g. `python3 server.py`)."),
                ]),
                "cwd": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Working directory (default: agent home). Rejected if outside allowed roots."
                    ),
                ]),
            ]),
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
                    + "Wait until the next turn.",
                tool: name,
                retryable: false
            )
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let cmdReq = requireString(
            args,
            "command",
            expected: "shell command to start (e.g. `python3 server.py`)",
            tool: name
        )
        guard case .value(let command) = cmdReq else { return cmdReq.failureEnvelope ?? "" }

        let cwd: String
        if let cwdArg = args["cwd"] as? String, !cwdArg.isEmpty {
            let cwdReq = requirePath(cwdArg, home: home, field: "cwd", tool: name)
            guard case .value(let resolvedCwd) = cwdReq else { return cwdReq.failureEnvelope ?? "" }
            cwd = resolvedCwd
        } else {
            cwd = home
        }

        let logFile = "\(home)/bg-\(UUID().uuidString.prefix(8)).log"
        let fullCmd = "cd '\(cwd)' && nohup \(command) > \(logFile) 2>&1 & echo $!"

        let result = try await SandboxToolCommandRunnerRegistry.shared.exec(
            user: "agent-\(agentName)",
            command: fullCmd,
            env: agentShellEnvironment(agentId: agentId, home: home, cwd: cwd),
            timeout: 10,
            streamToLogs: true,
            logSource: agentName
        )
        let pid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sandboxSuccess(
            tool: name,
            result: ["pid": pid, "log_file": logFile, "cwd": cwd]
        )
    }
}

// MARK: - sandbox_install

private struct SandboxInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_install"
    let description =
        "Install system packages via `apk` (runs as root). Example: `{\"packages\": [\"ffmpeg\"]}`. "
        + "For Python or Node packages prefer `sandbox_pip_install` / `sandbox_npm_install`."
    let agentName: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "packages": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Apk package names, e.g. `[\"ffmpeg\", \"imagemagick\"]`."),
                ])
            ]),
            "required": .array([.string("packages")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pkgsReq = requireStringArray(
            args,
            "packages",
            expected: "non-empty array of apk package names",
            tool: name
        )
        guard case .value(let packages) = pkgsReq else { return pkgsReq.failureEnvelope ?? "" }

        let pkgList = packages.joined(separator: " ")
        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsRoot(
            command: "apk add --no-cache \(pkgList)",
            timeout: 120,
            streamToLogs: true,
            logSource: "apk"
        )
        return installResultEnvelope(tool: name, packages: packages, result: result)
    }
}

// MARK: - sandbox_pip_install

private struct SandboxPipInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_pip_install"
    let description =
        "Install Python packages via pip into the agent's venv. Auto-creates the venv on first use. "
        + "Example: `{\"packages\": [\"numpy\", \"flask\"]}`."
    let agentId: String
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "packages": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Python package names, e.g. `[\"numpy\", \"flask\"]`."),
                ])
            ]),
            "required": .array([.string("packages")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pkgsReq = requireStringArray(
            args,
            "packages",
            expected: "non-empty array of pip package names",
            tool: name
        )
        guard case .value(let packages) = pkgsReq else { return pkgsReq.failureEnvelope ?? "" }

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
        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command:
                "test -x '\(venvPath)/bin/python3' || /usr/bin/python3 -m venv '\(venvPath)' && '\(venvPath)/bin/python3' -m pip install \(pkgList)",
            env: agentShellEnvironment(agentId: agentId, home: home),
            timeout: 120,
            streamToLogs: true,
            logSource: "pip"
        )
        return installResultEnvelope(tool: name, packages: packages, result: result)
    }
}

// MARK: - sandbox_npm_install

private struct SandboxNpmInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_npm_install"
    let description =
        "Install Node packages via `npm install` in the agent home. Example: "
        + "`{\"packages\": [\"express\", \"lodash\"]}`."
    let agentId: String
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "packages": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("npm package names, e.g. `[\"express\", \"lodash\"]`."),
                ])
            ]),
            "required": .array([.string("packages")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pkgsReq = requireStringArray(
            args,
            "packages",
            expected: "non-empty array of npm package names",
            tool: name
        )
        guard case .value(let packages) = pkgsReq else { return pkgsReq.failureEnvelope ?? "" }

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

        let pkgList = packages.joined(separator: " ")
        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: "npm install \(pkgList)",
            env: agentShellEnvironment(agentId: agentId, home: home, cwd: home),
            timeout: 120,
            streamToLogs: true,
            logSource: "npm"
        )
        return installResultEnvelope(tool: name, packages: packages, result: result)
    }
}

// MARK: - sandbox_run_script

private struct SandboxRunScriptTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_run_script"
    let description = """
        Write a multi-line script to a temp file in the sandbox and run it. \
        Use this when the program is long enough that an inline `bash -c '...'` \
        gets unwieldy — multi-screen scripts, anything with non-trivial \
        quoting, anything you want isolated in its own file.

        WHEN TO USE:
        - Bulk file analysis or transformation that needs more than a one-liner.
        - Data processing with proper data structures (use `python` and pandas/json).
        - Build orchestration where exit-code semantics matter.

        WHEN NOT TO USE:
        - The work fits in a single shell invocation — use the smaller \
          shell-exec tool with chained commands instead.
        - You only need a single file written — use the file-write tool.

        LIMITS:
        - Default timeout 60s, max 300s.
        - Combined stdout+stderr is truncated at ~50KB (40% head + 60% tail).
        - Per-turn command count is shared with other shell-exec calls.

        `language` is one of `python`, `bash`, `node`. Pass the full script in \
        `script`. Use `cwd` to run in a different directory.
        """
    let agentId: String
    let agentName: String
    let home: String
    let maxTimeout: Int
    let maxCommandsPerTurn: Int

    private static let languageConfig: [String: (ext: String, interpreter: String)] = [
        "python": (".py", "python3"),
        "bash": (".sh", "bash"),
        "node": (".js", "node"),
    ]

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "language": .object([
                    "type": .string("string"),
                    "description": .string("Script language: `python`, `bash`, or `node`."),
                    "enum": .array([.string("python"), .string("bash"), .string("node")]),
                ]),
                "script": .object([
                    "type": .string("string"),
                    "description": .string("Full script source to execute."),
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string("Timeout in seconds (default 60, max 300)."),
                    "default": .number(60),
                ]),
                "cwd": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Working directory (default: agent home). Rejected if outside allowed roots."
                    ),
                ]),
            ]),
            "required": .array([.string("language"), .string("script")]),
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

        let langReq = requireString(
            args,
            "language",
            expected: "one of `python`, `bash`, `node`",
            tool: name
        )
        guard case .value(let language) = langReq else { return langReq.failureEnvelope ?? "" }

        guard let config = Self.languageConfig[language] else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unsupported `language`: `\(language)`. Use one of: python, bash, node.",
                field: "language",
                expected: "one of `python`, `bash`, `node`",
                tool: name
            )
        }

        let scriptReq = requireString(
            args,
            "script",
            expected: "non-empty script source",
            tool: name
        )
        guard case .value(let script) = scriptReq else { return scriptReq.failureEnvelope ?? "" }

        // Strict cwd resolution — silent fallback to home was a footgun
        // (script ran in the wrong directory and looked like missing files).
        let cwd: String
        if let cwdArg = args["cwd"] as? String, !cwdArg.isEmpty {
            let cwdReq = requirePath(cwdArg, home: home, field: "cwd", tool: name)
            guard case .value(let resolvedCwd) = cwdReq else { return cwdReq.failureEnvelope ?? "" }
            cwd = resolvedCwd
        } else {
            cwd = home
        }

        let timeout = min(coerceInt(args["timeout"]) ?? 60, min(maxTimeout, 300))
        let scriptPath = "\(home)/.tmp/script_\(UUID().uuidString.prefix(8))\(config.ext)"
        let escaped = shellEscapeSingleQuoted(script)

        var command = "mkdir -p '\(home)/.tmp' && printf '%s' '\(escaped)' > '\(scriptPath)'"
        if language == "bash" { command += " && chmod +x '\(scriptPath)'" }
        // Note: no `2>&1` here — let stdout / stderr stay split so the
        // result envelope matches `sandbox_exec`. Callers that want them
        // merged read the `combined` field.
        command += " && cd '\(cwd)' && \(config.interpreter) '\(scriptPath)'"
        command += "; EXIT=$?; rm -f '\(scriptPath)'; exit $EXIT"

        let result = try await SandboxToolCommandRunnerRegistry.shared.exec(
            user: "agent-\(agentName)",
            command: command,
            env: agentShellEnvironment(agentId: agentId, home: home, cwd: cwd),
            timeout: TimeInterval(timeout),
            streamToLogs: true,
            logSource: agentName
        )

        let stdoutTrunc = truncateForModel(result.stdout)
        let stderrTrunc = truncateForModel(result.stderr, maxChars: 10_000)
        return sandboxSuccess(
            tool: name,
            result: [
                "stdout": stdoutTrunc,
                "stderr": stderrTrunc,
                "combined": truncateForModel(result.stdout + result.stderr),
                "exit_code": Int(result.exitCode),
                "language": language,
                "cwd": cwd,
            ]
        )
    }
}
