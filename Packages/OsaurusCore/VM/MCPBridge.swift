//
//  MCPBridge.swift
//  osaurus
//
//  Manages MCP server tool discovery and invocation inside agent VMs.
//  Each invocation pipes a JSON-RPC request through the MCP command via
//  conn.exec. Tool discovery (tools/list) runs once per plugin and is cached.
//

import Foundation

public actor MCPBridge {
    public static let shared = MCPBridge()

    /// Cached tool discovery results for a plugin.
    struct MCPPluginCache {
        let agentId: UUID
        let pluginName: String
        var discoveredTools: [MCPDiscoveredTool]
    }

    /// A tool discovered from an MCP server's tools/list response.
    struct MCPDiscoveredTool: @unchecked Sendable {
        let name: String
        let description: String
        let inputSchemaJSON: String?
    }

    private var cache: [String: MCPPluginCache] = [:]

    private init() {}

    private func cacheKey(agentId: UUID, pluginName: String) -> String {
        "\(agentId.uuidString):\(pluginName)"
    }

    // MARK: - Lifecycle

    /// Discover tools for an MCP plugin. Returns cached results on subsequent calls.
    func ensureRunning(
        agentId: UUID,
        plugin: SandboxPlugin
    ) async throws -> [MCPDiscoveredTool] {
        guard let mcp = plugin.mcp else { return [] }
        let key = cacheKey(agentId: agentId, pluginName: plugin.normalizedName)

        if let existing = cache[key] {
            return existing.discoveredTools
        }

        return try await discoverTools(agentId: agentId, plugin: plugin, mcp: mcp, key: key)
    }

    /// Clear cached tools for a plugin.
    public func stop(agentId: UUID, pluginName: String) async {
        let key = cacheKey(agentId: agentId, pluginName: pluginName)
        cache.removeValue(forKey: key)
    }

    /// Clear all cached tools for an agent.
    public func stopAll(for agentId: UUID) async {
        let agentPrefix = agentId.uuidString
        for key in cache.keys where key.hasPrefix(agentPrefix) {
            cache.removeValue(forKey: key)
        }
    }

    // MARK: - Tool Invocation

    /// Invoke an MCP tool by piping a JSON-RPC request to the MCP command.
    public func invokeTool(
        agentId: UUID,
        plugin: SandboxPlugin,
        toolName: String,
        arguments: [String: Any]
    ) async throws -> String {
        _ = try await ensureRunning(agentId: agentId, plugin: plugin)

        guard let conn = await MainActor.run(body: { VMManager.shared.vsockConnection(for: agentId) }) else {
            throw SandboxPluginError.vmNotAvailable
        }

        guard let mcp = plugin.mcp else {
            throw SandboxPluginError.setupFailed("Plugin has no MCP configuration")
        }

        let mcpRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "tools/call",
            "params": ["name": toolName, "arguments": arguments],
        ]

        guard let requestData = try? JSONSerialization.data(withJSONObject: mcpRequest),
              let requestStr = String(data: requestData, encoding: .utf8)
        else {
            throw SandboxPluginError.setupFailed("Failed to serialize MCP request")
        }

        let env = buildMCPEnv(plugin: plugin, mcp: mcp, agentId: agentId)
        let result = try await pipeMCPRequest(
            conn: conn, requestStr: requestStr, mcp: mcp,
            pluginName: plugin.normalizedName, env: env, timeout: 60
        )

        return result.stdout
    }

    // MARK: - Internal

    /// Run tools/list against the MCP command and cache the results.
    private func discoverTools(
        agentId: UUID,
        plugin: SandboxPlugin,
        mcp: MCPSpec,
        key: String
    ) async throws -> [MCPDiscoveredTool] {
        guard let conn = await MainActor.run(body: { VMManager.shared.vsockConnection(for: agentId) }) else {
            throw SandboxPluginError.vmNotAvailable
        }

        let listRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "discovery",
            "method": "tools/list",
            "params": [:] as [String: Any],
        ]

        var tools: [MCPDiscoveredTool] = []
        let env = buildMCPEnv(plugin: plugin, mcp: mcp, agentId: agentId)

        if let requestData = try? JSONSerialization.data(withJSONObject: listRequest),
           let requestStr = String(data: requestData, encoding: .utf8) {
            let result = try await pipeMCPRequest(
                conn: conn, requestStr: requestStr, mcp: mcp,
                pluginName: plugin.normalizedName, env: env, timeout: 15
            )

            if let responseData = result.stdout.data(using: .utf8),
               let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let resultObj = responseJSON["result"] as? [String: Any],
               let toolArray = resultObj["tools"] as? [[String: Any]] {
                tools = toolArray.compactMap { tool in
                    guard let name = tool["name"] as? String,
                          let desc = tool["description"] as? String
                    else { return nil }
                    let schemaJSON: String?
                    if let schema = tool["inputSchema"],
                       let data = try? JSONSerialization.data(withJSONObject: schema) {
                        schemaJSON = String(data: data, encoding: .utf8)
                    } else {
                        schemaJSON = nil
                    }
                    return MCPDiscoveredTool(name: name, description: desc, inputSchemaJSON: schemaJSON)
                }
            }
        }

        cache[key] = MCPPluginCache(
            agentId: agentId,
            pluginName: plugin.normalizedName,
            discoveredTools: tools
        )
        return tools
    }

    /// Pipe a JSON-RPC request string through the MCP command via conn.exec.
    private func pipeMCPRequest(
        conn: VsockConnection,
        requestStr: String,
        mcp: MCPSpec,
        pluginName: String,
        env: [String: String],
        timeout: Int
    ) async throws -> ExecResult {
        let escapedRequest = requestStr.replacingOccurrences(of: "'", with: "'\\''")
        let escapedCommand = mcp.command.replacingOccurrences(of: "'", with: "'\\''")
        return try await conn.exec(
            command: "printf '%s' '\(escapedRequest)' | \(escapedCommand)",
            cwd: "/workspace/plugins/\(pluginName)",
            env: env,
            timeout: timeout
        )
    }

    /// Build env vars for MCP calls: plugin secrets.
    private func buildMCPEnv(plugin: SandboxPlugin, mcp: MCPSpec, agentId: UUID) -> [String: String] {
        var env: [String: String] = [
            "OSAURUS_PLUGIN": plugin.normalizedName,
        ]
        if let secrets = plugin.secrets {
            for secretName in secrets {
                if let value = ToolSecretsKeychain.getSecret(id: secretName, for: plugin.normalizedName, agentId: agentId) {
                    env[secretName] = value
                }
            }
        }
        return env
    }
}
