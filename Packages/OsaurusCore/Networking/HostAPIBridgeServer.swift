//
//  HostAPIBridgeServer.swift
//  osaurus
//
//  Lightweight HTTP server exposed to the container via a Unix domain socket
//  relayed through vsock. The osaurus-host CLI inside the container talks to
//  this server using `curl --unix-socket`.
//  Each request includes the calling Linux username for identity verification.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

public actor HostAPIBridgeServer {
    public static let shared = HostAPIBridgeServer()

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var boundSocketPath: String?

    public var isRunning: Bool { group != nil }

    /// Start the bridge server on a Unix domain socket.
    /// The socket is relayed into the container via vsock by the Containerization framework.
    /// If already running, stops the existing server first to ensure a clean socket.
    public func start(socketPath: String) async throws {
        if group != nil {
            await stop()
        }

        try? FileManager.default.removeItem(atPath: socketPath)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HostAPIBridgeHandler())
                }
            }

        let ch = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
        self.group = group
        self.channel = ch
        self.boundSocketPath = socketPath
        NSLog("[HostAPIBridge] Started on unix:\(socketPath)")
    }

    public func stop() async {
        if let ch = channel {
            _ = try? await ch.close()
            channel = nil
        }
        if let g = group {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                g.shutdownGracefully { _ in cont.resume() }
            }
            group = nil
        }
        if let path = boundSocketPath {
            try? FileManager.default.removeItem(atPath: path)
            boundSocketPath = nil
        }
        NSLog("[HostAPIBridge] Stopped")
    }
}

// MARK: - HTTP Handler

/// Wraps a non-Sendable NIO context so it can cross Task boundaries.
/// Safety: the wrapped value is only ever accessed on its owning EventLoop.
private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
}

