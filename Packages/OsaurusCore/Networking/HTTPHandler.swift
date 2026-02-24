//
//  HTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// SwiftNIO HTTP request handler
final class HTTPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let configuration: ServerConfiguration
    private let chatEngine: ChatEngineProtocol
    private final class RequestState {
        var requestHead: HTTPRequestHead?
        var requestBodyBuffer: ByteBuffer?
        var corsHeaders: [(String, String)] = []
        var requestStartTime: Date = Date()
        var normalizedPath: String = ""
    }
    private let stateRef: NIOLoopBound<RequestState>

    init(
        configuration: ServerConfiguration,
        eventLoop: EventLoop,
        chatEngine: ChatEngineProtocol = ChatEngine()
    ) {
        self.configuration = configuration
        self.chatEngine = chatEngine
        self.stateRef = NIOLoopBound(RequestState(), eventLoop: eventLoop)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)

        switch part {
        case .head(let head):
            stateRef.value.requestHead = head
            stateRef.value.requestStartTime = Date()
            // Compute CORS headers for this request
            stateRef.value.corsHeaders = computeCORSHeaders(for: head, isPreflight: false)
            // Pre-size body buffer if Content-Length is available
            if let lengthStr = head.headers.first(name: "Content-Length"), let length = Int(lengthStr),
                length > 0
            {
                stateRef.value.requestBodyBuffer = context.channel.allocator.buffer(capacity: length)
            } else {
                stateRef.value.requestBodyBuffer = context.channel.allocator.buffer(capacity: 0)
            }

        case .body(var buffer):
            // Collect body data directly into a ByteBuffer
            if stateRef.value.requestBodyBuffer == nil {
                stateRef.value.requestBodyBuffer = context.channel.allocator.buffer(
                    capacity: buffer.readableBytes
                )
            }
            if var existing = stateRef.value.requestBodyBuffer {
                existing.writeBuffer(&buffer)
                stateRef.value.requestBodyBuffer = existing
            }

        case .end:
            guard let head = stateRef.value.requestHead else {
                sendBadRequest(context: context)
                return
            }

            // Extract and normalize path (support /, /v1, /api, /v1/api)
            let pathOnly = extractPath(from: head.uri)
            let path = normalize(pathOnly)
            stateRef.value.normalizedPath = path

            // Extract metadata for logging
            let startTime = stateRef.value.requestStartTime
            let method = head.method.rawValue
            let userAgent = head.headers.first(name: "User-Agent")

            // Handle CORS preflight (OPTIONS)
            if head.method == .OPTIONS {
                let cors = computeCORSHeaders(for: head, isPreflight: true)
                sendResponse(
                    context: context,
                    version: head.version,
                    status: .noContent,
                    headers: cors,
                    body: ""
                )
                // Skip logging for preflight requests
                stateRef.value.requestHead = nil
                stateRef.value.requestBodyBuffer = nil
                return
            }

            // Handle simple HEAD
            if head.method == .HEAD {
                var headers = [("Content-Type", "text/plain; charset=utf-8")]
                headers.append(contentsOf: stateRef.value.corsHeaders)
                sendResponse(
                    context: context,
                    version: head.version,
                    status: .noContent,
                    headers: headers,
                    body: ""
                )
                logRequest(
                    method: method,
                    path: path,
                    userAgent: userAgent,
                    requestBody: nil,
                    responseBody: "",
                    responseStatus: 204,
                    startTime: startTime
                )
            }
            // Handle core endpoints directly; fall back to Router only for legacy coverage
            else if head.method == .GET, path == "/" {
                var headers = [("Content-Type", "text/plain; charset=utf-8")]
                headers.append(contentsOf: stateRef.value.corsHeaders)
                let rootBody = "Osaurus Server is running! 🦕"
                sendResponse(
                    context: context,
                    version: head.version,
                    status: .ok,
                    headers: headers,
                    body: rootBody
                )
                logRequest(
                    method: method,
                    path: path,
                    userAgent: userAgent,
                    requestBody: nil,
                    responseBody: rootBody,
                    responseStatus: 200,
                    startTime: startTime
                )
            } else if head.method == .GET, path == "/health" {
                let obj: [String: Any] = ["status": "healthy", "timestamp": Date().ISO8601Format()]
                let data = try? JSONSerialization.data(withJSONObject: obj)
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: stateRef.value.corsHeaders)
                let healthBody = data.flatMap { String(decoding: $0, as: UTF8.self) } ?? "{}"
                sendResponse(
                    context: context,
                    version: head.version,
                    status: .ok,
                    headers: headers,
                    body: healthBody
                )
                logRequest(
                    method: method,
                    path: path,
                    userAgent: userAgent,
                    requestBody: nil,
                    responseBody: healthBody,
                    responseStatus: 200,
                    startTime: startTime
                )
            } else if head.method == .GET, path == "/models" {
                handleModelsEndpoint(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .GET, path == "/tags" {
                handleTagsEndpoint(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/show" {
                handleShowEndpoint(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/chat/completions" || path == "/v1/chat/completions" {
                handleChatCompletions(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/chat" {
                handleChatNDJSON(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .GET, path == "/mcp/health" {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: stateRef.value.corsHeaders)
                let mcpHealthBody = #"{"status":"ok"}"#
                sendResponse(
                    context: context,
                    version: head.version,
                    status: .ok,
                    headers: headers,
                    body: mcpHealthBody
                )
                logRequest(
                    method: method,
                    path: path,
                    userAgent: userAgent,
                    requestBody: nil,
                    responseBody: mcpHealthBody,
                    responseStatus: 200,
                    startTime: startTime
                )
            } else if head.method == .GET, path == "/mcp/tools" {
                handleMCPListTools(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/mcp/call" {
                handleMCPCallTool(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/messages" {
                handleAnthropicMessages(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/audio/transcriptions" {
                handleAudioTranscriptions(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/responses" {
                handleOpenResponses(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/memory/ingest" {
                handleMemoryIngest(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/memory/clear-chunks" {
                handleClearChunks(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .GET, path == "/agents" {
                handleListAgents(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else {
                var headers = [("Content-Type", "text/plain; charset=utf-8")]
                headers.append(contentsOf: stateRef.value.corsHeaders)
                let notFoundBody = "Not Found"
                sendResponse(
                    context: context,
                    version: head.version,
                    status: .notFound,
                    headers: headers,
                    body: notFoundBody
                )
                logRequest(
                    method: method,
                    path: path,
                    userAgent: userAgent,
                    requestBody: nil,
                    responseBody: notFoundBody,
                    responseStatus: 404,
                    startTime: startTime
                )
            }

            stateRef.value.requestHead = nil
            stateRef.value.requestBodyBuffer = nil
        }
    }

    // MARK: - Private Helpers

    private func extractPath(from uri: String) -> String {
        if let queryIndex = uri.firstIndex(of: "?") {
            return String(uri[..<queryIndex])
        }
        return uri
    }

    // Normalize common provider prefixes so we cover /, /v1, /api, /v1/api
    private func normalize(_ path: String) -> String {
        func stripPrefix(_ prefix: String, from s: String) -> String? {
            if s == prefix { return "/" }
            if s.hasPrefix(prefix + "/") {
                let idx = s.index(s.startIndex, offsetBy: prefix.count)
                let rest = String(s[idx...])
                return rest.isEmpty ? "/" : rest
            }
            return nil
        }
        if let r = stripPrefix("/v1/api", from: path) { return r }
        if let r = stripPrefix("/api", from: path) { return r }
        if let r = stripPrefix("/v1", from: path) { return r }
        return path
    }

    private func sendBadRequest(context: ChannelHandlerContext) {
        sendResponse(
            context: context,
            version: HTTPVersion(major: 1, minor: 1),
            status: .badRequest,
            headers: [("Content-Type", "text/plain; charset=utf-8")],
            body: "Bad Request"
        )
    }

    private func sendResponse(
        context: ChannelHandlerContext,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: String
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let bodyCopy = body
        let headersCopy = headers
        executeOnLoop(loop) {
            let context = ctx.value
            // Create response head
            var responseHead = HTTPResponseHead(version: version, status: status)

            // Create body buffer
            var buffer = context.channel.allocator.buffer(capacity: bodyCopy.utf8.count)
            buffer.writeString(bodyCopy)

            // Build headers
            var nioHeaders = HTTPHeaders()
            for (name, value) in headersCopy {
                nioHeaders.add(name: name, value: value)
            }
            nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
            nioHeaders.add(name: "Connection", value: "close")
            responseHead.headers = nioHeaders

            // Send response
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete {
                _ in
                ctx.value.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log and close the connection to avoid NIO debug preconditions crashing the app
        print("[Osaurus][NIO] errorCaught: \(error)")
        context.close(promise: nil)
    }

    // MARK: - CORS
    private func computeCORSHeaders(for head: HTTPRequestHead, isPreflight: Bool) -> [(
        String, String
    )] {
        guard !configuration.allowedOrigins.isEmpty else { return [] }
        let origin = head.headers.first(name: "Origin")
        var headers: [(String, String)] = []

        let allowsAny = configuration.allowedOrigins.contains("*")
        if allowsAny {
            headers.append(("Access-Control-Allow-Origin", "*"))
        } else if let origin,
            !origin.contains("\r"), !origin.contains("\n"),
            configuration.allowedOrigins.contains(origin)
        {
            headers.append(("Access-Control-Allow-Origin", origin))
            headers.append(("Vary", "Origin"))
        } else {
            // Not allowed; for preflight return no CORS headers which will cause browser to block
            return []
        }

        if isPreflight {
            // Methods
            let reqMethod = head.headers.first(name: "Access-Control-Request-Method")
            let allowMethods = sanitizeTokenList(reqMethod ?? "GET, POST, OPTIONS, HEAD")
            headers.append(("Access-Control-Allow-Methods", allowMethods))
            // Headers
            let reqHeaders = head.headers.first(name: "Access-Control-Request-Headers")
            let allowHeaders = sanitizeTokenList(reqHeaders ?? "Content-Type, Authorization")
            headers.append(("Access-Control-Allow-Headers", allowHeaders))
            headers.append(("Access-Control-Max-Age", "600"))
        }
        return headers
    }

    /// Allow only RFC7230 token characters plus comma and space for reflected header lists
    private func sanitizeTokenList(_ value: String) -> String {
        let allowedPunctuation = Set("!#$%&'*+-.^_`|~ ,")
        var result = String()
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x30 ... 0x39,  // 0-9
                0x41 ... 0x5A,  // A-Z
                0x61 ... 0x7A:  // a-z
                result.unicodeScalars.append(scalar)
            default:
                let ch = Character(scalar)
                if allowedPunctuation.contains(ch) {
                    result.append(ch)
                }
            }
        }
        // Trim leading/trailing spaces and collapse runs of spaces around commas
        let collapsed = result.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
        return collapsed
    }

    /// Expose CORS headers for use by async writers (must be accessed on event loop)
    var currentCORSHeaders: [(String, String)] { stateRef.value.corsHeaders }

    // MARK: - Chat handlers

    /// Inject assembled memory context into a chat request when an agent ID is provided
    /// via the `X-Osaurus-Agent-Id` header. Uses query-aware retrieval when the last
    /// user message is available, ensuring semantically relevant memories are included.
    private static func enrichWithMemoryContext(
        _ request: ChatCompletionRequest,
        agentId: String?
    ) async -> ChatCompletionRequest {
        guard let agentId, !agentId.isEmpty else { return request }

        let config = MemoryConfigurationStore.load()
        let query = request.messages.last(where: { $0.role == "user" })?.content ?? ""
        let memoryContext = await MemoryContextAssembler.assembleContext(
            agentId: agentId,
            config: config,
            query: query
        )
        guard !memoryContext.isEmpty else { return request }

        var enriched = request
        if let idx = enriched.messages.firstIndex(where: { $0.role == "system" }) {
            let existing = enriched.messages[idx].content ?? ""
            enriched.messages[idx] = ChatMessage(role: "system", content: memoryContext + "\n\n" + existing)
        } else {
            enriched.messages.insert(ChatMessage(role: "system", content: memoryContext), at: 0)
        }
        return enriched
    }

    // MARK: - Memory Ingestion

    /// Request body for the `/memory/ingest` endpoint.
    private struct MemoryIngestRequest: Codable {
        let agent_id: String
        let conversation_id: String
        let turns: [MemoryIngestTurn]
        let session_date: String?
        let skip_extraction: Bool?
    }

    private struct MemoryIngestTurn: Codable {
        let user: String
        let assistant: String
        let date: String?
    }

    /// Bulk-ingest conversation turns into the memory system.
    private func handleMemoryIngest(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let data: Data
        let requestBodyString: String?
        if let body = stateRef.value.requestBodyBuffer {
            var bodyCopy = body
            let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
            data = Data(bytes)
            requestBodyString = String(decoding: data, as: UTF8.self)
        } else {
            data = Data()
            requestBodyString = nil
        }

        guard let req = try? JSONDecoder().decode(MemoryIngestRequest.self, from: data) else {
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: [("Content-Type", "text/plain; charset=utf-8")],
                body: "Invalid request format. Expected {agent_id, conversation_id, turns: [{user, assistant}]}"
            )
            logRequest(
                method: "POST",
                path: "/memory/ingest",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid request format"
            )
            return
        }

        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString

        Task(priority: .userInitiated) {
            let db = MemoryDatabase.shared
            try? db.upsertConversation(
                id: req.conversation_id,
                agentId: req.agent_id,
                title: nil
            )

            let skipExtraction = req.skip_extraction ?? false

            try? db.deleteChunksForConversation(req.conversation_id)

            for (i, turn) in req.turns.enumerated() {
                let turnDate = turn.date ?? req.session_date

                let pairs: [(role: String, content: String, index: Int)] = [
                    ("user", turn.user, i * 2),
                    ("assistant", turn.assistant, i * 2 + 1),
                ]
                for (role, content, chunkIndex) in pairs {
                    let tokens = max(1, content.count / 4)
                    let chunk = ConversationChunk(
                        conversationId: req.conversation_id,
                        chunkIndex: chunkIndex,
                        role: role,
                        content: content,
                        tokenCount: tokens,
                        agentId: req.agent_id
                    )
                    try? db.insertChunk(
                        conversationId: req.conversation_id,
                        chunkIndex: chunkIndex,
                        role: role,
                        content: content,
                        tokenCount: tokens,
                        createdAt: turnDate
                    )
                    await MemorySearchService.shared.indexConversationChunk(chunk)
                }

                if !skipExtraction {
                    await MemoryService.shared.recordConversationTurn(
                        userMessage: turn.user,
                        assistantMessage: turn.assistant,
                        agentId: req.agent_id,
                        conversationId: req.conversation_id,
                        sessionDate: turnDate
                    )
                }
            }

            let responseBody = "{\"status\":\"ok\",\"turns_ingested\":\(req.turns.count)}"
            var headers: [(String, String)] = [("Content-Type", "application/json")]
            headers.append(contentsOf: cors)
            let headersCopy = headers
            hop {
                var responseHead = HTTPResponseHead(version: head.version, status: .ok)
                var buffer = ctx.value.channel.allocator.buffer(capacity: responseBody.utf8.count)
                buffer.writeString(responseBody)
                var nioHeaders = HTTPHeaders()
                for (name, value) in headersCopy { nioHeaders.add(name: name, value: value) }
                nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
                nioHeaders.add(name: "Connection", value: "close")
                responseHead.headers = nioHeaders
                let c = ctx.value
                c.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                c.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                c.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                    ctx.value.close(promise: nil)
                }
            }
            logSelf.logRequest(
                method: "POST",
                path: "/memory/ingest",
                userAgent: logUserAgent,
                requestBody: logRequestBody,
                responseBody: responseBody,
                responseStatus: 200,
                startTime: logStartTime
            )
        }
    }

    // MARK: - Clear Chunks

    private struct ClearChunksRequest: Codable {
        let agent_id: String
    }

    private func handleClearChunks(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let cors = stateRef.value.corsHeaders
        let data: Data
        let requestBodyString: String?
        if let body = stateRef.value.requestBodyBuffer {
            var bodyCopy = body
            let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
            data = Data(bytes)
            requestBodyString = String(decoding: data, as: UTF8.self)
        } else {
            data = Data()
            requestBodyString = nil
        }

        var headers: [(String, String)] = [("Content-Type", "application/json")]
        headers.append(contentsOf: cors)

        guard let req = try? JSONDecoder().decode(ClearChunksRequest.self, from: data) else {
            let body = "{\"error\":\"Invalid request body. Requires: agent_id\"}"
            sendResponse(context: context, version: head.version, status: .badRequest, headers: headers, body: body)
            logRequest(
                method: "POST",
                path: "/memory/clear-chunks",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseBody: body,
                responseStatus: 400,
                startTime: startTime
            )
            return
        }

        let db = MemoryDatabase.shared
        do {
            try db.deleteChunksForAgent(req.agent_id)
            let body = "{\"status\":\"ok\",\"agent_id\":\"\(req.agent_id)\"}"
            sendResponse(context: context, version: head.version, status: .ok, headers: headers, body: body)
            logRequest(
                method: "POST",
                path: "/memory/clear-chunks",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseBody: body,
                responseStatus: 200,
                startTime: startTime
            )
        } catch {
            let body = "{\"error\":\"Failed to clear chunks\"}"
            sendResponse(
                context: context,
                version: head.version,
                status: .internalServerError,
                headers: headers,
                body: body
            )
            logRequest(
                method: "POST",
                path: "/memory/clear-chunks",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseBody: body,
                responseStatus: 500,
                startTime: startTime
            )
        }
    }

    // MARK: - Agents

    private struct AgentListItem: Codable {
        let id: String
        let name: String
        let description: String
        let default_model: String?
        let is_built_in: Bool
        let memory_entry_count: Int
        let created_at: String
        let updated_at: String
    }

    private struct AgentListResponse: Codable {
        let agents: [AgentListItem]
    }

    private func handleListAgents(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent

        Task(priority: .userInitiated) {
            let agents = await MainActor.run { AgentManager.shared.agents }

            let db = MemoryDatabase.shared
            var memoryCounts: [String: Int] = [:]
            if db.isOpen, let counts = try? db.agentIdsWithEntries() {
                for (agentId, count) in counts {
                    memoryCounts[agentId] = count
                }
            }

            let formatter = ISO8601DateFormatter()
            let items = agents.map { agent in
                AgentListItem(
                    id: agent.id.uuidString,
                    name: agent.name,
                    description: agent.description,
                    default_model: agent.defaultModel,
                    is_built_in: agent.isBuiltIn,
                    memory_entry_count: memoryCounts[agent.id.uuidString] ?? 0,
                    created_at: formatter.string(from: agent.createdAt),
                    updated_at: formatter.string(from: agent.updatedAt)
                )
            }

            let response = AgentListResponse(agents: items)
            let json =
                (try? JSONEncoder().encode(response)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"agents":[]}"#

            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .ok,
                    headers: headers,
                    body: json
                )
            }
            logSelf.logRequest(
                method: "GET",
                path: "/agents",
                userAgent: logUserAgent,
                requestBody: nil,
                responseBody: json,
                responseStatus: 200,
                startTime: logStartTime
            )
        }
    }

    private func handleChatCompletions(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let data: Data
        let requestBodyString: String?
        if let body = stateRef.value.requestBodyBuffer {
            var bodyCopy = body
            let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
            data = Data(bytes)
            requestBodyString = String(decoding: data, as: UTF8.self)
        } else {
            data = Data()
            requestBodyString = nil
        }

        guard let req = try? JSONDecoder().decode(ChatCompletionRequest.self, from: data) else {
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: [("Content-Type", "text/plain; charset=utf-8")],
                body: "Invalid request format"
            )
            logRequest(
                method: "POST",
                path: "/chat/completions",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid request format"
            )
            return
        }

        let accept = head.headers.first(name: "Accept") ?? ""
        let wantsSSE = (req.stream ?? false) || accept.contains("text/event-stream")

        let created = Int(Date().timeIntervalSince1970)
        let responseId =
            "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let model = req.model

        let memoryAgentId = head.headers.first(name: "X-Osaurus-Agent-Id")

        if wantsSSE {
            let writer = SSEResponseWriter()
            let cors = stateRef.value.corsHeaders
            let loop = context.eventLoop
            let writerBound = NIOLoopBound(writer, eventLoop: loop)
            let ctx = NIOLoopBound(context, eventLoop: loop)
            let chatEngine = self.chatEngine
            let hop: (@escaping @Sendable () -> Void) -> Void = { block in
                if loop.inEventLoop { block() } else { loop.execute { block() } }
            }
            hop {
                writerBound.value.writeHeaders(ctx.value, extraHeaders: cors)
                writerBound.value.writeRole(
                    "assistant",
                    model: model,
                    responseId: responseId,
                    created: created,
                    context: ctx.value
                )
            }
            // Capture for logging
            let logStartTime = startTime
            let logUserAgent = userAgent
            let logRequestBody = requestBodyString
            let logModel = model
            let logTemperature = req.temperature ?? 0.7
            let logMaxTokens = req.max_tokens ?? 1024
            let logSelf = self
            Task(priority: .userInitiated) {
                do {
                    let enrichedReq = await Self.enrichWithMemoryContext(req, agentId: memoryAgentId)
                    let stream = try await chatEngine.streamChat(request: enrichedReq)
                    for try await delta in stream {
                        hop {
                            writerBound.value.writeContent(
                                delta,
                                model: model,
                                responseId: responseId,
                                created: created,
                                context: ctx.value
                            )
                        }
                    }
                    hop {
                        writerBound.value.writeFinish(
                            model,
                            responseId: responseId,
                            created: created,
                            context: ctx.value
                        )
                        writerBound.value.writeEnd(ctx.value)
                    }
                    logSelf.logRequest(
                        method: "POST",
                        path: "/chat/completions",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseStatus: 200,
                        startTime: logStartTime,
                        model: logModel,
                        temperature: logTemperature,
                        maxTokens: logMaxTokens,
                        finishReason: .stop
                    )
                } catch let inv as ServiceToolInvocation {
                    // Translate tool invocation to OpenAI-style streaming tool_calls deltas
                    // Use preserved tool call ID from stream if available
                    let callId: String
                    if let preservedId = inv.toolCallId, !preservedId.isEmpty {
                        callId = preservedId
                    } else {
                        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        callId = "call_" + String(raw.prefix(24))
                    }
                    let args = inv.jsonArguments
                    let chunkSize = 1024
                    hop {
                        writerBound.value.writeToolCallStart(
                            callId: callId,
                            functionName: inv.toolName,
                            index: 0,
                            model: model,
                            responseId: responseId,
                            created: created,
                            context: ctx.value
                        )
                    }
                    var i = args.startIndex
                    while i < args.endIndex {
                        let next = args.index(i, offsetBy: chunkSize, limitedBy: args.endIndex) ?? args.endIndex
                        let chunk = String(args[i ..< next])
                        hop {
                            writerBound.value.writeToolCallArgumentsDelta(
                                callId: callId,
                                index: 0,
                                argumentsChunk: chunk,
                                model: model,
                                responseId: responseId,
                                created: created,
                                context: ctx.value
                            )
                        }
                        i = next
                    }
                    hop {
                        writerBound.value.writeFinishWithReason(
                            "tool_calls",
                            model: model,
                            responseId: responseId,
                            created: created,
                            context: ctx.value
                        )
                        writerBound.value.writeEnd(ctx.value)
                    }
                    // Log tool call
                    let toolLog = ToolCallLog(name: inv.toolName, arguments: inv.jsonArguments)
                    logSelf.logRequest(
                        method: "POST",
                        path: "/chat/completions",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseStatus: 200,
                        startTime: logStartTime,
                        model: logModel,
                        toolCalls: [toolLog],
                        temperature: logTemperature,
                        maxTokens: logMaxTokens,
                        finishReason: .toolCalls
                    )
                } catch {
                    hop {
                        writerBound.value.writeError(error.localizedDescription, context: ctx.value)
                        writerBound.value.writeEnd(ctx.value)
                    }
                    logSelf.logRequest(
                        method: "POST",
                        path: "/chat/completions",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseStatus: 500,
                        startTime: logStartTime,
                        model: logModel,
                        temperature: logTemperature,
                        maxTokens: logMaxTokens,
                        finishReason: .error,
                        errorMessage: error.localizedDescription
                    )
                }
            }
        } else {
            let cors = stateRef.value.corsHeaders
            let loop = context.eventLoop
            let ctx = NIOLoopBound(context, eventLoop: loop)
            let chatEngine = self.chatEngine
            let hop: (@escaping @Sendable () -> Void) -> Void = { block in
                if loop.inEventLoop { block() } else { loop.execute { block() } }
            }
            // Capture for logging
            let logStartTime = startTime
            let logUserAgent = userAgent
            let logRequestBody = requestBodyString
            let logModel = model
            let logTemperature = req.temperature ?? 0.7
            let logMaxTokens = req.max_tokens ?? 1024
            let logSelf = self
            Task(priority: .userInitiated) {
                do {
                    let enrichedReq = await Self.enrichWithMemoryContext(req, agentId: memoryAgentId)
                    let resp = try await chatEngine.completeChat(request: enrichedReq)
                    let json = try JSONEncoder().encode(resp)
                    var headers: [(String, String)] = [("Content-Type", "application/json")]
                    headers.append(contentsOf: cors)
                    let headersCopy = headers
                    let body = String(decoding: json, as: UTF8.self)
                    hop {
                        var responseHead = HTTPResponseHead(version: head.version, status: .ok)
                        var buffer = ctx.value.channel.allocator.buffer(capacity: body.utf8.count)
                        buffer.writeString(body)
                        var nioHeaders = HTTPHeaders()
                        for (name, value) in headersCopy { nioHeaders.add(name: name, value: value) }
                        nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
                        nioHeaders.add(name: "Connection", value: "close")
                        responseHead.headers = nioHeaders
                        let c = ctx.value
                        c.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                        c.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                        c.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete {
                            _ in
                            ctx.value.close(promise: nil)
                        }
                    }
                    // Extract token counts and finish reason from response
                    let tokensIn = resp.usage.prompt_tokens
                    let tokensOut = resp.usage.completion_tokens
                    let finishReason: RequestLog.FinishReason = {
                        if let reason = resp.choices.first?.finish_reason {
                            switch reason {
                            case "stop": return .stop
                            case "length": return .length
                            case "tool_calls": return .toolCalls
                            default: return .stop
                            }
                        }
                        return .stop
                    }()
                    logSelf.logRequest(
                        method: "POST",
                        path: "/chat/completions",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseBody: body,
                        responseStatus: 200,
                        startTime: logStartTime,
                        model: logModel,
                        tokensInput: tokensIn,
                        tokensOutput: tokensOut,
                        temperature: logTemperature,
                        maxTokens: logMaxTokens,
                        finishReason: finishReason
                    )
                } catch {
                    let body = "Internal error: \(error.localizedDescription)"
                    let headers: [(String, String)] = [("Content-Type", "text/plain; charset=utf-8")]
                    let headersCopy = headers
                    hop {
                        var responseHead = HTTPResponseHead(version: head.version, status: .internalServerError)
                        var buffer = ctx.value.channel.allocator.buffer(capacity: body.utf8.count)
                        buffer.writeString(body)
                        var nioHeaders = HTTPHeaders()
                        for (name, value) in headersCopy { nioHeaders.add(name: name, value: value) }
                        nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
                        nioHeaders.add(name: "Connection", value: "close")
                        responseHead.headers = nioHeaders
                        let c = ctx.value
                        c.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                        c.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                        c.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete {
                            _ in
                            ctx.value.close(promise: nil)
                        }
                    }
                    logSelf.logRequest(
                        method: "POST",
                        path: "/chat/completions",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseStatus: 500,
                        startTime: logStartTime,
                        model: logModel,
                        errorMessage: error.localizedDescription
                    )
                }
            }
        }
    }

    private func handleChatNDJSON(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let data: Data
        let requestBodyString: String?
        if let body = stateRef.value.requestBodyBuffer {
            var bodyCopy = body
            let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
            data = Data(bytes)
            requestBodyString = String(decoding: data, as: UTF8.self)
        } else {
            data = Data()
            requestBodyString = nil
        }

        guard let req = try? JSONDecoder().decode(ChatCompletionRequest.self, from: data) else {
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: [("Content-Type", "text/plain; charset=utf-8")],
                body: "Invalid request format"
            )
            logRequest(
                method: "POST",
                path: "/chat",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid request format"
            )
            return
        }

        let writer = NDJSONResponseWriter()
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let writerBound = NIOLoopBound(writer, eventLoop: loop)
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let chatEngine = self.chatEngine
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }
        hop {
            writerBound.value.writeHeaders(ctx.value, extraHeaders: cors)
        }
        // Capture for logging
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logModel = req.model
        let logTemperature = req.temperature ?? 0.7
        let logMaxTokens = req.max_tokens ?? 1024
        let logSelf = self
        Task(priority: .userInitiated) {
            do {
                let stream = try await chatEngine.streamChat(request: req)
                for try await delta in stream {
                    hop {
                        writerBound.value.writeContent(
                            delta,
                            model: req.model,
                            responseId: "",
                            created: Int(Date().timeIntervalSince1970),
                            context: ctx.value
                        )
                    }
                }
                hop {
                    writerBound.value.writeFinish(
                        req.model,
                        responseId: "",
                        created: Int(Date().timeIntervalSince1970),
                        context: ctx.value
                    )
                    writerBound.value.writeEnd(ctx.value)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/chat",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    temperature: logTemperature,
                    maxTokens: logMaxTokens,
                    finishReason: .stop
                )
            } catch {
                hop {
                    writerBound.value.writeError(error.localizedDescription, context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/chat",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 500,
                    startTime: logStartTime,
                    model: logModel,
                    temperature: logTemperature,
                    maxTokens: logMaxTokens,
                    finishReason: .error,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Models Endpoints

    private func handleModelsEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logSelf = self

        Task(priority: .userInitiated) {
            // Get local models
            var models = MLXService.getAvailableModels().map { OpenAIModel(modelName: $0) }
            if FoundationModelService.isDefaultModelAvailable() {
                models.insert(OpenAIModel(modelName: "foundation"), at: 0)
            }

            // Get remote provider models
            let remoteModels = await MainActor.run {
                RemoteProviderManager.shared.getOpenAIModels()
            }
            models.append(contentsOf: remoteModels)

            let response = ModelsResponse(data: models)
            let json = (try? JSONEncoder().encode(response)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"

            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .ok,
                    headers: headers,
                    body: json
                )
            }
            logSelf.logRequest(
                method: "GET",
                path: "/models",
                userAgent: logUserAgent,
                requestBody: nil,
                responseBody: json,
                responseStatus: 200,
                startTime: logStartTime
            )
        }
    }

    private func handleTagsEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logSelf = self

        Task(priority: .userInitiated) {
            let now = Date().ISO8601Format()

            // Get local models
            var models = MLXService.getAvailableModels().map { name -> OpenAIModel in
                var m = OpenAIModel(from: name)
                m.name = name
                m.model = name
                m.modified_at = now
                m.size = 0
                m.digest = ""
                m.details = ModelDetails(
                    parent_model: "",
                    format: "safetensors",
                    family: "unknown",
                    families: ["unknown"],
                    parameter_size: "",
                    quantization_level: ""
                )
                return m
            }

            if FoundationModelService.isDefaultModelAvailable() {
                var fm = OpenAIModel(modelName: "foundation")
                fm.name = "foundation"
                fm.model = "foundation"
                fm.modified_at = now
                fm.size = 0
                fm.digest = ""
                fm.details = ModelDetails(
                    parent_model: "",
                    format: "native",
                    family: "foundation",
                    families: ["foundation"],
                    parameter_size: "",
                    quantization_level: ""
                )
                models.insert(fm, at: 0)
            }

            // Get remote provider models
            let remoteModels = await MainActor.run {
                RemoteProviderManager.shared.getOpenAIModels()
            }
            for var remoteModel in remoteModels {
                remoteModel.modified_at = now
                remoteModel.size = 0
                remoteModel.digest = ""
                remoteModel.name = remoteModel.id
                remoteModel.model = remoteModel.id
                remoteModel.details = ModelDetails(
                    parent_model: "",
                    format: "remote",
                    family: remoteModel.owned_by,
                    families: [remoteModel.owned_by],
                    parameter_size: "",
                    quantization_level: ""
                )
                models.append(remoteModel)
            }

            let payload = ["models": models]
            let json = (try? JSONEncoder().encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"

            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .ok,
                    headers: headers,
                    body: json
                )
            }
            logSelf.logRequest(
                method: "GET",
                path: "/tags",
                userAgent: logUserAgent,
                requestBody: nil,
                responseBody: json,
                responseStatus: 200,
                startTime: logStartTime
            )
        }
    }

    private func handleShowEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let data: Data
        let requestBodyString: String?
        if let body = stateRef.value.requestBodyBuffer {
            var bodyCopy = body
            let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
            data = Data(bytes)
            requestBodyString = String(decoding: data, as: UTF8.self)
        } else {
            data = Data()
            requestBodyString = nil
        }

        struct ShowRequest: Decodable {
            let name: String
        }

        guard let req = try? JSONDecoder().decode(ShowRequest.self, from: data) else {
            var headers = [("Content-Type", "application/json; charset=utf-8")]
            headers.append(contentsOf: stateRef.value.corsHeaders)
            let errorBody =
                #"{"error":{"message":"Invalid request: expected {\"name\": \"<model_id>\"}","type":"invalid_request_error"}}"#
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: headers,
                body: errorBody
            )
            logRequest(
                method: "POST",
                path: "/show",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseBody: errorBody,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid request format"
            )
            return
        }

        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logSelf = self
        let modelName = req.name

        Task(priority: .userInitiated) {
            // Handle "foundation" model specially
            if modelName.lowercased() == "foundation" || modelName.lowercased() == "default" {
                if FoundationModelService.isDefaultModelAvailable() {
                    let response: [String: Any] = [
                        "modelfile": "",
                        "parameters": "",
                        "template": "",
                        "details": [
                            "parent_model": "",
                            "format": "native",
                            "family": "foundation",
                            "families": ["foundation"],
                            "parameter_size": "",
                            "quantization_level": "",
                        ],
                        "model_info": [
                            "general.architecture": "foundation",
                            "general.name": "Apple Foundation Model",
                        ],
                    ]
                    let jsonData = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
                    let json = String(decoding: jsonData, as: UTF8.self)
                    hop {
                        var headers = [("Content-Type", "application/json; charset=utf-8")]
                        headers.append(contentsOf: cors)
                        self.sendResponse(
                            context: ctx.value,
                            version: head.version,
                            status: .ok,
                            headers: headers,
                            body: json
                        )
                    }
                    logSelf.logRequest(
                        method: "POST",
                        path: "/show",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseBody: json,
                        responseStatus: 200,
                        startTime: logStartTime,
                        model: "foundation"
                    )
                    return
                } else {
                    let errorBody =
                        #"{"error":{"message":"Foundation model not available","type":"invalid_request_error"}}"#
                    hop {
                        var headers = [("Content-Type", "application/json; charset=utf-8")]
                        headers.append(contentsOf: cors)
                        self.sendResponse(
                            context: ctx.value,
                            version: head.version,
                            status: .notFound,
                            headers: headers,
                            body: errorBody
                        )
                    }
                    logSelf.logRequest(
                        method: "POST",
                        path: "/show",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseBody: errorBody,
                        responseStatus: 404,
                        startTime: logStartTime,
                        errorMessage: "Foundation model not available"
                    )
                    return
                }
            }

            // Try to load model info for MLX models
            guard let modelInfo = ModelInfo.load(modelId: modelName) else {
                let errorBody =
                    #"{"error":{"message":"Model not found: \#(modelName)","type":"invalid_request_error"}}"#
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .notFound,
                        headers: headers,
                        body: errorBody
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/show",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: errorBody,
                    responseStatus: 404,
                    startTime: logStartTime,
                    errorMessage: "Model not found: \(modelName)"
                )
                return
            }

            let response = modelInfo.toShowResponse()
            let jsonData = (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)
            let json = String(decoding: jsonData, as: UTF8.self)

            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .ok,
                    headers: headers,
                    body: json
                )
            }
            logSelf.logRequest(
                method: "POST",
                path: "/show",
                userAgent: logUserAgent,
                requestBody: logRequestBody,
                responseBody: json,
                responseStatus: 200,
                startTime: logStartTime,
                model: modelName
            )
        }
    }

    // MARK: - Minimal MCP-style endpoints (same port)
    private func handleMCPListTools(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }
        // Capture for logging
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logSelf = self
        Task(priority: .userInitiated) {
            let entries = await MainActor.run {
                ToolRegistry.shared.listTools().filter { $0.enabled }
            }
            let tools = entries.map { e in
                var obj: [String: Any] = [
                    "name": e.name,
                    "description": e.description,
                ]
                if let params = e.parameters {
                    obj["inputSchema"] = params.anyValue
                }
                return obj
            }
            let payload: [String: Any] = ["tools": tools]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            let mcpToolsBody = String(decoding: data, as: UTF8.self)
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .ok,
                    headers: headers,
                    body: mcpToolsBody
                )
            }
            logSelf.logRequest(
                method: "GET",
                path: "/mcp/tools",
                userAgent: logUserAgent,
                requestBody: nil,
                responseBody: mcpToolsBody,
                responseStatus: 200,
                startTime: logStartTime
            )
        }
    }

    private func handleMCPCallTool(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let data: Data
        let requestBodyString: String?
        if let body = stateRef.value.requestBodyBuffer {
            var bodyCopy = body
            let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
            data = Data(bytes)
            requestBodyString = String(decoding: data, as: UTF8.self)
        } else {
            data = Data()
            requestBodyString = nil
        }

        struct CallBody: Codable {
            let name: String
            let arguments: AnyCodable?
        }

        // Lightweight AnyCodable for arguments passthrough
        struct AnyCodable: Codable {
            let value: Any
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let b = try? container.decode(Bool.self) { value = b; return }
                if let i = try? container.decode(Int.self) { value = i; return }
                if let d = try? container.decode(Double.self) { value = d; return }
                if let s = try? container.decode(String.self) { value = s; return }
                if let arr = try? container.decode([AnyCodable].self) { value = arr.map { $0.value }; return }
                if let dict = try? container.decode([String: AnyCodable].self) {
                    value = dict.mapValues { $0.value }
                    return
                }
                value = NSNull()
            }
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch value {
                case let b as Bool: try container.encode(b)
                case let i as Int: try container.encode(i)
                case let d as Double: try container.encode(d)
                case let s as String: try container.encode(s)
                case let arr as [Any]:
                    let enc = try JSONSerialization.data(withJSONObject: arr, options: [])
                    try container.encode(String(decoding: enc, as: UTF8.self))
                case let dict as [String: Any]:
                    let enc = try JSONSerialization.data(withJSONObject: dict, options: [])
                    try container.encode(String(decoding: enc, as: UTF8.self))
                default:
                    try container.encodeNil()
                }
            }
        }

        guard let req = try? JSONDecoder().decode(CallBody.self, from: data) else {
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: [("Content-Type", "text/plain; charset=utf-8")],
                body: "Invalid request format"
            )
            logRequest(
                method: "POST",
                path: "/mcp/call",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid request format"
            )
            return
        }

        let argsJSON: String = {
            if let a = req.arguments?.value,
                let d = try? JSONSerialization.data(withJSONObject: a, options: [])
            {
                return String(decoding: d, as: UTF8.self)
            }
            return "{}"
        }()

        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }
        let toolName = req.name
        // Capture for logging
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logSelf = self
        Task(priority: .userInitiated) {
            let toolCallStartTime = Date()
            do {
                // Validate against schema if available
                if let schema = await MainActor.run(body: { ToolRegistry.shared.parametersForTool(name: toolName) }) {
                    let argsObject: Any =
                        (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
                    let res = SchemaValidator.validate(arguments: argsObject, against: schema)
                    if res.isValid == false {
                        let message = res.errorMessage ?? "Invalid arguments"
                        let payload: [String: Any] = [
                            "content": [["type": "text", "text": message]],
                            "isError": true,
                        ]
                        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
                        let body = String(decoding: data, as: UTF8.self)
                        hop {
                            var headers = [("Content-Type", "application/json; charset=utf-8")]
                            headers.append(contentsOf: cors)
                            self.sendResponse(
                                context: ctx.value,
                                version: head.version,
                                status: .ok,
                                headers: headers,
                                body: body
                            )
                        }
                        let toolLog = ToolCallLog(
                            name: toolName,
                            arguments: argsJSON,
                            result: message,
                            durationMs: Date().timeIntervalSince(toolCallStartTime) * 1000,
                            isError: true
                        )
                        logSelf.logRequest(
                            method: "POST",
                            path: "/mcp/call",
                            userAgent: logUserAgent,
                            requestBody: logRequestBody,
                            responseStatus: 200,
                            startTime: logStartTime,
                            toolCalls: [toolLog]
                        )
                        return
                    }
                }

                let result = try await ToolRegistry.shared.execute(name: toolName, argumentsJSON: argsJSON)
                let payload: [String: Any] = [
                    "content": [["type": "text", "text": result]],
                    "isError": false,
                ]
                let d = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
                let body = String(decoding: d, as: UTF8.self)
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .ok,
                        headers: headers,
                        body: body
                    )
                }
                let toolLog = ToolCallLog(
                    name: toolName,
                    arguments: argsJSON,
                    result: result,
                    durationMs: Date().timeIntervalSince(toolCallStartTime) * 1000,
                    isError: false
                )
                logSelf.logRequest(
                    method: "POST",
                    path: "/mcp/call",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    toolCalls: [toolLog]
                )
            } catch {
                let payload: [String: Any] = [
                    "content": [["type": "text", "text": error.localizedDescription]],
                    "isError": true,
                ]
                let d = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
                let body = String(decoding: d, as: UTF8.self)
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .ok,
                        headers: headers,
                        body: body
                    )
                }
                let toolLog = ToolCallLog(
                    name: toolName,
                    arguments: argsJSON,
                    result: error.localizedDescription,
                    durationMs: Date().timeIntervalSince(toolCallStartTime) * 1000,
                    isError: true
                )
                logSelf.logRequest(
                    method: "POST",
                    path: "/mcp/call",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    toolCalls: [toolLog],
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Anthropic Messages API

    private func handleAnthropicMessages(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let data: Data
        let requestBodyString: String?
        if let body = stateRef.value.requestBodyBuffer {
            var bodyCopy = body
            let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
            data = Data(bytes)
            requestBodyString = String(decoding: data, as: UTF8.self)
        } else {
            data = Data()
            requestBodyString = nil
        }

        // Parse Anthropic request
        guard let anthropicReq = try? JSONDecoder().decode(AnthropicMessagesRequest.self, from: data) else {
            let error = AnthropicError(message: "Invalid request format", errorType: "invalid_request_error")
            let errorJson =
                (try? JSONEncoder().encode(error)).map { String(decoding: $0, as: UTF8.self) }
                ?? #"{"type":"error","error":{"type":"invalid_request_error","message":"Invalid request format"}}"#
            var headers = [("Content-Type", "application/json; charset=utf-8")]
            headers.append(contentsOf: stateRef.value.corsHeaders)
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: headers,
                body: errorJson
            )
            logRequest(
                method: "POST",
                path: "/messages",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid request format"
            )
            return
        }

        // Convert to internal format
        let internalReq = anthropicReq.toChatCompletionRequest()

        // Generate response ID
        let messageId = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
        let model = anthropicReq.model

        // Determine if streaming
        let wantsStream = anthropicReq.stream ?? false

        if wantsStream {
            handleAnthropicMessagesStreaming(
                anthropicReq: anthropicReq,
                internalReq: internalReq,
                messageId: messageId,
                model: model,
                head: head,
                context: context,
                startTime: startTime,
                userAgent: userAgent,
                requestBodyString: requestBodyString
            )
        } else {
            handleAnthropicMessagesNonStreaming(
                anthropicReq: anthropicReq,
                internalReq: internalReq,
                messageId: messageId,
                model: model,
                head: head,
                context: context,
                startTime: startTime,
                userAgent: userAgent,
                requestBodyString: requestBodyString
            )
        }
    }

    private func handleAnthropicMessagesStreaming(
        anthropicReq: AnthropicMessagesRequest,
        internalReq: ChatCompletionRequest,
        messageId: String,
        model: String,
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        requestBodyString: String?
    ) {
        let writer = AnthropicSSEResponseWriter()
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let writerBound = NIOLoopBound(writer, eventLoop: loop)
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let chatEngine = self.chatEngine
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }

        // Estimate input tokens (rough: 1 token per 4 chars)
        let inputTokens =
            anthropicReq.messages.reduce(0) { acc, msg in
                acc + max(1, msg.content.plainText.count / 4)
            } + (anthropicReq.system?.plainText.count ?? 0) / 4

        // Send headers and message_start
        hop {
            writerBound.value.writeHeaders(ctx.value, extraHeaders: cors)
            writerBound.value.writeMessageStart(
                messageId: messageId,
                model: model,
                inputTokens: inputTokens,
                context: ctx.value
            )
        }

        // Capture for logging
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logModel = model
        let logSelf = self

        Task(priority: .userInitiated) {
            do {
                let stream = try await chatEngine.streamChat(request: internalReq)
                for try await delta in stream {
                    hop {
                        writerBound.value.writeTextDelta(delta, context: ctx.value)
                    }
                }
                hop {
                    writerBound.value.writeFinish(stopReason: "end_turn", context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/messages",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    finishReason: .stop
                )
            } catch let inv as ServiceToolInvocation {
                // Handle tool invocation - emit tool_use content block
                let toolId =
                    inv.toolCallId ?? "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
                let args = inv.jsonArguments

                hop {
                    // Start tool_use block
                    writerBound.value.writeToolUseBlockStart(
                        toolId: toolId,
                        toolName: inv.toolName,
                        context: ctx.value
                    )

                    // Stream the JSON arguments in chunks
                    let chunkSize = 512
                    var i = args.startIndex
                    while i < args.endIndex {
                        let next = args.index(i, offsetBy: chunkSize, limitedBy: args.endIndex) ?? args.endIndex
                        let chunk = String(args[i ..< next])
                        writerBound.value.writeToolInputDelta(chunk, context: ctx.value)
                        i = next
                    }

                    // Close the tool_use block
                    writerBound.value.writeBlockStop(context: ctx.value)

                    // Finish with tool_use stop reason
                    writerBound.value.writeFinish(stopReason: "tool_use", context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }

                let toolLog = ToolCallLog(name: inv.toolName, arguments: inv.jsonArguments)
                logSelf.logRequest(
                    method: "POST",
                    path: "/messages",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    toolCalls: [toolLog],
                    finishReason: .toolCalls
                )
            } catch {
                hop {
                    writerBound.value.writeError(error.localizedDescription, context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/messages",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 500,
                    startTime: logStartTime,
                    model: logModel,
                    finishReason: .error,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private func handleAnthropicMessagesNonStreaming(
        anthropicReq: AnthropicMessagesRequest,
        internalReq: ChatCompletionRequest,
        messageId: String,
        model: String,
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        requestBodyString: String?
    ) {
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let chatEngine = self.chatEngine
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }

        // Capture for logging
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logModel = model
        let logSelf = self

        Task(priority: .userInitiated) {
            do {
                let resp = try await chatEngine.completeChat(request: internalReq)

                // Convert OpenAI response to Anthropic format
                let content = resp.choices.first?.message.content ?? ""
                let stopReason: String
                switch resp.choices.first?.finish_reason {
                case "stop": stopReason = "end_turn"
                case "length": stopReason = "max_tokens"
                case "tool_calls": stopReason = "tool_use"
                default: stopReason = "end_turn"
                }

                var contentBlocks: [AnthropicResponseContentBlock] = []

                // Check for tool calls
                if let toolCalls = resp.choices.first?.message.tool_calls, !toolCalls.isEmpty {
                    // Add any text content first
                    if !content.isEmpty {
                        contentBlocks.append(.textBlock(content))
                    }

                    // Add tool_use blocks
                    for toolCall in toolCalls {
                        // Parse arguments JSON to dictionary
                        var inputDict: [String: AnyCodableValue] = [:]
                        if let argsData = toolCall.function.arguments.data(using: .utf8),
                            let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                        {
                            inputDict = parsed.mapValues { AnyCodableValue($0) }
                        }
                        contentBlocks.append(
                            .toolUseBlock(
                                id: toolCall.id,
                                name: toolCall.function.name,
                                input: inputDict
                            )
                        )
                    }
                } else {
                    contentBlocks.append(.textBlock(content))
                }

                let anthropicResp = AnthropicMessagesResponse(
                    id: messageId,
                    model: model,
                    content: contentBlocks,
                    stopReason: stopReason,
                    usage: AnthropicUsage(
                        inputTokens: resp.usage.prompt_tokens,
                        outputTokens: resp.usage.completion_tokens
                    )
                )

                let json = try JSONEncoder().encode(anthropicResp)
                var headers: [(String, String)] = [("Content-Type", "application/json")]
                headers.append(contentsOf: cors)
                let headersCopy = headers
                let body = String(decoding: json, as: UTF8.self)

                hop {
                    var responseHead = HTTPResponseHead(version: head.version, status: .ok)
                    var buffer = ctx.value.channel.allocator.buffer(capacity: body.utf8.count)
                    buffer.writeString(body)
                    var nioHeaders = HTTPHeaders()
                    for (name, value) in headersCopy { nioHeaders.add(name: name, value: value) }
                    nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
                    nioHeaders.add(name: "Connection", value: "close")
                    responseHead.headers = nioHeaders
                    let c = ctx.value
                    c.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                    c.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    c.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                        ctx.value.close(promise: nil)
                    }
                }

                logSelf.logRequest(
                    method: "POST",
                    path: "/messages",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: body,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    tokensInput: resp.usage.prompt_tokens,
                    tokensOutput: resp.usage.completion_tokens,
                    finishReason: .stop
                )
            } catch let inv as ServiceToolInvocation {
                // Handle tool invocation for non-streaming
                let toolId =
                    inv.toolCallId ?? "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

                var inputDict: [String: AnyCodableValue] = [:]
                if let argsData = inv.jsonArguments.data(using: .utf8),
                    let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                {
                    inputDict = parsed.mapValues { AnyCodableValue($0) }
                }

                let anthropicResp = AnthropicMessagesResponse(
                    id: messageId,
                    model: model,
                    content: [.toolUseBlock(id: toolId, name: inv.toolName, input: inputDict)],
                    stopReason: "tool_use",
                    usage: AnthropicUsage(inputTokens: 0, outputTokens: 0)
                )

                let json =
                    (try? JSONEncoder().encode(anthropicResp))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                var headers: [(String, String)] = [("Content-Type", "application/json")]
                headers.append(contentsOf: cors)
                let headersCopy = headers
                let body = json

                hop {
                    var responseHead = HTTPResponseHead(version: head.version, status: .ok)
                    var buffer = ctx.value.channel.allocator.buffer(capacity: body.utf8.count)
                    buffer.writeString(body)
                    var nioHeaders = HTTPHeaders()
                    for (name, value) in headersCopy { nioHeaders.add(name: name, value: value) }
                    nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
                    nioHeaders.add(name: "Connection", value: "close")
                    responseHead.headers = nioHeaders
                    let c = ctx.value
                    c.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                    c.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    c.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                        ctx.value.close(promise: nil)
                    }
                }

                let toolLog = ToolCallLog(name: inv.toolName, arguments: inv.jsonArguments)
                logSelf.logRequest(
                    method: "POST",
                    path: "/messages",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: body,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    toolCalls: [toolLog],
                    finishReason: .toolCalls
                )
            } catch {
                let errorResp = AnthropicError(message: error.localizedDescription, errorType: "api_error")
                let errorJson =
                    (try? JSONEncoder().encode(errorResp))
                    .map { String(decoding: $0, as: UTF8.self) }
                    ?? #"{"type":"error","error":{"type":"api_error","message":"Internal error"}}"#
                var headers: [(String, String)] = [("Content-Type", "application/json")]
                headers.append(contentsOf: cors)
                let headersCopy = headers
                let body = errorJson

                hop {
                    var responseHead = HTTPResponseHead(version: head.version, status: .internalServerError)
                    var buffer = ctx.value.channel.allocator.buffer(capacity: body.utf8.count)
                    buffer.writeString(body)
                    var nioHeaders = HTTPHeaders()
                    for (name, value) in headersCopy { nioHeaders.add(name: name, value: value) }
                    nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
                    nioHeaders.add(name: "Connection", value: "close")
                    responseHead.headers = nioHeaders
                    let c = ctx.value
                    c.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                    c.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    c.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                        ctx.value.close(promise: nil)
                    }
                }

                logSelf.logRequest(
                    method: "POST",
                    path: "/messages",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 500,
                    startTime: logStartTime,
                    model: logModel,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    @inline(__always)
    private func executeOnLoop(_ loop: EventLoop, _ block: @escaping @Sendable () -> Void) {
        if loop.inEventLoop { block() } else { loop.execute { block() } }
    }

    // MARK: - Audio Transcriptions (OpenAI Whisper API Compatible)

    private func handleAudioTranscriptions(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let data: Data
        if let body = stateRef.value.requestBodyBuffer {
            var bodyCopy = body
            let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
            data = Data(bytes)
        } else {
            data = Data()
        }

        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }

        // Capture for logging
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logSelf = self

        // Parse Content-Type to get boundary
        guard let contentType = head.headers.first(name: "Content-Type"),
            contentType.contains("multipart/form-data"),
            let boundary = extractBoundary(from: contentType)
        else {
            let errorBody =
                #"{"error":{"message":"Invalid content type. Expected multipart/form-data","type":"invalid_request_error"}}"#
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .badRequest,
                    headers: headers,
                    body: errorBody
                )
            }
            logSelf.logRequest(
                method: "POST",
                path: "/audio/transcriptions",
                userAgent: logUserAgent,
                requestBody: nil,
                responseBody: errorBody,
                responseStatus: 400,
                startTime: logStartTime,
                errorMessage: "Invalid content type"
            )
            return
        }

        // Parse multipart form data
        let parsed = parseMultipartFormData(data: data, boundary: boundary)

        guard let audioData = parsed.file else {
            let errorBody = #"{"error":{"message":"Missing audio file in request","type":"invalid_request_error"}}"#
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .badRequest,
                    headers: headers,
                    body: errorBody
                )
            }
            logSelf.logRequest(
                method: "POST",
                path: "/audio/transcriptions",
                userAgent: logUserAgent,
                requestBody: nil,
                responseBody: errorBody,
                responseStatus: 400,
                startTime: logStartTime,
                errorMessage: "Missing audio file"
            )
            return
        }

        let modelParam = parsed.fields["model"]
        let responseFormat = parsed.fields["response_format"] ?? "json"

        Task(priority: .userInitiated) {
            do {
                // Write audio data to temp file
                let tempDir = FileManager.default.temporaryDirectory
                let audioURL = tempDir.appendingPathComponent("osaurus_transcription_\(UUID().uuidString).wav")
                try audioData.write(to: audioURL)

                defer {
                    try? FileManager.default.removeItem(at: audioURL)
                }

                // Get WhisperKitService and transcribe
                let service = await MainActor.run { WhisperKitService.shared }
                let result = try await service.transcribe(audioURL: audioURL)

                // Format response based on response_format
                let responseBody: String
                if responseFormat == "text" {
                    responseBody = result.text
                } else if responseFormat == "verbose_json" {
                    var response: [String: Any] = [
                        "text": result.text,
                        "task": "transcribe",
                    ]
                    if let lang = result.language {
                        response["language"] = lang
                    }
                    if let duration = result.durationSeconds {
                        response["duration"] = duration
                    }
                    var segments: [[String: Any]] = []
                    for segment in result.segments {
                        var seg: [String: Any] = [
                            "id": segment.id,
                            "text": segment.text,
                            "start": segment.start,
                            "end": segment.end,
                        ]
                        if let tokens = segment.tokens {
                            seg["tokens"] = tokens
                        }
                        segments.append(seg)
                    }
                    response["segments"] = segments
                    let jsonData = try JSONSerialization.data(withJSONObject: response)
                    responseBody = String(decoding: jsonData, as: UTF8.self)
                } else {
                    // Default JSON format
                    let response = ["text": result.text]
                    let jsonData = try JSONEncoder().encode(response)
                    responseBody = String(decoding: jsonData, as: UTF8.self)
                }

                hop {
                    var headers: [(String, String)]
                    if responseFormat == "text" {
                        headers = [("Content-Type", "text/plain; charset=utf-8")]
                    } else {
                        headers = [("Content-Type", "application/json; charset=utf-8")]
                    }
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .ok,
                        headers: headers,
                        body: responseBody
                    )
                }

                logSelf.logRequest(
                    method: "POST",
                    path: "/audio/transcriptions",
                    userAgent: logUserAgent,
                    requestBody: nil,
                    responseBody: responseBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: modelParam
                )
            } catch {
                let errorBody = #"{"error":{"message":"\#(error.localizedDescription)","type":"api_error"}}"#
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .internalServerError,
                        headers: headers,
                        body: errorBody
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/audio/transcriptions",
                    userAgent: logUserAgent,
                    requestBody: nil,
                    responseBody: errorBody,
                    responseStatus: 500,
                    startTime: logStartTime,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Open Responses API

    private func handleOpenResponses(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let data: Data
        let requestBodyString: String?
        if let body = stateRef.value.requestBodyBuffer {
            var bodyCopy = body
            let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
            data = Data(bytes)
            requestBodyString = String(decoding: data, as: UTF8.self)
        } else {
            data = Data()
            requestBodyString = nil
        }

        // Parse Open Responses request
        guard let openResponsesReq = try? JSONDecoder().decode(OpenResponsesRequest.self, from: data) else {
            let error = OpenResponsesErrorResponse(code: "invalid_request_error", message: "Invalid request format")
            let errorJson =
                (try? JSONEncoder().encode(error)).map { String(decoding: $0, as: UTF8.self) }
                ?? #"{"error":{"type":"error","code":"invalid_request_error","message":"Invalid request format"}}"#
            var headers = [("Content-Type", "application/json; charset=utf-8")]
            headers.append(contentsOf: stateRef.value.corsHeaders)
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: headers,
                body: errorJson
            )
            logRequest(
                method: "POST",
                path: "/responses",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid request format"
            )
            return
        }

        // Convert to internal format
        let internalReq = openResponsesReq.toChatCompletionRequest()

        // Generate response ID
        let responseId = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
        let model = openResponsesReq.model

        // Determine if streaming
        let wantsStream = openResponsesReq.stream ?? false

        if wantsStream {
            handleOpenResponsesStreaming(
                request: openResponsesReq,
                internalReq: internalReq,
                responseId: responseId,
                model: model,
                context: context,
                startTime: startTime,
                userAgent: userAgent,
                requestBodyString: requestBodyString
            )
        } else {
            handleOpenResponsesNonStreaming(
                internalReq: internalReq,
                responseId: responseId,
                model: model,
                head: head,
                context: context,
                startTime: startTime,
                userAgent: userAgent,
                requestBodyString: requestBodyString
            )
        }
    }

    private func handleOpenResponsesStreaming(
        request: OpenResponsesRequest,
        internalReq: ChatCompletionRequest,
        responseId: String,
        model: String,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        requestBodyString: String?
    ) {
        let writer = OpenResponsesSSEWriter()
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let writerBound = NIOLoopBound(writer, eventLoop: loop)
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let chatEngine = self.chatEngine
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }

        // Estimate input tokens (rough: 1 token per 4 chars)
        let inputTokens: Int =
            {
                switch request.input {
                case .text(let text):
                    return max(1, text.count / 4)
                case .items(let items):
                    return items.reduce(0) { acc, item in
                        switch item {
                        case .message(let msg):
                            return acc + max(1, msg.content.plainText.count / 4)
                        case .functionCallOutput(let output):
                            return acc + max(1, output.output.count / 4)
                        }
                    }
                }
            }() + (request.instructions?.count ?? 0) / 4

        let itemId = "item_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

        // Send headers and initial events
        hop {
            writerBound.value.writeHeaders(ctx.value, extraHeaders: cors)
            writerBound.value.writeResponseCreated(
                responseId: responseId,
                model: model,
                inputTokens: inputTokens,
                context: ctx.value
            )
            writerBound.value.writeResponseInProgress(context: ctx.value)
            writerBound.value.writeMessageItemAdded(itemId: itemId, context: ctx.value)
            writerBound.value.writeContentPartAdded(context: ctx.value)
        }

        // Capture for logging
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logModel = model
        let logSelf = self

        Task(priority: .userInitiated) {
            do {
                let stream = try await chatEngine.streamChat(request: internalReq)
                for try await delta in stream {
                    hop {
                        writerBound.value.writeTextDelta(delta, context: ctx.value)
                    }
                }
                hop {
                    writerBound.value.writeTextDone(context: ctx.value)
                    writerBound.value.writeMessageItemDone(context: ctx.value)
                    writerBound.value.writeResponseCompleted(context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/responses",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    finishReason: .stop
                )
            } catch let inv as ServiceToolInvocation {
                // Handle tool invocation - emit function_call item
                let callId =
                    inv.toolCallId ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
                let funcItemId = "item_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
                let args = inv.jsonArguments

                hop {
                    // Close the text content if any was written
                    writerBound.value.writeTextDone(context: ctx.value)
                    writerBound.value.writeMessageItemDone(context: ctx.value)

                    // Start function call item
                    writerBound.value.writeFunctionCallItemAdded(
                        itemId: funcItemId,
                        callId: callId,
                        name: inv.toolName,
                        context: ctx.value
                    )

                    // Stream the arguments in chunks
                    let chunkSize = 512
                    var i = args.startIndex
                    while i < args.endIndex {
                        let next = args.index(i, offsetBy: chunkSize, limitedBy: args.endIndex) ?? args.endIndex
                        let chunk = String(args[i ..< next])
                        writerBound.value.writeFunctionCallArgumentsDelta(
                            callId: callId,
                            delta: chunk,
                            context: ctx.value
                        )
                        i = next
                    }

                    // Complete the function call
                    writerBound.value.writeFunctionCallArgumentsDone(callId: callId, context: ctx.value)
                    writerBound.value.writeFunctionCallItemDone(
                        callId: callId,
                        name: inv.toolName,
                        context: ctx.value
                    )
                    writerBound.value.writeResponseCompleted(context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }

                let toolLog = ToolCallLog(name: inv.toolName, arguments: inv.jsonArguments)
                logSelf.logRequest(
                    method: "POST",
                    path: "/responses",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    toolCalls: [toolLog],
                    finishReason: .toolCalls
                )
            } catch {
                hop {
                    writerBound.value.writeError(error.localizedDescription, context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/responses",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 500,
                    startTime: logStartTime,
                    model: logModel,
                    finishReason: .error,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private func handleOpenResponsesNonStreaming(
        internalReq: ChatCompletionRequest,
        responseId: String,
        model: String,
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        requestBodyString: String?
    ) {
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let chatEngine = self.chatEngine
        let hop: (@escaping @Sendable () -> Void) -> Void = { block in
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }

        // Capture for logging
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logModel = model
        let logSelf = self

        Task(priority: .userInitiated) {
            do {
                let resp = try await chatEngine.completeChat(request: internalReq)

                // Convert to Open Responses format
                let openResponsesResp = resp.toOpenResponsesResponse(responseId: responseId)

                let json = try JSONEncoder().encode(openResponsesResp)
                var headers: [(String, String)] = [("Content-Type", "application/json")]
                headers.append(contentsOf: cors)
                let headersCopy = headers
                let body = String(decoding: json, as: UTF8.self)

                hop {
                    var responseHead = HTTPResponseHead(version: head.version, status: .ok)
                    var buffer = ctx.value.channel.allocator.buffer(capacity: body.utf8.count)
                    buffer.writeString(body)
                    var nioHeaders = HTTPHeaders()
                    for (name, value) in headersCopy { nioHeaders.add(name: name, value: value) }
                    nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
                    nioHeaders.add(name: "Connection", value: "close")
                    responseHead.headers = nioHeaders
                    let c = ctx.value
                    c.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                    c.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    c.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                        ctx.value.close(promise: nil)
                    }
                }

                logSelf.logRequest(
                    method: "POST",
                    path: "/responses",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: body,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    tokensInput: resp.usage.prompt_tokens,
                    tokensOutput: resp.usage.completion_tokens,
                    finishReason: .stop
                )
            } catch let inv as ServiceToolInvocation {
                // Handle tool invocation for non-streaming
                let callId =
                    inv.toolCallId ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
                let itemId = "item_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

                let functionCall = OpenResponsesFunctionCall(
                    id: itemId,
                    status: .completed,
                    callId: callId,
                    name: inv.toolName,
                    arguments: inv.jsonArguments
                )

                let openResponsesResp = OpenResponsesResponse(
                    id: responseId,
                    createdAt: Int(Date().timeIntervalSince1970),
                    status: .completed,
                    model: model,
                    output: [.functionCall(functionCall)],
                    usage: OpenResponsesUsage(inputTokens: 0, outputTokens: 0)
                )

                let json =
                    (try? JSONEncoder().encode(openResponsesResp))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                var headers: [(String, String)] = [("Content-Type", "application/json")]
                headers.append(contentsOf: cors)
                let headersCopy = headers
                let body = json

                hop {
                    var responseHead = HTTPResponseHead(version: head.version, status: .ok)
                    var buffer = ctx.value.channel.allocator.buffer(capacity: body.utf8.count)
                    buffer.writeString(body)
                    var nioHeaders = HTTPHeaders()
                    for (name, value) in headersCopy { nioHeaders.add(name: name, value: value) }
                    nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
                    nioHeaders.add(name: "Connection", value: "close")
                    responseHead.headers = nioHeaders
                    let c = ctx.value
                    c.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                    c.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    c.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                        ctx.value.close(promise: nil)
                    }
                }

                let toolLog = ToolCallLog(name: inv.toolName, arguments: inv.jsonArguments)
                logSelf.logRequest(
                    method: "POST",
                    path: "/responses",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: body,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    toolCalls: [toolLog],
                    finishReason: .toolCalls
                )
            } catch {
                let errorResp = OpenResponsesErrorResponse(code: "api_error", message: error.localizedDescription)
                let errorJson =
                    (try? JSONEncoder().encode(errorResp))
                    .map { String(decoding: $0, as: UTF8.self) }
                    ?? #"{"error":{"type":"error","code":"api_error","message":"Internal error"}}"#
                var headers: [(String, String)] = [("Content-Type", "application/json")]
                headers.append(contentsOf: cors)
                let headersCopy = headers
                let body = errorJson

                hop {
                    var responseHead = HTTPResponseHead(version: head.version, status: .internalServerError)
                    var buffer = ctx.value.channel.allocator.buffer(capacity: body.utf8.count)
                    buffer.writeString(body)
                    var nioHeaders = HTTPHeaders()
                    for (name, value) in headersCopy { nioHeaders.add(name: name, value: value) }
                    nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
                    nioHeaders.add(name: "Connection", value: "close")
                    responseHead.headers = nioHeaders
                    let c = ctx.value
                    c.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                    c.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    c.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                        ctx.value.close(promise: nil)
                    }
                }

                logSelf.logRequest(
                    method: "POST",
                    path: "/responses",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 500,
                    startTime: logStartTime,
                    model: logModel,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Multipart Form Data Parsing

    private func extractBoundary(from contentType: String) -> String? {
        // Parse: multipart/form-data; boundary=----WebKitFormBoundary...
        let parts = contentType.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var boundary = String(trimmed.dropFirst("boundary=".count))
                // Remove quotes if present
                if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
                    boundary = String(boundary.dropFirst().dropLast())
                }
                return boundary
            }
        }
        return nil
    }

    private struct MultipartParseResult {
        var file: Data?
        var filename: String?
        var fields: [String: String] = [:]
    }

    private func parseMultipartFormData(data: Data, boundary: String) -> MultipartParseResult {
        var result = MultipartParseResult()

        let boundaryData = ("--" + boundary).data(using: .utf8)!
        let crlfData = "\r\n".data(using: .utf8)!
        let doubleCrlfData = "\r\n\r\n".data(using: .utf8)!

        // Split by boundary
        var ranges: [Range<Data.Index>] = []
        var searchStart = data.startIndex
        while let range = data.range(of: boundaryData, in: searchStart ..< data.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }

        // Process each part
        for i in 0 ..< (ranges.count - 1) {
            let partStart = ranges[i].upperBound
            let partEnd = ranges[i + 1].lowerBound

            // Skip leading CRLF
            var contentStart = partStart
            if data[contentStart ..< min(contentStart + 2, partEnd)] == crlfData {
                contentStart = contentStart + 2
            }

            // Find headers end (double CRLF)
            guard let headerEnd = data.range(of: doubleCrlfData, in: contentStart ..< partEnd) else {
                continue
            }

            let headerData = data[contentStart ..< headerEnd.lowerBound]
            let bodyStart = headerEnd.upperBound
            var bodyEnd = partEnd

            // Trim trailing CRLF from body
            if bodyEnd >= 2 && data[bodyEnd - 2 ..< bodyEnd] == crlfData {
                bodyEnd = bodyEnd - 2
            }

            let bodyData = data[bodyStart ..< bodyEnd]

            // Parse headers
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                continue
            }

            var fieldName: String?
            var fileName: String?

            for line in headerString.split(separator: "\r\n") {
                let lineStr = String(line)
                if lineStr.lowercased().hasPrefix("content-disposition:") {
                    // Extract name
                    if let nameRange = lineStr.range(of: "name=\"") {
                        let nameStart = nameRange.upperBound
                        if let nameEndRange = lineStr.range(of: "\"", range: nameStart ..< lineStr.endIndex) {
                            fieldName = String(lineStr[nameStart ..< nameEndRange.lowerBound])
                        }
                    }
                    // Extract filename
                    if let fnRange = lineStr.range(of: "filename=\"") {
                        let fnStart = fnRange.upperBound
                        if let fnEndRange = lineStr.range(of: "\"", range: fnStart ..< lineStr.endIndex) {
                            fileName = String(lineStr[fnStart ..< fnEndRange.lowerBound])
                        }
                    }
                }
            }

            guard let name = fieldName else { continue }

            if fileName != nil {
                // This is a file field
                result.file = Data(bodyData)
                result.filename = fileName
            } else {
                // This is a regular field
                if let value = String(data: bodyData, encoding: .utf8) {
                    result.fields[name] = value
                }
            }
        }

        return result
    }

    // MARK: - Request Logging

    /// Log a completed request to InsightsService
    private func logRequest(
        method: String,
        path: String,
        userAgent: String?,
        requestBody: String?,
        responseBody: String? = nil,
        responseStatus: Int,
        startTime: Date,
        model: String? = nil,
        tokensInput: Int? = nil,
        tokensOutput: Int? = nil,
        toolCalls: [ToolCallLog]? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        finishReason: RequestLog.FinishReason? = nil,
        errorMessage: String? = nil
    ) {
        let durationMs = Date().timeIntervalSince(startTime) * 1000
        InsightsService.logAsync(
            method: method,
            path: path,
            userAgent: userAgent,
            requestBody: requestBody,
            responseBody: responseBody,
            responseStatus: responseStatus,
            durationMs: durationMs,
            model: model,
            tokensInput: tokensInput,
            tokensOutput: tokensOutput,
            temperature: temperature,
            maxTokens: maxTokens,
            toolCalls: toolCalls,
            finishReason: finishReason,
            errorMessage: errorMessage
        )
    }
}
