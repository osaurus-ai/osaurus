//
//  MCPCommand.swift
//  osaurus
//
//  Implements MCP (Model Context Protocol) stdio server that proxies tool calls to the local HTTP server.
//

import Foundation
import MCP

public struct MCPCommand: Command {
    public static let name = "mcp"

    public static func execute(args: [String]) async {
        fputs("[MCP] Starting MCP command...\n", stderr)
        // Ensure app server is up; auto-launch only if not already running
        let port = await ServerControl.ensureServerReadyOrExit(pollSeconds: 5.0)
        fputs("[MCP] Server ready on port \(port)\n", stderr)
        let baseURL = "http://127.0.0.1:\(port)"

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "cli"
        fputs("[MCP] Creating server with version: \(version)\n", stderr)

        // Build MCP server
        let server = MCP.Server(
            name: "Osaurus MCP Proxy",
            version: version,
            capabilities: .init(tools: .init(listChanged: true))
        )

        // Register ListTools -> GET /mcp/tools
        await server.withMethodHandler(MCP.ListTools.self) { _ in
            fputs("[MCP] Handling ListTools\n", stderr)
            guard let url = URL(string: "\(baseURL)/mcp/tools") else {
                fputs("[MCP] Invalid tools URL\n", stderr)
                return .init(tools: [])
            }
            fputs("[MCP] Fetching tools from \(url)\n", stderr)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 5.0
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    fputs(
                        "[MCP] Failed to list tools: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)\n",
                        stderr
                    )
                    return .init(tools: [])
                }
                fputs("[MCP] Tools fetched successfully\n", stderr)
                let tools: [MCP.Tool]
                if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let arr = obj["tools"] as? [[String: Any]]
                {
                    tools = arr.map { item in
                        let name = (item["name"] as? String) ?? ""
                        let description = (item["description"] as? String) ?? ""
                        let schemaAny = item["inputSchema"]
                        let schema = toMCPValue(from: schemaAny)
                        return MCP.Tool(name: name, description: description, inputSchema: schema)
                    }
                } else {
                    tools = []
                }
                return .init(tools: tools)
            } catch {
                fputs("[MCP] Error fetching tools: \(error)\n", stderr)
                return .init(tools: [])
            }
        }

        // Register CallTool -> POST /mcp/call
        await server.withMethodHandler(MCP.CallTool.self) { params in
            fputs("[MCP] Handling CallTool: \(params.name)\n", stderr)
            struct CallBody: Encodable {
                let name: String
                let arguments: MCP.Value?
            }
            struct CallResponse: Decodable {
                struct Item: Decodable {
                    let type: String
                    let text: String?
                }
                let content: [Item]
                let isError: Bool
            }
            guard let url = URL(string: "\(baseURL)/mcp/call") else {
                return .init(content: [.text("Invalid URL")], isError: true)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30.0

            do {
                // Wrap dictionary arguments into a single MCP.Value object if present
                let argValue: MCP.Value? = params.arguments.map { .object($0) }
                let body = CallBody(name: params.name, arguments: argValue)
                request.httpBody = try JSONEncoder().encode(body)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let message = String(decoding: data, as: UTF8.self)
                    return .init(
                        content: [
                            .text("HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode)): \(message)")
                        ],
                        isError: true
                    )
                }
                let decoded = try JSONDecoder().decode(CallResponse.self, from: data)
                // Aggregate text items into a single text content to match our server's MCP usage
                let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
                if text.isEmpty {
                    return .init(content: [], isError: decoded.isError)
                } else {
                    return .init(content: [.text(text)], isError: decoded.isError)
                }
            } catch {
                fputs("[MCP] Error calling tool: \(error)\n", stderr)
                return .init(content: [.text(error.localizedDescription)], isError: true)
            }
        }

        // Start stdio transport
        do {
            fputs("[MCP] Starting Stdio transport...\n", stderr)
            let transport = MCP.StdioTransport()
            try await server.start(transport: transport)
            fputs("[MCP] Server started. If 'start' is non-blocking, we are now in the loop.\n", stderr)

            // Keep the process alive
            while true {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            fputs("MCP server error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    // Convert loosely-typed JSON (from JSONSerialization) into MCP.Value
    private static func toMCPValue(from any: Any?) -> MCP.Value {
        guard let value = any else { return .null }
        if value is NSNull { return .null }
        if let b = value as? Bool { return .bool(b) }
        if let i = value as? Int { return .double(Double(i)) }
        if let d = value as? Double { return .double(d) }
        if let s = value as? String { return .string(s) }
        if let arr = value as? [Any] {
            return .array(arr.map { toMCPValue(from: $0) })
        }
        if let dict = value as? [String: Any] {
            var mapped: [String: MCP.Value] = [:]
            for (k, v) in dict {
                mapped[k] = toMCPValue(from: v)
            }
            return .object(mapped)
        }
        // NSNumber (covers both ints and doubles when decoded by JSONSerialization)
        if let n = value as? NSNumber {
            if CFNumberGetType(n) == .charType { return .bool(n.boolValue) }
            return .double(n.doubleValue)
        }
        return .null
    }
}
