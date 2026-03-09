//
//  SandboxMCPManager.swift
//  osaurus
//
//  Manages MCP server processes that run inside the shared Linux container.
//  MCP servers are started lazily on first tool call, tracked by PID,
//  and auto-restarted on exit.
//

import Foundation

public actor SandboxMCPManager {
    public static let shared = SandboxMCPManager()

    /// Tracks a running MCP server process.
    private struct MCPProcess: Sendable {
        let agentName: String
        let pluginId: String
        let command: String
        let pid: String
        let startedAt: Date
        var restartCount: Int = 0
    }

    /// key = "agentName:pluginId"
    private var processes: [String: MCPProcess] = [:]

    /// Restart tracking: timestamps of recent restarts per key
    private var restartHistory: [String: [Date]] = [:]

    private static let maxRestartsInWindow = 5
    private static let restartWindowSeconds: TimeInterval = 300  // 5 minutes

    // MARK: - Start

    /// Start an MCP server for a sandbox plugin, if not already running.
    public func ensureRunning(
        agentName: String,
        pluginId: String,
        spec: SandboxMCPSpec,
        env: [String: String] = [:]
    ) async throws {
        let key = processKey(agentName: agentName, pluginId: pluginId)

        if let existing = processes[key] {
            if await isProcessAlive(agentName: agentName, pid: existing.pid) {
                return
            }
            processes.removeValue(forKey: key)
        }

        guard canRestart(key: key) else {
            throw SandboxMCPError.restartLimitExceeded(pluginId)
        }

        let pluginDir = OsaurusPaths.inContainerPluginDir(agentName, pluginId)
        var mergedEnv = env
        for (k, v) in (spec.env ?? [:]) {
            mergedEnv[k] = v
        }

        let envString = mergedEnv.map { "\($0.key)='\($0.value)'" }.joined(separator: " ")
        let fullCommand =
            "cd '\(pluginDir)' && \(envString) nohup \(spec.command) > /tmp/mcp-\(pluginId).log 2>&1 & echo $!"

        let result = try await SandboxManager.shared.exec(
            user: "agent-\(agentName)",
            command: fullCommand,
            timeout: 15
        )

        guard result.succeeded else {
            throw SandboxMCPError.startFailed(result.stderr)
        }

        let pid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty else {
            throw SandboxMCPError.startFailed("No PID returned")
        }

        let process = MCPProcess(
            agentName: agentName,
            pluginId: pluginId,
            command: spec.command,
            pid: pid,
            startedAt: Date()
        )
        processes[key] = process
        recordRestart(key: key)

        NSLog("[SandboxMCP] Started \(pluginId) for agent-\(agentName), PID=\(pid)")
    }

    // MARK: - Stop

    /// Stop an MCP server.
    public func stop(agentName: String, pluginId: String) async {
        let key = processKey(agentName: agentName, pluginId: pluginId)
        guard let process = processes[key] else { return }

        _ = try? await SandboxManager.shared.exec(
            user: "agent-\(agentName)",
            command: "kill \(process.pid) 2>/dev/null"
        )
        processes.removeValue(forKey: key)
        NSLog("[SandboxMCP] Stopped \(pluginId) for agent-\(agentName)")
    }

    /// Stop all MCP servers (e.g. on app quit or container restart).
    public func stopAll() async {
        for (_, process) in processes {
            _ = try? await SandboxManager.shared.exec(
                user: "agent-\(process.agentName)",
                command: "kill \(process.pid) 2>/dev/null"
            )
        }
        processes.removeAll()
        NSLog("[SandboxMCP] Stopped all MCP servers")
    }

    // MARK: - Health Check

    /// Check if a process is still alive.
    private func isProcessAlive(agentName: String, pid: String) async -> Bool {
        guard
            let result = try? await SandboxManager.shared.exec(
                user: "agent-\(agentName)",
                command: "kill -0 \(pid) 2>/dev/null"
            )
        else { return false }
        return result.succeeded
    }

    /// Returns info about running MCP servers.
    public func runningServers() -> [(agentName: String, pluginId: String, pid: String, uptime: TimeInterval)] {
        processes.values.map { p in
            (
                agentName: p.agentName,
                pluginId: p.pluginId,
                pid: p.pid,
                uptime: Date().timeIntervalSince(p.startedAt)
            )
        }
    }

    // MARK: - Restart Backoff

    private func canRestart(key: String) -> Bool {
        let now = Date()
        let history = restartHistory[key] ?? []
        let recentRestarts = history.filter {
            now.timeIntervalSince($0) < Self.restartWindowSeconds
        }
        return recentRestarts.count < Self.maxRestartsInWindow
    }

    private func recordRestart(key: String) {
        var history = restartHistory[key] ?? []
        history.append(Date())
        // Prune old entries
        let cutoff = Date().addingTimeInterval(-Self.restartWindowSeconds)
        history = history.filter { $0 > cutoff }
        restartHistory[key] = history
    }

    // MARK: - Helpers

    private func processKey(agentName: String, pluginId: String) -> String {
        "\(agentName):\(pluginId)"
    }
}

// MARK: - Errors

public enum SandboxMCPError: Error, LocalizedError {
    case startFailed(String)
    case restartLimitExceeded(String)

    public var errorDescription: String? {
        switch self {
        case .startFailed(let msg): "MCP server start failed: \(msg)"
        case .restartLimitExceeded(let plugin): "MCP server \(plugin) exceeded restart limit (5 in 5 min)"
        }
    }
}
