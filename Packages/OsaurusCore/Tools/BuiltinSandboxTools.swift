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

private func validatePath(_ path: String, home: String) -> String? {
    SandboxPathSanitizer.sanitize(path, agentHome: home)
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

private func installResultJSON(packages: [String], result: ContainerExecResult) -> String {
    var payload: [String: Any] = [
        "exit_code": Int(result.exitCode),
        "output": result.stdout + result.stderr,
    ]
    if result.succeeded {
        payload["installed"] = packages
    } else {
        payload["requested"] = packages
    }
    return jsonResult(payload)
}

// MARK: - sandbox_read_file

private struct SandboxReadFileTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_read_file"
    let description = "Read a file's contents from the sandbox environment. Supports line ranges and log tails."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File path, relative to agent home or absolute within sandbox"),
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
        guard let args = parseArguments(argumentsJSON),
            let path = args["path"] as? String,
            let resolved = validatePath(path, home: home)
        else { return jsonResult(["error": "Invalid path"]) }

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
        return jsonResult(payload)
    }
}

// MARK: - sandbox_list_directory

private struct SandboxListDirectoryTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_list_directory"
    let description = "List files and directories in the sandbox environment."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
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
        let args = parseArguments(argumentsJSON) ?? [:]
        let path = args["path"] as? String ?? "."
        let recursive = coerceBool(args["recursive"]) ?? false

        guard let resolved = validatePath(path, home: home)
        else { return jsonResult(["error": "Invalid path"]) }

        let cmd =
            recursive
            ? "tree -L 3 --dirsfirst '\(resolved)' 2>/dev/null | head -200"
            : "ls -la '\(resolved)' 2>/dev/null"

        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(agentName, command: cmd)
        return jsonResult(["entries": result.stdout])
    }
}

// MARK: - sandbox_search_files

private struct SandboxSearchFilesTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_search_files"
    let description =
        "Search file contents with ripgrep in the sandbox. Returns matching lines with file paths and line numbers. Searches inside file bodies — does not match against file names."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string("Regex pattern to search for"),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Directory to search (default: agent home)"),
                    "default": .string("."),
                ]),
                "include": .object([
                    "type": .string("string"),
                    "description": .string("File glob filter (e.g. '*.py')"),
                ]),
                "context_lines": .object([
                    "type": .string("integer"),
                    "description": .string("Number of context lines to show before and after each match"),
                ]),
                "case_insensitive": .object([
                    "type": .string("boolean"),
                    "description": .string("Enable case-insensitive search"),
                    "default": .bool(false),
                ]),
                "max_results": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum lines of output (default: 100)"),
                ]),
            ]),
            "required": .array([.string("pattern")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let pattern = args["pattern"] as? String
        else { return jsonResult(["error": "Pattern required"]) }

        let path = args["path"] as? String ?? "."
        guard let resolved = validatePath(path, home: home)
        else { return jsonResult(["error": "Invalid path"]) }

        var cmd = "rg -n --no-heading"
        if coerceBool(args["case_insensitive"]) == true {
            cmd += " -i"
        }
        if let contextLines = coerceInt(args["context_lines"]), contextLines > 0 {
            cmd += " -C \(min(contextLines, 10))"
        }
        if let include = args["include"] as? String {
            cmd += " --glob '\(include)'"
        }
        let maxResults = coerceInt(args["max_results"]) ?? 100
        let cappedMax = max(1, min(maxResults, 500))
        cmd += " '\(pattern)' '\(resolved)' 2>/dev/null | head -\(cappedMax)"

        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(agentName, command: cmd)
        return jsonResult(["matches": result.stdout])
    }
}

// MARK: - sandbox_find_files

