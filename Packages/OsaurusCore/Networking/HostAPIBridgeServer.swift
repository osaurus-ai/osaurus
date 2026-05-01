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
private final class UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    init(value: T) { self.value = value }
}

private final class HostAPIBridgeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Cap the request body to keep a misbehaving guest plugin from
    /// exhausting host memory. 8 MiB is far above any legitimate bridge
    /// payload (the largest is `plugin/create` which is a small JSON blob).
    private static let maxBodyBytes = 8 * 1024 * 1024

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer = ByteBuffer()
    private var bodyBytesSeen = 0
    private var rejectedTooLarge = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer.clear()
            bodyBytesSeen = 0
            rejectedTooLarge = false

            // Pre-auth Content-Length guard. Same rationale as the public
            // HTTP server: refuse before allocating into the body buffer.
            if let lengthStr = head.headers.first(name: "Content-Length"),
                let length = Int(lengthStr),
                length > Self.maxBodyBytes
            {
                rejectTooLarge(context: context, head: head, declared: length)
                return
            }

        case .body(var buf):
            if rejectedTooLarge { return }
            bodyBytesSeen += buf.readableBytes
            if bodyBytesSeen > Self.maxBodyBytes, let head = requestHead {
                rejectTooLarge(context: context, head: head, declared: bodyBytesSeen)
                return
            }
            bodyBuffer.writeBuffer(&buf)

        case .end:
            if rejectedTooLarge {
                requestHead = nil
                bodyBuffer.clear()
                return
            }
            guard let head = requestHead else { return }
            let body =
                bodyBuffer.readableBytes > 0
                ? bodyBuffer.getString(at: bodyBuffer.readerIndex, length: bodyBuffer.readableBytes) ?? ""
                : ""
            handleRequest(context: context, head: head, body: body)
            requestHead = nil
        }
    }

    private func rejectTooLarge(context: ChannelHandlerContext, head: HTTPRequestHead, declared: Int) {
        rejectedTooLarge = true
        bodyBuffer.clear()
        let response = BridgeResponse.error(
            413,
            "Request body too large (\(declared) > \(Self.maxBodyBytes) bytes)"
        )
        let bytes = response.body.data(using: .utf8) ?? Data()
        var buf = context.channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        let responseHead = HTTPResponseHead(
            version: head.version,
            status: .payloadTooLarge,
            headers: HTTPHeaders([
                ("Content-Type", "application/json"),
                ("Content-Length", String(bytes.count)),
                ("Connection", "close"),
            ])
        )
        let box = UnsafeSendableBox(value: context)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            box.value.close(promise: nil)
        }
    }

    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead, body: String) {
        // Identity comes exclusively from the bearer token. The shim reads it
        // from a per-user file inside the guest VM (mode 0600). We deliberately
        // ignore X-Osaurus-User even if present — trusting it would let any
        // sandboxed code claim any agent.
        let bearerToken = Self.extractBearerToken(headers: head.headers)
        let pluginName = head.headers["X-Osaurus-Plugin"].first
        // `sandbox_execute_code` scripts identify themselves with this
        // header so the host can scope the per-script tool-call budget
        // and re-apply the chat-engine task locals.
        let scriptId = head.headers["X-Osaurus-Script-Id"].first
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let version = head.version
        let method = head.method
        let box = UnsafeSendableBox(value: context)
        let handler = UnsafeSendableBox(value: self)

        Task {
            let response: BridgeResponse
            if let token = bearerToken,
                let identity = await SandboxBridgeTokenStore.shared.resolve(token: token)
            {
                response = await handler.value.routeRequest(
                    method: method,
                    path: path,
                    body: body,
                    identity: identity,
                    pluginName: pluginName,
                    scriptId: scriptId
                )
            } else {
                // Fail closed: no token, or token does not resolve to any
                // known agent. We never fall back to a default identity.
                response = .error(401, "Bridge token missing or unrecognised")
            }

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

    /// Pull the bearer credential out of an `Authorization` header. Tolerant of
    /// case differences in the scheme (`Bearer`, `bearer`) and surrounding
    /// whitespace; returns `nil` when no usable token is present.
    fileprivate static func extractBearerToken(headers: HTTPHeaders) -> String? {
        guard let raw = headers.first(name: "Authorization") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let prefix = "bearer "
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let token = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : String(token)
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
        identity: SandboxBridgeTokenStore.Identity,
        pluginName: String?,
        scriptId: String? = nil
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
                identity: identity,
                pluginName: pluginName
            )
        case "config":
            // Config is keyed by plugin name only — no per-agent scoping
            // today, so identity is intentionally not threaded through.
            return await handleConfig(
                method: method,
                remaining: remaining,
                body: body,
                pluginName: pluginName
            )
        case "inference":
            return await handleInference(method: method, remaining: remaining, body: body, identity: identity)
        case "agent":
            return await handleAgent(method: method, remaining: remaining, body: body, identity: identity)
        case "events":
            return await handleEvents(method: method, remaining: remaining, body: body, identity: identity)
        case "plugin":
            return await handlePlugin(method: method, remaining: remaining, body: body, identity: identity)
        case "log":
            return handleLog(method: method, body: body, identity: identity)
        case "sandbox-tool":
            return await handleSandboxToolCall(
                method: method,
                remaining: remaining,
                body: body,
                identity: identity,
                scriptId: scriptId
            )
        default:
            return .error(404, "Unknown service: \(service)")
        }
    }

    // MARK: - Service Handlers

    private func handleSecrets(
        method: HTTPMethod,
        remaining: [String],
        identity: SandboxBridgeTokenStore.Identity,
        pluginName: String?
    ) async -> BridgeResponse {
        guard method == .GET, let name = remaining.first else {
            return .error(400, "GET /api/secrets/{name} expected")
        }
        guard let pluginName = pluginName else {
            return .error(400, "X-Osaurus-Plugin header required")
        }

        let value =
            ToolSecretsKeychain.getSecret(id: name, for: pluginName, agentId: identity.agentId)
            ?? AgentSecretsKeychain.getSecret(id: name, agentId: identity.agentId)
        if let value = value {
            return .ok("{\"value\":\(jsonEscape(value))}")
        }
        return .error(404, "Secret not found")
    }

    private func handleConfig(
        method: HTTPMethod,
        remaining: [String],
        body: String,
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
        identity: SandboxBridgeTokenStore.Identity
    ) async -> BridgeResponse {
        guard method == .POST, remaining.first == "chat" else {
            return .error(400, "POST /api/inference/chat expected")
        }
        guard SandboxRateLimiter.shared.checkLimit(agent: identity.linuxName, service: "inference") else {
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
        identity: SandboxBridgeTokenStore.Identity
    ) async -> BridgeResponse {
        guard let subcommand = remaining.first else {
            return .error(400, "Subcommand required: dispatch, memory")
        }

        switch subcommand {
        case "dispatch":
            return await handleAgentDispatch(body: body, identity: identity)
        case "memory":
            return await handleAgentMemory(
                method: method,
                remaining: Array(remaining.dropFirst()),
                body: body,
                identity: identity
            )
        default:
            return .error(404, "Unknown agent subcommand: \(subcommand)")
        }
    }

    private func handleAgentDispatch(
        body: String,
        identity: SandboxBridgeTokenStore.Identity
    ) async -> BridgeResponse {
        guard SandboxRateLimiter.shared.checkLimit(agent: identity.linuxName, service: "dispatch") else {
            return .error(429, "Rate limit exceeded for dispatch")
        }
        guard let parsed = parseJSON(body),
            let task = parsed["task"] as? String
        else {
            return .error(400, "Body must contain task")
        }

        // The bridge ignores the caller's claimed `agent_id` — identity is
        // bound to the bridge token. If a body id is supplied, it must match
        // the resolved one; otherwise we reject so a confused client cannot
        // silently dispatch into the wrong agent.
        if let claimed = parsed["agent_id"] as? String,
            !claimed.isEmpty,
            claimed.lowercased() != identity.agentId.uuidString.lowercased()
        {
            return .error(403, "agent_id in body does not match token-bound identity")
        }

        // Empty/whitespace prompts make `ChatSession.send` no-op, leaving
        // the dispatched task hanging in `.running` until the watchdog.
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(400, "task is empty")
        }

        let request = DispatchRequest(
            prompt: task,
            agentId: identity.agentId,
            sourcePluginId: "sandbox:\(identity.linuxName)",
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
        identity: SandboxBridgeTokenStore.Identity
    ) async -> BridgeResponse {
        guard let action = remaining.first else {
            return .error(400, "Action required: query or store")
        }

        switch action {
        case "query":
            guard let parsed = parseJSON(body), let query = parsed["query"] as? String else {
                return .error(400, "Body must contain query")
            }
            // Confine results to the calling agent's pinned facts. Pre-fix
            // this route returned facts from every agent that matched the
            // query — direct cross-agent confidentiality leak.
            let results = await MemorySearchService.shared.searchPinnedFacts(
                query: query,
                agentId: identity.agentId.uuidString,
                topK: 10
            )
            let entries = results.map { fact -> [String: Any] in
                [
                    "content": fact.content,
                    "salience": fact.salience,
                    "created_at": fact.createdAt,
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
                let fact = PinnedFact(
                    agentId: identity.agentId.uuidString,
                    content: content,
                    salience: 0.7,
                    tagsCSV: "source:sandbox:\(identity.linuxName)"
                )
                try MemoryDatabase.shared.insertPinnedFact(fact)
                await MemorySearchService.shared.indexPinnedFact(fact)
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
        identity: SandboxBridgeTokenStore.Identity
    ) async -> BridgeResponse {
        guard method == .POST, remaining.first == "emit" else {
            return .error(400, "POST /api/events/emit expected")
        }
        guard SandboxRateLimiter.shared.checkLimit(agent: identity.linuxName, service: "http") else {
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
                    "source": "sandbox:\(identity.linuxName)",
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
        identity: SandboxBridgeTokenStore.Identity
    ) async -> BridgeResponse {
        guard method == .POST, remaining.first == "create" else {
            return .error(400, "POST /api/plugin/create expected")
        }

        let agentUUID = identity.agentId
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
        identity: SandboxBridgeTokenStore.Identity
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

        NSLog("[Sandbox:\(identity.linuxName)] [\(level)] \(message)")
        let user = identity.linuxName
        Task { @MainActor in
            SandboxLogBuffer.shared.append(level: level, message: message, source: user)
        }
        return .ok()
    }

    /// Dispatches a tool call from inside a `sandbox_execute_code` Python
    /// script. The script supplies an `X-Osaurus-Script-Id` header that
    /// scopes the per-script tool-call budget AND carries the chat-engine
    /// task locals captured when the script started — so dispatched tools
    /// resolve to the same session as a direct top-level call would have.
    ///
    /// Only the names in `BuiltinSandboxTools.executeCodeBridgeAllowedTools`
    /// are accepted here (file/exec/install helpers — explicitly NOT
    /// `share_artifact`, the launcher itself, or any chat-layer-intercepted
    /// tool whose post-execute UI hook only fires for top-level calls).
    /// We deliberately do NOT route plugin / MCP / folder tools through
    /// this path — that would let a Python script invoke any plugin the
    /// host has installed, even ones the active agent never authorised.
    private func handleSandboxToolCall(
        method: HTTPMethod,
        remaining: [String],
        body: String,
        identity: SandboxBridgeTokenStore.Identity,
        scriptId: String?
    ) async -> BridgeResponse {
        guard method == .POST else {
            return .error(405, "POST /api/sandbox-tool/{name} expected")
        }
        guard let toolName = remaining.first, !toolName.isEmpty else {
            return .error(400, "Tool name segment required")
        }
        guard let scriptId, !scriptId.isEmpty else {
            return .error(
                400,
                "X-Osaurus-Script-Id header required — sandbox-tool calls must "
                    + "originate from inside a sandbox_execute_code invocation"
            )
        }

        // The allow-list is hard-coded by `BuiltinSandboxTools` — adding
        // a new sandbox built-in must require an explicit opt-in there.
        // Read the doc-comment on `executeCodeBridgeAllowedTools` for why
        // chat-layer-intercepted tools and the launcher itself are excluded.
        guard BuiltinSandboxTools.executeCodeBridgeAllowedTools.contains(toolName) else {
            let allowed = BuiltinSandboxTools.executeCodeBridgeAllowedTools.sorted()
                .joined(separator: ", ")
            return .error(
                403,
                "Tool `\(toolName)` is not exposed to sandbox_execute_code helpers. "
                    + "Allowed: \(allowed)"
            )
        }

        // Per-script tool-call budget. `tryIncrement` returns false
        // when the script id isn't tracked (script already finished or
        // was never started here) OR the cap is exceeded — both cases
        // collapse into one rejection so the agent fixes its loop.
        guard await SandboxExecuteCodeBudget.shared.tryIncrement(scriptId: scriptId) else {
            return .error(
                429,
                "sandbox_execute_code per-script tool-call budget exceeded "
                    + "(\(SandboxExecuteCodeBudget.maxCallsPerScript) calls). Refactor your script "
                    + "to do less work per call, or call `sandbox_execute_code` again from the model."
            )
        }

        // Pull the chat-engine context that was captured when the script
        // started so dispatched tools see the same session/agent as the
        // launching call. Missing context -> session-aware tools surface
        // their existing "no active session" envelope, which is the
        // right signal for an unanchored bridge call.
        let context = await SandboxExecuteCodeBudget.shared.context(scriptId: scriptId)

        // The helper module wraps args as `{"arguments": {...}}`; ad-hoc
        // curl callers typically send `{...}` directly. Accept both —
        // unwrapping the outer envelope when present, otherwise passing
        // the body through. Empty body becomes `{}` so downstream
        // `requireArgumentsDictionary` parses it as a no-op rather than
        // an `invalid_args` failure.
        let argumentsJSON = unwrapArgumentsBody(body) ?? (body.isEmpty ? "{}" : body)

        // Re-apply the chat-engine task locals so dispatched tools see
        // the same session/agent as a direct top-level call would.
        // ToolRegistry is `@MainActor`, so the actual `execute` call hops
        // to MainActor automatically — no explicit `MainActor.run` here.
        let result: String
        do {
            result = try await ChatExecutionContext.$currentAgentId.withValue(context?.agentId ?? identity.agentId) {
                try await ChatExecutionContext.$currentSessionId.withValue(context?.sessionId) {
                    try await ChatExecutionContext.$currentAssistantTurnId.withValue(context?.assistantTurnId) {
                        try await ChatExecutionContext.$currentBatchId.withValue(context?.batchId) {
                            try await ToolRegistry.shared.execute(
                                name: toolName,
                                argumentsJSON: argumentsJSON
                            )
                        }
                    }
                }
            }
        } catch {
            return .error(500, "Tool dispatch threw: \(error.localizedDescription)")
        }

        // The tool result is already a JSON-serialised envelope — pass
        // it back verbatim. The helper will `json.loads` it and return
        // the dict to the caller.
        return BridgeResponse(statusCode: 200, body: result)
    }

    // MARK: - Helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    /// If `body` parses as `{"arguments": {...}}`, return the inner
    /// arguments object re-encoded as JSON. Returns `nil` when the body
    /// isn't JSON, doesn't have an `arguments` key, or that key isn't
    /// an object — caller falls back to passing the body through verbatim.
    private func unwrapArgumentsBody(_ body: String) -> String? {
        guard let parsed = parseJSON(body),
            let inner = parsed["arguments"] as? [String: Any],
            let data = try? JSONSerialization.data(withJSONObject: inner),
            let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    private func jsonEscape(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: string),
            let escaped = String(data: data, encoding: .utf8)
        else { return "\"\(string)\"" }
        return escaped
    }
}
