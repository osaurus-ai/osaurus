//
//  MCPServerManager.swift
//  OsaurusCore
//
//  Hosts the MCP server and transports, exposing only enabled tools.
//

import Foundation
import MCP

@MainActor
final class MCPServerManager {
    static let shared = MCPServerManager()

    private init() {}

    // MARK: - MCP Core
    private var server: MCP.Server?
    private var stdioTask: Task<Void, Never>?

    // MARK: - Lifecycle
    func startStdio() async throws {
        // If already running, ignore
        if server != nil { return }

        // Initialize MCP server
        let srv = MCP.Server(
            name: "Osaurus MCP",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            capabilities: .init(
                // We expose tools only; resources/prompts omitted for now
                tools: .init(listChanged: true)
            )
        )

        // Register handlers
        await registerHandlers(on: srv)

        // Start stdio transport in background
        let transport = MCP.StdioTransport()
        stdioTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await srv.start(transport: transport)
            } catch {
                // Silent fail in background; consider adding logging later
                _ = self  // keep self captured
            }
        }
        server = srv
    }

    func stopAll() async {
        if let stdioTask {
            stdioTask.cancel()
            self.stdioTask = nil
        }
        if let server {
            await server.stop()
            self.server = nil
        }
    }

    // MARK: - Dynamic Tool Changes
    func notifyToolsListChanged() async {
        // The MCP Swift SDK advertises listChanged in capabilities; most clients will re-list
        // on reconnect or UI trigger. This is a hook for future push events if added.
    }

    // MARK: - Internal
    private func registerHandlers(on server: MCP.Server) async {
        // ListTools returns only enabled tools from ToolRegistry
        await server.withMethodHandler(MCP.ListTools.self) { _ in
            let entries = await ToolRegistry.shared.listTools().filter { $0.enabled }
            let tools: [MCP.Tool] = entries.map { entry in
                let schema: MCP.Value = entry.parameters.map { Self.toMCPValue($0) } ?? .null
                return MCP.Tool(name: entry.name, description: entry.description, inputSchema: schema)
            }
            return .init(tools: tools)
        }

        await server.withMethodHandler(MCP.CallTool.self) { params in
            // Try to stringify arguments; default to empty JSON object
            let argsData: Data? = {
                guard let a = params.arguments else { return nil }
                return try? JSONEncoder().encode(a)
            }()
            let argumentsAny: Any = {
                guard let d = argsData,
                    let obj = try? JSONSerialization.jsonObject(with: d)
                else { return [String: Any]() }
                return obj
            }()
            let argsJSON: String = {
                if let d = argsData {
                    return String(decoding: d, as: UTF8.self)
                }
                return "{}"
            }()

            do {
                // Validate against tool schema when available
                if let schema = await ToolRegistry.shared.parametersForTool(name: params.name) {
                    let result = SchemaValidator.validate(arguments: argumentsAny, against: schema)
                    if result.isValid == false {
                        let message = result.errorMessage ?? "Invalid arguments"
                        return .init(content: [.text(message)], isError: true)
                    }
                }

                let result = try await ToolRegistry.shared.execute(name: params.name, argumentsJSON: argsJSON)
                return .init(content: [.text(result)], isError: false)
            } catch {
                return .init(content: [.text(error.localizedDescription)], isError: true)
            }
        }
    }

    // MARK: - Schema bridging
    nonisolated private static func toMCPValue(_ value: JSONValue) -> MCP.Value {
        switch value {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        case .number(let n):
            return .double(n)
        case .string(let s):
            return .string(s)
        case .array(let arr):
            return .array(arr.map { toMCPValue($0) })
        case .object(let obj):
            var mapped: [String: MCP.Value] = [:]
            for (k, v) in obj {
                mapped[k] = toMCPValue(v)
            }
            return .object(mapped)
        }
    }
}