private struct SandboxFindFilesTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_find_files"
    let description =
        "Find files by name pattern in the sandbox. Use this to locate files by glob (e.g. '*.py', '*.swift'). Matches file names only — does not look inside file contents."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string("File name glob pattern (e.g. '*.py', 'test_*', '*.ts')"),
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
        guard let args = parseArguments(argumentsJSON),
            let pattern = args["pattern"] as? String
        else { return jsonResult(["error": "Pattern required"]) }

        let path = args["path"] as? String ?? "."
        guard let resolved = validatePath(path, home: home)
        else { return jsonResult(["error": "Invalid path"]) }

        let escapedPattern = pattern.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "find '\(resolved)' -type f -name '\(escapedPattern)' 2>/dev/null | head -200"

        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(agentName, command: cmd)
        return jsonResult(["files": result.stdout])
    }
}

// MARK: - sandbox_write_file

private struct SandboxWriteFileTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_write_file"
    let description = "Write content to a file in the sandbox. Creates parent directories."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File path relative to agent home"),
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string(
                        "File contents to write"
                    ),
                ]),
            ]),
            "required": .array([.string("path"), .string("content")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let path = args["path"] as? String,
            let content = args["content"] as? String,
            let resolved = validatePath(path, home: home)
        else { return jsonResult(["error": "Invalid arguments"]) }

        let dir = (resolved as NSString).deletingLastPathComponent
        _ = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(agentName, command: "mkdir -p '\(dir)'")

        let escaped = content.replacingOccurrences(of: "'", with: "'\\''")
        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: "printf '%s' '\(escaped)' > '\(resolved)'"
        )
        guard result.succeeded else {
            return jsonResult(["error": result.stderr])
        }
        return jsonResult(["path": resolved, "size": content.count])
    }
}

// MARK: - sandbox_edit_file

private struct SandboxEditFileTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_edit_file"
    let description =
        "Edit a file by replacing an exact string match. old_string must uniquely match exactly one location in the file — include surrounding context lines if needed. Fails if old_string is not found or matches multiple locations. Use this for targeted in-place edits when you do not want to rewrite the whole file."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File path relative to agent home or absolute within sandbox"),
                ]),
                "old_string": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The exact text to find and replace (must match exactly one location in the file)"
                    ),
                ]),
                "new_string": .object([
                    "type": .string("string"),
                    "description": .string("The replacement text"),
                ]),
            ]),
            "required": .array([.string("path"), .string("old_string"), .string("new_string")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let path = args["path"] as? String,
            let oldString = args["old_string"] as? String,
            let newString = args["new_string"] as? String,
            let resolved = validatePath(path, home: home)
        else { return jsonResult(["error": "Invalid arguments"]) }

        guard !oldString.isEmpty else {
            return jsonResult(["error": "old_string must not be empty"])
        }

        let tmpDir = "\(home)/.tmp"
        _ = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: "mkdir -p '\(tmpDir)'"
        )

        let suffix = String(UUID().uuidString.prefix(8))
        let oldFile = "\(tmpDir)/.edit_old_\(suffix)"
        let newFile = "\(tmpDir)/.edit_new_\(suffix)"

        let escapedOld = oldString.replacingOccurrences(of: "'", with: "'\\''")
        let escapedNew = newString.replacingOccurrences(of: "'", with: "'\\''")
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

        let escapedScript = script.replacingOccurrences(of: "'", with: "'\\''")
        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command:
                "python3 -c '\(escapedScript)' '\(resolved)' '\(oldFile)' '\(newFile)'; EC=$?; rm -f '\(oldFile)' '\(newFile)'; exit $EC"
        )

        guard result.succeeded else {
            return jsonResult(["error": result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)])
        }

        return jsonResult([
            "path": resolved,
            "result": result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
    }
}

// MARK: - sandbox_move

private struct SandboxMoveTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_move"
    let description = "Move or rename a file/directory in the sandbox."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "source": .object(["type": .string("string"), "description": .string("Source path")]),
                "destination": .object(["type": .string("string"), "description": .string("Destination path")]),
            ]),
            "required": .array([.string("source"), .string("destination")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let source = args["source"] as? String,
            let dest = args["destination"] as? String,
            let resolvedSrc = validatePath(source, home: home),
            let resolvedDst = validatePath(dest, home: home)
        else { return jsonResult(["error": "Invalid arguments"]) }

        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            agentName,
            command: "mv '\(resolvedSrc)' '\(resolvedDst)'"
        )
        guard result.succeeded else {
            return jsonResult(["error": result.stderr])
        }
        return jsonResult(["source": resolvedSrc, "destination": resolvedDst])
    }
}

