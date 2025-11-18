//
//  MCPServerManager.swift
//  OsaurusCore
//
//  Hosts the MCP server and transports, exposing only enabled tools.
//

import Foundation

#if canImport(MCP)
import MCP
#endif

@MainActor
final class MCPServerManager {
    static let shared = MCPServerManager()

    private init() {}

    // MARK: - MCP Core
    #if canImport(MCP)
    private var server: MCP.Server?
    private var stdioTask: Task<Void, Never>?
    #endif

    // MARK: - Lifecycle
    func startStdio() async throws {
        #if canImport(MCP)
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
                _ = self // keep self captured
            }
        }
        server = srv
        #else
        // MCP SDK not available; nothing to start
        #endif
    }

    func stopAll() async {
        #if canImport(MCP)
        if let stdioTask {
            stdioTask.cancel()
            self.stdioTask = nil
        }
        if let server {
            await server.stop()
            self.server = nil
        }
        #endif
    }

    // MARK: - Dynamic Tool Changes
    func notifyToolsListChanged() async {
        // The MCP Swift SDK advertises listChanged in capabilities; most clients will re-list
        // on reconnect or UI trigger. This is a hook for future push events if added.
    }

    // MARK: - Internal
    #if canImport(MCP)
    private func registerHandlers(on server: MCP.Server) async {
        // ListTools returns only enabled tools from ToolRegistry
        await server.withMethodHandler(MCP.ListTools.self) { _ in
            let entries = await ToolRegistry.shared.listTools().filter { $0.enabled }
            let tools: [MCP.Tool] = entries.map { entry in
                // Input schema is optional; we'll omit for now
                MCP.Tool(name: entry.name, description: entry.description, inputSchema: nil)
            }
            return .init(tools: tools)
        }

        await server.withMethodHandler(MCP.CallTool.self) { params in
            // Try to stringify arguments; default to empty JSON object
            let argsJSON: String
            if let a = params.arguments {
                // Attempt to encode arguments to JSON string
                if let data = try? JSONEncoder().encode(a) {
                    argsJSON = String(decoding: data, as: UTF8.self)
                } else if let s = a as? String {
                    argsJSON = s
                } else {
                    argsJSON = "{}"
                }
            } else {
                argsJSON = "{}"
            }

            do {
                let result = try await ToolRegistry.shared.execute(name: params.name, argumentsJSON: argsJSON)
                return .init(content: [.text(result)], isError: false)
            } catch {
                return .init(content: [.text(error.localizedDescription)], isError: true)
            }
        }
    }
    #endif
}


