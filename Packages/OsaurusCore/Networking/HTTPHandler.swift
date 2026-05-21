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

private final class SendableBool: @unchecked Sendable {
    private var _value: Bool
    private let _lock = NSLock()
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { _lock.withLock { _value } }
        set { _lock.withLock { _value = newValue } }
    }
}

private final class LockedStringAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ value: String) {
        lock.withLock {
            storage += value
        }
    }

    var value: String {
        lock.withLock { storage }
    }
}

private final class OpenResponsesContextStore: @unchecked Sendable {
    private struct Entry {
        let model: String
        let messages: [ChatMessage]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private let maxEntries = 128
    private let maxMessagesPerEntry = 40

    func transcript(for responseId: String?, model: String) -> [ChatMessage] {
        guard let responseId, !responseId.isEmpty else { return [] }
        return lock.withLock {
            guard let entry = entries[responseId], entry.model == model else { return [] }
            return entry.messages
        }
    }

    func store(responseId: String, model: String, messages: [ChatMessage]) {
        guard !responseId.isEmpty, !messages.isEmpty else { return }
        let clipped = Array(messages.suffix(maxMessagesPerEntry))
        lock.withLock {
            if entries[responseId] == nil {
                insertionOrder.append(responseId)
            }
            entries[responseId] = Entry(model: model, messages: clipped)

            while insertionOrder.count > maxEntries {
                let evicted = insertionOrder.removeFirst()
                entries.removeValue(forKey: evicted)
            }
        }
    }
}

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<Value, Never>, returning value: Value) -> Bool {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return false
        }
        didResume = true
        lock.unlock()
        continuation.resume(returning: value)
        return true
    }
}

private final class HTTPTraceRecorder: @unchecked Sendable {
    private let trace: TTFTTrace?
    private let lock = NSLock()
    private var emitted = false
    private var markedFirstSemanticDelta = false

    init(_ trace: TTFTTrace?) {
        self.trace = trace
    }

    func mark(_ name: String) {
        trace?.mark(name)
    }

    func set(_ key: String, _ value: Any) {
        trace?.set(key, value)
    }

    func markFirstSemanticDelta(_ kind: String) {
        guard trace != nil else { return }
        lock.lock()
        let shouldMark = !markedFirstSemanticDelta
        if shouldMark {
            markedFirstSemanticDelta = true
        }
        lock.unlock()
        guard shouldMark else { return }
        trace?.set("http_first_semantic_delta_kind", kind)
        trace?.mark("http_first_semantic_delta")
    }

    func emit(finishReason: String, responseStatus: Int, errorMessage: String? = nil) {
        guard trace != nil else { return }
        lock.lock()
        let shouldEmit = !emitted
        if shouldEmit {
            emitted = true
        }
        lock.unlock()
        guard shouldEmit else { return }
        trace?.set("http_finish_reason", finishReason)
        trace?.set("http_response_status", responseStatus)
        if let errorMessage {
            trace?.set("http_error", errorMessage)
        }
        trace?.mark("http_trace_emit")
        trace?.emit()
    }
}

