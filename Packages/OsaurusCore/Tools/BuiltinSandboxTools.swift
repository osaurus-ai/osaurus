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
        registry.registerSandboxTool(SandboxReadFileTool(agentName: agentName, home: home))
        registry.registerSandboxTool(SandboxListDirectoryTool(agentName: agentName, home: home))
        registry.registerSandboxTool(SandboxSearchFilesTool(agentName: agentName, home: home))

        // Gated by autonomous_exec.enabled
        guard let config = config, config.enabled else { return }

        let maxCmdsPerTurn = config.maxCommandsPerTurn

        registry.registerSandboxTool(SandboxWriteFileTool(agentName: agentName, home: home))
        registry.registerSandboxTool(SandboxMoveTool(agentName: agentName, home: home))
        registry.registerSandboxTool(SandboxDeleteTool(agentName: agentName, home: home))
        registry.registerSandboxTool(
            SandboxExecTool(
                agentName: agentName,
                home: home,
                maxTimeout: config.commandTimeout,
                maxCommandsPerTurn: maxCmdsPerTurn
            )
        )
        registry.registerSandboxTool(
            SandboxExecBackgroundTool(
                agentName: agentName,
                home: home,
                maxCommandsPerTurn: maxCmdsPerTurn
            )
        )
        registry.registerSandboxTool(SandboxExecKillTool(agentName: agentName))
        registry.registerSandboxTool(SandboxInstallTool(agentName: agentName))
        registry.registerSandboxTool(SandboxPipInstallTool(agentName: agentName, home: home))
        registry.registerSandboxTool(SandboxNpmInstallTool(agentName: agentName, home: home))
        registry.registerSandboxTool(SandboxWhoamiTool(agentName: agentName, home: home))
        registry.registerSandboxTool(SandboxProcessesTool(agentName: agentName))
    }

    /// Unregister all built-in sandbox tools.
    @MainActor
    static func unregisterAll() {
        let names = [
            "sandbox_read_file", "sandbox_list_directory", "sandbox_search_files",
            "sandbox_write_file", "sandbox_move", "sandbox_delete",
            "sandbox_exec", "sandbox_exec_background", "sandbox_exec_kill",
            "sandbox_install", "sandbox_pip_install", "sandbox_npm_install",
            "sandbox_whoami", "sandbox_processes",
        ]
        ToolRegistry.shared.unregister(names: names)
    }
}

// MARK: - Path Validation

private func validatePath(_ path: String, home: String) -> String? {
    SandboxPathSanitizer.sanitize(path, agentHome: home)
}

private func jsonResult(_ dict: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
        let json = String(data: data, encoding: .utf8)
    else { return "{}" }
    return json
}

// MARK: - sandbox_read_file

private struct SandboxReadFileTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_read_file"
    let description = "Read a file's contents from the sandbox environment."
    let agentName: String
    let home: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File path, relative to agent home or absolute within sandbox"),
                ])
            ]),
            "required": .array([.string("path")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let path = args["path"] as? String,
            let resolved = validatePath(path, home: home)
        else { return jsonResult(["error": "Invalid path"]) }

        let result = try await SandboxManager.shared.execAsAgent(agentName, command: "cat '\(resolved)'")
        return jsonResult([
            "content": result.stdout,
            "size": result.stdout.count,
        ])
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
        let recursive = args["recursive"] as? Bool ?? false

        guard let resolved = validatePath(path, home: home)
        else { return jsonResult(["error": "Invalid path"]) }

        let cmd =
            recursive
            ? "find '\(resolved)' -maxdepth 3 -printf '%T@ %y %s %p\\n' 2>/dev/null | sort -rn | head -200"
            : "ls -la '\(resolved)' 2>/dev/null"

        let result = try await SandboxManager.shared.execAsAgent(agentName, command: cmd)
        return jsonResult(["entries": result.stdout])
    }
}

// MARK: - sandbox_search_files

private struct SandboxSearchFilesTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_search_files"
    let description = "Search file contents with grep in the sandbox environment."
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

        var cmd = "grep -rn"
        if let include = args["include"] as? String {
            cmd += " --include='\(include)'"
        }
        cmd += " '\(pattern)' '\(resolved)' 2>/dev/null | head -100"

        let result = try await SandboxManager.shared.execAsAgent(agentName, command: cmd)
        return jsonResult(["matches": result.stdout])
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
                    "description": .string("File contents to write"),
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
        _ = try await SandboxManager.shared.execAsAgent(agentName, command: "mkdir -p '\(dir)'")

        let escaped = content.replacingOccurrences(of: "'", with: "'\\''")
        let result = try await SandboxManager.shared.execAsAgent(
            agentName,
            command: "printf '%s' '\(escaped)' > '\(resolved)'"
        )
        guard result.succeeded else {
            return jsonResult(["error": result.stderr])
        }
        return jsonResult(["path": resolved, "size": content.count])
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

        let result = try await SandboxManager.shared.execAsAgent(
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

        let recursive = args["recursive"] as? Bool ?? false
        let cmd = recursive ? "rm -rf '\(resolved)'" : "rm -f '\(resolved)'"
        let result = try await SandboxManager.shared.execAsAgent(agentName, command: cmd)
        guard result.succeeded else {
            return jsonResult(["error": result.stderr])
        }
        return jsonResult(["deleted": resolved])
    }
}

