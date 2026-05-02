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
    ///
    /// The schema is deliberately lean so the model can keep the whole
    /// tool surface in working memory:
    ///   - reads/searches: `sandbox_read_file`, `sandbox_search_files`
    ///   - writes/edits: `sandbox_write_file`, `sandbox_edit_file`
    ///   - exec: `sandbox_exec` (foreground OR background via flag),
    ///     `sandbox_process` (poll/wait/kill background jobs)
    ///   - power tool: `sandbox_execute_code` (Python orchestration)
    ///   - installs: `sandbox_install` / `sandbox_pip_install` /
    ///     `sandbox_npm_install`
    ///
    /// Removed-by-design (use the consolidated alternative):
    ///   - `sandbox_list_directory` → `sandbox_search_files(target:"files")`
    ///   - `sandbox_find_files` → `sandbox_search_files(target:"files")`
    ///   - `sandbox_move` / `sandbox_delete` → `sandbox_exec("mv …" / "rm …")`
    ///   - `sandbox_exec_background` → `sandbox_exec(background:true)`
    ///   - `sandbox_run_script` → `sandbox_execute_code` for Python, or
    ///     `sandbox_exec` with a heredoc for short bash/node snippets.
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
            SandboxEditFileTool(agentName: agentName, home: home),
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
            SandboxProcessTool(agentId: agentId, agentName: agentName, home: home),
            runtimeManaged: true
        )
        registry.registerSandboxTool(
            SandboxExecuteCodeTool(
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

    /// Tool names a `sandbox_execute_code` Python script is allowed to
    /// dispatch via the host bridge. Hard-coded (not derived from the
    /// live registry) so adding a new sandbox built-in can't silently
    /// expose it to in-script callers — opt-in by adding a name here.
    ///
    /// Deliberately excluded:
    ///   - `sandbox_execute_code` itself (no recursive launches).
    ///   - `sandbox_init_pending` (placeholder only registered while the
    ///     container is booting; calling it from a script is meaningless).
    ///   - `share_artifact` and the chat-layer-intercepted tools (`todo`,
    ///     `complete`, `clarify`, `speak`, `sandbox_secret_set`,
    ///     `sandbox_plugin_register`). Their post-execute UI hooks only
    ///     fire for top-level tool calls; calling them from inside a
    ///     script would silently no-op the chat surfacing. The model
    ///     should call them at the model layer instead.
    public static let executeCodeBridgeAllowedTools: Set<String> = [
        "sandbox_read_file",
        "sandbox_write_file",
        "sandbox_edit_file",
        "sandbox_search_files",
        "sandbox_exec",
        "sandbox_process",
        "sandbox_install",
        "sandbox_pip_install",
        "sandbox_npm_install",
        "sandbox_secret_check",
    ]
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

/// Per-agent npm project workspace. `sandbox_npm_install` bootstraps a
/// `package.json` here and installs into `<workdir>/node_modules/`.
/// Isolating npm state under our namespace prevents leftover artefacts
/// from cross-contaminating the agent home and stops the well-known
/// "Tracker idealTree already exists" error that fires when `npm install`
/// runs over a stale `node_modules/.package-lock.json`.
private func agentNodeWorkdir(home: String) -> String {
    "\(home)/.osaurus/node_workspace"
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
    let combined = truncateForModel(result.stdout + result.stderr, maxChars: 20_000)
    if result.succeeded {
        var payload: [String: Any] = [
            "installed": packages,
            "exit_code": Int(result.exitCode),
            "output": combined,
        ]
        if retried { payload["retried"] = true }
        return ToolEnvelope.success(tool: tool, result: payload)
    }
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
        maxChars: 10_000
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
    cleanup: @Sendable () async throws -> Void
) async throws -> String {
    let first = try await attempt()
    if first.succeeded || !isRecoverable(first) {
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
        + "bodies, or `target=\"files\"` for a filename glob (e.g. `*.py`, `test_*`). Cap output "
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
                            + "When `target=\"files\"`: filename glob (e.g. `*.py`, `test_*`)."
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
        let cappedMax = max(1, min(maxResults, 500))

        switch target {
        case "files":
            let escapedPattern = shellEscapeSingleQuoted(pattern)
            let cmd =
                "find '\(resolved)' -type f -name '\(escapedPattern)' 2>/dev/null | head -\(cappedMax)"
            let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
                agentName,
                command: cmd
            )
            return sandboxSuccess(
                tool: name,
                result: [
                    "pattern": pattern,
                    "target": "files",
                    "path": resolved,
                    "matches": result.stdout,
                ]
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
            return sandboxSuccess(
                tool: name,
                result: [
                    "pattern": pattern,
                    "target": "content",
                    "path": resolved,
                    "matches": result.stdout,
                ]
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
        "Write `content` to `path` in the sandbox, replacing any existing file. **Use this instead "
        + "of `echo`/`cat` heredoc in `sandbox_exec`.** Creates parent directories as needed. Both "
        + "arguments are required — passing only `path` returns an `invalid_args` failure pointing "
        + "at the missing field."
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
        "Edit a file by replacing an exact string match. **Use this instead of `sed`/`awk` in "
        + "`sandbox_exec`.** `old_string` must uniquely match one location — include surrounding "
        + "context lines if needed. Fails if `old_string` is not found or matches multiple "
        + "locations. Prefer this over `sandbox_write_file` for targeted in-place edits."
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

// MARK: - sandbox_exec
//
// One shell tool, foreground OR background via the `background` flag.
// Folded the previously-separate `sandbox_exec_background` in here so
// the model picks "run a command" and toggles a flag, rather than
// picking between two near-identical tool names.

private struct SandboxExecTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_exec"
    let description = """
        Run a shell command (bash) in the agent's sandbox. **Reserve this for \
        builds, installs, git, processes, network calls, package managers, \
        and anything else that needs a shell.**

        Do NOT use `cat` / `head` / `tail` to read files — use `sandbox_read_file`. \
        Do NOT use `grep` / `rg` / `find` / `ls` to search — use `sandbox_search_files`. \
        Do NOT use `sed` / `awk` to edit files — use `sandbox_edit_file`. \
        Do NOT use `echo` / `cat` heredoc to create files — use `sandbox_write_file`.

        Foreground (default): returns INSTANTLY when the command finishes, \
        even if you set a high `timeout`. Prefer ONE rich invocation \
        (chained with `&&` / `;` / pipes) over many round-trips.

        Background (`background:true`): returns a `pid` + `log_file` \
        immediately; spawn-side timeout is fixed at 10s. Use for servers, \
        watchers, test runs, long builds. Then call `sandbox_process` to \
        poll/wait/kill. Do NOT shell-background yourself with `&` / `nohup` \
        / `disown` — pass `background:true` so the runtime can track it.

        For multi-step Python orchestration (≥3 tool calls with logic \
        between them, output filtering, looping), prefer `sandbox_execute_code`.

        LIMITS: foreground default timeout 30s, max 300s. Stdout truncated \
        at ~50KB (40% head + 60% tail). Per-turn command count is capped — \
        chain inside one call instead of burning the cap on N small ones.
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
                    "description": .string(
                        "Foreground timeout in seconds (default 30, max 300). Ignored when `background:true`."
                    ),
                    "default": .number(30),
                ]),
                "background": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "When true, the command runs detached with stdout+stderr redirected to "
                            + "a per-job log under the agent home; the tool returns the pid + log "
                            + "path immediately. Use for long-lived processes (servers, watchers) "
                            + "and tasks that exceed the foreground timeout. Pair with `sandbox_process`."
                    ),
                    "default": .bool(false),
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

        let background = coerceBool(args["background"]) ?? false

        if background {
            // Detached job: start it, return pid + log path right away. The
            // 10s timeout here is just for the spawn shim — the spawned
            // process itself can run as long as it likes.
            let logFile = "\(home)/bg-\(UUID().uuidString.prefix(8)).log"
            let fullCmd = "cd '\(cwd)' && nohup \(command) > \(logFile) 2>&1 & echo $!"

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
                command: "kill -0 \(pid) 2>/dev/null && echo alive || echo dead"
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
                + "kill -0 \(pid) 2>/dev/null || { echo exited; exit 0; }; "
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
            let signal = force ? "-9" : "-15"
            let killResult = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
                agentName,
                command: "kill \(signal) \(pid) 2>&1; sleep 0.2; kill -0 \(pid) 2>/dev/null && echo alive || echo dead"
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
        return result?.stdout ?? ""
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

private struct SandboxInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_install"
    let description =
        "Install system packages via `apk` (runs as root) — available globally inside the container. "
        + "**Use this instead of `sandbox_exec(\"apk add …\")`** so the auto-refresh + retry "
        + "harness runs and concurrent installs don't collide on apk's lock. Example: "
        + "`{\"packages\": [\"ffmpeg\"]}`. For Python or Node packages prefer "
        + "`sandbox_pip_install` / `sandbox_npm_install`."
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
        // `apk update` first refreshes the package index — cheap when the
        // cache is fresh, and eliminates "no such package" errors caused
        // by a stale index. `|| true` so a transient network blip on the
        // index refresh doesn't poison the install. Recovery harness
        // catches the rest.
        let installCmd = "apk update --quiet || true; apk add --no-cache \(pkgList)"

        let toolName = self.name
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
                }
            )
        }
    }
}

// MARK: - sandbox_pip_install

private struct SandboxPipInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_pip_install"
    let description =
        "Install Python packages via pip into the agent's venv at `~/.venv/`. **Use this instead "
        + "of `sandbox_exec(\"pip install …\")`** so the venv bootstrap, retry harness, and "
        + "per-agent serialization apply. Auto-creates the venv on first use. The venv's "
        + "`python3` and installed scripts are on your PATH — call them from any `sandbox_exec` "
        + "cwd. 240s timeout (covers cold-cache installs of large packages). Example: "
        + "`{\"packages\": [\"numpy\", \"flask\"]}`."
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
                }
            )
        }
    }
}

// MARK: - sandbox_npm_install

private struct SandboxNpmInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_npm_install"
    let description =
        "Install Node packages via `npm install` into a per-agent project workspace at "
        + "`~/.osaurus/node_workspace/`. **Use this instead of `sandbox_exec(\"npm install …\")`** "
        + "so the workdir bootstrap, recovery harness, and per-agent serialization apply — bare "
        + "`npm install` in the agent home is what produced the original `Tracker idealTree "
        + "already exists` failures. Bootstraps a `package.json` on first use; subsequent calls "
        + "accumulate into the same workspace. Installed CLI binaries are on your PATH "
        + "automatically — call them from any `sandbox_exec` cwd. 240s timeout. Example: "
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
                }
            )
        }
    }
}

// MARK: - sandbox_execute_code
//
// Python orchestration: write a Python script that imports the same
// sandbox tools as Python helpers (`from osaurus_tools import …`) and
// runs them in-process. Use when the model needs ≥3 tool calls with
// logic between them, output filtering before it lands in context,
// conditional branching, or looping. The helpers RPC back to the host
// via the bridge socket so the tools run with the same authority and
// accounting as direct calls.

private struct SandboxExecuteCodeTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_execute_code"
    let description = """
        Run a Python script that can call sandbox tools as Python functions. \
        Use this when:
        - You need ≥3 tool calls with processing logic between them.
        - You need to filter / reduce a large tool output before it enters \
          your context (e.g. read 5 logs, return the top 10 errors).
        - You need conditional branching or loops (fetch N pages, retry \
          on failure, walk a directory tree).

        Available helpers (no install needed):
            from osaurus_tools import read_file, write_file, edit_file, \
                search_files, terminal

        Each helper mirrors the equivalent sandbox tool 1:1. They return \
        Python dicts (the same JSON envelope you would see from a direct \
        call). Print your final result to stdout.

        Surfacing artifacts: `share_artifact` is NOT exposed to the script \
        — call it AFTER `sandbox_execute_code` returns, as a separate \
        top-level tool call against the file path your script wrote. \
        Surfacing from inside the script would silently no-op the chat \
        artifact card.

        Installing packages: call `sandbox_pip_install` / `sandbox_install` \
        BEFORE `sandbox_execute_code` (they live at the model layer), or \
        run `terminal("pip install …")` from inside the script for a \
        one-shot install.

        WHEN NOT TO USE:
        - You need to look at one tool result before deciding the next \
          step — make a normal tool call instead.
        - You only need ONE tool call — call it directly.

        LIMITS:
        - 5-minute hard timeout, 50KB stdout cap (40% head + 60% tail).
        - At most 50 tool calls per script.
        - Per-turn command count is shared with other `sandbox_exec` calls.
        """
    let agentId: String
    let agentName: String
    let home: String
    let maxCommandsPerTurn: Int

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "code": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Python source. Import helpers via `from osaurus_tools import "
                            + "read_file, write_file, edit_file, search_files, terminal`. "
                            + "Print the final result to stdout. (`share_artifact` is "
                            + "intentionally not exposed — call it AFTER this tool returns.)"
                    ),
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string("Timeout in seconds (default 300, max 300)."),
                    "default": .number(300),
                ]),
                "cwd": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Working directory (default: agent home). Rejected if outside allowed roots."
                    ),
                ]),
            ]),
            "required": .array([.string("code")]),
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
                    + "Wait until the next turn or chain more steps inside one `sandbox_execute_code` call.",
                tool: name,
                retryable: false
            )
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let codeReq = requireString(
            args,
            "code",
            expected: "non-empty Python source",
            tool: name
        )
        guard case .value(let code) = codeReq else { return codeReq.failureEnvelope ?? "" }

        let cwd: String
        if let cwdArg = args["cwd"] as? String, !cwdArg.isEmpty {
            let cwdReq = requirePath(cwdArg, home: home, field: "cwd", tool: name)
            guard case .value(let resolvedCwd) = cwdReq else { return cwdReq.failureEnvelope ?? "" }
            cwd = resolvedCwd
        } else {
            cwd = home
        }

        // 5min hard cap; the per-turn SandboxExecLimiter still applies
        // on top so the model can't burn its turn budget on one script.
        let timeout = min(max(coerceInt(args["timeout"]) ?? 300, 1), 300)

        // Script id scopes the tool-call counter on the host bridge so
        // one runaway script can't exceed its 50-call budget by reusing
        // an old id. We snapshot the task-local chat context here so the
        // bridge handler can re-establish it for each dispatched tool —
        // without that, session-aware tools (`sandbox_secret_check`,
        // anything plugin-namespaced if the allow-list is widened later)
        // would resolve to "no active session" from inside the script.
        let scriptId = UUID().uuidString
        let context = SandboxExecuteCodeBudget.ScriptContext(
            agentId: ChatExecutionContext.currentAgentId,
            sessionId: ChatExecutionContext.currentSessionId,
            assistantTurnId: ChatExecutionContext.currentAssistantTurnId,
            batchId: ChatExecutionContext.currentBatchId
        )
        await SandboxExecuteCodeBudget.shared.start(scriptId: scriptId, context: context)
        defer { Task { await SandboxExecuteCodeBudget.shared.finish(scriptId: scriptId) } }

        let helpersDir = "\(home)/.osaurus"
        let helpersPath = "\(helpersDir)/osaurus_tools.py"
        let scriptPath = "\(home)/.tmp/exec_\(UUID().uuidString.prefix(8)).py"

        // Stage the helper module + the user's code under the agent home,
        // run it, then clean up. The helper module RPCs to the host via
        // the Unix socket at `/tmp/osaurus-bridge.sock`, reading the
        // per-user bearer token from `/run/osaurus/$USER.token` (mode
        // 0600, owned by the agent user — set up by
        // `SandboxManager.provisionBridgeToken`).
        let escapedHelpers = shellEscapeSingleQuoted(SandboxExecuteCodeHelpers.pythonSource)
        let escapedCode = shellEscapeSingleQuoted(code)
        let writeHelpers =
            "mkdir -p '\(helpersDir)' '\(home)/.tmp' && "
            + "printf '%s' '\(escapedHelpers)' > '\(helpersPath)'"
        let writeCode = "printf '%s' '\(escapedCode)' > '\(scriptPath)'"

        var command = writeHelpers + " && " + writeCode
        command += " && cd '\(cwd)' && OSAURUS_SCRIPT_ID='\(scriptId)' "
        command += "PYTHONPATH='\(helpersDir)':$PYTHONPATH "
        command += "python3 '\(scriptPath)'"
        command += "; EXIT=$?; rm -f '\(scriptPath)'; exit $EXIT"

        let result = try await SandboxToolCommandRunnerRegistry.shared.exec(
            user: "agent-\(agentName)",
            command: command,
            env: agentShellEnvironment(agentId: agentId, home: home, cwd: cwd),
            cwd: cwd,
            timeout: TimeInterval(timeout),
            streamToLogs: true,
            logSource: agentName
        )

        let toolCalls = await SandboxExecuteCodeBudget.shared.callCount(scriptId: scriptId)
        return sandboxSuccess(
            tool: name,
            result: [
                "stdout": truncateForModel(result.stdout),
                "stderr": truncateForModel(result.stderr, maxChars: 10_000),
                "exit_code": Int(result.exitCode),
                "tool_calls": toolCalls,
                "cwd": cwd,
            ]
        )
    }
}

/// Tracks the number of bridge tool calls each `sandbox_execute_code`
/// script makes plus the chat execution context that should be re-applied
/// to dispatched tools. The per-script cap (50) is
/// enforced inside `HostAPIBridgeServer.handleSandboxToolCall` by
/// reading this counter via the `OSAURUS_SCRIPT_ID` request header.
public actor SandboxExecuteCodeBudget {
    public static let shared = SandboxExecuteCodeBudget()

    /// Capped at 50 so a runaway loop can't burn the whole turn's
    /// compute. Configurable per-script from the host side if we ever
    /// need to lift it.
    public static let maxCallsPerScript = 50

    /// Snapshot of the chat-engine task locals at the moment a script
    /// started. The bridge dispatcher re-applies them with
    /// `ChatExecutionContext.$… .withValue` so dispatched tools resolve
    /// to the same session as a direct top-level call would have.
    public struct ScriptContext: Sendable {
        public let agentId: UUID?
        public let sessionId: String?
        public let assistantTurnId: UUID?
        public let batchId: UUID?
    }

    private struct Entry {
        var calls: Int
        let context: ScriptContext
    }

    private var entries: [String: Entry] = [:]

    /// Begin tracking a `sandbox_execute_code` script. `context` carries
    /// the chat-engine task locals captured at script-start time so the
    /// bridge handler can re-apply them around each dispatched tool.
    func start(scriptId: String, context: ScriptContext) {
        entries[scriptId] = Entry(calls: 0, context: context)
    }

    func finish(scriptId: String) {
        entries.removeValue(forKey: scriptId)
    }

    /// Try to charge one tool-call against this script's budget.
    /// Returns `true` when the script is tracked AND the cap hasn't been
    /// reached, `false` otherwise — a `false` return is the host's
    /// signal to reject the bridge call. The actual call count for the
    /// result envelope comes from `callCount(scriptId:)`.
    public func tryIncrement(scriptId: String) -> Bool {
        guard var entry = entries[scriptId], entry.calls < Self.maxCallsPerScript
        else { return false }
        entry.calls += 1
        entries[scriptId] = entry
        return true
    }

    public func callCount(scriptId: String) -> Int {
        entries[scriptId]?.calls ?? 0
    }

    /// Returns the chat-engine context snapshot for a tracked script id.
    /// Returns nil if the id isn't known — the bridge handler treats that
    /// as a rejected call.
    public func context(scriptId: String) -> ScriptContext? {
        entries[scriptId]?.context
    }
}

/// Source of the Python helper module that gets staged under each agent's
/// home on every `sandbox_execute_code` call. Talks to the host bridge via
/// the Unix socket already used by `osaurus-host`. Each helper returns a
/// dict (the parsed envelope) so callers can branch on `ok`/`kind` etc.
enum SandboxExecuteCodeHelpers {
    static let pythonSource: String = #"""
        # osaurus_tools -- sandbox helpers for sandbox_execute_code scripts.
        #
        # Each helper mirrors the same-named built-in sandbox tool. They make a
        # JSON POST to the host bridge at /api/sandbox-tool/{name} over the Unix
        # socket mounted at /tmp/osaurus-bridge.sock. The bearer token is read
        # from /run/osaurus/$USER.token (mode 0600, owned by the agent user).
        # The decoded JSON response is returned as a dict.
        #
        # `share_artifact` is intentionally NOT exposed here -- calling it from
        # inside a script would create the marker envelope but the chat-layer
        # post-processor that turns it into a real artifact card only fires for
        # top-level tool calls. Surface artifacts by calling `share_artifact`
        # from the model layer, AFTER `sandbox_execute_code` returns.

        import getpass
        import json
        import os
        import socket

        _BRIDGE_SOCKET_PATH = "/tmp/osaurus-bridge.sock"
        _TOKEN_PATH_TEMPLATE = "/run/osaurus/{user}.token"
        _SCRIPT_ID_HEADER = "X-Osaurus-Script-Id"


        class SandboxToolError(RuntimeError):
            """Raised when the bridge round-trip itself fails (transport-level)."""


        def _read_token() -> str:
            user = os.environ.get("USER") or getpass.getuser()
            path = _TOKEN_PATH_TEMPLATE.format(user=user)
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    token = fh.read().strip()
            except OSError as exc:
                raise SandboxToolError(
                    f"could not read bridge token at {path}: {exc}. "
                    f"sandbox_execute_code helpers must run inside a provisioned sandbox agent."
                ) from exc
            if not token:
                raise SandboxToolError(f"bridge token at {path} is empty")
            return token


        def _send_http(method: str, path: str, headers: dict, body: bytes, timeout: float = 300.0) -> tuple:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            try:
                sock.connect(_BRIDGE_SOCKET_PATH)
            except OSError as exc:
                sock.close()
                raise SandboxToolError(
                    f"could not connect to host bridge at {_BRIDGE_SOCKET_PATH}: {exc}"
                ) from exc

            request_line = f"{method} {path} HTTP/1.1\r\n"
            full_headers = {"Host": "osaurus", "Connection": "close"}
            full_headers.update(headers)
            full_headers["Content-Length"] = str(len(body))
            if body and "Content-Type" not in full_headers:
                full_headers["Content-Type"] = "application/json"

            try:
                sock.sendall(request_line.encode("utf-8"))
                for name, value in full_headers.items():
                    sock.sendall(f"{name}: {value}\r\n".encode("utf-8"))
                sock.sendall(b"\r\n")
                if body:
                    sock.sendall(body)

                chunks = []
                while True:
                    data = sock.recv(65536)
                    if not data:
                        break
                    chunks.append(data)
            finally:
                sock.close()

            raw = b"".join(chunks)
            head, _, response_body = raw.partition(b"\r\n\r\n")
            status_line = head.split(b"\r\n", 1)[0].decode("latin-1") if head else ""
            parts = status_line.split(" ", 2)
            status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 500
            return status, response_body


        def _call(tool_name: str, args: dict) -> dict:
            body = json.dumps({"arguments": args}).encode("utf-8")
            headers = {"Authorization": f"Bearer {_read_token()}"}
            script_id = os.environ.get("OSAURUS_SCRIPT_ID", "")
            if script_id:
                headers[_SCRIPT_ID_HEADER] = script_id
            status, raw = _send_http(
                "POST",
                f"/api/sandbox-tool/{tool_name}",
                headers=headers,
                body=body,
            )
            text = raw.decode("utf-8", errors="replace")
            if not text:
                return {"ok": False, "kind": "execution_error", "message": "empty bridge response"}
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError as exc:
                raise SandboxToolError(f"bridge returned non-JSON ({status}): {text[:200]}") from exc
            if status >= 400 and isinstance(parsed, dict) and "ok" not in parsed:
                # Wrap raw {"error": "..."} responses in the standard envelope shape
                # so user code can branch on `result["ok"]` uniformly.
                return {
                    "ok": False,
                    "kind": "execution_error",
                    "message": parsed.get("error", text),
                    "tool": tool_name,
                }
            return parsed


        def read_file(path: str, **kwargs) -> dict:
            """Read a file from the sandbox. See `sandbox_read_file` for arg shapes."""
            return _call("sandbox_read_file", {"path": path, **kwargs})


        def write_file(path: str, content: str) -> dict:
            """Write content to a file in the sandbox. See `sandbox_write_file`."""
            return _call("sandbox_write_file", {"path": path, "content": content})


        def edit_file(path: str, old_string: str, new_string: str) -> dict:
            """Targeted exact-string replacement. See `sandbox_edit_file`."""
            return _call(
                "sandbox_edit_file",
                {"path": path, "old_string": old_string, "new_string": new_string},
            )


        def search_files(pattern: str, target: str = "content", **kwargs) -> dict:
            """Search file contents (rg) or names (find). See `sandbox_search_files`."""
            payload = {"pattern": pattern, "target": target}
            payload.update(kwargs)
            return _call("sandbox_search_files", payload)


        def terminal(command: str, **kwargs) -> dict:
            """Run a shell command. Foreground or background via `background=True`. See `sandbox_exec`."""
            return _call("sandbox_exec", {"command": command, **kwargs})


        __all__ = [
            "read_file",
            "write_file",
            "edit_file",
            "search_files",
            "terminal",
            "SandboxToolError",
        ]
        """#
}