private final class HostAPIBridgeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer.clear()
        case .body(var buf):
            bodyBuffer.writeBuffer(&buf)
        case .end:
            guard let head = requestHead else { return }
            let body =
                bodyBuffer.readableBytes > 0
                ? bodyBuffer.getString(at: bodyBuffer.readerIndex, length: bodyBuffer.readableBytes) ?? ""
                : ""
            handleRequest(context: context, head: head, body: body)
            requestHead = nil
        }
    }

    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead, body: String) {
        let callingUser = head.headers["X-Osaurus-User"].first ?? "unknown"
        let pluginName = head.headers["X-Osaurus-Plugin"].first
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let version = head.version
        let method = head.method
        let box = UnsafeSendableBox(value: context)
        let handler = UnsafeSendableBox(value: self)

        Task {
            let response = await handler.value.routeRequest(
                method: method,
                path: path,
                body: body,
                callingUser: callingUser,
                pluginName: pluginName
            )

            box.value.eventLoop.execute {
                let ctx = box.value
                let responseData = response.body.data(using: .utf8) ?? Data()
                var buf = ctx.channel.allocator.buffer(capacity: responseData.count)
                buf.writeBytes(responseData)

                let responseHead = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode),
                    headers: HTTPHeaders([
                        ("Content-Type", "application/json"),
                        ("Content-Length", "\(responseData.count)"),
                    ])
                )

                ctx.write(handler.value.wrapOutboundOut(.head(responseHead)), promise: nil)
                ctx.write(handler.value.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                ctx.writeAndFlush(handler.value.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }

    // MARK: - Routing

    private struct BridgeResponse {
        let statusCode: Int
        let body: String

        static func ok(_ body: String = "{}") -> BridgeResponse {
            BridgeResponse(statusCode: 200, body: body)
        }
        static func error(_ code: Int, _ message: String) -> BridgeResponse {
            let escaped =
                message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return BridgeResponse(statusCode: code, body: "{\"error\":\"\(escaped)\"}")
        }
    }

    private func routeRequest(
        method: HTTPMethod,
        path: String,
        body: String,
        callingUser: String,
        pluginName: String?
    ) async -> BridgeResponse {
        let components = path.split(separator: "/").map(String.init)
        // Expected: ["api", <service>, ...]
        guard components.count >= 2, components[0] == "api" else {
            return .error(404, "Not found")
        }

        let service = components[1]
        let remaining = Array(components.dropFirst(2))

        switch service {
        case "secrets":
            return await handleSecrets(
                method: method,
                remaining: remaining,
                callingUser: callingUser,
                pluginName: pluginName
            )
        case "config":
            return await handleConfig(
                method: method,
                remaining: remaining,
                body: body,
                callingUser: callingUser,
                pluginName: pluginName
            )
        case "inference":
            return await handleInference(method: method, remaining: remaining, body: body, callingUser: callingUser)
        case "agent":
            return await handleAgent(method: method, remaining: remaining, body: body, callingUser: callingUser)
        case "events":
            return await handleEvents(method: method, remaining: remaining, body: body, callingUser: callingUser)
        case "plugin":
            return await handlePlugin(method: method, remaining: remaining, body: body, callingUser: callingUser)
        case "log":
            return handleLog(method: method, body: body, callingUser: callingUser)
        default:
            return .error(404, "Unknown service: \(service)")
        }
    }

    // MARK: - Service Handlers

    private func handleSecrets(
        method: HTTPMethod,
        remaining: [String],
        callingUser: String,
        pluginName: String?
    ) async -> BridgeResponse {
        guard method == .GET, let name = remaining.first else {
            return .error(400, "GET /api/secrets/{name} expected")
        }
        guard let pluginName = pluginName else {
            return .error(400, "X-Osaurus-Plugin header required")
        }

        let agentId = resolveAgentUUID(callingUser)
        let value =
            ToolSecretsKeychain.getSecret(id: name, for: pluginName, agentId: agentId)
            ?? AgentSecretsKeychain.getSecret(id: name, agentId: agentId)
        if let value = value {
            return .ok("{\"value\":\(jsonEscape(value))}")
        }
        return .error(404, "Secret not found")
    }

    private func handleConfig(
        method: HTTPMethod,
        remaining: [String],
        body: String,
        callingUser: String,
        pluginName: String?
    ) async -> BridgeResponse {
        guard let key = remaining.first, let pluginName = pluginName else {
            return .error(400, "Plugin and key required")
        }

        // Plugin config is non-sensitive -- use a file-based JSON store, not Keychain
        let configDir = OsaurusPaths.pluginDataDirectory(for: pluginName)
        let configFile = configDir.appendingPathComponent("config.json")

        if method == .GET {
            guard let data = try? Data(contentsOf: configFile),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                let value = dict[key]
            else {
                return .error(404, "Config key not found")
            }
            return .ok("{\"value\":\(jsonEscape(value))}")
        } else if method == .POST {
            if let parsed = parseJSON(body), let value = parsed["value"] as? String {
                OsaurusPaths.ensureExistsSilent(configDir)
                var dict: [String: String] = [:]
                if let data = try? Data(contentsOf: configFile),
                    let existing = try? JSONSerialization.jsonObject(with: data) as? [String: String]
                {
                    dict = existing
                }
                dict[key] = value
                if let data = try? JSONSerialization.data(withJSONObject: dict) {
                    try? data.write(to: configFile, options: .atomic)
                }
                return .ok()
            }
            return .error(400, "Body must contain {\"value\": \"...\"}")
        }
        return .error(405, "Method not allowed")
    }

    private func handleInference(
        method: HTTPMethod,
        remaining: [String],
        body: String,
        callingUser: String
    ) async -> BridgeResponse {
        guard method == .POST, remaining.first == "chat" else {
            return .error(400, "POST /api/inference/chat expected")
        }
        guard SandboxRateLimiter.shared.checkLimit(agent: callingUser, service: "inference") else {
            return .error(429, "Rate limit exceeded for inference")
        }
        guard let parsed = parseJSON(body) else {
            return .error(400, "Invalid JSON body")
        }

        let model = parsed["model"] as? String ?? "default"
        let messagesRaw = parsed["messages"] as? [[String: Any]] ?? []

        var chatMessages: [ChatMessage] = []
        for msg in messagesRaw {
            if let role = msg["role"] as? String, let content = msg["content"] as? String {
                chatMessages.append(ChatMessage(role: role, content: content))
            }
        }

        guard !chatMessages.isEmpty else {
            return .error(400, "Messages array required")
        }

        do {
            let request = ChatCompletionRequest(
                model: model,
                messages: chatMessages,
                temperature: nil,
                max_tokens: nil,
                stream: false,
                top_p: nil,
                frequency_penalty: nil,
                presence_penalty: nil,
                stop: nil,
                n: nil,
                tools: nil,
                tool_choice: nil,
                session_id: nil
            )

            let engine = ChatEngine(source: .plugin)
            let response = try await engine.completeChat(request: request)
            let content = response.choices.first?.message.content ?? ""
            return .ok("{\"content\":\(jsonEscape(content))}")
        } catch {
            return .error(500, "Inference failed: \(error.localizedDescription)")
        }
    }

    private func handleAgent(
        method: HTTPMethod,
        remaining: [String],
        body: String,
        callingUser: String
    ) async -> BridgeResponse {
        guard let subcommand = remaining.first else {
            return .error(400, "Subcommand required: dispatch, memory")
        }

        switch subcommand {
        case "dispatch":
            return await handleAgentDispatch(body: body, callingUser: callingUser)
        case "memory":
            return await handleAgentMemory(
                method: method,
                remaining: Array(remaining.dropFirst()),
                body: body,
                callingUser: callingUser
            )
        default:
            return .error(404, "Unknown agent subcommand: \(subcommand)")
        }
    }

    private func handleAgentDispatch(body: String, callingUser: String) async -> BridgeResponse {
        guard SandboxRateLimiter.shared.checkLimit(agent: callingUser, service: "dispatch") else {
            return .error(429, "Rate limit exceeded for dispatch")
        }
        guard let parsed = parseJSON(body),
            let agentId = parsed["agent_id"] as? String,
            let task = parsed["task"] as? String
        else {
            return .error(400, "Body must contain agent_id and task")
        }

        // Empty/whitespace prompts make `ChatSession.send` no-op, leaving
        // the dispatched task hanging in `.running` until the watchdog.
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(400, "task is empty")
        }

        let request = DispatchRequest(
            prompt: task,
            agentId: UUID(uuidString: agentId),
            sourcePluginId: "sandbox:\(callingUser)",
            source: .plugin,
            externalSessionKey: parsed["external_session_key"] as? String
        )

        let manager = await MainActor.run { BackgroundTaskManager.shared }
        let handle = await manager.dispatchChat(request)
        let taskIdStr = handle?.id.uuidString ?? ""
        return .ok("{\"task_id\":\(jsonEscape(taskIdStr))}")
    }

    private func handleAgentMemory(
        method: HTTPMethod,
        remaining: [String],
        body: String,
        callingUser: String
    ) async -> BridgeResponse {
        guard let action = remaining.first else {
            return .error(400, "Action required: query or store")
        }

        switch action {
        case "query":
            guard let parsed = parseJSON(body), let query = parsed["query"] as? String else {
                return .error(400, "Body must contain query")
            }
            let results = await MemorySearchService.shared.searchMemoryEntries(
                query: query,
                topK: 10
            )
            let entries = results.map { entry -> [String: Any] in
                [
                    "content": entry.content,
                    "type": entry.type.rawValue,
                    "created_at": entry.createdAt,
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["results": entries]),
                let json = String(data: data, encoding: .utf8)
            {
                return .ok(json)
            }
            return .ok("{\"results\":[]}")

        case "store":
            guard let parsed = parseJSON(body), let content = parsed["content"] as? String else {
                return .error(400, "Body must contain content")
            }
            do {
                let agentId = resolveAgentUUID(callingUser)
                let entry = MemoryEntry(
                    agentId: agentId.uuidString,
                    type: .fact,
                    content: content,
                    model: "sandbox",
                    tagsJSON: "[\"source:sandbox:\(callingUser)\"]"
                )
                try MemoryDatabase.shared.insertMemoryEntry(entry)
                return .ok()
            } catch {
                return .error(500, "Memory store failed: \(error.localizedDescription)")
            }

        default:
            return .error(404, "Unknown memory action: \(action)")
        }
    }

    private func handleEvents(
        method: HTTPMethod,
        remaining: [String],
        body: String,
        callingUser: String
    ) async -> BridgeResponse {
        guard method == .POST, remaining.first == "emit" else {
            return .error(400, "POST /api/events/emit expected")
        }
        guard SandboxRateLimiter.shared.checkLimit(agent: callingUser, service: "http") else {
            return .error(429, "Rate limit exceeded")
        }
        guard let parsed = parseJSON(body),
            let eventType = parsed["type"] as? String
        else {
            return .error(400, "Body must contain type")
        }

        let payload = parsed["payload"]
        let payloadStr: String
        if let payloadDict = payload {
            if let data = try? JSONSerialization.data(withJSONObject: payloadDict),
                let str = String(data: data, encoding: .utf8)
            {
                payloadStr = str
            } else {
                payloadStr = "{}"
            }
        } else {
            payloadStr = "{}"
        }

        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("SandboxEvent.\(eventType)"),
                object: nil,
                userInfo: [
                    "source": "sandbox:\(callingUser)",
                    "type": eventType,
                    "payload": payloadStr,
                ]
            )
        }
        return .ok()
    }

    private func handlePlugin(
        method: HTTPMethod,
        remaining: [String],
        body: String,
        callingUser: String
    ) async -> BridgeResponse {
        guard method == .POST, remaining.first == "create" else {
            return .error(400, "POST /api/plugin/create expected")
        }

        let agentUUID = resolveAgentUUID(callingUser)
        let agentId = agentUUID.uuidString

        let execConfig = await MainActor.run { AgentManager.shared.effectiveAutonomousExec(for: agentUUID) }
        guard execConfig?.pluginCreate == true else {
            return .error(403, "Plugin creation is disabled for this agent")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = body.data(using: .utf8),
            let plugin = try? decoder.decode(SandboxPlugin.self, from: data)
        else {
            return .error(400, "Invalid plugin JSON")
        }

        // Reuse the shared registration pipeline so this endpoint matches
        // the in-process tool: validation, library save, restricted defaults,
        // install, hot-registration, toast, capability buffer, and rate
        // limiting all live in one place.
        do {
            let outcome = try await SandboxPluginRegistration.register(
                plugin: plugin,
                agentId: agentId,
                source: .hostBridge
            )
            return .ok(pluginCreateResponseBody(outcome: outcome))
        } catch let error as SandboxPluginRegistrationError {
            return .error(error.httpStatusCode, error.message)
        } catch {
            return .error(500, "Plugin registration failed: \(error.localizedDescription)")
        }
    }

    private func pluginCreateResponseBody(
        outcome: SandboxPluginRegistrationOutcome
    ) -> String {
        let payload: [String: Any] = [
            "status": "installed",
            "plugin_id": outcome.plugin.id,
            "plugin_name": outcome.plugin.name,
            "tools": outcome.registeredTools.map {
                ["name": $0.name, "description": $0.description]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
            let str = String(data: data, encoding: .utf8)
        else {
            return "{\"status\":\"installed\",\"plugin_id\":\(jsonEscape(outcome.plugin.id))}"
        }
        return str
    }

    private func handleLog(
        method: HTTPMethod,
        body: String,
        callingUser: String
    ) -> BridgeResponse {
        guard method == .POST else {
            return .error(405, "POST expected")
        }
        guard let parsed = parseJSON(body),
            let level = parsed["level"] as? String,
            let message = parsed["message"] as? String
        else {
            return .error(400, "Body must contain level and message")
        }

        NSLog("[Sandbox:\(callingUser)] [\(level)] \(message)")
        let user = callingUser
        Task { @MainActor in
            SandboxLogBuffer.shared.append(level: level, message: message, source: user)
        }
        return .ok()
    }

    // MARK: - Helpers

    /// Map a Linux username (e.g. "agent-researcher") back to an Osaurus agent UUID.
    /// Uses the persistent mapping populated when agent users are created.
    private func resolveAgentUUID(_ linuxUser: String) -> UUID {
        SandboxAgentMap.resolve(linuxName: linuxUser) ?? Agent.defaultId
    }

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    private func jsonEscape(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: string),
            let escaped = String(data: data, encoding: .utf8)
        else { return "\"\(string)\"" }
        return escaped
    }
}