// MARK: - sandbox_exec

private struct SandboxExecTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_exec"
    let description = "Run a shell command in the agent's sandbox environment."
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
                    "type": .string("number"),
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
            (args["timeout"] as? Int) ?? 30,
            min(maxTimeout, 300)
        )

        let result = try await SandboxManager.shared.exec(
            user: "agent-\(agentName)",
            command: command,
            cwd: cwd,
            timeout: TimeInterval(timeout),
            streamToLogs: true,
            logSource: agentName
        )

        return jsonResult([
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exit_code": Int(result.exitCode),
        ])
    }
}

// MARK: - sandbox_exec_background

private struct SandboxExecBackgroundTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_exec_background"
    let description = "Start a background process in the sandbox. Log output is written to the agent's home directory."
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

        let result = try await SandboxManager.shared.exec(
            user: "agent-\(agentName)",
            command: fullCmd,
            timeout: 10,
            streamToLogs: true,
            logSource: agentName
        )
        let pid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return jsonResult(["pid": pid, "log_file": logFile])
    }
}

// MARK: - sandbox_exec_kill

private struct SandboxExecKillTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_exec_kill"
    let description = "Kill a background process in the sandbox."
    let agentName: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "pid": .object(["type": .string("integer"), "description": .string("Process ID to kill")])
            ]),
            "required": .array([.string("pid")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let pid = args["pid"] as? Int
        else { return jsonResult(["error": "PID required"]) }

        let result = try await SandboxManager.shared.exec(
            user: "agent-\(agentName)",
            command: "kill \(pid) 2>/dev/null"
        )
        return jsonResult(["killed": result.succeeded])
    }
}

// MARK: - sandbox_install

private struct SandboxInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_install"
    let description = "Install system packages via apk (runs as root)."
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
            let packages = args["packages"] as? [String], !packages.isEmpty
        else { return jsonResult(["error": "Packages array required"]) }

        let pkgList = packages.joined(separator: " ")
        let result = try await SandboxManager.shared.execAsRoot(
            command: "apk add --no-cache \(pkgList)",
            timeout: 120,
            streamToLogs: true,
            logSource: "apk"
        )
        return jsonResult([
            "installed": packages,
            "exit_code": Int(result.exitCode),
            "output": result.stdout,
        ])
    }
}

// MARK: - sandbox_pip_install

private struct SandboxPipInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_pip_install"
    let description = "Install Python packages via pip (runs as agent user)."
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
            let packages = args["packages"] as? [String], !packages.isEmpty
        else { return jsonResult(["error": "Packages array required"]) }

        let pkgList = packages.joined(separator: " ")
        let result = try await SandboxManager.shared.execAsAgent(
            agentName,
            command: "pip install --user \(pkgList)",
            timeout: 120,
            streamToLogs: true,
            logSource: "pip"
        )
        return jsonResult([
            "installed": packages,
            "exit_code": Int(result.exitCode),
            "output": result.stdout,
        ])
    }
}

// MARK: - sandbox_npm_install

private struct SandboxNpmInstallTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_npm_install"
    let description = "Install Node packages via npm (runs as agent user)."
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
            let packages = args["packages"] as? [String], !packages.isEmpty
        else { return jsonResult(["error": "Packages array required"]) }

        let pkgList = packages.joined(separator: " ")
        let result = try await SandboxManager.shared.execAsAgent(
            agentName,
            command: "npm install \(pkgList)",
            timeout: 120,
            streamToLogs: true,
            logSource: "npm"
        )
        return jsonResult([
            "installed": packages,
            "exit_code": Int(result.exitCode),
            "output": result.stdout,
        ])
    }
}

// MARK: - sandbox_whoami

private struct SandboxWhoamiTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_whoami"
    let description = "Get current agent identity and sandbox environment info."
    let agentName: String
    let home: String

    var parameters: JSONValue? { nil }

    func execute(argumentsJSON: String) async throws -> String {
        var info: [String: Any] = [
            "agent_name": agentName,
            "linux_user": "agent-\(agentName)",
            "home": home,
        ]

        if let pluginsResult = try? await SandboxManager.shared.execAsAgent(
            agentName,
            command: "ls \(home)/plugins 2>/dev/null"
        ), pluginsResult.succeeded {
            let plugins = pluginsResult.stdout.split(separator: "\n").map(String.init)
            info["plugins"] = plugins
        }

        if let diskResult = try? await SandboxManager.shared.execAsAgent(
            agentName,
            command: "du -sh \(home) 2>/dev/null | cut -f1"
        ), diskResult.succeeded {
            info["disk_usage"] = diskResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return jsonResult(info)
    }
}

// MARK: - sandbox_processes

private struct SandboxProcessesTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_processes"
    let description = "List running processes for this agent in the sandbox."
    let agentName: String

    var parameters: JSONValue? { nil }

    func execute(argumentsJSON: String) async throws -> String {
        let result = try await SandboxManager.shared.exec(
            user: "agent-\(agentName)",
            command: "ps aux 2>/dev/null"
        )
        return jsonResult(["processes": result.stdout])
    }
}