// MARK: - sandbox_delete

private struct SandboxDeleteTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_delete"
    let description = "Delete a file or directory in the sandbox."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("Path to delete")]),
                "recursive": .object([
                    "type": .string("boolean"),
                    "description": .string("Required true for directories"),
                    "default": .bool(false),
                ]),
            ]),
            "required": .array([.string("path")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let path = args["path"] as? String,
            let resolved = validatePath(path, home: home)
        else { return jsonResult(["error": "Invalid path"]) }

        let recursive = coerceBool(args["recursive"]) ?? false
        let cmd = recursive ? "rm -rf '\(resolved)'" : "rm -f '\(resolved)'"
        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(agentName, command: cmd)
        guard result.succeeded else {
            return jsonResult(["error": result.stderr])
        }
        return jsonResult(["deleted": resolved])
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
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Shell command to run"),
                ]),
                "cwd": .object([
                    "type": .string("string"),
                    "description": .string("Working directory (default: agent home)"),
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string("Timeout in seconds (default: 30, max: 300)"),
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
            return jsonResult(["error": "Command limit (\(maxCommandsPerTurn)) per turn exceeded"])
        }

        guard let args = parseArguments(argumentsJSON),
            let command = args["command"] as? String
        else { return jsonResult(["error": "Command required"]) }

        let cwd: String?
        if let cwdArg = args["cwd"] as? String {
            cwd = validatePath(cwdArg, home: home)
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

        return jsonResult([
            "stdout": truncateForModel(result.stdout),
            "stderr": truncateForModel(result.stderr, maxChars: 10_000),
            "exit_code": Int(result.exitCode),
        ])
    }
}

// MARK: - sandbox_exec_background

private struct SandboxExecBackgroundTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_exec_background"
    let description = "Start a background process in the sandbox. Log output is written to the agent's home directory."
    let agentId: String
    let agentName: String
    let home: String
    let maxCommandsPerTurn: Int

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object(["type": .string("string"), "description": .string("Command to run")]),
                "cwd": .object(["type": .string("string"), "description": .string("Working directory")]),
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
            return jsonResult(["error": "Command limit (\(maxCommandsPerTurn)) per turn exceeded"])
        }

        guard let args = parseArguments(argumentsJSON),
            let command = args["command"] as? String
        else { return jsonResult(["error": "Command required"]) }

        let cwd = (args["cwd"] as? String).flatMap { validatePath($0, home: home) } ?? home
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
        return jsonResult(["pid": pid, "log_file": logFile])
    }
}

// MARK: - sandbox_install

private struct SandboxInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_install"
    let description =
        "Install system packages via apk (runs as root). Example args: {\"packages\": [\"ffmpeg\", \"imagemagick\"]}"
    let agentName: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "packages": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Package names to install"),
                ])
            ]),
            "required": .array([.string("packages")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let packages = coerceStringArray(args["packages"]), !packages.isEmpty
        else {
            return jsonResult([
                "error":
                    "Invalid packages argument. Expected a JSON array of strings, e.g. {\"packages\": [\"ffmpeg\", \"imagemagick\"]}"
            ])
        }

        let pkgList = packages.joined(separator: " ")
        let result = try await SandboxToolCommandRunnerRegistry.shared.execAsRoot(
            command: "apk add --no-cache \(pkgList)",
            timeout: 120,
            streamToLogs: true,
            logSource: "apk"
        )
        return installResultJSON(packages: packages, result: result)
    }
}

// MARK: - sandbox_pip_install

