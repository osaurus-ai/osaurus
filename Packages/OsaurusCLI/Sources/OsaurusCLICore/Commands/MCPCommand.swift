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
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(EXIT_SUCCESS)
        }

        fputs("[MCP] Starting MCP command...\n", stderr)
        let credential = resolvedAccessKey(args: args)
        let networkExposed = Configuration.resolveExposeToNetwork()
        if let credential {
            fputs("[MCP] Using access key from \(credential.source)\n", stderr)
        } else if networkExposed {
            fputs(
                "[MCP] No access key configured; Server > Network exposure is enabled — provide --access-key or OSAURUS_MCP_ACCESS_KEY\n",
                stderr
            )
        } else {
            fputs("[MCP] No access key configured; relying on local loopback trust\n", stderr)
        }

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
            capabilities: .init(tools: .init(listChanged: false))
        )

        // Register ListTools -> GET /mcp/tools
        await server.withMethodHandler(MCP.ListTools.self) { _ in
            fputs("[MCP] Handling ListTools\n", stderr)
            guard let url = URL(string: "\(baseURL)/mcp/tools") else {
                throw MCPError.internalError("Invalid tools URL")
            }
            fputs("[MCP] Fetching tools from \(url)\n", stderr)
            let request = makeProxyRequest(url: url, method: "GET", timeout: 5.0, credential: credential)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw MCPError.internalError("Failed to list tools: non-HTTP response")
                }
                guard http.statusCode == 200 else {
                    let body = String(bytes: data, encoding: .utf8) ?? ""
                    throw MCPError.internalError(
                        "Failed to list tools: HTTP \(http.statusCode)\(body.isEmpty ? "" : ": \(body)")"
                    )
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
                    throw MCPError.internalError("Failed to list tools: unexpected response shape")
                }
                return .init(tools: tools)
            } catch let error as MCPError {
                throw error
            } catch {
                fputs("[MCP] Error fetching tools: \(error)\n", stderr)
                throw MCPError.internalError("Failed to list tools: \(error.localizedDescription)")
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
                return .init(content: [.text(text: "Invalid URL", annotations: nil, _meta: nil)], isError: true)
            }
            var request = makeProxyRequest(url: url, method: "POST", timeout: 30.0, credential: credential)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

            do {
                // Wrap dictionary arguments into a single MCP.Value object if present
                let argValue: MCP.Value? = params.arguments.map { .object($0) }
                let body = CallBody(name: params.name, arguments: argValue)
                request.httpBody = try JSONEncoder().encode(body)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let message = String(bytes: data, encoding: .utf8) ?? ""
                    return .init(
                        content: [
                            .text(
                                text:
                                    "HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode)): \(message)",
                                annotations: nil,
                                _meta: nil
                            )
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
                    return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: decoded.isError)
                }
            } catch {
                fputs("[MCP] Error calling tool: \(error)\n", stderr)
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
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

    struct AccessKeyCredential: Equatable {
        let token: String
        let source: String
    }

    static func resolvedAccessKey(
        args: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AccessKeyCredential? {
        for index in args.indices {
            let arg = args[index]
            if let value = accessKeyValue(fromInlineArgument: arg) {
                return AccessKeyCredential(token: value, source: accessKeySource(fromInlineArgument: arg))
            }
            guard accessKeyOptionNames.contains(arg), args.indices.contains(index + 1) else {
                continue
            }
            if let token = normalizedAccessKey(args[index + 1]) {
                return AccessKeyCredential(token: token, source: arg)
            }
        }

        for name in accessKeyEnvironmentNames {
            if let token = normalizedAccessKey(environment[name]) {
                return AccessKeyCredential(token: token, source: name)
            }
        }

        for name in authorizationEnvironmentNames {
            if let token = normalizedAuthorizationHeader(environment[name]) {
                return AccessKeyCredential(token: token, source: name)
            }
        }

        return nil
    }

    static func makeProxyRequest(
        url: URL,
        method: String,
        timeout: TimeInterval,
        credential: AccessKeyCredential?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        if let credential {
            request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static let accessKeyOptionNames: Set<String> = [
        "--access-key",
        "--api-key",
        "--token",
        "--bearer-token",
    ]

    private static let accessKeyEnvironmentNames = [
        "OSAURUS_MCP_ACCESS_KEY",
        "OSAURUS_ACCESS_KEY",
        "OSAURUS_API_KEY",
        "OSU_ACCESS_KEY",
        "OSU_API_KEY",
    ]

    private static let authorizationEnvironmentNames = [
        "OSAURUS_MCP_AUTHORIZATION",
        "AUTHORIZATION",
        "HTTP_AUTHORIZATION",
    ]

    private static func accessKeyValue(fromInlineArgument argument: String) -> String? {
        for option in accessKeyOptionNames {
            let prefix = option + "="
            guard argument.hasPrefix(prefix) else { continue }
            return normalizedAccessKey(String(argument.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func accessKeySource(fromInlineArgument argument: String) -> String {
        argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "--access-key"
    }

    private static func normalizedAccessKey(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private static func normalizedAuthorizationHeader(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            value.lowercased().hasPrefix("bearer ")
        else {
            return nil
        }
        return normalizedAccessKey(value)
    }

    private static func printUsage() {
        let usage = """
            Usage:
              osaurus mcp [--access-key KEY]

            Runs an MCP stdio server that proxies tool discovery and calls to
            the local Osaurus HTTP server. Local-only servers can rely on
            loopback trust. If Server > Network exposure is enabled, provide an
            access key with --access-key or OSAURUS_MCP_ACCESS_KEY.

            Accepted environment variables:
              OSAURUS_MCP_ACCESS_KEY, OSAURUS_ACCESS_KEY, OSAURUS_API_KEY,
              OSU_ACCESS_KEY, OSU_API_KEY, OSAURUS_MCP_AUTHORIZATION,
              HTTP_AUTHORIZATION, AUTHORIZATION
            """
        print(usage)
    }

    // Convert loosely-typed JSON (from JSONSerialization) into MCP.Value
    static func toMCPValue(from any: Any?) -> MCP.Value {
        guard let value = any else { return .null }
        if value is NSNull { return .null }
        // JSONSerialization decodes every JSON number AND boolean as NSNumber, so
        // this branch must run before any `as? Bool` / `as? Int` cast: in
        // Foundation's bridging both `NSNumber(value: 0) as? Bool` and
        // `NSNumber(value: 1) as? Bool` succeed, so a plain JSON integer 0 or 1
        // would otherwise be miscast to a boolean and corrupt the proxied tool
        // schema (e.g. {"minimum": 0} -> {"minimum": false}). Use the CFBoolean
        // type id to tell a real JSON boolean apart from the integers 0/1.
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .double(n.doubleValue)
        }
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
        return .null
    }
}