/// SwiftNIO HTTP request handler
final class HTTPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let configuration: ServerConfiguration
    private let apiKeyValidatorProvider: @Sendable () -> APIKeyValidator
    private var apiKeyValidator: APIKeyValidator { apiKeyValidatorProvider() }
    private let chatEngine: ChatEngineProtocol
    private let trustLoopback: Bool
    private let _isChannelActive = SendableBool(false)
    private static let openResponsesContextStore = OpenResponsesContextStore()
    /// Per-request scratch state. `internal` so peer-file helpers (e.g.
    /// `HTTPRequestParse.readRequestBody()`) can drain the buffered body
    /// without going through a private accessor.
    final class RequestState {
        var requestHead: HTTPRequestHead?
        var requestBodyBuffer: ByteBuffer?
        var corsHeaders: [(String, String)] = []
        var requestStartTime: Date = Date()
        var normalizedPath: String = ""
        /// Cached body-size cap for the current request (route-aware).
        /// `Int.max` means "no in-handler cap"; tests that want disable can
        /// also rely on this. Set at `.head`.
        var bodyByteLimit: Int = Int.max
        /// Running total of accumulated body bytes. Used by the streaming
        /// guard so a chunked client cannot bypass the Content-Length check.
        var bodyBytesSeen: Int = 0
        /// Set when the request has already been rejected with 413 so any
        /// subsequent `.body` / `.end` parts are dropped without further
        /// allocation or routing.
        var rejectedTooLarge: Bool = false
    }
    let stateRef: NIOLoopBound<RequestState>

    init(
        configuration: ServerConfiguration,
        apiKeyValidator: APIKeyValidator = .empty,
        apiKeyValidatorProvider: (@Sendable () -> APIKeyValidator)? = nil,
        eventLoop: EventLoop,
        chatEngine: ChatEngineProtocol = ChatEngine(),
        trustLoopback: Bool = true
    ) {
        self.configuration = configuration
        self.apiKeyValidatorProvider = apiKeyValidatorProvider ?? { apiKeyValidator }
        self.chatEngine = chatEngine
        self.trustLoopback = trustLoopback
        self.stateRef = NIOLoopBound(RequestState(), eventLoop: eventLoop)
    }

    func channelActive(context: ChannelHandlerContext) {
        _isChannelActive.value = true
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        _isChannelActive.value = false
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)

        switch part {
        case .head(let head):
            stateRef.value.requestHead = head
            stateRef.value.requestStartTime = Date()
            stateRef.value.bodyBytesSeen = 0
            stateRef.value.rejectedTooLarge = false
            stateRef.value.corsHeaders = computeCORSHeaders(
                for: head,
                isPreflight: false,
                isLoopback: isLoopbackConnection(context)
            )
            stateRef.value.bodyByteLimit = bodyByteLimit(for: head)

            // Reject before allocating the body buffer so a client lying
            // about Content-Length can't force a huge allocation up front.
            if let lengthStr = head.headers.first(name: "Content-Length"),
                let length = Int(lengthStr)
            {
                if length > stateRef.value.bodyByteLimit {
                    rejectPayloadTooLarge(
                        context: context,
                        head: head,
                        declaredLength: length,
                        limit: stateRef.value.bodyByteLimit
                    )
                    return
                }
                stateRef.value.requestBodyBuffer = context.channel.allocator.buffer(capacity: length)
            } else {
                stateRef.value.requestBodyBuffer = context.channel.allocator.buffer(capacity: 0)
            }

        case .body(var buffer):
            if stateRef.value.rejectedTooLarge { return }

            if stateRef.value.requestBodyBuffer == nil {
                stateRef.value.requestBodyBuffer = context.channel.allocator.buffer(
                    capacity: buffer.readableBytes
                )
            }
            // Streaming guard catches chunked clients and any client whose
            // body grows past the cap mid-stream. Counter is bumped before
            // append so an oversize chunk never lands in our buffer.
            stateRef.value.bodyBytesSeen += buffer.readableBytes
            if stateRef.value.bodyBytesSeen > stateRef.value.bodyByteLimit,
                let head = stateRef.value.requestHead
            {
                rejectPayloadTooLarge(
                    context: context,
                    head: head,
                    declaredLength: stateRef.value.bodyBytesSeen,
                    limit: stateRef.value.bodyByteLimit
                )
                return
            }
            if var existing = stateRef.value.requestBodyBuffer {
                existing.writeBuffer(&buffer)
                stateRef.value.requestBodyBuffer = existing
            }

        case .end:
            if stateRef.value.rejectedTooLarge {
                stateRef.value.requestHead = nil
                stateRef.value.requestBodyBuffer = nil
                return
            }
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
                let cors = computeCORSHeaders(
                    for: head,
                    isPreflight: true,
                    isLoopback: isLoopbackConnection(context)
                )
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

            // Access key authentication gate (all data snapshotted at server start, zero locks)
            // Plugin routes handle their own auth per-route, so skip the global gate.
            // Loopback connections (CLI / local tools) are trusted without a token.
            let publicPaths: Set<String> = ["/", "/health", "/pair", "/pair-invite"]
            let isPluginRoute = path.hasPrefix("/plugins/")
            let isLoopback = isLoopbackConnection(context)
            if !publicPaths.contains(path) && !isPluginRoute && !isLoopback {
                let authHeader = head.headers.first(name: "Authorization") ?? ""
                let token =
                    authHeader.hasPrefix("Bearer ")
                    ? String(authHeader.dropFirst(7))
                    : ""

                let message: String
                if !apiKeyValidator.hasKeys {
                    message = "No access keys configured. Create one in Osaurus settings."
                } else {
                    let result = apiKeyValidator.validate(rawKey: token)
                    switch result {
                    case .valid:
                        message = ""
                    case .expired:
                        message = "Access key has expired"
                    case .revoked:
                        message = "Access key has been revoked"
                    case .invalid(let reason):
                        message = "Invalid access key: \(reason)"
                    }
                }

                if !message.isEmpty {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: stateRef.value.corsHeaders)
                    let errorBody = #"{"error":{"message":"\#(message)","type":"authentication_error"}}"#
                    sendResponse(
                        context: context,
                        version: head.version,
                        status: .unauthorized,
                        headers: headers,
                        body: errorBody
                    )
                    logRequest(
                        method: method,
                        path: path,
                        userAgent: userAgent,
                        requestBody: nil,
                        responseBody: errorBody,
                        responseStatus: 401,
                        startTime: startTime
                    )
                    stateRef.value.requestHead = nil
                    stateRef.value.requestBodyBuffer = nil
                    return
                }
            }

            // Handle simple HEAD for non-plugin paths only. Plugin routes
            // need the same matching/auth pipeline as GET so they can return
            // accurate Content-Type/Content-Length headers; falling through
            // to `handlePluginRoute` for HEAD lets the plugin handler decide,
            // and the response writer suppresses the body for HEAD.
            if head.method == .HEAD && !path.hasPrefix("/plugins/") {
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
            // Core endpoints — dispatched here directly. (`Router.swift` is a
            // legacy non-streaming dispatcher kept around as a reference; the
            // production HTTP path is fully owned by this handler.)
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
                handleHealthEndpoint(
                    head: head,
                    context: context,
                    startTime: startTime,
                    userAgent: userAgent,
                    method: method,
                    path: path
                )
            } else if head.method == .GET, path == "/admin/cache-stats" {
                handleCacheStatsEndpoint(
                    head: head,
                    context: context,
                    startTime: startTime,
                    userAgent: userAgent,
                    method: method,
                    path: path
                )
            } else if head.method == .GET, path == "/models" {
                handleModelsEndpoint(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .GET, path == "/tags" {
                handleTagsEndpoint(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/show" {
                handleShowEndpoint(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/chat/completions" || path == "/v1/chat/completions" {
                handleChatCompletions(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/generate" {
                handleOllamaGenerate(head: head, context: context, startTime: startTime, userAgent: userAgent)
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
            } else if head.method == .POST, path == "/pair" {
                handlePairEndpoint(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/pair-invite" {
                handlePairInviteEndpoint(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .GET, path == "/agents" {
                handleListAgents(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .GET, path.hasPrefix("/agents/") {
                handleGetAgentEndpoint(
                    head: head,
                    context: context,
                    path: path,
                    startTime: startTime,
                    userAgent: userAgent
                )
            } else if head.method == .POST, path.hasPrefix("/agents/"), path.hasSuffix("/run") {
                handleAgentRunEndpoint(
                    head: head,
                    context: context,
                    path: path,
                    startTime: startTime,
                    userAgent: userAgent
                )
            } else if head.method == .POST, path.hasPrefix("/agents/"), path.hasSuffix("/dispatch") {
                handleDispatchEndpoint(
                    head: head,
                    context: context,
                    path: path,
                    startTime: startTime,
                    userAgent: userAgent
                )
            } else if head.method == .GET, path.hasPrefix("/tasks/"), !path.hasSuffix("/clarify") {
                handleTaskStatusEndpoint(
                    head: head,
                    context: context,
                    path: path,
                    startTime: startTime,
                    userAgent: userAgent
                )
            } else if head.method == .DELETE, path.hasPrefix("/tasks/") {
                handleTaskCancelEndpoint(
                    head: head,
                    context: context,
                    path: path,
                    startTime: startTime,
                    userAgent: userAgent
                )
            } else if head.method == .POST, path.hasPrefix("/tasks/"), path.hasSuffix("/clarify") {
                handleTaskClarifyEndpoint(
                    head: head,
                    context: context,
                    path: path,
                    startTime: startTime,
                    userAgent: userAgent
                )
            } else if head.method == .POST, path == "/embeddings" || path == "/embed" {
                handleEmbeddings(
                    head: head,
                    context: context,
                    startTime: startTime,
                    userAgent: userAgent,
                    ollamaFormat: path == "/embed"
                )
            } else if path.hasPrefix("/plugins/") {
                handlePluginRoute(
                    head: head,
                    context: context,
                    startTime: startTime,
                    userAgent: userAgent,
                    isLoopback: isLoopback
                )
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

    /// `/admin/cache-stats` exposes the current vmlx `CacheCoordinator`
    /// counters for loaded models. It is intentionally read-only and does not
    /// load a model by itself; an empty `models` array is the correct cold
    /// startup state.
    private func handleCacheStatsEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        method: String,
        path: String
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let version = head.version
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logMethod = method
        let logPath = path

        Task(priority: .userInitiated) {
            let cached = await ModelRuntime.shared.cachedModelSummaries()
            var aggregate: [String: Int] = [
                "prefix_hits": 0,
                "prefix_misses": 0,
                "paged_hits": 0,
                "paged_misses": 0,
                "disk_l2_hits": 0,
                "disk_l2_misses": 0,
                "disk_l2_stores": 0,
                "ssm_companion_hits": 0,
                "ssm_companion_misses": 0,
                "ssm_companion_rederives": 0,
            ]

            let models: [[String: Any]] = cached.map { summary in
                var row: [String: Any] = [
                    "name": summary.name,
                    "is_current": summary.isCurrent,
                    "weights_bytes": summary.bytes,
                ]
                if let draftStrategy = summary.draftStrategyDescription {
                    row["draft_strategy"] = draftStrategy
                } else {
                    row["draft_strategy"] = NSNull()
                }
                if let nativeMTPDepth = summary.nativeMTPDepth {
                    row["native_mtp_depth"] = nativeMTPDepth
                } else {
                    row["native_mtp_depth"] = NSNull()
                }
                let mlxPress = summary.mlxPressStatus
                var mlxPressStatus: [String: Any] = [
                    "enabled": mlxPress.enabled,
                    "backend": mlxPress.backend.rawValue,
                    "tiles_under_management": mlxPress.tilesUnderManagement,
                    "total_routed_bytes": mlxPress.totalRoutedBytes,
                ]
                if let coldFraction = mlxPress.coldFraction {
                    mlxPressStatus["cold_fraction"] = coldFraction
                } else {
                    mlxPressStatus["cold_fraction"] = NSNull()
                }
                row["mlx_press"] = mlxPressStatus
                guard let stats = summary.cacheStats else {
                    row["cache_enabled"] = false
                    return row
                }

                row["cache_enabled"] = true
                row["is_hybrid"] = stats.isHybrid
                row["is_paged_incompatible"] = stats.isPagedIncompatible

                var paged: [String: Any] = ["enabled": stats.pagedEnabled]
                if let pagedStats = stats.pagedStats {
                    paged["total_blocks"] = pagedStats.totalBlocks
                    paged["allocated_blocks"] = pagedStats.allocatedBlocks
                    paged["free_blocks"] = pagedStats.freeBlocks
                    paged["hits"] = pagedStats.cacheHits
                    paged["misses"] = pagedStats.cacheMisses
                    paged["evictions"] = pagedStats.evictions
                    aggregate["paged_hits", default: 0] += pagedStats.cacheHits
                    aggregate["paged_misses", default: 0] += pagedStats.cacheMisses
                    aggregate["prefix_hits", default: 0] += pagedStats.cacheHits
                    aggregate["prefix_misses", default: 0] += pagedStats.cacheMisses
                }
                row["paged_cache"] = paged

                var disk: [String: Any] = ["enabled": stats.diskEnabled]
                if let diskStats = stats.diskStats {
                    disk["hits"] = diskStats.hits
                    disk["misses"] = diskStats.misses
                    disk["stores"] = diskStats.stores
                    disk["max_size_bytes"] = diskStats.maxSizeBytes
                    aggregate["disk_l2_hits", default: 0] += diskStats.hits
                    aggregate["disk_l2_misses", default: 0] += diskStats.misses
                    aggregate["disk_l2_stores", default: 0] += diskStats.stores
                    aggregate["prefix_hits", default: 0] += diskStats.hits
                    aggregate["prefix_misses", default: 0] += diskStats.misses
                }
                row["block_disk_store"] = disk

                let ssm = stats.ssmStats
                row["ssm_companion_cache"] = [
                    "hits": ssm.hits,
                    "misses": ssm.misses,
                    "rederives": ssm.reDerives,
                ]
                aggregate["ssm_companion_hits", default: 0] += ssm.hits
                aggregate["ssm_companion_misses", default: 0] += ssm.misses
                aggregate["ssm_companion_rederives", default: 0] += ssm.reDerives
                return row
            }

            let obj: [String: Any] = [
                "status": "ok",
                "timestamp": Date().ISO8601Format(),
                "models": models,
                "aggregate": aggregate,
            ]
            let data = try? JSONSerialization.data(withJSONObject: obj, options: .osaurusCanonical)
            let body = data.flatMap { String(decoding: $0, as: UTF8.self) } ?? "{}"
            let headers: [(String, String)] =
                [("Content-Type", "application/json; charset=utf-8")]
                + cors

            hop {
                logSelf.sendResponse(
                    context: ctx.value,
                    version: version,
                    status: .ok,
                    headers: headers,
                    body: body
                )
            }
            logSelf.logRequest(
                method: logMethod,
                path: logPath,
                userAgent: logUserAgent,
                requestBody: nil,
                responseBody: body,
                responseStatus: 200,
                startTime: logStartTime
            )
        }
    }

    // MARK: - Plugin Route Handler

    private func handlePluginRoute(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        isLoopback: Bool
    ) {
        let path = stateRef.value.normalizedPath
        let method = head.method.rawValue
        let corsHeaders = stateRef.value.corsHeaders

        // Parse: /plugins/<pluginId>/<subpath>
        let segments = path.dropFirst("/plugins/".count)
        guard let slashIdx = segments.firstIndex(of: "/") else {
            sendPluginError(
                context: context,
                head: head,
                status: .notFound,
                message: "Invalid plugin route",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
            return
        }
        let pluginId = String(segments[..<slashIdx])
        let subpath = String(segments[slashIdx...])

        // Reject path traversal
        if pluginId.contains("..") || subpath.contains("..") {
            sendPluginError(
                context: context,
                head: head,
                status: .badRequest,
                message: "Invalid path",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
            return
        }

        let loop = context.eventLoop
        let ctxBound = NIOLoopBound(context, eventLoop: loop)
        let bodyBuffer = stateRef.value.requestBodyBuffer
        let uri = head.uri
        let headersDict = Dictionary(
            head.headers.map { ($0.name.lowercased(), $0.value) },
            uniquingKeysWith: { $1 }
        )
        let version = head.version

        // All plugin route access requires an agent context.
        // Accept either the `X-Osaurus-Agent-Id` header (preferred for SDK
        // and tunnel callers) or the `osr_agent` query parameter (for
        // browser-launched web UIs that cannot set custom headers on the
        // top-level navigation). The injected `window.__osaurus` script
        // then carries the same id forward to the page's fetch calls.
        let queryAgent: String? = {
            guard let q = head.uri.split(separator: "?").dropFirst().first else { return nil }
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, kv[0] == "osr_agent" {
                    return kv[1].removingPercentEncoding ?? kv[1]
                }
            }
            return nil
        }()
        let agentIdStr = headersDict["x-osaurus-agent-id"] ?? queryAgent
        guard let agentIdStr, let agentUUID = UUID(uuidString: agentIdStr) else {
            sendPluginError(
                context: context,
                head: head,
                status: .unauthorized,
                message:
                    "Plugin routes require an agent context (X-Osaurus-Agent-Id header or osr_agent query parameter)",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
            return
        }

        // Narrow MainActor scope: only the few lookups that need it run on
        // MainActor. Route matching, auth, JSON encoding, plugin invocation,
        // and response handling all run off MainActor to avoid serializing
        // concurrent requests through the main thread.
        let task = Task {
            let loaded = await MainActor.run {
                PluginManager.shared.loadedPlugin(for: pluginId)
            }
            guard let loaded else {
                return self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .notFound,
                    message: "Plugin not found: \(pluginId)",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }

            let manifest = loaded.plugin.manifest

            // Check for static web serving first
            if let webSpec = loaded.webConfig {
                let mountPrefix = webSpec.mount.hasPrefix("/") ? webSpec.mount : "/\(webSpec.mount)"
                if subpath.hasPrefix(mountPrefix) {
                    // Tunnel exposure gate: web UIs are loopback-only by
                    // default. Plugins must opt in via `capabilities.web.tunnel_exposed`
                    // for the static UI to be reachable over the tunnel.
                    // We return 404 (not 403) so the existence of the
                    // route is not advertised to outside callers.
                    if !isLoopback && !webSpec.isTunnelExposed {
                        return self.sendPluginErrorFromTask(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            status: .notFound,
                            message: "No matching route",
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }
                    if webSpec.auth == .owner && !self.isValidOwnerAuth(headers: headersDict) {
                        return self.sendPluginErrorFromTask(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            status: .unauthorized,
                            message: "Authentication required",
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }

                    // Check for dev proxy configuration
                    if let proxyURL = Self.loadDevProxyURL(for: pluginId) {
                        let relPath = String(subpath.dropFirst(mountPrefix.count))
                        let targetPath = relPath.isEmpty ? "/" : relPath
                        // Forward the original method/headers/body so HMR,
                        // POST APIs, and any non-GET dev-server traffic
                        // works during plugin development.
                        let proxyBody: Data? = {
                            guard let buf = bodyBuffer, buf.readableBytes > 0 else { return nil }
                            return Data(buffer: buf)
                        }()
                        return await self.proxyToDevServer(
                            proxyBaseURL: proxyURL,
                            targetPath: targetPath,
                            pluginId: pluginId,
                            apiMount: webSpec.api_mount ?? "/api",
                            agentId: agentIdStr,
                            requestMethod: method,
                            requestHeaders: headersDict,
                            requestBody: proxyBody,
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }

                    let relPath = String(subpath.dropFirst(mountPrefix.count))
                    let filePath: String
                    if relPath.isEmpty || relPath == "/" {
                        filePath = webSpec.entry
                    } else {
                        filePath = relPath.hasPrefix("/") ? String(relPath.dropFirst()) : relPath
                    }

                    let versionDir = URL(fileURLWithPath: loaded.plugin.bundlePath).deletingLastPathComponent()
                    let webDir = versionDir.appendingPathComponent(webSpec.static_dir, isDirectory: true)
                    let fileURL = webDir.appendingPathComponent(filePath)

                    // Prevent escaping the web directory
                    let resolvedPath = fileURL.standardizedFileURL.path
                    let webDirPath = webDir.standardizedFileURL.path
                    guard resolvedPath.hasPrefix(webDirPath) else {
                        return self.sendPluginErrorFromTask(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            status: .forbidden,
                            message: "Access denied",
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }

                    let apiMount = webSpec.api_mount ?? "/api"
                    if FileManager.default.fileExists(atPath: resolvedPath) {
                        return self.serveStaticFile(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            filePath: resolvedPath,
                            pluginId: pluginId,
                            apiMount: apiMount,
                            agentId: agentIdStr,
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }

                    // SPA fallback: serve entry point for non-file paths
                    let entryPath = webDir.appendingPathComponent(webSpec.entry).path
                    if FileManager.default.fileExists(atPath: entryPath) {
                        return self.serveStaticFile(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            filePath: entryPath,
                            pluginId: pluginId,
                            apiMount: apiMount,
                            agentId: agentIdStr,
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }

                    return self.sendPluginErrorFromTask(
                        loop: loop,
                        ctxBound: ctxBound,
                        version: version,
                        status: .notFound,
                        message: "File not found",
                        corsHeaders: corsHeaders,
                        startTime: startTime,
                        method: method,
                        path: path,
                        userAgent: userAgent
                    )
                }
            }

            // Dynamic route matching with path-parameter extraction.
            guard let routeMatch = manifest.matchRouteWithParams(method: method, subpath: subpath) else {
                return self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .notFound,
                    message: "No matching route",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }
            let route = routeMatch.route

            // Tunnel exposure gate: dynamic routes are loopback-only by
            // default. Plugins must opt in via `tunnel_exposed: true` on
            // the route spec for it to be reachable over the tunnel.
            // We return 404 (not 403) so route existence isn't leaked.
            if !isLoopback && !route.isTunnelExposed {
                return self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .notFound,
                    message: "No matching route",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }

            switch route.auth {
            case .owner:
                if !self.isValidOwnerAuth(headers: headersDict) {
                    return self.sendPluginErrorFromTask(
                        loop: loop,
                        ctxBound: ctxBound,
                        version: version,
                        status: .unauthorized,
                        message: "Authentication required",
                        corsHeaders: corsHeaders,
                        startTime: startTime,
                        method: method,
                        path: path,
                        userAgent: userAgent
                    )
                }
            case .none, .verify:
                if !PluginRateLimiter.shared.allow(pluginId: pluginId) {
                    return self.sendPluginErrorFromTask(
                        loop: loop,
                        ctxBound: ctxBound,
                        version: version,
                        status: .tooManyRequests,
                        message: "Rate limit exceeded",
                        corsHeaders: corsHeaders,
                        startTime: startTime,
                        method: method,
                        path: path,
                        userAgent: userAgent
                    )
                }
            }

            guard loaded.plugin.hasRouteHandler else {
                return self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .notImplemented,
                    message: "Plugin does not support route handling",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }

            let queryParams = OsaurusHTTPRequest.parseQueryParams(from: uri)

            var bodyString = ""
            var bodyEncoding = "utf8"
            if let buf = bodyBuffer, buf.readableBytes > 0 {
                var readBuf = buf
                if let str = readBuf.readString(length: readBuf.readableBytes) {
                    bodyString = str
                } else {
                    let data = Data(buffer: buf)
                    bodyString = data.base64EncodedString()
                    bodyEncoding = "base64"
                }
            }

            let serverPort = self.configuration.port
            let localBaseURL = "http://127.0.0.1:\(serverPort)"

            // Second (and last) MainActor hop: resolve tunnel URL and agent address
            let (agentAddress, tunnelURL) = await MainActor.run {
                let address = AgentManager.shared.agent(for: agentUUID)?.agentAddress ?? ""
                let tunnel = Self.resolveTunnelBaseURL(for: agentUUID)
                return (address, tunnel)
            }

            let baseURL = tunnelURL ?? localBaseURL
            let pluginURL = "\(baseURL)/plugins/\(pluginId)"

            let request = OsaurusHTTPRequest(
                route_id: route.id,
                method: method,
                path: subpath,
                query: queryParams,
                path_params: routeMatch.pathParams,
                headers: headersDict,
                body: bodyString,
                body_encoding: bodyEncoding,
                remote_addr: "",
                plugin_id: pluginId,
                osaurus: .init(
                    base_url: baseURL,
                    plugin_url: pluginURL,
                    agent_address: agentAddress
                )
            )

            let encoder = JSONEncoder.osaurusCanonical()
            guard let requestData = try? encoder.encode(request),
                let requestJSON = String(data: requestData, encoding: .utf8)
            else {
                return self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .internalServerError,
                    message: "Failed to encode request",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }

            do {
                let responseJSON = try await loaded.plugin.handleRoute(requestJSON: requestJSON, agentId: agentUUID)

                guard let responseData = responseJSON.data(using: .utf8),
                    let response = try? JSONDecoder().decode(OsaurusHTTPResponse.self, from: responseData)
                else {
                    return self.sendPluginErrorFromTask(
                        loop: loop,
                        ctxBound: ctxBound,
                        version: version,
                        status: .internalServerError,
                        message: "Invalid plugin response",
                        corsHeaders: corsHeaders,
                        startTime: startTime,
                        method: method,
                        path: path,
                        userAgent: userAgent
                    )
                }

                let httpStatus = HTTPResponseStatus(statusCode: response.status)
                var responseHeaders: [(String, String)] = corsHeaders
                if let hdrs = response.headers {
                    for (k, v) in hdrs {
                        responseHeaders.append((k, v))
                    }
                }

                var responseBody = ""
                if let body = response.body {
                    if response.body_encoding == "base64" {
                        if let decoded = Data(base64Encoded: body) {
                            self.sendBinaryPluginResponse(
                                loop: loop,
                                ctxBound: ctxBound,
                                version: version,
                                status: httpStatus,
                                headers: responseHeaders,
                                body: decoded,
                                startTime: startTime,
                                method: method,
                                path: path,
                                userAgent: userAgent
                            )
                            return
                        }
                        // Plugin claimed base64 but the body did not decode.
                        // Surface the corruption rather than silently sending
                        // the raw string; binary clients would otherwise get
                        // garbage they cannot detect.
                        return self.sendPluginErrorFromTask(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            status: .badGateway,
                            message:
                                "Plugin response declared body_encoding=base64 but the body is not valid base64.",
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }
                    responseBody = body
                }

                self.sendPluginResponse(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: httpStatus,
                    headers: responseHeaders,
                    body: responseBody,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            } catch {
                self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .internalServerError,
                    message: "Plugin error: \(error.localizedDescription)",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }
        }
        _ = task
    }

    private func sendPluginError(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        status: HTTPResponseStatus,
        message: String,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        var headers = [("Content-Type", "application/json; charset=utf-8")]
        headers.append(contentsOf: corsHeaders)
        let body = #"{"error":{"message":"\#(message)"}}"#
        sendResponse(context: context, version: head.version, status: status, headers: headers, body: body)
        logRequest(
            method: method,
            path: path,
            userAgent: userAgent,
            requestBody: nil,
            responseBody: body,
            responseStatus: Int(status.code),
            startTime: startTime
        )
    }

    /// Core NIO response writer for plugin routes. All plugin response helpers funnel through this.
    private func writePluginResponse(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        bodyWriter: @Sendable @escaping (ChannelHandlerContext) -> ByteBuffer
    ) {
        executeOnLoop(loop) {
            let context = ctxBound.value
            var responseHead = HTTPResponseHead(version: version, status: status)
            var nioHeaders = HTTPHeaders()
            for (name, value) in headers { nioHeaders.add(name: name, value: value) }
            let buffer = bodyWriter(context)
            nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
            nioHeaders.add(name: "Connection", value: "close")
            responseHead.headers = nioHeaders
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                ctxBound.value.close(promise: nil)
            }
        }
    }

    private func sendPluginErrorFromTask(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        message: String,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        let headers: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")] + corsHeaders
        let body = #"{"error":{"message":"\#(message)"}}"#
        writePluginResponse(loop: loop, ctxBound: ctxBound, version: version, status: status, headers: headers) { ctx in
            var buffer = ctx.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            return buffer
        }
        logRequest(
            method: method,
            path: path,
            userAgent: userAgent,
            requestBody: nil,
            responseBody: body,
            responseStatus: Int(status.code),
            startTime: startTime
        )
    }

    private func sendPluginResponse(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: String,
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        writePluginResponse(loop: loop, ctxBound: ctxBound, version: version, status: status, headers: headers) { ctx in
            var buffer = ctx.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            return buffer
        }
        logRequest(
            method: method,
            path: path,
            userAgent: userAgent,
            requestBody: nil,
            responseBody: body,
            responseStatus: Int(status.code),
            startTime: startTime
        )
    }

    private func sendBinaryPluginResponse(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: Data,
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        writePluginResponse(loop: loop, ctxBound: ctxBound, version: version, status: status, headers: headers) { ctx in
            var buffer = ctx.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            return buffer
        }
        logRequest(
            method: method,
            path: path,
            userAgent: userAgent,
            requestBody: nil,
            responseBody: nil,
            responseStatus: Int(status.code),
            startTime: startTime
        )
    }

    private func serveStaticFile(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        filePath: String,
        pluginId: String,
        apiMount: String = "/api",
        agentId: String? = nil,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        guard let fileData = FileManager.default.contents(atPath: filePath) else {
            sendPluginErrorFromTask(
                loop: loop,
                ctxBound: ctxBound,
                version: version,
                status: .notFound,
                message: "File not found",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
            return
        }

        let ext = (filePath as NSString).pathExtension
        let mimeType = MIMEType.forExtension(ext)
        var headers: [(String, String)] = corsHeaders
        headers.append(("Content-Type", mimeType))
        headers.append(("Cache-Control", "public, max-age=3600"))

        if ext == "html" || ext == "htm", var html = String(data: fileData, encoding: .utf8) {
            Self.injectOsaurusContext(into: &html, pluginId: pluginId, apiMount: apiMount, agentId: agentId)
            sendPluginResponse(
                loop: loop,
                ctxBound: ctxBound,
                version: version,
                status: .ok,
                headers: headers,
                body: html,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
        } else {
            sendBinaryPluginResponse(
                loop: loop,
                ctxBound: ctxBound,
                version: version,
                status: .ok,
                headers: headers,
                body: fileData,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
        }
    }

    /// Validates a Bearer token from the Authorization header.
    /// Returns true if the token is a valid `osk-v1` access key.
    private func isValidOwnerAuth(headers: [String: String]) -> Bool {
        let authHeader = headers["authorization"] ?? ""
        let token = authHeader.hasPrefix("Bearer ") ? String(authHeader.dropFirst(7)) : ""
        if case .valid = apiKeyValidator.validate(rawKey: token) { return true }
        return false
    }

    /// Injects the `window.__osaurus` context object into an HTML string before `</head>`.
    /// Injects a small context object into the plugin's web HTML. Plugins
    /// can opt in to a custom API mount via `capabilities.web.api_mount`
    /// (e.g. `"/v2"`); the default `/api` is preserved when unset.
    /// `agentId` is propagated to the page so the plugin's `fetch()` calls
    /// can attach it as the `X-Osaurus-Agent-Id` header without re-entering
    /// the URL bar.
    private static func injectOsaurusContext(
        into html: inout String,
        pluginId: String,
        apiMount: String = "/api",
        agentId: String? = nil
    ) {
        let normalizedApiMount: String = {
            let trimmed = apiMount.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return "/api" }
            return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        }()
        let agentField = agentId.map { #"agentId: "\#($0)","# } ?? ""
        let script = """
            <script>
            window.__osaurus = {
              pluginId: "\(pluginId)",
              baseUrl: "/plugins/\(pluginId)",
              apiUrl: "/plugins/\(pluginId)\(normalizedApiMount)",
              \(agentField)
              // Helper that wraps fetch with the X-Osaurus-Agent-Id header
              // so the page never accidentally drops the agent context.
              fetch: function(input, init) {
                init = init || {};
                init.headers = new Headers(init.headers || {});
                if (window.__osaurus.agentId && !init.headers.has("X-Osaurus-Agent-Id")) {
                  init.headers.set("X-Osaurus-Agent-Id", window.__osaurus.agentId);
                }
                return fetch(input, init);
              }
            };
            </script>
            """
        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            html.insert(contentsOf: "\n\(script)\n", at: headEnd.lowerBound)
        }
    }

    /// Loads the dev proxy URL for a plugin from the dev-proxy.json config file.
    private static func loadDevProxyURL(for pluginId: String) -> String? {
        let configFile = OsaurusPaths.config().appendingPathComponent("dev-proxy.json")
        guard let data = try? Data(contentsOf: configFile),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let configPluginId = obj["plugin_id"] as? String,
            configPluginId == pluginId,
            let proxyURL = obj["web_proxy"] as? String
        else { return nil }
        return proxyURL
    }

    /// Proxies a web request to a local dev server for HMR support.
    private func proxyToDevServer(
        proxyBaseURL: String,
        targetPath: String,
        pluginId: String,
        apiMount: String = "/api",
        agentId: String? = nil,
        requestMethod: String,
        requestHeaders: [String: String],
        requestBody: Data?,
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) async {
        let targetURL = proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + targetPath
        guard let url = URL(string: targetURL) else {
            sendPluginErrorFromTask(
                loop: loop,
                ctxBound: ctxBound,
                version: version,
                status: .badGateway,
                message: "Invalid proxy URL",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = requestMethod
        request.timeoutInterval = 10
        // Forward the request body for non-GET methods so things like Vite
        // HMR pings, plugin POST APIs, and form submissions work.
        if let body = requestBody, !body.isEmpty {
            request.httpBody = body
        }
        // Forward most headers verbatim. Drop hop-by-hop and host-management
        // headers that URLSession should set for us, and the agent header
        // (which is host-internal context, not relevant to the dev server).
        let stripped: Set<String> = [
            "host", "content-length", "connection", "transfer-encoding",
            "x-osaurus-agent-id", "authorization",
        ]
        for (k, v) in requestHeaders where !stripped.contains(k.lowercased()) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .badGateway,
                    message: "Invalid response from dev server",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
                return
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            var headers: [(String, String)] = corsHeaders
            headers.append(("Content-Type", contentType))
            headers.append(("Access-Control-Allow-Origin", "*"))

            if contentType.contains("text/html"), var html = String(data: data, encoding: .utf8) {
                Self.injectOsaurusContext(into: &html, pluginId: pluginId, apiMount: apiMount, agentId: agentId)
                sendPluginResponse(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: HTTPResponseStatus(statusCode: httpResponse.statusCode),
                    headers: headers,
                    body: html,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            } else {
                sendBinaryPluginResponse(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: HTTPResponseStatus(statusCode: httpResponse.statusCode),
                    headers: headers,
                    body: data,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }
        } catch {
            sendPluginErrorFromTask(
                loop: loop,
                ctxBound: ctxBound,
                version: version,
                status: .badGateway,
                message: "Dev server unreachable: \(error.localizedDescription)",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
        }
    }

    /// Resolves the tunnel base URL for a specific agent from RelayTunnelManager.
    @MainActor
    private static func resolveTunnelBaseURL(for agentId: UUID) -> String? {
        if case .connected(let url) = RelayTunnelManager.shared.agentStatuses[agentId] {
            return url
        }
        return nil
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

    /// Decide the body-byte cap for the request based on its route. Most
    /// endpoints get the generic configuration limit; `/pair` and
    /// `/pair-invite` are tighter because they are unauthenticated and only
    /// ever carry a small JSON envelope.
    private func bodyByteLimit(for head: HTTPRequestHead) -> Int {
        let path = normalize(extractPath(from: head.uri))
        if path == "/pair" || path == "/pair-invite" {
            return configuration.maxPairingBodyBytes
        }
        return configuration.maxRequestBodyBytes
    }

    /// Reply 413 Payload Too Large, log the rejection so it shows up in the
    /// request log, mark the request as rejected so subsequent body parts
    /// are dropped, and close the connection. We do this *before* the auth
    /// gate so an unauthenticated client cannot OOM the server.
    private func rejectPayloadTooLarge(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        declaredLength: Int,
        limit: Int
    ) {
        stateRef.value.rejectedTooLarge = true
        stateRef.value.requestBodyBuffer = nil

        let path = normalize(extractPath(from: head.uri))
        let body =
            #"{"error":{"message":"Request body too large (\#(declaredLength) > \#(limit) bytes)","type":"payload_too_large"}}"#
        var headers = [("Content-Type", "application/json; charset=utf-8")]
        headers.append(contentsOf: stateRef.value.corsHeaders)
        sendResponse(
            context: context,
            version: head.version,
            status: .payloadTooLarge,
            headers: headers,
            body: body
        )
        logRequest(
            method: head.method.rawValue,
            path: path,
            userAgent: head.headers.first(name: "User-Agent"),
            requestBody: nil,
            responseBody: body,
            responseStatus: 413,
            startTime: stateRef.value.requestStartTime
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

    /// Whether the inbound connection is a "trusted local caller" — i.e., a
    /// process on the user's own machine reaching us via 127.0.0.1 / ::1.
    /// Both the auth gate and CORS auto-trust use this predicate so the two
    /// stay in lockstep; flipping `trustLoopback` off (e.g. behind a reverse
    /// proxy) disables both.
    private func isLoopbackConnection(_ context: ChannelHandlerContext) -> Bool {
        trustLoopback && (context.channel.remoteAddress?.isLoopback ?? false)
    }

    /// Loopback callers always get `Access-Control-Allow-Origin: *` (issue
    /// #952): a request reaching us via 127.0.0.1 / ::1 is by definition on
    /// the user's machine, so it gets the same trust the auth gate already
    /// grants. Non-loopback callers respect `configuration.allowedOrigins`:
    /// a literal `"*"` matches everything; otherwise the request `Origin`
    /// header must appear in the list verbatim, in which case it's echoed
    /// back with `Vary: Origin`.
    private func computeCORSHeaders(
        for head: HTTPRequestHead,
        isPreflight: Bool,
        isLoopback: Bool
    ) -> [(String, String)] {
        let origin = head.headers.first(name: "Origin")
        var headers: [(String, String)] = []

        let allowsAny = isLoopback || configuration.allowedOrigins.contains("*")
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

    // MARK: - Chat handlers

    /// Enrich a chat request with the agent's system prompt and memory context
    /// when an agent ID is provided via the `X-Osaurus-Agent-Id` header.
    ///
    /// Goes through `composeChatContext` (the same entry point the chat UI
    /// uses) and then injects the rendered prompt + memory snippet into the
    /// outgoing message array. `executionMode: .none` matches the original
    /// HTTP-path semantics — sandbox / folder modes are chat-window-only;
    /// HTTP requests don't have one of those bound.
    private static func enrichWithAgentContext(
        _ request: ChatCompletionRequest,
        agentId: String?
    ) async -> ChatCompletionRequest {
        guard let agentId, !agentId.isEmpty,
            let agentUUID = UUID(uuidString: agentId)
        else { return request }

        var enriched = request
        let query = request.messages.last(where: { $0.role == "user" })?.content ?? ""
        let composed = await SystemPromptComposer.composeChatContext(
            agentId: agentUUID,
            executionMode: .none,
            query: query,
            messages: enriched.messages
        )
        if !composed.prompt.isEmpty {
            SystemPromptComposer.injectSystemContent(composed.prompt, into: &enriched.messages)
        }
        SystemPromptComposer.injectMemoryPrefix(composed.memorySection, into: &enriched.messages)
        let mergedTools = mergeAgentContextTools(composed.tools, clientTools: request.tools)
        let resolvedToolChoice: ToolChoiceOption? = {
            guard let mergedTools, !mergedTools.isEmpty else { return nil }
            return request.tool_choice ?? .auto
        }()
        return enriched.withContext(
            messages: enriched.messages,
            tools: mergedTools,
            toolChoice: resolvedToolChoice
        )
    }

    private static func mergeAgentContextTools(
        _ agentTools: [Tool],
        clientTools: [Tool]?
    ) -> [Tool]? {
        let clientTools = clientTools ?? []
        guard !agentTools.isEmpty || !clientTools.isEmpty else { return nil }
        let clientNames = Set(clientTools.map(\.function.name))
        let contextTools = agentTools.filter { !clientNames.contains($0.function.name) }
        return contextTools + clientTools
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
        guard MemoryConfigurationStore.load().enabled else {
            let responseBody = #"{"error":"memory_disabled","message":"Memory is disabled"}"#
            sendResponse(
                context: context,
                version: head.version,
                status: .serviceUnavailable,
                headers: [("Content-Type", "application/json; charset=utf-8")] + cors,
                body: responseBody
            )
            logRequest(
                method: "POST",
                path: "/memory/ingest",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseBody: responseBody,
                responseStatus: 503,
                startTime: startTime,
                errorMessage: "memory disabled"
            )
            return
        }

        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString

        Task(priority: .userInitiated) {
            let db = MemoryDatabase.shared
            guard await MemoryDatabase.waitForSharedOpen(timeoutSeconds: 8) else {
                let responseBody = #"{"error":"memory_database_unavailable","message":"Memory database is not ready"}"#
                var headers: [(String, String)] = [("Content-Type", "application/json")]
                headers.append(contentsOf: cors)
                let headersCopy = headers
                hop {
                    var responseHead = HTTPResponseHead(version: head.version, status: .serviceUnavailable)
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
                    responseStatus: 503,
                    startTime: logStartTime,
                    errorMessage: "memory database not ready"
                )
                return
            }

            let skipExtraction = req.skip_extraction ?? false

            do {
                try db.deleteTranscriptForConversation(req.conversation_id)

                for (i, turn) in req.turns.enumerated() {
                    let turnDate = turn.date ?? req.session_date

                    let pairs: [(role: String, content: String, index: Int)] = [
                        ("user", turn.user, i * 2),
                        ("assistant", turn.assistant, i * 2 + 1),
                    ]
                    for (role, content, chunkIndex) in pairs {
                        let tokens = TokenEstimator.estimate(content)
                        let storedTurn = TranscriptTurn(
                            conversationId: req.conversation_id,
                            chunkIndex: chunkIndex,
                            role: role,
                            content: content,
                            tokenCount: tokens,
                            agentId: req.agent_id
                        )
                        try db.insertTranscriptTurn(
                            agentId: req.agent_id,
                            conversationId: req.conversation_id,
                            chunkIndex: chunkIndex,
                            role: role,
                            content: content,
                            tokenCount: tokens,
                            createdAt: turnDate
                        )
                        await MemorySearchService.shared.indexTranscriptTurn(storedTurn)
                    }

                    if !skipExtraction {
                        await MemoryService.shared.bufferTurn(
                            userMessage: turn.user,
                            assistantMessage: turn.assistant,
                            agentId: req.agent_id,
                            conversationId: req.conversation_id,
                            sessionDate: turnDate
                        )
                    }
                }
            } catch {
                let responseBody = #"{"error":"memory_ingest_failed","message":"Memory transcript write failed"}"#
                var headers: [(String, String)] = [("Content-Type", "application/json")]
                headers.append(contentsOf: cors)
                let headersCopy = headers
                hop {
                    var responseHead = HTTPResponseHead(version: head.version, status: .internalServerError)
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
                    responseStatus: 500,
                    startTime: logStartTime,
                    errorMessage: "\(error)"
                )
                return
            }

            // Ingestion always implies "I'm done with this conversation
            // batch": flush distillation immediately so callers (benchmarks,
            // bulk imports) don't have to wait for the debounce.
            if !skipExtraction {
                await MemoryService.shared.flushSession(
                    agentId: req.agent_id,
                    conversationId: req.conversation_id
                )
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

    // MARK: - Agents

    private struct AgentListItem: Codable {
        let id: String
        let name: String
        let description: String
        let default_model: String?
        /// Server-resolved model id, known before the first streamed chunk.
        let effective_model: String?
        /// True when the resolved model has a `disableThinking` ModelProfile
        /// option — i.e. clients should render a thinking on/off toggle.
        let supports_thinking: Bool
        let supports_vision: Bool
        let is_built_in: Bool
        let memory_entry_count: Int
        let created_at: String
        let updated_at: String
    }

    private struct AgentListResponse: Codable {
        let agents: [AgentListItem]
    }

    // MARK: - Pair Endpoint

    private struct PairRequest: Codable {
        let connectorAddress: String
        let agentId: String
        let nonce: String
        let signature: String
    }

    private struct PairResponse: Codable {
        let agentAddress: String
        let apiKey: String
        let isPermanent: Bool
    }

    /// POST /pair — unauthenticated endpoint for cryptographic Bonjour pairing.
    private func handlePairEndpoint(
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

        guard let req = try? JSONDecoder().decode(PairRequest.self, from: data) else {
            var headers = [("Content-Type", "application/json; charset=utf-8")]
            headers.append(contentsOf: stateRef.value.corsHeaders)
            let body = #"{"error":"Invalid pairing request"}"#
            sendResponse(context: context, version: head.version, status: .badRequest, headers: headers, body: body)
            logRequest(
                method: "POST",
                path: "/pair",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseBody: body,
                responseStatus: 400,
                startTime: startTime
            )
            return
        }

        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        // Strip port from Host header (e.g. "device.local:1337" → "device.local")
        let pairingHost =
            (head.headers.first(name: "Host") ?? "unknown")
            .components(separatedBy: ":").first ?? "unknown"

        Task(priority: .userInitiated) {
            // 1. Verify the connector's signature over the nonce.
            let hexSig = req.signature.hasPrefix("0x") ? String(req.signature.dropFirst(2)) : req.signature
            guard let sigBytes = Data(hexEncoded: hexSig),
                let recovered = try? recoverAddress(
                    payload: Data(req.nonce.utf8),
                    signature: sigBytes,
                    domainPrefix: "Osaurus Signed Pairing"
                ),
                recovered == req.connectorAddress
            else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    let body = #"{"error":"Signature verification failed"}"#
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .unauthorized,
                        headers: headers,
                        body: body
                    )
                    logSelf.logRequest(
                        method: "POST",
                        path: "/pair",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseBody: body,
                        responseStatus: 401,
                        startTime: logStartTime
                    )
                }
                return
            }

            // 2. Resolve the target agent.
            let agents = await MainActor.run { AgentManager.shared.agents }
            guard let agentUUID = UUID(uuidString: req.agentId),
                let agent = agents.first(where: { $0.id == agentUUID && $0.bonjourEnabled }),
                let agentAddress = agent.agentAddress
            else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    let body = #"{"error":"Agent not found or not available for pairing"}"#
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .notFound,
                        headers: headers,
                        body: body
                    )
                    logSelf.logRequest(
                        method: "POST",
                        path: "/pair",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseBody: body,
                        responseStatus: 404,
                        startTime: logStartTime
                    )
                }
                return
            }

            // 3. Show the approval popup on the advertiser's device.
            let approval = await PairingPromptService.requestApproval(
                connectorAddress: req.connectorAddress,
                agentName: agent.name
            )

            guard approval.approved else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    let body = #"{"error":"Pairing denied"}"#
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .forbidden,
                        headers: headers,
                        body: body
                    )
                    logSelf.logRequest(
                        method: "POST",
                        path: "/pair",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseBody: body,
                        responseStatus: 403,
                        startTime: logStartTime
                    )
                }
                return
            }

            let isPermanent = approval.isPermanent

            // 4. Generate an *agent-scoped* osk-v1 API key. The token's `aud`
            //    is the agent's address, so it cannot be presented to other
            //    agents — pre-fix this minted a master-scoped, never-expiring
            //    key after agent-specific approval, a hidden privilege upgrade.
            //
            //    Default to a 90-day expiry; only mint with `.never` when the
            //    user explicitly opts in via the approval dialog's "Make this
            //    access permanent" toggle.
            //
            //    Generating the key triggers biometric auth to derive the
            //    agent key from the Master Key.
            let label = "Paired – \(pairingHost)"
            guard let agentIndex = agent.agentIndex else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    let body = #"{"error":"Agent is missing a derived key index"}"#
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .internalServerError,
                        headers: headers,
                        body: body
                    )
                    logSelf.logRequest(
                        method: "POST",
                        path: "/pair",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseBody: body,
                        responseStatus: 500,
                        startTime: logStartTime
                    )
                }
                return
            }
            let expiration: AccessKeyExpiration = isPermanent ? .never : .days90
            guard
                let (fullKey, keyInfo) = try? APIKeyManager.shared.generate(
                    label: label,
                    expiration: expiration,
                    agentIndex: agentIndex
                )
            else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    let body = #"{"error":"Failed to generate access key"}"#
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .internalServerError,
                        headers: headers,
                        body: body
                    )
                    logSelf.logRequest(
                        method: "POST",
                        path: "/pair",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseBody: body,
                        responseStatus: 500,
                        startTime: logStartTime
                    )
                }
                return
            }

            // Temporary keys are revoked and removed from the key list on app exit.
            if !isPermanent {
                TemporaryPairedKeyStore.shared.register(keyId: keyInfo.id)
            }

            // 5. Return the agent's address, the generated API key, and the permanence flag.
            let response = PairResponse(agentAddress: agentAddress, apiKey: fullKey, isPermanent: isPermanent)
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(response)).map { String(decoding: $0, as: UTF8.self) }
                ?? #"{"error":"Encoding failed"}"#
            // Never log the freshly minted key. The wire response still
            // contains it; the request log gets a redacted copy with the
            // same shape so operators can see "this pairing happened" without
            // recovering the credential from the ring buffer.
            let redactedResponse = PairResponse(
                agentAddress: agentAddress,
                apiKey: "<redacted>",
                isPermanent: isPermanent
            )
            let redactedJson =
                (try? JSONEncoder.osaurusCanonical().encode(redactedResponse)).map {
                    String(decoding: $0, as: UTF8.self)
                }
                ?? #"{"agentAddress":"<redacted>","apiKey":"<redacted>"}"#

            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(context: ctx.value, version: head.version, status: .ok, headers: headers, body: json)
                logSelf.logRequest(
                    method: "POST",
                    path: "/pair",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: redactedJson,
                    responseStatus: 200,
                    startTime: logStartTime
                )
            }
        }
    }

    // MARK: - /pair-invite (signed deeplink redemption)

    private struct PairInviteResponse: Codable {
        let agentAddress: String
        let agentName: String
        let agentDescription: String?
        let relayBaseURL: String
        let apiKey: String
    }

    /// POST /pair-invite — unauthenticated endpoint that swaps a signed
    /// `AgentInvite` for an `osk-v1` access key. The invite IS the auth: it's
    /// signed by the agent's per-agent child key, it carries a single-use
    /// nonce that's recorded server-side, and it has a hard expiry.
    ///
    /// The receiving client is expected to POST the EXACT JSON body that was
    /// embedded in the deeplink's `pair` query parameter so the server can
    /// re-verify the signature it has on hand.
    private func handlePairInviteEndpoint(
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

        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        // Origin label for the issued-invite ledger (purely informational).
        let origin =
            (head.headers.first(name: "X-Forwarded-For")
            ?? head.headers.first(name: "Host"))?.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces)

        func reply(status: HTTPResponseStatus, body: String, code: Int) {
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: status,
                    headers: headers,
                    body: body
                )
                logSelf.logRequest(
                    method: "POST",
                    path: "/pair-invite",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: body,
                    responseStatus: code,
                    startTime: logStartTime
                )
            }
        }

        guard let invite = try? JSONDecoder().decode(AgentInvite.self, from: data) else {
            reply(status: .badRequest, body: #"{"error":"Invalid invite payload"}"#, code: 400)
            return
        }
        guard invite.v == AgentInvite.currentVersion else {
            reply(status: .badRequest, body: #"{"error":"Unsupported invite version"}"#, code: 400)
            return
        }
        do {
            try invite.verifySignature()
        } catch {
            reply(status: .unauthorized, body: #"{"error":"Signature verification failed"}"#, code: 401)
            return
        }
        if invite.isExpired {
            reply(status: .gone, body: #"{"error":"Invite has expired"}"#, code: 410)
            return
        }

        Task(priority: .userInitiated) {
            // 1. Resolve a local agent that matches the invite address. The
            //    receiver only ever connects via the relay tunnel, so the
            //    address has to belong to an agent on THIS device.
            let agents = await MainActor.run { AgentManager.shared.agents }
            guard
                let agent = agents.first(where: { ($0.agentAddress?.lowercased() ?? "") == invite.addr.lowercased() }),
                let agentIndex = agent.agentIndex,
                let agentAddress = agent.agentAddress
            else {
                reply(status: .notFound, body: #"{"error":"Agent address not found on this server"}"#, code: 404)
                return
            }

            // 2. Verify + consume the nonce atomically so concurrent redemptions
            //    of the same invite cannot both succeed.
            let consume = await MainActor.run {
                AgentInviteStore.verifyAndConsume(nonce: invite.nonce, for: agent.id, from: origin)
            }
            switch consume {
            case .unknownNonce:
                // The signature checks out but we have no record of this nonce.
                // Could be a replay against a different agent, an invite issued
                // before a wipe, or simply a mismatched device. Reject so a
                // stolen URL can't mint forever-keys against a fresh ledger.
                reply(status: .unauthorized, body: #"{"error":"Invite is not registered on this server"}"#, code: 401)
                return
            case .alreadyUsed:
                reply(status: .conflict, body: #"{"error":"Invite has already been redeemed"}"#, code: 409)
                return
            case .revoked:
                reply(status: .forbidden, body: #"{"error":"Invite was revoked"}"#, code: 403)
                return
            case .expired:
                reply(status: .gone, body: #"{"error":"Invite has expired"}"#, code: 410)
                return
            case .consumed:
                break
            }

            // 3. Mint an agent-scoped osk-v1 access key. Triggers biometric.
            //    1-year expiry matches the share-link UX: long enough that
            //    users don't get random disconnects, short enough that a
            //    forgotten leak self-resolves. Sender can revoke any time
            //    via the issued-invites list.
            let label = "Invite – \(invite.name) (\(invite.nonce.prefix(8)))"
            do {
                let (fullKey, keyInfo) = try APIKeyManager.shared.generate(
                    label: label,
                    expiration: .year1,
                    agentIndex: agentIndex
                )
                await MainActor.run {
                    AgentInviteStore.attachAccessKey(
                        nonce: invite.nonce,
                        for: agent.id,
                        accessKeyId: keyInfo.id
                    )
                }

                func responseBody(apiKey: String) -> String {
                    let body = PairInviteResponse(
                        agentAddress: agentAddress,
                        agentName: agent.name,
                        agentDescription: agent.description.isEmpty ? nil : agent.description,
                        relayBaseURL: invite.url,
                        apiKey: apiKey
                    )
                    return (try? JSONEncoder.osaurusCanonical().encode(body))
                        .map { String(decoding: $0, as: UTF8.self) }
                        ?? #"{"error":"Encoding failed"}"#
                }

                let json = responseBody(apiKey: fullKey)
                // Redacted twin for the request log — the ring buffer powers
                // the in-app diagnostics panel and must never echo the key.
                let redactedJson = responseBody(apiKey: "<redacted>")
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
                    logSelf.logRequest(
                        method: "POST",
                        path: "/pair-invite",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseBody: redactedJson,
                        responseStatus: 200,
                        startTime: logStartTime
                    )
                }
            } catch {
                // Roll the nonce back to active so a transient APIKeyManager
                // failure doesn't permanently brick the invite.
                await MainActor.run {
                    AgentInviteStore.rollbackConsume(nonce: invite.nonce, for: agent.id)
                }
                reply(status: .internalServerError, body: #"{"error":"Failed to mint access key"}"#, code: 500)
            }
        }
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
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent

        Task(priority: .userInitiated) {
            let agents = await MainActor.run { AgentManager.shared.agents }

            let db = MemoryDatabase.shared
            var memoryCounts: [String: Int] = [:]
            if db.isOpen, let counts = try? db.agentIdsWithPinnedFacts() {
                for (agentId, count) in counts {
                    memoryCounts[agentId] = count
                }
            }

            let formatter = ISO8601DateFormatter()
            let effectiveModels = await MainActor.run {
                Dictionary(
                    uniqueKeysWithValues: agents.map {
                        ($0.id, AgentManager.shared.effectiveModel(for: $0.id))
                    }
                )
            }
            let items = agents.map { agent in
                let modelId = effectiveModels[agent.id] ?? agent.defaultModel
                let supportsVision = modelId.map { VLMDetection.isVLM(modelId: $0) } ?? false
                let supportsThinking =
                    modelId.flatMap { ModelProfileRegistry.profile(for: $0)?.thinkingOption } != nil
                return AgentListItem(
                    id: agent.id.uuidString,
                    name: agent.name,
                    description: agent.description,
                    default_model: agent.defaultModel,
                    effective_model: modelId,
                    supports_thinking: supportsThinking,
                    supports_vision: supportsVision,
                    is_built_in: agent.isBuiltIn,
                    memory_entry_count: memoryCounts[agent.id.uuidString] ?? 0,
                    created_at: formatter.string(from: agent.createdAt),
                    updated_at: formatter.string(from: agent.updatedAt)
                )
            }

            let response = AgentListResponse(agents: items)
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(response)).map { String(decoding: $0, as: UTF8.self) }
                ?? #"{"agents":[]}"#

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

    // MARK: - Agent Info & Run Endpoints

    /// GET /agents/{id} — return info for a single agent
    private func handleGetAgentEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        path: String,
        startTime: Date,
        userAgent: String?
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent

        // Extract agent ID: /agents/{id}
        let components = path.split(separator: "/")
        guard components.count == 2, components[0] == "agents", let agentId = UUID(uuidString: String(components[1]))
        else {
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .badRequest,
                    headers: headers,
                    body: #"{"error":"invalid_agent_id","message":"Invalid agent UUID in path"}"#
                )
            }
            return
        }

        Task(priority: .userInitiated) {
            guard let agent = await MainActor.run(body: { AgentManager.shared.agent(for: agentId) }) else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .notFound,
                        headers: headers,
                        body: #"{"error":"agent_not_found","message":"No agent found for the given ID"}"#
                    )
                }
                return
            }

            let formatter = ISO8601DateFormatter()
            let effectiveModelId =
                await MainActor.run {
                    AgentManager.shared.effectiveModel(for: agent.id)
                } ?? agent.defaultModel
            let supportsVision = effectiveModelId.map { VLMDetection.isVLM(modelId: $0) } ?? false
            let supportsThinking =
                effectiveModelId.flatMap { ModelProfileRegistry.profile(for: $0)?.thinkingOption } != nil
            let item = AgentListItem(
                id: agent.id.uuidString,
                name: agent.name,
                description: agent.description,
                default_model: agent.defaultModel,
                effective_model: effectiveModelId,
                supports_thinking: supportsThinking,
                supports_vision: supportsVision,
                is_built_in: agent.isBuiltIn,
                memory_entry_count: 0,
                created_at: formatter.string(from: agent.createdAt),
                updated_at: formatter.string(from: agent.updatedAt)
            )
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(item)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"

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
                path: path,
                userAgent: logUserAgent,
                requestBody: nil,
                responseBody: json,
                responseStatus: 200,
                startTime: logStartTime
            )
        }
    }

    /// POST /agents/{id}/run — run the full agent chat loop server-side.
    ///
    /// Accepts a `ChatCompletionRequest` body. Runs inference with the agent's
    /// system prompt and executes any tool calls locally on the server, looping
    /// until the model produces a final text response. Streams SSE text deltas
    /// back to the caller — tool invocations are never forwarded to the client.
    private func handleAgentRunEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        path: String,
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
                path: path,
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid request format"
            )
            return
        }

        // Extract agent ID: /agents/{id}/run
        let pathComponents = path.split(separator: "/")
        guard pathComponents.count >= 2, let agentId = UUID(uuidString: String(pathComponents[1])) else {
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: #"{"error":"invalid_agent_id","message":"Invalid agent UUID in path"}"#
            )
            return
        }

        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let writer = SSEResponseWriter()
        let writerBound = NIOLoopBound(writer, eventLoop: loop)
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let chatEngine = self.chatEngine

        let responseId = Self.shortId(prefix: "chatcmpl-", length: 12)
        let created = Int(Date().timeIntervalSince1970)

        hop { writerBound.value.writeHeaders(ctx.value, extraHeaders: cors) }

        Task(priority: .userInitiated) {
            // Resolve model: client sends "default" when no specific model was known
            let model: String
            if req.model.isEmpty || req.model == "default" {
                let agentModel = await MainActor.run { AgentManager.shared.effectiveModel(for: agentId) }
                model = agentModel ?? req.model
            } else {
                model = req.model
            }

            // Enrich with agent context (system prompt + memory)
            var messages = await Self.enrichWithAgentContext(req, agentId: agentId.uuidString).messages

            // INTENTIONAL DIVERGENCE FROM CHAT: the OpenAI-compatible HTTP
            // API is stateless (no Osaurus session id), so we cannot reuse
            // SessionToolStateStore, run a preflight LLM, or freeze a
            // per-session schema. Bare `alwaysLoadedSpecs(mode:)` keeps the
            // HTTP schema predictable and avoids per-request preflight cost.
            // See docs/AGENT_LOOP.md before "fixing" this onto resolveTools.
            //
            // Tools resolution:
            //   1. Always-loaded specs from the agent's execution mode form
            //      the base set (sandbox, folder, etc.).
            //   2. Client-supplied `req.tools` are appended (deduped by
            //      function name, client wins on conflicts) so callers can
            //      ship custom function definitions without losing the
            //      agent surface.
            let baseTools = await MainActor.run {
                let autonomousEnabled = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
                let mode = ToolRegistry.shared.resolveExecutionMode(
                    folderContext: nil,
                    autonomousEnabled: autonomousEnabled
                )
                return ToolRegistry.shared.alwaysLoadedSpecs(mode: mode)
            }
            let tools: [Tool] = {
                guard let clientTools = req.tools, !clientTools.isEmpty else { return baseTools }
                let clientNames = Set(clientTools.map { $0.function.name })
                let kept = baseTools.filter { !clientNames.contains($0.function.name) }
                return kept + clientTools
            }()
            // Honor client `tool_choice` when supplied (`none`, `auto`, or
            // a forced function). Default to `.auto` so existing clients
            // that set `tools` without `tool_choice` keep working.
            let resolvedToolChoice: ToolChoiceOption? = {
                if tools.isEmpty { return nil }
                return req.tool_choice ?? .auto
            }()

            let maxIterations = 30
            var iteration = 0
            let requestId = UUID().uuidString

            hop {
                writerBound.value.writeRole(
                    "assistant",
                    model: model,
                    responseId: responseId,
                    created: created,
                    prefixHash: nil,
                    context: ctx.value
                )
            }

            while iteration < maxIterations {
                iteration += 1

                var iterationReq = ChatCompletionRequest(
                    model: model,
                    messages: messages,
                    temperature: req.temperature,
                    max_tokens: req.resolvedMaxTokens,
                    stream: true,
                    top_p: req.top_p,
                    frequency_penalty: req.frequency_penalty,
                    presence_penalty: req.presence_penalty,
                    stop: req.stop,
                    n: nil,
                    tools: tools.isEmpty ? nil : tools,
                    tool_choice: resolvedToolChoice,
                    session_id: req.session_id,
                    seed: req.seed,
                    response_format: req.response_format,
                    stream_options: req.stream_options
                )
                if let enable = req.enable_thinking {
                    var opts = iterationReq.modelOptions ?? [:]
                    opts["disableThinking"] = .bool(!enable)
                    iterationReq.modelOptions = opts
                    iterationReq.enable_thinking = enable
                }
                iterationReq.reasoning_effort = req.reasoning_effort

                var responseContent = ""
                // Local models can emit multiple tool calls in a single
                // completion; ServiceToolInvocations carries the full batch.
                var pendingInvocations: [ServiceToolInvocation] = []

                do {
                    let stream = try await chatEngine.streamChat(request: iterationReq)
                    for try await delta in stream {
                        // Reasoning sentinel must be decoded BEFORE the
                        // generic `isSentinel` filter; emit it on the
                        // OpenAI extended `reasoning_content` channel
                        // and do NOT mix it into `responseContent`.
                        if let reasoning = StreamingReasoningHint.decode(delta) {
                            hop {
                                writerBound.value.writeReasoning(
                                    reasoning,
                                    model: model,
                                    responseId: responseId,
                                    created: created,
                                    context: ctx.value
                                )
                            }
                            continue
                        }
                        if StreamingStatsHint.decode(delta) != nil { continue }
                        if StreamingToolHint.isSentinel(delta) { continue }
                        responseContent += delta
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
                } catch let invs as ServiceToolInvocations {
                    pendingInvocations = invs.invocations
                } catch let inv as ServiceToolInvocation {
                    pendingInvocations = [inv]
                } catch {
                    // SSE response head was already written as 200 — the
                    // failure surfaces as an in-band SSE error chunk. Log
                    // the actual on-wire status (200) so dashboards don't
                    // mis-attribute a delivered stream as a 500.
                    hop {
                        writerBound.value.writeError(error.localizedDescription, context: ctx.value)
                        writerBound.value.writeEnd(ctx.value)
                    }
                    logSelf.logRequest(
                        method: "POST",
                        path: path,
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseStatus: 200,
                        startTime: logStartTime,
                        errorMessage: error.localizedDescription
                    )
                    return
                }

                if pendingInvocations.isEmpty {
                    // Final text response — done
                    messages.append(ChatMessage(role: "assistant", content: responseContent))
                    break
                }

                // Execute every parsed tool call. Independent calls run
                // in parallel via a TaskGroup so wall-clock time stays
                // proportional to the slowest call rather than the sum.
                // Per-call errors land as `ToolEnvelope.fromError` so a
                // single bad call never aborts the rest of the batch.
                let outcomes = await Self.runToolBatchInParallel(
                    pendingInvocations,
                    requestId: requestId,
                    agentId: agentId
                )

                var assistantToolCalls: [ToolCall] = []
                var toolResultsByCallId: [(String, String)] = []
                for outcome in outcomes {
                    let invocation = outcome.invocation
                    let callId = outcome.callId
                    assistantToolCalls.append(
                        ToolCall(
                            id: callId,
                            type: "function",
                            function: ToolCallFunction(
                                name: invocation.toolName,
                                arguments: invocation.jsonArguments
                            )
                        )
                    )
                    toolResultsByCallId.append((callId, outcome.result))
                }

                messages.append(
                    ChatMessage(
                        role: "assistant",
                        content: responseContent.isEmpty ? nil : responseContent,
                        tool_calls: assistantToolCalls,
                        tool_call_id: nil
                    )
                )
                for (callId, result) in toolResultsByCallId {
                    messages.append(
                        ChatMessage(role: "tool", content: result, tool_calls: nil, tool_call_id: callId)
                    )
                }
            }

            // If we exited via the iteration cap without producing a
            // final text turn (i.e. the last loop body still required
            // tools), stream a synthetic notice so the client sees a
            // reason instead of a silent stop.
            let exitedAtCap = (iteration >= maxIterations)
            if exitedAtCap, let last = messages.last, last.tool_calls?.isEmpty == false {
                let notice =
                    "Tool-loop budget of \(maxIterations) iterations exhausted without a final answer."
                hop {
                    writerBound.value.writeContent(
                        notice,
                        model: model,
                        responseId: responseId,
                        created: created,
                        context: ctx.value
                    )
                }
            }
            hop {
                writerBound.value.writeFinish(model, responseId: responseId, created: created, context: ctx.value)
                writerBound.value.writeEnd(ctx.value)
            }
            logSelf.logRequest(
                method: "POST",
                path: path,
                userAgent: logUserAgent,
                requestBody: logRequestBody,
                responseStatus: 200,
                startTime: logStartTime,
                model: model
            )
        }
    }

    // MARK: - Dispatch & Task Endpoints

    /// POST /agents/{identifier}/dispatch — dispatch work/chat task
    /// The identifier can be an agent UUID or a crypto address (0x...).
    private func handleDispatchEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        path: String,
        startTime: Date,
        userAgent: String?
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent

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

        // Extract identifier from path: /agents/{identifier}/dispatch
        let components = path.split(separator: "/")
        guard components.count >= 3 else {
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .badRequest,
                    headers: headers,
                    body: #"{"error":"invalid_agent","message":"Missing agent identifier in path"}"#
                )
            }
            return
        }
        let agentIdentifier = String(components[1])

        Task(priority: .userInitiated) {
            // Resolve identifier: try UUID first, then crypto address
            guard let agentId = await MainActor.run(body: { AgentManager.shared.resolveAgentId(agentIdentifier) })
            else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .notFound,
                        headers: headers,
                        body: #"{"error":"agent_not_found","message":"No agent found for the given identifier"}"#
                    )
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let prompt = json["prompt"] as? String
            else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .badRequest,
                        headers: headers,
                        body: #"{"error":"invalid_request","message":"Missing required field: prompt"}"#
                    )
                }
                return
            }

            // Empty/whitespace prompts make `ChatSession.send` no-op, leaving
            // the dispatched task hanging in `.running` until the watchdog.
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .badRequest,
                        headers: headers,
                        body: #"{"error":"invalid_request","message":"Prompt is empty"}"#
                    )
                }
                return
            }

            let title = json["title"] as? String
            let requestId = UUID()
            let externalSessionKey =
                json["external_session_key"] as? String
                ?? json["session_id"] as? String

            let request = DispatchRequest(
                id: requestId,
                prompt: prompt,
                agentId: agentId,
                title: title,
                showToast: true,
                source: .http,
                externalSessionKey: externalSessionKey
            )

            let handle = await TaskDispatcher.shared.dispatch(request)
            let responseBody: String
            let status: HTTPResponseStatus

            if let handle {
                // Use the resolved task id — when an `external_session_key`
                // matches an existing session the dispatcher reattaches and
                // reports the existing session's id rather than `requestId`.
                let resolvedId = handle.id.uuidString
                let pollUrl = "/v1/tasks/\(resolvedId)"
                let resp: [String: Any] = ["id": resolvedId, "status": "running", "poll_url": pollUrl]
                responseBody =
                    (try? JSONSerialization.data(withJSONObject: resp, options: .osaurusCanonical))
                    .flatMap { String(decoding: $0, as: UTF8.self) }
                    ?? "{}"
                status = .accepted
            } else {
                responseBody =
                    #"{"error":"task_limit_reached","message":"Maximum concurrent background tasks reached"}"#
                status = .tooManyRequests
            }

            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: status,
                    headers: headers,
                    body: responseBody
                )
            }
            logSelf.logRequest(
                method: "POST",
                path: path,
                userAgent: logUserAgent,
                requestBody: requestBodyString,
                responseBody: responseBody,
                responseStatus: Int(status.code),
                startTime: logStartTime
            )
        }
    }

    /// GET /tasks/{task_id} — poll task status
    private func handleTaskStatusEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        path: String,
        startTime: Date,
        userAgent: String?
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent

        // Extract task_id from path: /tasks/{task_id}
        let components = path.split(separator: "/")
        guard components.count >= 2,
            let taskId = UUID(uuidString: String(components[1]))
        else {
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .badRequest,
                    headers: headers,
                    body: #"{"error":"invalid_task_id","message":"Invalid task UUID in path"}"#
                )
            }
            return
        }

        Task(priority: .userInitiated) {
            let (responseBody, found) = await MainActor.run {
                guard let state = BackgroundTaskManager.shared.taskState(for: taskId) else {
                    return (#"{"error":"not_found","message":"Task not found"}"#, false)
                }
                return (PluginHostContext.serializeTaskState(id: taskId, state: state), true)
            }

            let status: HTTPResponseStatus = found ? .ok : .notFound
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: status,
                    headers: headers,
                    body: responseBody
                )
            }
            logSelf.logRequest(
                method: "GET",
                path: path,
                userAgent: logUserAgent,
                requestBody: nil,
                responseBody: responseBody,
                responseStatus: Int(status.code),
                startTime: logStartTime
            )
        }
    }

    /// DELETE /tasks/{task_id} — cancel task
    private func handleTaskCancelEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        path: String,
        startTime: Date,
        userAgent: String?
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent

        let components = path.split(separator: "/")
        guard components.count >= 2,
            let taskId = UUID(uuidString: String(components[1]))
        else {
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .badRequest,
                    headers: headers,
                    body: #"{"error":"invalid_task_id","message":"Invalid task UUID in path"}"#
                )
            }
            return
        }

        Task(priority: .userInitiated) {
            await MainActor.run {
                BackgroundTaskManager.shared.cancelTask(taskId)
            }

            hop {
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .noContent,
                    headers: cors,
                    body: ""
                )
            }
            logSelf.logRequest(
                method: "DELETE",
                path: path,
                userAgent: logUserAgent,
                requestBody: nil,
                responseBody: nil,
                responseStatus: 204,
                startTime: logStartTime
            )
        }
    }

    /// POST /tasks/{task_id}/clarify — answer clarification
    private func handleTaskClarifyEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        path: String,
        startTime: Date,
        userAgent: String?
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent

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

        // Extract task_id from path: /tasks/{task_id}/clarify
        let components = path.split(separator: "/")
        guard components.count >= 3,
            let taskId = UUID(uuidString: String(components[1]))
        else {
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .badRequest,
                    headers: headers,
                    body: #"{"error":"invalid_task_id","message":"Invalid task UUID in path"}"#
                )
            }
            return
        }

        Task(priority: .userInitiated) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let response = json["response"] as? String
            else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .badRequest,
                        headers: headers,
                        body: #"{"error":"invalid_request","message":"Missing required field: response"}"#
                    )
                }
                return
            }

            // Clarifications now happen inline in the chat window via the
            // `clarify` agent intercept — there is no out-of-band submit
            // channel for HTTP callers. Keep the URL routable (so old
            // callers don't 404) but return 410 Gone with a clear error.
            _ = taskId
            _ = response
            let responseBody =
                #"{"error":"not_supported","message":"clarify is no longer accepted over HTTP; the agent surfaces clarifications inline in the chat window"}"#
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .gone,
                    headers: headers,
                    body: responseBody
                )
            }
            logSelf.logRequest(
                method: "POST",
                path: path,
                userAgent: logUserAgent,
                requestBody: requestBodyString,
                responseBody: responseBody,
                responseStatus: 410,
                startTime: logStartTime
            )
        }
    }

    // MARK: - Embeddings

    private func handleEmbeddings(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        ollamaFormat: Bool
    ) {
        let logPath = ollamaFormat ? "/embed" : "/embeddings"

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

        guard let request = try? JSONDecoder().decode(EmbeddingRequest.self, from: data) else {
            let errorBody =
                ollamaFormat
                ? #"{"error":"invalid request body"}"#
                : #"{"error":{"message":"Invalid request body","type":"invalid_request_error","code":"invalid_body"}}"#
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: errorBody
            )
            logRequest(
                method: "POST",
                path: logPath,
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid request body"
            )
            return
        }

        let texts = request.input.texts
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString

        Task(priority: .userInitiated) {
            do {
                let embeddings = try await EmbeddingService.shared.embed(texts: texts)

                let json: String
                if ollamaFormat {
                    let response = OllamaEmbedResponse(model: EmbeddingService.modelName, embeddings: embeddings)
                    json =
                        (try? JSONEncoder.osaurusCanonical().encode(response)).map {
                            String(decoding: $0, as: UTF8.self)
                        } ?? "{}"
                } else {
                    let objects = embeddings.enumerated().map { OpenAIEmbeddingObject(embedding: $1, index: $0) }
                    let tokenCount = texts.reduce(0) { $0 + $1.split(separator: " ").count }
                    let response = OpenAIEmbeddingResponse(
                        data: objects,
                        model: EmbeddingService.modelName,
                        usage: OpenAIEmbeddingUsage(prompt_tokens: tokenCount, total_tokens: tokenCount)
                    )
                    json =
                        (try? JSONEncoder.osaurusCanonical().encode(response)).map {
                            String(decoding: $0, as: UTF8.self)
                        } ?? "{}"
                }

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
                    path: logPath,
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: json,
                    responseStatus: 200,
                    startTime: logStartTime
                )
            } catch {
                let errorJson =
                    ollamaFormat
                    ? #"{"error":"\#(error.localizedDescription)"}"#
                    : #"{"error":{"message":"\#(error.localizedDescription)","type":"server_error","code":"embedding_failed"}}"#

                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .internalServerError,
                        headers: headers,
                        body: errorJson
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: logPath,
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: errorJson,
                    responseStatus: 500,
                    startTime: logStartTime,
                    errorMessage: error.localizedDescription
                )
            }
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

        guard var req = try? JSONDecoder().decode(ChatCompletionRequest.self, from: data) else {
            let body = Self.errorBody(.openai(type: "invalid_request_error"), message: "Invalid request format")
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: body
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

        // Reject unsupported sampler params explicitly with HTTP 400
        // rather than silently ignoring — silent ignoring is the worst
        // behavior for an OpenAI-compatible harness.
        if let unsupported = Self.unsupportedSamplerReason(req) {
            let body = Self.errorBody(
                .openai(type: "invalid_request_error"),
                message: unsupported
            )
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: body
            )
            logRequest(
                method: "POST",
                path: "/chat/completions",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: unsupported
            )
            return
        }

        let accept = head.headers.first(name: "Accept") ?? ""
        let wantsSSE = (req.stream ?? false) || accept.contains("text/event-stream")

        let created = Int(Date().timeIntervalSince1970)
        let responseId = Self.shortId(prefix: "chatcmpl-", length: 12)
        let model = req.model
        #if DEBUG
            let ttftTrace: TTFTTrace? = TTFTTrace()
        #else
            let ttftTrace: TTFTTrace? = nil
        #endif
        let httpTrace = HTTPTraceRecorder(ttftTrace)
        req.ttftTrace = ttftTrace
        httpTrace.mark("http_request_decoded")
        httpTrace.set("endpoint", "/chat/completions")
        httpTrace.set("model", model)
        httpTrace.set("stream", wantsSSE ? 1 : 0)
        httpTrace.set("request_body_bytes", data.count)
        httpTrace.set("http_message_count", req.messages.count)
        httpTrace.set("http_input_image_count", req.messages.reduce(0) { $0 + $1.imageUrls.count })
        httpTrace.set("http_input_audio_count", req.messages.reduce(0) { $0 + $1.audioInputs.count })
        httpTrace.set("http_input_video_count", req.messages.reduce(0) { $0 + $1.videoUrls.count })

        let memoryAgentId = head.headers.first(name: "X-Osaurus-Agent-Id")

        // HTTP-specific persistence knobs:
        //   X-Persist: false   → skip writing the conversation to chat history
        //   X-Session-Id: <id> → group repeat calls under one session row
        //                       (falls back to request.session_id when absent)
        let persistDisabled =
            (head.headers.first(name: "X-Persist") ?? "").lowercased() == "false"
        let externalSessionKey: String? =
            head.headers.first(name: "X-Session-Id") ?? req.session_id
        let resolvedAgentUUID = memoryAgentId.flatMap { UUID(uuidString: $0) }
        let priorMessages = req.messages
        let persistOnSuccess = !persistDisabled

        if wantsSSE {
            let writer = SSEResponseWriter()
            let cors = stateRef.value.corsHeaders
            let loop = context.eventLoop
            let writerBound = NIOLoopBound(writer, eventLoop: loop)
            let ctx = NIOLoopBound(context, eventLoop: loop)
            let hop = Self.makeHop(channel: context.channel, loop: loop)
            hop {
                writerBound.value.writeHeaders(ctx.value, extraHeaders: cors)
            }
            // Capture for logging
            let logStartTime = startTime
            let logUserAgent = userAgent
            let logRequestBody = requestBodyString
            let logModel = model
            let logTemperature = req.temperature ?? 0.7
            let logMaxTokens = req.max_tokens ?? 1024
            let logSelf = self
            // SSE keepalive: emit a `: ping` comment line every 15s so
            // intermediate proxies / load balancers do not idle out long
            // tool-execution / reasoning pauses. Cancelled when the
            // producer task finishes.
            let keepaliveTask = Self.startSSEKeepalive(
                writer: writerBound,
                channel: context.channel,
                loop: loop,
                ctx: ctx
            )
            Task(priority: .userInitiated) {
                defer { keepaliveTask.cancel() }
                do {
                    httpTrace.mark("http_task_start")
                    let chatEngine = self.chatEngine
                    let enrichedReq = await Self.enrichWithAgentContext(req, agentId: memoryAgentId)
                    httpTrace.mark("http_enrich_done")
                    httpTrace.set("http_enriched_message_count", enrichedReq.messages.count)

                    // Compute prefix evidence after enrichment so it tracks
                    // the actual system prompt + tool schema payload sent.
                    let prefixHash: String = {
                        let sysContent = enrichedReq.messages.first(where: { $0.role == "system" })?.content ?? ""
                        return ModelRuntime.computePrefixHash(
                            systemContent: sysContent,
                            tools: enrichedReq.tools ?? []
                        )
                    }()
                    hop {
                        writerBound.value.writeRole(
                            "assistant",
                            model: model,
                            responseId: responseId,
                            created: created,
                            prefixHash: prefixHash,
                            context: ctx.value
                        )
                    }
                    httpTrace.mark("http_sse_role_written")

                    httpTrace.mark("http_stream_chat_start")
                    let stream = try await chatEngine.streamChat(request: enrichedReq)
                    httpTrace.mark("http_stream_chat_ready")
                    var accumulatedContent = ""
                    var authoritativeCompletionTokens: Int?
                    var streamFinishReason = "stop"
                    for try await delta in stream {
                        if let reasoning = StreamingReasoningHint.decode(delta) {
                            httpTrace.markFirstSemanticDelta("reasoning")
                            hop {
                                writerBound.value.writeReasoning(
                                    reasoning,
                                    model: model,
                                    responseId: responseId,
                                    created: created,
                                    context: ctx.value
                                )
                            }
                            continue
                        }
                        if let stats = StreamingStatsHint.decode(delta) {
                            authoritativeCompletionTokens = stats.tokenCount
                            if let stopReason = stats.stopReason {
                                streamFinishReason = stopReason
                            }
                            continue
                        }
                        if StreamingToolHint.isSentinel(delta) { continue }
                        httpTrace.markFirstSemanticDelta("content")
                        accumulatedContent += delta
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
                    let includeUsage = req.stream_options?.include_usage == true
                    let promptTokens = Self.estimatePromptTokens(enrichedReq.messages)
                    let completionTokens =
                        authoritativeCompletionTokens ?? TokenEstimator.estimate(accumulatedContent)
                    httpTrace.set("http_prompt_tokens_estimate", promptTokens)
                    httpTrace.set("http_completion_tokens", completionTokens)
                    let finalStreamFinishReason = streamFinishReason
                    hop {
                        writerBound.value.writeFinishWithReason(
                            finalStreamFinishReason,
                            model: model,
                            responseId: responseId,
                            created: created,
                            context: ctx.value
                        )
                        if includeUsage {
                            writerBound.value.writeUsageChunk(
                                promptTokens: promptTokens,
                                completionTokens: completionTokens,
                                model: model,
                                responseId: responseId,
                                created: created,
                                context: ctx.value
                            )
                        }
                        writerBound.value.writeEnd(ctx.value)
                    }
                    httpTrace.mark("http_sse_finish_written")
                    httpTrace.emit(finishReason: finalStreamFinishReason, responseStatus: 200)
                    if persistOnSuccess {
                        var finalMessages = priorMessages
                        if !accumulatedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            finalMessages.append(
                                ChatMessage(role: "assistant", content: accumulatedContent)
                            )
                        }
                        ChatHistoryWriter.persistInBackground(
                            source: .http,
                            sourcePluginId: nil,
                            agentId: resolvedAgentUUID,
                            externalKey: externalSessionKey,
                            finalMessages: finalMessages,
                            model: model
                        )
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
                        finishReason: RequestLog.FinishReason(rawValue: finalStreamFinishReason) ?? .stop
                    )
                } catch let invs as ServiceToolInvocations {
                    // Multi-tool MLX completion: emit one tool_call delta
                    // per invocation, sharing one finish_reason="tool_calls".
                    // OpenAI clients deduplicate by `index`.
                    httpTrace.markFirstSemanticDelta("tool_calls")
                    httpTrace.set("http_tool_call_count", invs.invocations.count)
                    let includeUsage = req.stream_options?.include_usage == true
                    // Use `req.messages` here (not `enrichedReq.messages`)
                    // because the enriched value is scoped to the `do` block
                    // and unavailable in this catch — at worst we under-
                    // count by the agent system-prompt fragment.
                    let promptTokens = Self.estimatePromptTokens(req.messages)
                    let requestTools = req.tools
                    hop {
                        for (idx, inv) in invs.invocations.enumerated() {
                            self.writeOpenAIToolCallSSE(
                                inv,
                                index: idx,
                                writer: writerBound.value,
                                model: model,
                                responseId: responseId,
                                created: created,
                                context: ctx.value,
                                tools: requestTools
                            )
                        }
                        writerBound.value.writeFinishWithReason(
                            "tool_calls",
                            model: model,
                            responseId: responseId,
                            created: created,
                            context: ctx.value
                        )
                        if includeUsage {
                            writerBound.value.writeUsageChunk(
                                promptTokens: promptTokens,
                                completionTokens: 0,
                                model: model,
                                responseId: responseId,
                                created: created,
                                context: ctx.value
                            )
                        }
                        writerBound.value.writeEnd(ctx.value)
                    }
                    httpTrace.mark("http_sse_tool_calls_written")
                    httpTrace.emit(finishReason: "tool_calls", responseStatus: 200)
                    let toolLogs = invs.invocations.map {
                        ToolCallLog(name: $0.toolName, arguments: $0.jsonArguments)
                    }
                    logSelf.logRequest(
                        method: "POST",
                        path: "/chat/completions",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseStatus: 200,
                        startTime: logStartTime,
                        model: logModel,
                        toolCalls: toolLogs,
                        temperature: logTemperature,
                        maxTokens: logMaxTokens,
                        finishReason: .toolCalls
                    )
                } catch let inv as ServiceToolInvocation {
                    // Single tool invocation — same emission as above.
                    httpTrace.markFirstSemanticDelta("tool_calls")
                    httpTrace.set("http_tool_call_count", 1)
                    let includeUsage = req.stream_options?.include_usage == true
                    let promptTokens = Self.estimatePromptTokens(req.messages)
                    let requestTools = req.tools
                    hop {
                        self.writeOpenAIToolCallSSE(
                            inv,
                            index: 0,
                            writer: writerBound.value,
                            model: model,
                            responseId: responseId,
                            created: created,
                            context: ctx.value,
                            tools: requestTools
                        )
                        writerBound.value.writeFinishWithReason(
                            "tool_calls",
                            model: model,
                            responseId: responseId,
                            created: created,
                            context: ctx.value
                        )
                        if includeUsage {
                            writerBound.value.writeUsageChunk(
                                promptTokens: promptTokens,
                                completionTokens: 0,
                                model: model,
                                responseId: responseId,
                                created: created,
                                context: ctx.value
                            )
                        }
                        writerBound.value.writeEnd(ctx.value)
                    }
                    httpTrace.mark("http_sse_tool_calls_written")
                    httpTrace.emit(finishReason: "tool_calls", responseStatus: 200)
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
                    // SSE response head was already written as 200 — the
                    // failure surfaces as an in-band SSE error chunk. Log
                    // the actual on-wire status (200) so dashboards don't
                    // mis-attribute a delivered stream as a 500.
                    hop {
                        writerBound.value.writeError(error.localizedDescription, context: ctx.value)
                        writerBound.value.writeEnd(ctx.value)
                    }
                    httpTrace.mark("http_sse_error_written")
                    httpTrace.emit(
                        finishReason: "error",
                        responseStatus: 200,
                        errorMessage: error.localizedDescription
                    )
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
                        finishReason: .error,
                        errorMessage: error.localizedDescription
                    )
                }
            }
        } else {
            let cors = stateRef.value.corsHeaders
            let loop = context.eventLoop
            let ctx = NIOLoopBound(context, eventLoop: loop)
            let hop = Self.makeHop(channel: context.channel, loop: loop)
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
                    httpTrace.mark("http_task_start")
                    let chatEngine = self.chatEngine
                    let enrichedReq = await Self.enrichWithAgentContext(req, agentId: memoryAgentId)
                    httpTrace.mark("http_enrich_done")
                    httpTrace.set("http_enriched_message_count", enrichedReq.messages.count)
                    httpTrace.mark("http_complete_chat_start")
                    var resp = try await chatEngine.completeChat(request: enrichedReq)
                    httpTrace.mark("http_complete_chat_done")
                    // Compute prefix evidence after enrichment so it tracks
                    // the actual system prompt + tool schema payload sent.
                    let sysContent = enrichedReq.messages.first(where: { $0.role == "system" })?.content ?? ""
                    resp.prefix_hash = ModelRuntime.computePrefixHash(
                        systemContent: sysContent,
                        tools: enrichedReq.tools ?? []
                    )
                    if persistOnSuccess, let assistantMsg = resp.choices.first?.message {
                        var finalMessages = priorMessages
                        finalMessages.append(assistantMsg)
                        ChatHistoryWriter.persistInBackground(
                            source: .http,
                            sourcePluginId: nil,
                            agentId: resolvedAgentUUID,
                            externalKey: externalSessionKey,
                            finalMessages: finalMessages,
                            model: model
                        )
                    }
                    let body = try Self.chatCompletionResponseBody(resp)
                    var headers: [(String, String)] = [("Content-Type", "application/json")]
                    headers.append(contentsOf: cors)
                    let headersCopy = headers
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
                    let finishReasonString = resp.choices.first?.finish_reason ?? "stop"
                    let finishReason: RequestLog.FinishReason = {
                        switch finishReasonString {
                        case "stop": return .stop
                        case "length": return .length
                        case "tool_calls": return .toolCalls
                        default: return .stop
                        }
                    }()
                    httpTrace.markFirstSemanticDelta("completion")
                    httpTrace.set("http_prompt_tokens", tokensIn)
                    httpTrace.set("http_completion_tokens", tokensOut)
                    httpTrace.mark("http_json_response_written")
                    httpTrace.emit(finishReason: finishReasonString, responseStatus: 200)
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
                    // Map known errors to their intended HTTP status (e.g.
                    // 404 for unknown model) instead of blanket-500. The
                    // body is always OpenAI-shaped JSON so external clients
                    // can parse it uniformly. See PR #863 / issue #858.
                    let status: HTTPResponseStatus
                    let errorType: String
                    let message: String
                    if let engineError = error as? ChatEngine.EngineError {
                        status = HTTPResponseStatus(statusCode: engineError.httpStatus)
                        errorType =
                            engineError.httpStatus == 404
                            ? "invalid_request_error" : "service_unavailable"
                        message = engineError.errorDescription ?? error.localizedDescription
                    } else {
                        status = .internalServerError
                        errorType = "internal_error"
                        message = error.localizedDescription
                    }
                    let body = Self.errorBody(.openai(type: errorType), message: message)
                    let actualStatus = Int(status.code)
                    let headers: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")]
                    let headersCopy = headers
                    hop {
                        var responseHead = HTTPResponseHead(version: head.version, status: status)
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
                    httpTrace.mark("http_json_error_written")
                    httpTrace.emit(
                        finishReason: "error",
                        responseStatus: actualStatus,
                        errorMessage: error.localizedDescription
                    )
                    logSelf.logRequest(
                        method: "POST",
                        path: "/chat/completions",
                        userAgent: logUserAgent,
                        requestBody: logRequestBody,
                        responseStatus: actualStatus,
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

        let shouldStream = req.stream ?? true
        if !shouldStream {
            handleOllamaChatNonStreaming(
                head: head,
                context: context,
                startTime: startTime,
                userAgent: userAgent,
                requestBodyString: requestBodyString,
                request: req
            )
            return
        }

        let writer = NDJSONResponseWriter()
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let writerBound = NIOLoopBound(writer, eventLoop: loop)
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
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
                let chatEngine = self.chatEngine
                let stream = try await chatEngine.streamChat(request: req)
                for try await delta in stream {
                    // Ollama-style NDJSON has no `reasoning` / `thinking`
                    // field today — `StreamingReasoningHint`, along with
                    // `StreamingToolHint` / `StreamingStatsHint`, is
                    // intentionally dropped here so it doesn't leak as
                    // assistant content. Add a `thinking` field on the
                    // NDJSON response shape (and decode reasoning here
                    // first) when an upstream client requests it.
                    if StreamingReasoningHint.decode(delta) != nil { continue }
                    if StreamingStatsHint.decode(delta) != nil { continue }
                    if StreamingToolHint.isSentinel(delta) { continue }
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
            } catch let invs as ServiceToolInvocations {
                hop {
                    writerBound.value.writeToolCalls(invs.invocations, model: req.model, context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                let toolLogs = invs.invocations.map {
                    ToolCallLog(name: $0.toolName, arguments: $0.jsonArguments)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/chat",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    toolCalls: toolLogs,
                    temperature: logTemperature,
                    maxTokens: logMaxTokens,
                    finishReason: .toolCalls
                )
            } catch let inv as ServiceToolInvocation {
                hop {
                    writerBound.value.writeToolCalls([inv], model: req.model, context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                let toolLog = ToolCallLog(name: inv.toolName, arguments: inv.jsonArguments)
                logSelf.logRequest(
                    method: "POST",
                    path: "/chat",
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
                // NDJSON response head was already 200 — surface as in-band
                // NDJSON error chunk and log actual on-wire status.
                hop {
                    writerBound.value.writeError(error.localizedDescription, context: ctx.value)
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
                    finishReason: .error,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private func handleOllamaChatNonStreaming(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        requestBodyString: String?,
        request: ChatCompletionRequest
    ) {
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        Task(priority: .userInitiated) {
            do {
                let response = try await self.chatEngine.completeChat(request: request)
                let message = response.choices.first?.message
                let body = Self.ollamaChatJSON(
                    model: request.model,
                    content: message?.content ?? "",
                    toolCalls: message?.tool_calls,
                    done: true
                )
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .ok,
                        headers: headers,
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/chat",
                    userAgent: userAgent,
                    requestBody: requestBodyString,
                    responseBody: body,
                    responseStatus: 200,
                    startTime: startTime,
                    model: request.model,
                    tokensInput: response.usage.prompt_tokens,
                    tokensOutput: response.usage.completion_tokens,
                    temperature: request.temperature ?? 0.7,
                    maxTokens: request.max_tokens ?? 1024,
                    finishReason: message?.tool_calls?.isEmpty == false ? .toolCalls : .stop
                )
            } catch let invs as ServiceToolInvocations {
                let body = Self.ollamaChatToolCallsJSON(model: request.model, invocations: invs.invocations)
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .ok,
                        headers: headers,
                        body: body
                    )
                }
                let toolLogs = invs.invocations.map {
                    ToolCallLog(name: $0.toolName, arguments: $0.jsonArguments)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/chat",
                    userAgent: userAgent,
                    requestBody: requestBodyString,
                    responseBody: body,
                    responseStatus: 200,
                    startTime: startTime,
                    model: request.model,
                    toolCalls: toolLogs,
                    temperature: request.temperature ?? 0.7,
                    maxTokens: request.max_tokens ?? 1024,
                    finishReason: .toolCalls
                )
            } catch let inv as ServiceToolInvocation {
                let body = Self.ollamaChatToolCallsJSON(model: request.model, invocations: [inv])
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .ok,
                        headers: headers,
                        body: body
                    )
                }
                let toolLog = ToolCallLog(name: inv.toolName, arguments: inv.jsonArguments)
                logSelf.logRequest(
                    method: "POST",
                    path: "/chat",
                    userAgent: userAgent,
                    requestBody: requestBodyString,
                    responseBody: body,
                    responseStatus: 200,
                    startTime: startTime,
                    model: request.model,
                    toolCalls: [toolLog],
                    temperature: request.temperature ?? 0.7,
                    maxTokens: request.max_tokens ?? 1024,
                    finishReason: .toolCalls
                )
            } catch {
                let body = Self.ollamaGenerateErrorJSON(error.localizedDescription)
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .internalServerError,
                        headers: headers,
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/chat",
                    userAgent: userAgent,
                    requestBody: requestBodyString,
                    responseStatus: 500,
                    startTime: startTime,
                    model: request.model,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private struct OllamaGenerateOptions: Decodable, Sendable {
        let num_predict: Int?
        let temperature: Float?
        let top_p: Float?
        let stop: FlexibleStringArray?
    }

    private struct OllamaGenerateRequest: Decodable, Sendable {
        let model: String
        let prompt: String
        let system: String?
        let stream: Bool?
        let options: OllamaGenerateOptions?
    }

    private struct FlexibleStringArray: Decodable, Sendable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                values = [value]
            } else {
                values = (try? container.decode([String].self)) ?? []
            }
        }
    }

    private func handleOllamaGenerate(
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

        guard let ollama = try? JSONDecoder().decode(OllamaGenerateRequest.self, from: data) else {
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: [("Content-Type", "text/plain; charset=utf-8")],
                body: "Invalid request format"
            )
            logRequest(
                method: "POST",
                path: "/generate",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid request format"
            )
            return
        }

        let maxTokens = ollama.options?.num_predict.flatMap { $0 > 0 ? $0 : nil }
        var messages: [ChatMessage] = []
        if let system = ollama.system?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            messages.append(ChatMessage(role: "system", content: system))
        }
        messages.append(ChatMessage(role: "user", content: ollama.prompt))
        let chatRequest = ChatCompletionRequest(
            model: ollama.model,
            messages: messages,
            temperature: ollama.options?.temperature,
            max_tokens: maxTokens,
            stream: ollama.stream,
            top_p: ollama.options?.top_p,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: ollama.options?.stop?.values,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )

        let shouldStream = ollama.stream ?? true
        if !shouldStream {
            handleOllamaGenerateNonStreaming(
                head: head,
                context: context,
                startTime: startTime,
                userAgent: userAgent,
                requestBodyString: requestBodyString,
                request: chatRequest
            )
            return
        }

        let writer = OllamaGenerateNDJSONResponseWriter()
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let writerBound = NIOLoopBound(writer, eventLoop: loop)
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        hop {
            writerBound.value.writeHeaders(ctx.value, extraHeaders: cors)
        }

        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logModel = chatRequest.model
        let logTemperature = chatRequest.temperature ?? 0.7
        let logMaxTokens = chatRequest.max_tokens ?? 1024
        let logSelf = self
        Task(priority: .userInitiated) {
            do {
                let stream = try await self.chatEngine.streamChat(request: chatRequest)
                for try await delta in stream {
                    if StreamingReasoningHint.decode(delta) != nil { continue }
                    if StreamingStatsHint.decode(delta) != nil { continue }
                    if StreamingToolHint.isSentinel(delta) { continue }
                    hop {
                        writerBound.value.writeContent(
                            delta,
                            model: chatRequest.model,
                            created: Int(Date().timeIntervalSince1970),
                            context: ctx.value
                        )
                    }
                }
                hop {
                    writerBound.value.writeFinish(
                        chatRequest.model,
                        created: Int(Date().timeIntervalSince1970),
                        context: ctx.value
                    )
                    writerBound.value.writeEnd(ctx.value)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/generate",
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
                    path: "/generate",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
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

    private func handleOllamaGenerateNonStreaming(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        requestBodyString: String?,
        request: ChatCompletionRequest
    ) {
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        Task(priority: .userInitiated) {
            do {
                let response = try await self.chatEngine.completeChat(request: request)
                let content = response.choices.first?.message.content ?? ""
                let body = Self.ollamaGenerateJSON(
                    model: request.model,
                    response: content,
                    done: true
                )
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .ok,
                        headers: headers,
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/generate",
                    userAgent: userAgent,
                    requestBody: requestBodyString,
                    responseBody: body,
                    responseStatus: 200,
                    startTime: startTime,
                    model: request.model,
                    tokensInput: response.usage.prompt_tokens,
                    tokensOutput: response.usage.completion_tokens,
                    temperature: request.temperature ?? 0.7,
                    maxTokens: request.max_tokens ?? 1024,
                    finishReason: .stop
                )
            } catch {
                let body = Self.ollamaGenerateErrorJSON(error.localizedDescription)
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .internalServerError,
                        headers: headers,
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/generate",
                    userAgent: userAgent,
                    requestBody: requestBodyString,
                    responseStatus: 500,
                    startTime: startTime,
                    model: request.model,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private static func ollamaGenerateJSON(model: String, response: String, done: Bool) -> String {
        let object: [String: Any] = [
            "model": model,
            "created_at": Date().ISO8601Format(),
            "response": response,
            "done": done,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .osaurusCanonical) else {
            return #"{"done":true}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func ollamaChatJSON(
        model: String,
        content: String,
        toolCalls: [ToolCall]? = nil,
        done: Bool
    ) -> String {
        var message: [String: Any] = [
            "role": "assistant",
            "content": content,
        ]
        if let toolCalls, !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls.map { call in
                [
                    "function": [
                        "name": call.function.name,
                        "arguments": ollamaArguments(from: call.function.arguments),
                    ]
                ]
            }
        }
        let object: [String: Any] = [
            "model": model,
            "created_at": Date().ISO8601Format(),
            "message": message,
            "done": done,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return #"{"message":{"role":"assistant","content":""},"done":true}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func ollamaChatToolCallsJSON(
        model: String,
        invocations: [ServiceToolInvocation]
    ) -> String {
        let toolCalls = invocations.map { inv in
            [
                "function": [
                    "name": inv.toolName,
                    "arguments": ollamaArguments(from: inv.jsonArguments),
                ]
            ]
        }
        let object: [String: Any] = [
            "model": model,
            "created_at": Date().ISO8601Format(),
            "message": [
                "role": "assistant",
                "content": "",
                "tool_calls": toolCalls,
            ],
            "done": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return #"{"message":{"role":"assistant","content":"","tool_calls":[]},"done":true}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func ollamaArguments(from json: String) -> Any {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return json }
        return object
    }

    private static func ollamaGenerateErrorJSON(_ message: String) -> String {
        let object: [String: Any] = [
            "error": [
                "message": message,
                "type": "internal_error",
            ],
            "done": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .osaurusCanonical) else {
            return #"{"error":{"message":"internal error","type":"internal_error"},"done":true}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - SSE keepalive

    /// Spawn a background task that emits a `: ping\n\n` SSE comment
    /// every 15s, hopping back to the channel's event loop for each
    /// write. Comment lines are ignored by SSE clients per the spec
    /// but keep intermediate proxies from idling out long
    /// tool-execution or reasoning pauses. Callers must `cancel()` the
    /// returned task when their producer finishes.
    static func startSSEKeepalive(
        writer: NIOLoopBound<SSEResponseWriter>,
        channel: Channel,
        loop: EventLoop,
        ctx: NIOLoopBound<ChannelHandlerContext>
    ) -> Task<Void, Never> {
        Task<Void, Never>(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { return }
                guard channel.isActive else { return }
                loop.execute { writer.value.writePing(ctx.value) }
            }
        }
    }

    // MARK: - Tool batch execution

    /// One executed tool call carrying everything the SSE writer + the
    /// follow-up assistant/tool message construction need. Returned in
    /// the same order as the input invocations so the SSE frame order
    /// matches the model's own tool_call sequence.
    struct ToolOutcome: Sendable {
        let invocation: ServiceToolInvocation
        let callId: String
        let result: String
    }

    /// Run every invocation in parallel via a TaskGroup, then restore
    /// the input order for deterministic SSE framing. Each task scopes
    /// `ChatExecutionContext` so tools see the same session/agent ids
    /// they would on a sequential dispatch. Per-call errors are caught
    /// and converted to `ToolEnvelope.fromError` so a single bad call
    /// never aborts the rest of the batch.
    static func runToolBatchInParallel(
        _ invocations: [ServiceToolInvocation],
        requestId: String,
        agentId: UUID
    ) async -> [ToolOutcome] {
        // Pre-allocate call ids so the parallel tasks don't race the
        // shortId generator and reorder ids vs invocation indices.
        let calls: [(index: Int, callId: String, invocation: ServiceToolInvocation)] =
            invocations.enumerated().map { idx, inv in
                (idx, inv.toolCallId ?? shortId(prefix: "call_"), inv)
            }

        let indexed: [(Int, ToolOutcome)] = await withTaskGroup(
            of: (Int, ToolOutcome).self
        ) { group in
            for call in calls {
                group.addTask {
                    let result: String
                    do {
                        result = try await ChatExecutionContext.$currentSessionId.withValue(requestId) {
                            try await ChatExecutionContext.$currentAgentId.withValue(agentId) {
                                try await ToolRegistry.shared.execute(
                                    name: call.invocation.toolName,
                                    argumentsJSON: call.invocation.jsonArguments
                                )
                            }
                        }
                    } catch {
                        result = ToolEnvelope.fromError(error, tool: call.invocation.toolName)
                    }
                    let outcome = ToolOutcome(
                        invocation: call.invocation,
                        callId: call.callId,
                        result: result
                    )
                    return (call.index, outcome)
                }
            }
            var collected: [(Int, ToolOutcome)] = []
            for await item in group { collected.append(item) }
            return collected
        }

        return indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    // MARK: - Request validation

    /// Convenience adapter over `RequestValidator.unsupportedSamplerReason`
    /// that pulls the relevant fields off a `ChatCompletionRequest`. The
    /// underlying logic lives at module scope so the eval kit can exercise
    /// it without depending on `HTTPHandler` / `ChatCompletionRequest`.
    nonisolated static func unsupportedSamplerReason(_ req: ChatCompletionRequest) -> String? {
        RequestValidator.unsupportedSamplerReason(
            n: req.n,
            responseFormatType: req.response_format?.type
        )
    }

    // MARK: - Token estimation

    /// Cheap char-based prompt-token estimate, mirrored on
    /// `ChatEngine.estimateInputTokens` so SSE `usage` chunks and
    /// non-stream `usage` totals are consistent. Includes assistant
    /// `tool_calls` payloads and `tool` role bodies.
    nonisolated static func estimatePromptTokens(_ messages: [ChatMessage]) -> Int {
        let totalChars = messages.reduce(0) { sum, msg in
            var chars = msg.content?.count ?? 0
            if let calls = msg.tool_calls {
                for call in calls {
                    chars += call.function.name.count
                    chars += call.function.arguments.count
                    chars += TokenEstimator.toolCallEnvelopeChars
                }
            }
            return sum + chars
        }
        return max(1, totalChars / TokenEstimator.charsPerToken)
    }

    // MARK: - Health Endpoint

    /// `/health` returns liveness plus per-model in-flight counts and the
    /// list of currently-loaded models. External observers can use this to
    /// detect contention without scraping logs (one model starving the
    /// others, eviction churn under sustained load, etc.).
    private func handleHealthEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        method: String,
        path: String
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let version = head.version
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logMethod = method
        let logPath = path

        Task(priority: .userInitiated) {
            let inflight = await ModelLease.shared.snapshot()
            let cached = await ModelRuntime.shared.cachedModelSummaries()
            let residency = await ModelResidencyManager.shared.snapshots()
            let residencyByName = Dictionary(uniqueKeysWithValues: residency.map { ($0.modelName, $0) })
            let now = Date()
            let loaded = cached.map { $0.name }
            let current = cached.first(where: { $0.isCurrent })?.name as Any? ?? NSNull()

            var inflightObj: [String: Any] = [:]
            for (name, count) in inflight { inflightObj[name] = count }

            let residentModels: [[String: Any]] = cached.map { summary in
                var row: [String: Any] = [
                    "name": summary.name,
                    "is_current": summary.isCurrent,
                    "inflight": inflight[summary.name] ?? 0,
                ]
                if let draftStrategy = summary.draftStrategyDescription {
                    row["draft_strategy"] = draftStrategy
                } else {
                    row["draft_strategy"] = NSNull()
                }
                if let nativeMTPDepth = summary.nativeMTPDepth {
                    row["native_mtp_depth"] = nativeMTPDepth
                } else {
                    row["native_mtp_depth"] = NSNull()
                }
                if let unloadAt = residencyByName[summary.name]?.unloadAt {
                    row["idle_unload_at"] = unloadAt.ISO8601Format()
                    row["idle_seconds_remaining"] =
                        max(0, Int(ceil(unloadAt.timeIntervalSince(now))))
                } else {
                    row["idle_unload_at"] = NSNull()
                    row["idle_seconds_remaining"] = NSNull()
                }
                return row
            }

            let memoryConfig = MemoryConfigurationStore.load()
            let obj: [String: Any] = [
                "status": "healthy",
                "timestamp": Date().ISO8601Format(),
                "loaded": loaded,
                "current_model": current,
                "inflight": inflightObj,
                "resident_models": residentModels,
                "memory_enabled": memoryConfig.enabled,
                "memory_database_open": MemoryDatabase.shared.isOpen,
            ]
            let data = try? JSONSerialization.data(withJSONObject: obj, options: .osaurusCanonical)
            let body = data.flatMap { String(decoding: $0, as: UTF8.self) } ?? "{}"
            let headers: [(String, String)] =
                [("Content-Type", "application/json; charset=utf-8")]
                + cors

            hop {
                logSelf.sendResponse(
                    context: ctx.value,
                    version: version,
                    status: .ok,
                    headers: headers,
                    body: body
                )
            }
            logSelf.logRequest(
                method: logMethod,
                path: logPath,
                userAgent: logUserAgent,
                requestBody: nil,
                responseBody: body,
                responseStatus: 200,
                startTime: logStartTime
            )
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
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logSelf = self

        Task(priority: .userInitiated) {
            // Get local models
            var models = MLXService.getAvailableModels().map { OpenAIModel(modelName: $0) }
            if FoundationModelService.isDefaultModelAvailable() {
                models.insert(OpenAIModel(modelName: "foundation"), at: 0)
            }

            // Remote provider startup may be blocked on Keychain auth. Keep
            // local model listing responsive and append remote models only
            // when the MainActor snapshot is immediately available.
            let remoteModels = await Self.remoteOpenAIModelsSnapshot()
            models.append(contentsOf: remoteModels)

            let response = ModelsResponse(data: models)
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(response)).map { String(decoding: $0, as: UTF8.self) }
                ?? "{}"

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
        let hop = Self.makeHop(channel: context.channel, loop: loop)
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

            // Keep Ollama tags usable for local models even if remote
            // provider auth is blocked during app startup.
            let remoteModels = await Self.remoteOpenAIModelsSnapshot()
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
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(payload)).map { String(decoding: $0, as: UTF8.self) }
                ?? "{}"

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

    private static func remoteOpenAIModelsSnapshot(timeoutNanoseconds: UInt64 = 250_000_000) async
        -> [OpenAIModel]
    {
        await withCheckedContinuation { continuation in
            let once = OneShotContinuation<[OpenAIModel]>()
            let modelsTask = Task {
                let models = await MainActor.run {
                    RemoteProviderManager.shared.getOpenAIModels()
                }
                _ = once.resume(continuation, returning: models)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                if once.resume(continuation, returning: []) {
                    modelsTask.cancel()
                }
            }
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
            let model: String

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let model = try container.decodeIfPresent(String.self, forKey: .model) {
                    self.model = model
                } else {
                    self.model = try container.decode(String.self, forKey: .name)
                }
            }

            private enum CodingKeys: String, CodingKey {
                case model, name
            }
        }

        guard let req = try? JSONDecoder().decode(ShowRequest.self, from: data) else {
            var headers = [("Content-Type", "application/json; charset=utf-8")]
            headers.append(contentsOf: stateRef.value.corsHeaders)
            let errorBody =
                #"{"error":{"message":"Invalid request: expected {\"model\": \"<model_id>\"}","type":"invalid_request_error"}}"#
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
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logSelf = self
        let modelName = req.model

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
                    let jsonData =
                        (try? JSONSerialization.data(withJSONObject: response, options: .osaurusCanonical))
                        ?? Data("{}".utf8)
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
            let jsonData = (try? JSONEncoder.osaurusCanonical().encode(response)) ?? Data("{}".utf8)
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
        let hop = Self.makeHop(channel: context.channel, loop: loop)
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
            // Sorted keys: external MCP clients may byte-compare or hash
            // schema bytes. See `JSONDeterminism.swift`.
            let data =
                (try? JSONSerialization.data(withJSONObject: payload, options: .osaurusCanonical))
                ?? Data("{}".utf8)
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
                    let enc = try JSONSerialization.data(withJSONObject: arr, options: .osaurusCanonical)
                    try container.encode(String(decoding: enc, as: UTF8.self))
                case let dict as [String: Any]:
                    let enc = try JSONSerialization.data(withJSONObject: dict, options: .osaurusCanonical)
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
                let d = try? JSONSerialization.data(withJSONObject: a, options: .osaurusCanonical)
            {
                return String(decoding: d, as: UTF8.self)
            }
            return "{}"
        }()

        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let cors = stateRef.value.corsHeaders
        let hop = Self.makeHop(channel: context.channel, loop: loop)
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
                        let data =
                            (try? JSONSerialization.data(withJSONObject: payload, options: .osaurusCanonical))
                            ?? Data("{}".utf8)
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
                let d =
                    (try? JSONSerialization.data(withJSONObject: payload, options: .osaurusCanonical))
                    ?? Data("{}".utf8)
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
                let d =
                    (try? JSONSerialization.data(withJSONObject: payload, options: .osaurusCanonical))
                    ?? Data("{}".utf8)
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
                (try? JSONEncoder.osaurusCanonical().encode(error)).map { String(decoding: $0, as: UTF8.self) }
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
        let messageId = Self.shortId(prefix: "msg_")
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
        let hop = Self.makeHop(channel: context.channel, loop: loop)

        // Estimate input tokens (rough: 1 token per 4 chars)
        let inputTokens =
            anthropicReq.messages.reduce(0) { acc, msg in
                acc + TokenEstimator.estimate(msg.content.plainText)
            } + (anthropicReq.system?.plainText.count ?? 0) / TokenEstimator.charsPerToken

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
                let chatEngine = self.chatEngine
                let stream = try await chatEngine.streamChat(request: internalReq)
                for try await delta in stream {
                    // Reasoning sentinel must be decoded BEFORE the
                    // generic `isSentinel` filter, otherwise it gets
                    // dropped together with tool/stats hints.
                    if let reasoning = StreamingReasoningHint.decode(delta) {
                        hop {
                            writerBound.value.writeThinkingDelta(reasoning, context: ctx.value)
                        }
                        continue
                    }
                    if let stats = StreamingStatsHint.decode(delta) {
                        hop {
                            writerBound.value.setOutputTokens(stats.tokenCount)
                        }
                        continue
                    }
                    if StreamingToolHint.isSentinel(delta) { continue }
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
            } catch let invs as ServiceToolInvocations {
                // Multi-tool MLX completion: one `tool_use` content block
                // per invocation, then a single `tool_use` finish.
                hop {
                    for inv in invs.invocations {
                        self.writeAnthropicToolUse(inv, writer: writerBound.value, context: ctx.value)
                    }
                    writerBound.value.writeFinish(stopReason: "tool_use", context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                let toolLogs = invs.invocations.map {
                    ToolCallLog(name: $0.toolName, arguments: $0.jsonArguments)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/messages",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    toolCalls: toolLogs,
                    finishReason: .toolCalls
                )
            } catch let inv as ServiceToolInvocation {
                // Single tool invocation — same emission path.
                hop {
                    self.writeAnthropicToolUse(inv, writer: writerBound.value, context: ctx.value)
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
                // SSE response head was already 200 — surface as in-band
                // SSE error chunk and log actual on-wire status.
                hop {
                    writerBound.value.writeError(error.localizedDescription, context: ctx.value)
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
        let hop = Self.makeHop(channel: context.channel, loop: loop)

        // Capture for logging
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logModel = model
        let logSelf = self

        Task(priority: .userInitiated) {
            do {
                let chatEngine = self.chatEngine
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

                let json = try JSONEncoder.osaurusCanonical().encode(anthropicResp)
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
            } catch let invs as ServiceToolInvocations {
                // Multi-tool MLX completion: emit one Anthropic
                // `tool_use` content block per invocation.
                let blocks: [AnthropicResponseContentBlock] = invs.invocations.map {
                    Self.makeAnthropicToolUseBlock(from: $0)
                }
                let body = Self.anthropicNonStreamingBody(
                    messageId: messageId,
                    model: model,
                    blocks: blocks
                )
                Self.writeJSONResponse(body: body, cors: cors, head: head, ctx: ctx, hop: hop)
                let toolLogs = invs.invocations.map {
                    ToolCallLog(name: $0.toolName, arguments: $0.jsonArguments)
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
                    toolCalls: toolLogs,
                    finishReason: .toolCalls
                )
            } catch let inv as ServiceToolInvocation {
                // Single tool invocation — same emission with one block.
                let body = Self.anthropicNonStreamingBody(
                    messageId: messageId,
                    model: model,
                    blocks: [Self.makeAnthropicToolUseBlock(from: inv)]
                )
                Self.writeJSONResponse(body: body, cors: cors, head: head, ctx: ctx, hop: hop)
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
                    (try? JSONEncoder.osaurusCanonical().encode(errorResp))
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
        guard _isChannelActive.value else { return }
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
        let hop = Self.makeHop(channel: context.channel, loop: loop)

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

                // Get SpeechService and transcribe
                let service = await MainActor.run { SpeechService.shared }
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
                    if let duration = result.durationSeconds {
                        response["duration"] = duration
                    }
                    let jsonData = try JSONSerialization.data(withJSONObject: response, options: .osaurusCanonical)
                    responseBody = String(decoding: jsonData, as: UTF8.self)
                } else {
                    // Default JSON format
                    let response = ["text": result.text]
                    let jsonData = try JSONEncoder.osaurusCanonical().encode(response)
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

    private static func applyOpenResponsesContext(
        to request: ChatCompletionRequest,
        previousResponseId: String?
    ) -> ChatCompletionRequest {
        let previous = openResponsesContextStore.transcript(
            for: previousResponseId,
            model: request.model
        )
        guard !previous.isEmpty else { return request }

        var copy = request
        let currentSystem = request.messages.filter { $0.role.lowercased() == "system" }
        let currentNonSystem = request.messages.filter { $0.role.lowercased() != "system" }
        copy.messages = currentSystem + previous + currentNonSystem
        return copy
    }

    private static func assistantMessages(from response: ChatCompletionResponse) -> [ChatMessage] {
        response.choices.compactMap { choice in
            let message = choice.message
            if let content = message.content, !content.isEmpty {
                return ChatMessage(
                    role: "assistant",
                    content: content,
                    tool_calls: message.tool_calls,
                    tool_call_id: nil,
                    reasoning_content: message.reasoning_content
                )
            }
            if let toolCalls = message.tool_calls, !toolCalls.isEmpty {
                return ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: toolCalls,
                    tool_call_id: nil,
                    reasoning_content: message.reasoning_content
                )
            }
            return nil
        }
    }

    private static func assistantMessage(from invocations: [ServiceToolInvocation]) -> ChatMessage? {
        let toolCalls = invocations.map { inv in
            ToolCall(
                id: inv.toolCallId ?? Self.shortId(prefix: "call_"),
                type: "function",
                function: ToolCallFunction(name: inv.toolName, arguments: inv.jsonArguments)
            )
        }
        guard !toolCalls.isEmpty else { return nil }
        return ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: toolCalls,
            tool_call_id: nil
        )
    }

    private static func storeOpenResponsesContext(
        responseId: String,
        model: String,
        request: ChatCompletionRequest,
        assistantMessages: [ChatMessage]
    ) {
        guard !assistantMessages.isEmpty else { return }
        openResponsesContextStore.store(
            responseId: responseId,
            model: model,
            messages: request.messages + assistantMessages
        )
    }

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
                (try? JSONEncoder.osaurusCanonical().encode(error)).map { String(decoding: $0, as: UTF8.self) }
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

        // Generate response ID
        let responseId = Self.shortId(prefix: "resp_")
        let model = openResponsesReq.model

        // Convert to internal format, preserving local Responses API
        // context when clients chain turns with `previous_response_id`.
        let internalReq = Self.applyOpenResponsesContext(
            to: openResponsesReq.toChatCompletionRequest(),
            previousResponseId: openResponsesReq.previous_response_id
        )

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
        let hop = Self.makeHop(channel: context.channel, loop: loop)

        // Estimate input tokens (rough: 1 token per 4 chars)
        let inputTokens: Int =
            {
                switch request.input {
                case .text(let text):
                    return TokenEstimator.estimate(text)
                case .items(let items):
                    return items.reduce(0) { acc, item in
                        switch item {
                        case .message(let msg):
                            return acc + TokenEstimator.estimate(msg.content.plainText)
                        case .functionCall(let call):
                            return acc + TokenEstimator.estimate(call.arguments)
                        case .functionCallOutput(let output):
                            return acc + TokenEstimator.estimate(output.output)
                        }
                    }
                }
            }() + (request.instructions?.count ?? 0) / TokenEstimator.charsPerToken

        let itemId = Self.shortId(prefix: "item_")
        let reasoningItemId = Self.shortId(prefix: "rs_")

        // Send headers and initial response-level events. Output items
        // (reasoning / message) are now opened lazily inside the stream
        // loop so a reasoning item can land BEFORE the message item, which
        // matches OpenAI Responses semantics for reasoning models.
        hop {
            writerBound.value.writeHeaders(ctx.value, extraHeaders: cors)
            writerBound.value.writeResponseCreated(
                responseId: responseId,
                model: model,
                inputTokens: inputTokens,
                context: ctx.value
            )
            writerBound.value.writeResponseInProgress(context: ctx.value)
        }

        // Capture for logging
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logModel = model
        let logSelf = self

        // Track whether the message item has been opened across the
        // streaming and catch closures. A heap box satisfies Sendable for
        // the concurrent closures that read/mutate the flag.
        let messageItemOpen = AtomicBoolBox()
        let outputText = LockedStringAccumulator()

        Task(priority: .userInitiated) {
            do {
                let chatEngine = self.chatEngine
                let stream = try await chatEngine.streamChat(request: internalReq)
                for try await delta in stream {
                    // Reasoning sentinel must be decoded BEFORE the
                    // generic `isSentinel` filter, otherwise it gets
                    // dropped together with tool/stats hints.
                    if let reasoning = StreamingReasoningHint.decode(delta) {
                        hop {
                            writerBound.value.writeReasoningDelta(
                                reasoning,
                                itemId: reasoningItemId,
                                context: ctx.value
                            )
                        }
                        continue
                    }
                    if let stats = StreamingStatsHint.decode(delta) {
                        hop {
                            writerBound.value.setOutputTokens(stats.tokenCount)
                        }
                        continue
                    }
                    if StreamingToolHint.isSentinel(delta) { continue }
                    outputText.append(delta)
                    hop {
                        // First non-reasoning chunk: close the reasoning
                        // item (if any) then open the message item so the
                        // text deltas land on the message item.
                        writerBound.value.writeReasoningItemDone(context: ctx.value)
                        if !messageItemOpen.value {
                            messageItemOpen.value = true
                            writerBound.value.writeMessageItemAdded(itemId: itemId, context: ctx.value)
                            writerBound.value.writeContentPartAdded(context: ctx.value)
                        }
                        writerBound.value.writeTextDelta(delta, context: ctx.value)
                    }
                }
                hop {
                    // Close any open reasoning item that never got any
                    // following content (rare — reasoning-only response).
                    writerBound.value.writeReasoningItemDone(context: ctx.value)
                    if messageItemOpen.value {
                        writerBound.value.writeTextDone(context: ctx.value)
                        writerBound.value.writeMessageItemDone(context: ctx.value)
                    }
                    writerBound.value.writeResponseCompleted(context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                let text = outputText.value
                if !text.isEmpty {
                    Self.storeOpenResponsesContext(
                        responseId: responseId,
                        model: model,
                        request: internalReq,
                        assistantMessages: [ChatMessage(role: "assistant", content: text)]
                    )
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
            } catch let invs as ServiceToolInvocations {
                // Multi-tool MLX completion: emit one function_call item
                // per invocation. Use the lazy `messageItemOpen` flag so
                // we don't close an item that was never opened.
                hop {
                    writerBound.value.writeReasoningItemDone(context: ctx.value)
                    if messageItemOpen.value {
                        writerBound.value.writeTextDone(context: ctx.value)
                        writerBound.value.writeMessageItemDone(context: ctx.value)
                    }
                    for inv in invs.invocations {
                        self.writeOpenResponsesFunctionCall(inv, writer: writerBound.value, context: ctx.value)
                    }
                    writerBound.value.writeResponseCompleted(context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                if let assistant = Self.assistantMessage(from: invs.invocations) {
                    Self.storeOpenResponsesContext(
                        responseId: responseId,
                        model: model,
                        request: internalReq,
                        assistantMessages: [assistant]
                    )
                }
                let toolLogs = invs.invocations.map {
                    ToolCallLog(name: $0.toolName, arguments: $0.jsonArguments)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/responses",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: logModel,
                    toolCalls: toolLogs,
                    finishReason: .toolCalls
                )
            } catch let inv as ServiceToolInvocation {
                // Single tool invocation — same flow with one item.
                hop {
                    writerBound.value.writeReasoningItemDone(context: ctx.value)
                    if messageItemOpen.value {
                        writerBound.value.writeTextDone(context: ctx.value)
                        writerBound.value.writeMessageItemDone(context: ctx.value)
                    }
                    self.writeOpenResponsesFunctionCall(inv, writer: writerBound.value, context: ctx.value)
                    writerBound.value.writeResponseCompleted(context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                if let assistant = Self.assistantMessage(from: [inv]) {
                    Self.storeOpenResponsesContext(
                        responseId: responseId,
                        model: model,
                        request: internalReq,
                        assistantMessages: [assistant]
                    )
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
                // SSE response head was already 200 — surface as in-band
                // SSE error chunk and log actual on-wire status.
                hop {
                    writerBound.value.writeError(error.localizedDescription, context: ctx.value)
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
                    finishReason: .error,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    /// Build a complete (non-streaming) OpenResponses body whose `output`
    /// is one `function_call` item per supplied invocation. Returns the
    /// JSON body so the caller can also feed it to the request log.
    private static func openResponsesNonStreamingBody(
        responseId: String,
        model: String,
        invocations: [ServiceToolInvocation]
    ) -> String {
        let items: [OpenResponsesOutputItem] = invocations.map { inv in
            let callId = inv.toolCallId ?? Self.shortId(prefix: "call_")
            let itemId = Self.shortId(prefix: "item_")
            return .functionCall(
                OpenResponsesFunctionCall(
                    id: itemId,
                    status: .completed,
                    callId: callId,
                    name: inv.toolName,
                    arguments: inv.jsonArguments
                )
            )
        }
        let resp = OpenResponsesResponse(
            id: responseId,
            createdAt: Int(Date().timeIntervalSince1970),
            status: .completed,
            model: model,
            output: items,
            usage: OpenResponsesUsage(inputTokens: 0, outputTokens: 0)
        )
        return (try? JSONEncoder.osaurusCanonical().encode(resp))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Build an Anthropic `tool_use` block for a single MLX-emitted
    /// invocation. Used by the non-streaming `/messages` handler.
    private static func makeAnthropicToolUseBlock(
        from inv: ServiceToolInvocation
    ) -> AnthropicResponseContentBlock {
        let toolId = inv.toolCallId ?? Self.shortId(prefix: "toolu_")
        var inputDict: [String: AnyCodableValue] = [:]
        if let argsData = inv.jsonArguments.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        {
            inputDict = parsed.mapValues { AnyCodableValue($0) }
        }
        return AnthropicResponseContentBlock.toolUseBlock(
            id: toolId,
            name: inv.toolName,
            input: inputDict
        )
    }

    /// Encode a non-streaming Anthropic Messages response carrying the
    /// supplied content blocks (text/tool_use). Returns the JSON body so
    /// the caller can also feed it to the request log.
    private static func anthropicNonStreamingBody(
        messageId: String,
        model: String,
        blocks: [AnthropicResponseContentBlock]
    ) -> String {
        let resp = AnthropicMessagesResponse(
            id: messageId,
            model: model,
            content: blocks,
            stopReason: "tool_use",
            usage: AnthropicUsage(inputTokens: 0, outputTokens: 0)
        )
        return (try? JSONEncoder.osaurusCanonical().encode(resp))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Emit a complete Anthropic `tool_use` content block for a single
    /// invocation: `content_block_start` → chunked `input_json_delta` →
    /// `content_block_stop`. Caller is responsible for the shared
    /// `tool_use` finish event after the last invocation.
    @inline(__always)
    private func writeAnthropicToolUse(
        _ inv: ServiceToolInvocation,
        writer: AnthropicSSEResponseWriter,
        context: ChannelHandlerContext
    ) {
        let toolId = inv.toolCallId ?? Self.shortId(prefix: "toolu_")
        writer.writeToolUseBlockStart(
            toolId: toolId,
            toolName: inv.toolName,
            context: context
        )
        Self.forEachStringChunk(inv.jsonArguments, size: 512) { chunk in
            writer.writeToolInputDelta(chunk, context: context)
        }
        writer.writeBlockStop(context: context)
    }

    /// Emit a complete OpenAI-style streaming `tool_calls` delta for a
    /// single invocation: `tool_calls[index]` start frame followed by
    /// chunked `arguments` delta frames. Caller is responsible for the
    /// shared `finish_reason: "tool_calls"` after the last invocation.
    @inline(__always)
    private func writeOpenAIToolCallSSE(
        _ inv: ServiceToolInvocation,
        index: Int,
        writer: SSEResponseWriter,
        model: String,
        responseId: String,
        created: Int,
        context: ChannelHandlerContext,
        tools: [Tool]? = nil
    ) {
        let callId: String = {
            if let preservedId = inv.toolCallId, !preservedId.isEmpty { return preservedId }
            return Self.shortId(prefix: "call_")
        }()
        let argumentsJSON = Self.canonicalToolArgumentsJSON(
            inv.jsonArguments,
            schema: Self.toolSchema(named: inv.toolName, in: tools)
        )
        writer.writeToolCallStart(
            callId: callId,
            functionName: inv.toolName,
            index: index,
            model: model,
            responseId: responseId,
            created: created,
            context: context
        )
        Self.forEachStringChunk(argumentsJSON, size: 1024) { chunk in
            writer.writeToolCallArgumentsDelta(
                callId: callId,
                index: index,
                argumentsChunk: chunk,
                model: model,
                responseId: responseId,
                created: created,
                context: context
            )
        }
    }

    /// Emit a complete OpenResponses function-call output item for a single
    /// tool invocation: `output_item.added` → chunked
    /// `function_call_arguments.delta` → `function_call_arguments.done` →
    /// `output_item.done`. Caller is responsible for any preceding item
    /// teardown (closing message / reasoning items) and for emitting
    /// `response.completed` after the last invocation.
    @inline(__always)
    private func writeOpenResponsesFunctionCall(
        _ inv: ServiceToolInvocation,
        writer: OpenResponsesSSEWriter,
        context: ChannelHandlerContext
    ) {
        let callId = inv.toolCallId ?? Self.shortId(prefix: "call_")
        let funcItemId = Self.shortId(prefix: "item_")
        writer.writeFunctionCallItemAdded(
            itemId: funcItemId,
            callId: callId,
            name: inv.toolName,
            context: context
        )
        Self.forEachStringChunk(inv.jsonArguments, size: 512) { chunk in
            writer.writeFunctionCallArgumentsDelta(
                callId: callId,
                delta: chunk,
                context: context
            )
        }
        writer.writeFunctionCallArgumentsDone(callId: callId, context: context)
        writer.writeFunctionCallItemDone(
            callId: callId,
            name: inv.toolName,
            context: context
        )
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
        let hop = Self.makeHop(channel: context.channel, loop: loop)

        // Capture for logging
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        let logModel = model
        let logSelf = self

        Task(priority: .userInitiated) {
            do {
                let chatEngine = self.chatEngine
                let resp = try await chatEngine.completeChat(request: internalReq)

                // Convert to Open Responses format
                let openResponsesResp = resp.toOpenResponsesResponse(responseId: responseId)
                Self.storeOpenResponsesContext(
                    responseId: responseId,
                    model: model,
                    request: internalReq,
                    assistantMessages: Self.assistantMessages(from: resp)
                )

                let json = try JSONEncoder.osaurusCanonical().encode(openResponsesResp)
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
            } catch let invs as ServiceToolInvocations {
                let body = Self.openResponsesNonStreamingBody(
                    responseId: responseId,
                    model: model,
                    invocations: invs.invocations
                )
                if let assistant = Self.assistantMessage(from: invs.invocations) {
                    Self.storeOpenResponsesContext(
                        responseId: responseId,
                        model: model,
                        request: internalReq,
                        assistantMessages: [assistant]
                    )
                }
                Self.writeJSONResponse(body: body, cors: cors, head: head, ctx: ctx, hop: hop)
                let toolLogs = invs.invocations.map {
                    ToolCallLog(name: $0.toolName, arguments: $0.jsonArguments)
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
                    toolCalls: toolLogs,
                    finishReason: .toolCalls
                )
            } catch let inv as ServiceToolInvocation {
                let body = Self.openResponsesNonStreamingBody(
                    responseId: responseId,
                    model: model,
                    invocations: [inv]
                )
                if let assistant = Self.assistantMessage(from: [inv]) {
                    Self.storeOpenResponsesContext(
                        responseId: responseId,
                        model: model,
                        request: internalReq,
                        assistantMessages: [assistant]
                    )
                }
                Self.writeJSONResponse(body: body, cors: cors, head: head, ctx: ctx, hop: hop)
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
                    (try? JSONEncoder.osaurusCanonical().encode(errorResp))
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
                contentStart += 2
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
                bodyEnd -= 2
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

    /// Encode an OpenAI chat-completions response and verify the bytes before
    /// putting them on the wire. Tool-call arguments are model-authored JSON
    /// strings and can contain nested backslash/quote sequences; if Codable
    /// ever produces bytes a client parser rejects, fall back to a
    /// JSONSerialization envelope that treats those arguments as opaque
    /// strings and escapes them at the transport boundary.
    private static func chatCompletionResponseBody(_ response: ChatCompletionResponse) throws -> String {
        let encoded = try JSONEncoder.osaurusCanonical().encode(response)
        if (try? JSONSerialization.jsonObject(with: encoded)) != nil {
            return String(decoding: encoded, as: UTF8.self)
        }

        let data = try JSONSerialization.data(
            withJSONObject: chatCompletionResponseJSONObject(response),
            options: .osaurusCanonical
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func chatCompletionResponseJSONObject(_ response: ChatCompletionResponse) -> [String: Any] {
        var object: [String: Any] = [
            "id": response.id,
            "object": response.object,
            "created": response.created,
            "model": response.model,
            "choices": response.choices.map(chatChoiceJSONObject(_:)),
            "usage": [
                "prompt_tokens": response.usage.prompt_tokens,
                "completion_tokens": response.usage.completion_tokens,
                "total_tokens": response.usage.total_tokens,
            ],
        ]
        if let fingerprint = response.system_fingerprint {
            object["system_fingerprint"] = fingerprint
        }
        if let prefixHash = response.prefix_hash {
            object["prefix_hash"] = prefixHash
        }
        return object
    }

    private static func chatChoiceJSONObject(_ choice: ChatChoice) -> [String: Any] {
        [
            "index": choice.index,
            "finish_reason": choice.finish_reason,
            "message": chatMessageJSONObject(choice.message),
        ]
    }

    private static func chatMessageJSONObject(_ message: ChatMessage) -> [String: Any] {
        var object: [String: Any] = ["role": message.role]
        if let content = message.content {
            object["content"] = content
        }
        if let toolCalls = message.tool_calls {
            object["tool_calls"] = toolCalls.map(toolCallJSONObject(_:))
        }
        if let toolCallId = message.tool_call_id {
            object["tool_call_id"] = toolCallId
        }
        if let reasoning = message.reasoning_content {
            object["reasoning_content"] = reasoning
        }
        return object
    }

    private static func toolCallJSONObject(_ call: ToolCall) -> [String: Any] {
        var object: [String: Any] = [
            "id": call.id,
            "type": call.type,
            "function": [
                "name": call.function.name,
                "arguments": canonicalToolArgumentsJSON(call.function.arguments),
            ],
        ]
        if let signature = call.geminiThoughtSignature {
            object["geminiThoughtSignature"] = signature
        }
        return object
    }

    private static func canonicalToolArgumentsJSON(_ json: String, schema: JSONValue? = nil) -> String {
        let candidates = [
            json,
            json.replacingOccurrences(of: #"\""#, with: #"""#),
        ]
        guard
            let object = candidates.lazy.compactMap({ candidate -> Any? in
                guard let data = candidate.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data)
            }).first
        else {
            return json
        }
        let normalized = normalizeNestedJSONStringValues(object)
        let coerced: Any
        if let schema {
            let candidate = SchemaValidator.coerceArguments(normalized, against: schema)
            let result = SchemaValidator.validate(arguments: candidate, against: schema)
            coerced = result.isValid ? candidate : normalized
        } else {
            coerced = normalized
        }
        guard JSONSerialization.isValidJSONObject(coerced),
            let encoded = try? JSONSerialization.data(withJSONObject: coerced, options: .osaurusCanonical),
            let string = String(data: encoded, encoding: .utf8)
        else {
            return json
        }
        return string
    }

    private static func normalizeNestedJSONStringValues(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(normalizeNestedJSONStringValues(_:))
        }
        if let array = value as? [Any] {
            return array.map(normalizeNestedJSONStringValues(_:))
        }
        if let string = value as? String,
            let nestedData = string.data(using: .utf8),
            let nested = try? JSONSerialization.jsonObject(with: nestedData)
        {
            return normalizeNestedJSONStringValues(nested)
        }
        return value
    }

    private static func toolSchema(named name: String, in tools: [Tool]?) -> JSONValue? {
        tools?.first(where: { $0.function.name == name })?.function.parameters
    }

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