private struct SandboxPipInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_pip_install"
    let description =
        "Install Python packages via pip (runs as agent user). Example args: {\"packages\": [\"numpy\", \"flask\"]}"
    let agentId: String
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "packages": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Python package names"),
                ])
            ]),
            "required": .array([.string("packages")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let packages = coerceStringArray(args["packages"]), !packages.isEmpty
        else {
            return jsonResult([
                "error":
                    "Invalid packages argument. Expected a JSON array of strings, e.g. {\"packages\": [\"numpy\", \"flask\"]}"
            ])
        }

        let venvPath = agentVenvPath(home: home)
        let checkResult = try await SandboxToolCommandRunnerRegistry.shared.execAsRoot(
            command: "test -x /usr/bin/python3",
            timeout: 10
        )
        guard checkResult.succeeded else {
            return jsonResult(["error": "python3 is not installed in the sandbox image"])
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
        return installResultJSON(packages: packages, result: result)
    }
}

// MARK: - sandbox_npm_install

private struct SandboxNpmInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_npm_install"
    let description =
        "Install Node packages via npm (runs as agent user). Example args: {\"packages\": [\"express\", \"lodash\"]}"
    let agentId: String
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "packages": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("npm package names"),
                ])
            ]),
            "required": .array([.string("packages")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let packages = coerceStringArray(args["packages"]), !packages.isEmpty
        else {
            return jsonResult([
                "error":
                    "Invalid packages argument. Expected a JSON array of strings, e.g. {\"packages\": [\"express\", \"lodash\"]}"
            ])
        }

        let checkResult = try await SandboxToolCommandRunnerRegistry.shared.execAsRoot(
            command: "test -x /usr/bin/node && test -x /usr/bin/npm",
            timeout: 10
        )
        guard checkResult.succeeded else {
            return jsonResult(["error": "node/npm is not installed in the sandbox image"])
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
        return installResultJSON(packages: packages, result: result)
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
            "properties": .object([
                "language": .object([
                    "type": .string("string"),
                    "description": .string("Script language: python, bash, or node"),
                    "enum": .array([.string("python"), .string("bash"), .string("node")]),
                ]),
                "script": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The script contents to execute"
                    ),
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string("Timeout in seconds (default: 60, max: 300)"),
                ]),
                "cwd": .object([
                    "type": .string("string"),
                    "description": .string("Working directory (default: agent home)"),
                ]),
            ]),
            "required": .array([.string("language"), .string("script")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard SandboxExecLimiter.shared.checkAndIncrement(agentName: agentName, limit: maxCommandsPerTurn)
        else {
            return jsonResult(["error": "Command limit (\(maxCommandsPerTurn)) per turn exceeded"])
        }

        guard let args = parseArguments(argumentsJSON),
            let language = args["language"] as? String,
            let script = args["script"] as? String,
            let config = Self.languageConfig[language]
        else {
            return jsonResult(["error": "Required: language (python|bash|node) and script"])
        }

        let timeout = min(coerceInt(args["timeout"]) ?? 60, min(maxTimeout, 300))
        let cwd = (args["cwd"] as? String).flatMap { validatePath($0, home: home) } ?? home
        let scriptPath = "\(home)/.tmp/script_\(UUID().uuidString.prefix(8))\(config.ext)"
        let escaped = script.replacingOccurrences(of: "'", with: "'\\''")

        var command = "mkdir -p '\(home)/.tmp' && printf '%s' '\(escaped)' > '\(scriptPath)'"
        if language == "bash" { command += " && chmod +x '\(scriptPath)'" }
        command += " && cd '\(cwd)' && \(config.interpreter) '\(scriptPath)' 2>&1"
        command += "; EXIT=$?; rm -f '\(scriptPath)'; exit $EXIT"

        let result = try await SandboxToolCommandRunnerRegistry.shared.exec(
            user: "agent-\(agentName)",
            command: command,
            env: agentShellEnvironment(agentId: agentId, home: home, cwd: cwd),
            timeout: TimeInterval(timeout),
            streamToLogs: true,
            logSource: agentName
        )

        return jsonResult([
            "output": truncateForModel(result.stdout + result.stderr),
            "exit_code": Int(result.exitCode),
        ])
    }
}
