//
//  MCPServerManager.swift
//  OsaurusCore
//
//  Hosts the MCP server and transports, exposing only enabled tools.
//

import Foundation
import MCP
import os.log

private let mcpLog = Logger(subsystem: "ai.osaurus", category: "MCP")

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

        // Start stdio transport in background. Log any startup failure
        // (used to be a silent fail) so MCP wiring problems don't hide.
        let transport = MCP.StdioTransport()
        stdioTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await srv.start(transport: transport)
            } catch {
                mcpLog.error(
                    "stdio transport failed to start: \(error.localizedDescription, privacy: .public)"
                )
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

    // MARK: - Internal
    private func registerHandlers(on server: MCP.Server) async {
        // ListTools returns only enabled, externally exposable tools from ToolRegistry.
        await server.withMethodHandler(MCP.ListTools.self) { _ in
            let entries = await ToolRegistry.shared.listTools().filter {
                Self.isToolVisibleToExternalMCP(name: $0.name, enabled: $0.enabled)
            }
            let tools: [MCP.Tool] = entries.map { entry in
                let schema: MCP.Value = entry.parameters.map { Self.toMCPValue($0) } ?? .null
                return MCP.Tool(name: entry.name, description: entry.description, inputSchema: schema)
            }
            return .init(tools: tools)
        }

        await server.withMethodHandler(MCP.CallTool.self) { params in
            // Try to stringify arguments; default to empty JSON object.
            // Encoding/parsing failures used to fall through silently — we
            // now log them under the `MCP` subsystem so a malformed args
            // payload from an MCP client is at least visible to operators.
            let argsData: Data? = {
                guard let a = params.arguments else { return nil }
                do {
                    return try JSONEncoder().encode(a)
                } catch {
                    mcpLog.error(
                        "tool '\(params.name, privacy: .public)' arguments failed to encode: \(error.localizedDescription, privacy: .public)"
                    )
                    return nil
                }
            }()
            let argumentsAny: Any = {
                guard let d = argsData else { return [String: Any]() }
                do {
                    return try JSONSerialization.jsonObject(with: d)
                } catch {
                    mcpLog.error(
                        "tool '\(params.name, privacy: .public)' arguments failed to parse as JSON object: \(error.localizedDescription, privacy: .public)"
                    )
                    return [String: Any]()
                }
            }()
            let argsJSON: String = {
                if let d = argsData {
                    return String(data: d, encoding: .utf8) ?? "{}"
                }
                return "{}"
            }()

            do {
                if let denial = Self.externalMCPDenialMessage(for: params.name) {
                    return .init(
                        content: [
                            .text(
                                text: denial,
                                annotations: nil,
                                _meta: nil
                            )
                        ],
                        isError: true
                    )
                }

                // Validate against tool schema when available
                if let schema = await ToolRegistry.shared.parametersForTool(name: params.name) {
                    let result = SchemaValidator.validate(arguments: argumentsAny, against: schema)
                    if result.isValid == false {
                        let message = result.errorMessage ?? "Invalid arguments"
                        return .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
                    }
                }

                let result = try await Self.executeToolAsExternalMCP(
                    name: params.name,
                    argumentsJSON: argsJSON
                )
                return .init(content: [.text(text: result, annotations: nil, _meta: nil)], isError: false)
            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }
    }

    nonisolated static func isToolVisibleToExternalMCP(name: String, enabled: Bool) -> Bool {
        enabled && !ToolRegistry.externallyDeniedToolNames.contains(name)
    }

    nonisolated static func externalMCPDenialMessage(for name: String) -> String? {
        guard ToolRegistry.externallyDeniedToolNames.contains(name) else { return nil }
        return "'\(name)' is not available to external callers. "
            + "App-only tools can only run from the Osaurus app."
    }

    static func executeToolAsExternalMCP(name: String, argumentsJSON: String) async throws -> String {
        try await ChatExecutionContext.$isExternalSurface.withValue(true) {
            try await ToolRegistry.shared.execute(name: name, argumentsJSON: argumentsJSON)
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
