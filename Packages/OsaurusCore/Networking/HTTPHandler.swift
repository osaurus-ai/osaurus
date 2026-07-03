//
//  HTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import LocalAuthentication
@preconcurrency import MLXLMCommon
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

/// Thread-safe optional-string holder for cross-closure model capture on the
/// agent-run streaming route, where the model name isn't known until after
/// agent resolution but the close hook (a different closure) needs it.
private final class SendableStringBox: @unchecked Sendable {
    private var _value: String?
    private let _lock = NSLock()
    var value: String? {
        get { _lock.withLock { _value } }
        set { _lock.withLock { _value = newValue } }
    }
}

/// Thread-safe holder for the inbound request's attribution metadata
/// (paired-key nonce + audience + transport). The auth gate sets it on the
/// event loop; the request log can be emitted off-loop from inside
/// `runRequestTask`, where touching the `NIOLoopBound` `RequestState` would
/// trap — so the snapshot is read through this lock instead.
private final class SendableConnectionBox: @unchecked Sendable {
    private var _value: RequestConnectionInfo?
    private let _lock = NSLock()
    var value: RequestConnectionInfo? {
        get { _lock.withLock { _value } }
        set { _lock.withLock { _value = newValue } }
    }
}

private final class ChannelCloseFutureBox: @unchecked Sendable {
    private var future: EventLoopFuture<Void>?
    private let lock = NSLock()

    func set(_ value: EventLoopFuture<Void>) {
        lock.withLock { future = value }
    }

    func snapshot() -> EventLoopFuture<Void>? {
        lock.withLock { future }
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
    private let requestTasks = HTTPRequestTaskRegistry()
    private let channelCloseFuture = ChannelCloseFutureBox()
    /// Off-loop-readable mirror of the current request's inbound attribution
    /// (set by the auth gate, cleared on each `.head`). See
    /// `SendableConnectionBox` for why this isn't read off the `RequestState`.
    private let _inboundConnection = SendableConnectionBox()
    private static let openResponsesContextStore = OpenResponsesContextStore()

    /// Internal marker header stamped by `RelayTunnelManager` on every request
    /// it proxies from the relay tunnel to the loopback server. Such requests
    /// arrive over 127.0.0.1 but ORIGINATE from the public internet, so they
    /// must never inherit the loopback auth/CORS trust that genuine local
    /// callers (CLI, App Intents) get. The relay sets this header AFTER copying
    /// the external caller's headers, so a remote caller cannot suppress it.
    static let relayOriginHeaderName = "X-Osaurus-Relay-Origin"
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
        /// Set at `.head` when the request carries the relay-origin marker.
        /// Forces `isLoopbackConnection` to report `false` so relayed internet
        /// traffic is auth-gated even when `trustLoopback` is on.
        var isRelayOrigin: Bool = false
        /// The validated access key's audience (lowercased), set by the auth
        /// gate when a Bearer token validates. `nil` means the caller was
        /// loopback-trusted or hit a public route (no per-agent restriction).
        var authedAudience: String?
        /// `true` when `authedAudience` is the master address — an unrestricted
        /// all-agent key. Agent-scoped keys (`false`) are confined to their
        /// own agent's routes.
        var authedScopeIsMaster: Bool = false
        /// Set when the request arrived as an encrypted `/secure/call`
        /// envelope and was rewritten to its inner request. Routes that
        /// hard-require end-to-end encryption (`/agents/{id}/run`,
        /// `/agents/{id}/dispatch`) check this to reject non-loopback
        /// plaintext with 426.
        var isSecureChannel: Bool = false
    }
    let stateRef: NIOLoopBound<RequestState>

    /// The outbound encryption stage for Secure Channel responses. Lives in
    /// the same pipeline (same event loop); armed when a `/secure/call`
    /// envelope is decrypted so the response is sealed on the way out.
    let responseEncryptor: SecureChannelResponseEncryptor?

    init(
        configuration: ServerConfiguration,
        apiKeyValidator: APIKeyValidator = .empty,
        apiKeyValidatorProvider: (@Sendable () -> APIKeyValidator)? = nil,
        eventLoop: EventLoop,
        chatEngine: ChatEngineProtocol = ChatEngine(),
        trustLoopback: Bool = true,
        responseEncryptor: SecureChannelResponseEncryptor? = nil
    ) {
        self.configuration = configuration
        self.apiKeyValidatorProvider = apiKeyValidatorProvider ?? { apiKeyValidator }
        self.chatEngine = chatEngine
        self.trustLoopback = trustLoopback
        self.responseEncryptor = responseEncryptor
        self.stateRef = NIOLoopBound(RequestState(), eventLoop: eventLoop)
    }

    func channelActive(context: ChannelHandlerContext) {
        _isChannelActive.value = true
        channelCloseFuture.set(context.channel.closeFuture)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        _isChannelActive.value = false
        requestTasks.cancelAll()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            _isChannelActive.value = false
            requestTasks.cancelAll()
        }
        // Slow-loris / idle-hold defense: an upstream `IdleStateHandler` fires
        // this when the connection has stalled past its read/write/all budget
        // (a client dribbling bytes, holding a half-open socket, or parked
        // mid-stream after disconnecting). Cancel in-flight work and close so
        // the socket can't be pinned indefinitely.
        if let idle = event as? IdleStateHandler.IdleStateEvent {
            NSLog("[Osaurus] Closing idle connection (state=%@)", String(describing: idle))
            _isChannelActive.value = false
            requestTasks.cancelAll()
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    private func runRequestTask(
        priority: TaskPriority? = nil,
        operation: @escaping () async -> Void
    ) {
        let id = UUID()
        let requestTasks = requestTasks
        let operationBox = RequestTaskOperation(operation)
        let task = Task(priority: priority) {
            defer { requestTasks.remove(id: id) }
            await operationBox.run()
        }
        channelCloseFuture.snapshot()?.whenComplete { _ in
            task.cancel()
        }
        requestTasks.insert(id: id, task: task)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)

        switch part {
        case .head(let head):
            stateRef.value.requestHead = head
            stateRef.value.requestStartTime = Date()
            stateRef.value.bodyBytesSeen = 0
            stateRef.value.rejectedTooLarge = false
            stateRef.value.isSecureChannel = false
            stateRef.value.authedAudience = nil
            stateRef.value.authedScopeIsMaster = false
            // Clear last request's attribution so a keep-alive connection's
            // next (possibly loopback / public) request can't inherit it.
            _inboundConnection.value = nil
            // Detect relay-proxied traffic before computing CORS / loopback
            // trust so the relay marker can strip loopback privileges.
            stateRef.value.isRelayOrigin =
                head.headers.first(name: HTTPHandler.relayOriginHeaderName) != nil
            stateRef.value.corsHeaders = computeCORSHeaders(
                for: head,
                isPreflight: false,
                isLoopback: isLoopbackConnection(context)
            )
            stateRef.value.bodyByteLimit = bodyByteLimit(for: head)

            // Header DoS guard: reject pathological header sets (a client
            // sending tens of thousands of headers, or megabytes of header
            // bytes) before we do any further per-header work. NIO/llhttp
            // imposes no default ceiling, so an unauthenticated peer could
            // otherwise pin memory/CPU purely with headers.
            var headerCount = 0
            var headerBytes = 0
            for (name, value) in head.headers {
                headerCount += 1
                headerBytes += name.utf8.count + value.utf8.count
                if headerCount > Self.maxRequestHeaderCount
                    || headerBytes > Self.maxRequestHeaderBytes
                {
                    rejectHeadersTooLarge(context: context, head: head)
                    return
                }
            }

            // Reject before allocating the body buffer so a client lying
            // about Content-Length can't force a huge allocation up front.
            if let lengthStr = head.headers.first(name: "Content-Length") {
                // A present-but-malformed or negative Content-Length is a
                // protocol violation (and a negative value would crash the
                // `buffer(capacity:)` allocation below). Reject with 400
                // instead of silently treating it as "no length".
                guard let length = Int(lengthStr), length >= 0 else {
                    sendBadRequest(context: context)
                    stateRef.value.requestHead = nil
                    stateRef.value.requestBodyBuffer = nil
                    return
                }
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
            guard var head = stateRef.value.requestHead else {
                sendBadRequest(context: context)
                return
            }

            // Extract and normalize path (support /, /v1, /api, /v1/api)
            let pathOnly = extractPath(from: head.uri)
            var path = normalize(pathOnly)
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

            // Secure Channel: decrypt an encrypted `/secure/call` envelope and
            // swap in the inner request BEFORE the auth gate, so the inner
            // Authorization header flows through the existing validator,
            // scope check, and routing untouched. The response encryptor is
            // armed here so everything the route writes goes out sealed.
            if head.method == .POST, path == "/secure/call" {
                guard let rewritten = decryptSecureCall(head: head, context: context) else {
                    // decryptSecureCall already sent the error response.
                    stateRef.value.requestHead = nil
                    stateRef.value.requestBodyBuffer = nil
                    return
                }
                head = rewritten.head
                path = rewritten.path
                stateRef.value.requestHead = head
                stateRef.value.normalizedPath = path
                stateRef.value.isSecureChannel = true
            }

            // Access key authentication gate (all data snapshotted at server start, zero locks)
            // Plugin routes handle their own auth per-route, so skip the global gate.
            // Loopback connections (CLI / local tools) are trusted without a token.
            let publicPaths: Set<String> = [
                "/", "/health", "/pair", "/pair/challenge", "/pair-invite", "/secure/session",
            ]
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
                    case .valid(_, let audience, let keyNonce):
                        message = ""
                        // Record the key's scope so agent-addressing routes can
                        // confine an agent-scoped key to its own agent.
                        stateRef.value.authedAudience = audience.lowercased()
                        stateRef.value.authedScopeIsMaster =
                            apiKeyValidator.isMasterScoped(audience: audience)
                        // Snapshot the attribution into the off-loop-readable box
                        // (read by the possibly-off-loop request log) so inbound
                        // `.httpAPI` traffic is tied to this paired key. Built
                        // here where audience + nonce + transport are all known.
                        _inboundConnection.value = RequestConnectionInfo(
                            transport: stateRef.value.isSecureChannel ? .secureChannel : .direct,
                            accessKeyId: keyNonce,
                            audience: audience.lowercased()
                        )
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
            } else if head.method == .GET, path == "/admin/generation-settings" {
                handleGenerationSettingsEndpoint(
                    head: head,
                    context: context,
                    startTime: startTime,
                    userAgent: userAgent,
                    method: method,
                    path: path
                )
            } else if (head.method == .GET || head.method == .PUT), path == "/admin/runtime-settings" {
                handleRuntimeSettingsEndpoint(
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
            } else if head.method == .POST, path == "/completions" || path == "/v1/completions" {
                handleCompletions(head: head, context: context, startTime: startTime, userAgent: userAgent)
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
            } else if head.method == .POST, path == "/responses" || path == "/v1/responses" {
                handleOpenResponses(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/memory/ingest" {
                handleMemoryIngest(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .GET, path == "/pair/challenge" {
                handlePairChallengeEndpoint(
                    head: head,
                    context: context,
                    startTime: startTime,
                    userAgent: userAgent
                )
            } else if head.method == .POST, path == "/pair" {
                handlePairEndpoint(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/pair-invite" {
                handlePairInviteEndpoint(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/secure/session" {
                handleSecureSessionEndpoint(head: head, context: context, startTime: startTime, userAgent: userAgent)
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
            } else if head.method == .GET, path == "/images/models" {
                handleImageModels(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/images/generations" {
                handleImageGenerations(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/images/edits" {
                handleImageEdits(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/images/upscale" {
                handleImageUpscale(head: head, context: context, startTime: startTime, userAgent: userAgent)
            } else if head.method == .POST, path == "/images/cancel" {
                handleImageCancel(head: head, context: context, startTime: startTime, userAgent: userAgent)
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

        runRequestTask(priority: .userInitiated) {
            let cached = await ModelRuntime.shared.cachedModelSummaries(refreshTopology: true)
            let batchDiagnostics = await MLXBatchAdapter.snapshotDiagnostics()
            let lastEffectiveGenerationSettings =
                await MLXBatchAdapter.lastEffectiveGenerationSettingsSnapshot()
            var aggregate: [String: Int] = [
                "prefix_hits": 0,
                "prefix_misses": 0,
                "paged_hits": 0,
                "paged_misses": 0,
                "disk_l2_hits": 0,
                "disk_l2_misses": 0,
                "disk_l2_stores": 0,
                "companion_hits": 0,
                "companion_misses": 0,
                "companion_rederives": 0,
                "ssm_companion_hits": 0,
                "ssm_companion_misses": 0,
                "ssm_companion_rederives": 0,
                "zaya_cca_disk_payload_hits": 0,
                "zaya_cca_disk_payload_misses": 0,
                "zaya_cca_disk_payload_stores": 0,
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
                row["native_mtp_status"] = summary.nativeMTPStatus ?? NSNull()
                row["native_mtp_reason"] = summary.nativeMTPReason ?? NSNull()
                row["generation_defaults"] = Self.generationDefaultsJSONObject(
                    LocalGenerationDefaults.defaults(forModelId: summary.name)
                )
                if let effective = lastEffectiveGenerationSettings[summary.name] {
                    row["last_effective_generation"] = Self.effectiveGenerationSettingsJSONObject(effective)
                } else {
                    row["last_effective_generation"] = NSNull()
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
                row["effective_kv_mode"] = ModelRuntime.cacheKVModeTag(
                    for: ServerRuntimeSettingsStore.snapshot().cache,
                    modelName: summary.name,
                    cacheTopology: summary.cacheTopology
                )
                if let topology = summary.cacheTopology {
                    row["cache_topology"] =
                        [
                            "layer_count": topology.layerCount,
                            "kv_layer_count": topology.kvLayerCount,
                            "chunked_kv_layer_count": topology.chunkedKVLayerCount,
                            "quantized_kv_layer_count": topology.quantizedKVLayerCount,
                            "turbo_quant_kv_layer_count": topology.turboQuantKVLayerCount,
                            "compilable_kv_layer_count": topology.compilableKVLayerCount,
                            "compilable_turbo_quant_kv_layer_count": topology.compilableTurboQuantKVLayerCount,
                            "rotating_kv_layer_count": topology.rotatingKVLayerCount,
                            "compilable_rotating_kv_layer_count": topology.compilableRotatingKVLayerCount,
                            "rotating_wrapper_layer_count": topology.rotatingWrapperLayerCount,
                            "hybrid_pool_layer_count": topology.hybridPoolLayerCount,
                            "mamba_layer_count": topology.mambaLayerCount,
                            "compilable_mamba_layer_count": topology.compilableMambaLayerCount,
                            "arrays_layer_count": topology.arraysLayerCount,
                            "zaya_cca_layer_count": topology.zayaCCALayerCount,
                            "cache_list_layer_count": topology.cacheListLayerCount,
                            "requires_ssm_companion_state": topology.requiresSSMCompanionState,
                            "requires_disk_backed_restore": topology.requiresDiskBackedCoordinatorRestore,
                            "tags": topology.topologyTags,
                        ] as [String: Any]
                }

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
                }
                row["block_disk_store"] = disk

                let ssm = stats.ssmStats
                let companionKinds =
                    summary.cacheTopology?.topologyTags.filter {
                        $0.hasPrefix("companion=")
                    } ?? []
                let hasSSMCompanion = companionKinds.contains("companion=ssm")
                let hasZayaCCACompanion =
                    (summary.cacheTopology?.zayaCCALayerCount ?? 0) > 0
                if hasZayaCCACompanion, let diskStats = stats.diskStats {
                    row["zaya_cca_disk_payload_restore"] =
                        [
                            "hits": diskStats.hits,
                            "misses": diskStats.misses,
                            "stores": diskStats.stores,
                            "embedded_state": true,
                        ] as [String: Any]
                    aggregate["zaya_cca_disk_payload_hits", default: 0] += diskStats.hits
                    aggregate["zaya_cca_disk_payload_misses", default: 0] += diskStats.misses
                    aggregate["zaya_cca_disk_payload_stores", default: 0] += diskStats.stores
                }
                row["companion_cache"] = [
                    "hits": ssm.hits,
                    "misses": ssm.misses,
                    "rederives": ssm.reDerives,
                    "kinds": companionKinds,
                ]
                if hasSSMCompanion {
                    row["ssm_companion_cache"] = [
                        "hits": ssm.hits,
                        "misses": ssm.misses,
                        "rederives": ssm.reDerives,
                    ]
                }
                aggregate["companion_hits", default: 0] += ssm.hits
                aggregate["companion_misses", default: 0] += ssm.misses
                aggregate["companion_rederives", default: 0] += ssm.reDerives
                if hasSSMCompanion {
                    aggregate["ssm_companion_hits", default: 0] += ssm.hits
                    aggregate["ssm_companion_misses", default: 0] += ssm.misses
                    aggregate["ssm_companion_rederives", default: 0] += ssm.reDerives
                }
                return row
            }

            let runtimeSettings = ServerRuntimeSettingsStore.snapshot()
            let memoryStatus = MemoryStatus.snapshot()
            let memorySafetyPlan = runtimeSettings.resolvedMemorySafetyPlan(
                baseLoadConfiguration: .osaurusProduction,
                host: memoryStatus
            )

            var obj: [String: Any] = [
                "status": "ok",
                "timestamp": Date().ISO8601Format(),
                "models": models,
                "aggregate": aggregate,
                "memory_safety": Self.memorySafetyJSONObject(
                    settings: runtimeSettings,
                    plan: memorySafetyPlan,
                    memoryStatus: memoryStatus
                ),
                "storage_locations": Self.storageLocationsJSONObject(),
            ]
            if let batchDiagnostics {
                obj["batch_diagnostics"] =
                    [
                        "pending_count": batchDiagnostics.pendingCount,
                        "active_count": batchDiagnostics.activeCount,
                        "active_high_watermark": batchDiagnostics.activeHighWatermark,
                        "decode_split_count": batchDiagnostics.decodeSplitCount,
                        "turbo_quant_compressions": batchDiagnostics.turboQuantCompressions,
                        "is_accepting_requests": batchDiagnostics.isAcceptingRequests,
                        "loaded_model_count": batchDiagnostics.loadedModelCount,
                        "native_mtp_model_count": batchDiagnostics.nativeMTPModelCount,
                        "native_mtp_depth_summary": batchDiagnostics.nativeMTPDepthSummary ?? NSNull(),
                        "cache_enabled_model_count": batchDiagnostics.cacheEnabledModelCount,
                        "hybrid_model_count": batchDiagnostics.hybridModelCount,
                        "paged_incompatible_model_count": batchDiagnostics.pagedIncompatibleModelCount,
                        "prefix_hits": batchDiagnostics.prefixHits,
                        "prefix_misses": batchDiagnostics.prefixMisses,
                        "disk_l2_hits": batchDiagnostics.diskL2Hits,
                        "disk_l2_misses": batchDiagnostics.diskL2Misses,
                        "disk_l2_stores": batchDiagnostics.diskL2Stores,
                        "ssm_companion_hits": batchDiagnostics.ssmCompanionHits,
                        "ssm_companion_misses": batchDiagnostics.ssmCompanionMisses,
                        "ssm_companion_rederives": batchDiagnostics.ssmCompanionReDerives,
                    ] as [String: Any]
            } else {
                obj["batch_diagnostics"] = NSNull()
            }
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

    /// `/admin/generation-settings` exposes the bundle-derived defaults and
    /// the last effective generation settings that were actually submitted to
    /// vmlx. It intentionally avoids `ModelRuntime` so it remains responsive
    /// when an in-flight MLX prepare/decode path is blocked.
    private func handleGenerationSettingsEndpoint(
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

        runRequestTask(priority: .userInitiated) {
            let lastEffectiveGenerationSettings =
                await MLXBatchAdapter.lastEffectiveGenerationSettingsSnapshot()
            var defaultsByModel: [String: Any] = [:]
            var effectiveByModel: [String: Any] = [:]
            for modelName in lastEffectiveGenerationSettings.keys.sorted() {
                defaultsByModel[modelName] = Self.generationDefaultsJSONObject(
                    LocalGenerationDefaults.defaults(forModelId: modelName)
                )
                if let effective = lastEffectiveGenerationSettings[modelName] {
                    effectiveByModel[modelName] = Self.effectiveGenerationSettingsJSONObject(effective)
                }
            }

            let obj: [String: Any] = [
                "status": "ok",
                "timestamp": Date().ISO8601Format(),
                "source":
                    "last effective settings resolved by Osaurus; stage indicates whether they are pending preload or submitted to vmlx BatchEngine",
                "models": lastEffectiveGenerationSettings.keys.sorted(),
                "generation_defaults_by_model": defaultsByModel,
                "last_effective_generation_by_model": effectiveByModel,
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

    /// `/admin/runtime-settings` is the automation companion for the Server
    /// Settings panel. GET returns the exact persisted vMLX runtime settings.
    /// PUT accepts a full `VMLXServerRuntimeSettings` JSON document and applies
    /// only runtime-scoped changes; network rebinding still belongs to the
    /// SwiftUI panel / `ServerController` path so an HTTP request cannot
    /// restart the server out from under itself.
    private func handleRuntimeSettingsEndpoint(
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
        let parsedBody = head.method == .PUT ? readRequestBody() : nil

        runRequestTask(priority: .userInitiated) {
            let previous = ServerRuntimeSettingsStore.snapshot()

            if head.method == .GET {
                let body = Self.runtimeSettingsResponseBody(
                    settings: previous,
                    previous: nil,
                    effects: [:]
                )
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
                return
            }

            guard let parsedBody, !parsedBody.data.isEmpty else {
                let body = Self.errorBody(
                    .openai(type: "invalid_request_error"),
                    message: "Runtime settings PUT requires a JSON VMLXServerRuntimeSettings body."
                )
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: version,
                        status: .badRequest,
                        headers: headers,
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: logMethod,
                    path: logPath,
                    userAgent: logUserAgent,
                    requestBody: parsedBody?.text,
                    responseBody: body,
                    responseStatus: 400,
                    startTime: logStartTime
                )
                return
            }

            let next: VMLXServerRuntimeSettings
            do {
                next = try JSONDecoder().decode(VMLXServerRuntimeSettings.self, from: parsedBody.data)
            } catch {
                let body = Self.errorBody(
                    .openai(type: "invalid_request_error"),
                    message: "Invalid runtime settings JSON: \(error.localizedDescription)"
                )
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: version,
                        status: .badRequest,
                        headers: headers,
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: logMethod,
                    path: logPath,
                    userAgent: logUserAgent,
                    requestBody: parsedBody.text,
                    responseBody: body,
                    responseStatus: 400,
                    startTime: logStartTime
                )
                return
            }

            if previous.network != next.network {
                let body = Self.errorBody(
                    .openai(type: "invalid_request_error"),
                    message:
                        "Network runtime settings require the Server Settings panel because they can restart/rebind the HTTP server. Keep network unchanged for /admin/runtime-settings."
                )
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: version,
                        status: .badRequest,
                        headers: headers,
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: logMethod,
                    path: logPath,
                    userAgent: logUserAgent,
                    requestBody: parsedBody.text,
                    responseBody: body,
                    responseStatus: 400,
                    startTime: logStartTime
                )
                return
            }

            let validationIssues = next.validationIssues()
            let blockingIssues = validationIssues.filter { $0.severity == .error }
            guard blockingIssues.isEmpty else {
                let obj: [String: Any] = [
                    "error": [
                        "message": "Runtime settings contain validation errors.",
                        "type": "invalid_request_error",
                        "issues": blockingIssues.map(Self.settingsIssueJSONObject),
                    ] as [String: Any]
                ]
                let data = try? JSONSerialization.data(withJSONObject: obj, options: .osaurusCanonical)
                let body = data.flatMap { String(decoding: $0, as: UTF8.self) } ?? "{}"
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: version,
                        status: .badRequest,
                        headers: headers,
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: logMethod,
                    path: logPath,
                    userAgent: logUserAgent,
                    requestBody: parsedBody.text,
                    responseBody: body,
                    responseStatus: 400,
                    startTime: logStartTime
                )
                return
            }

            let loadedModelRefreshNeeded =
                previous.cache != next.cache
                || previous.multimodal != next.multimodal
                || previous.mtp != next.mtp
                // The tied-head codec applies at model construction
                // (TiedHeadQuantizationPolicy is read while loading the head),
                // so a change takes effect on the next load — evicting the
                // resident model makes the toggle live. Compare
                // effectivePerformance so a nil<->explicit-default edit
                // (semantically unchanged) does not force a spurious reload.
                //
                // NOTE: the *compiled-decode* lever is different — MLX caches
                // its compile state at the first model load of the process, so
                // it can only engage when VMLX_ENABLE_UNSAFE_COMPILE is set
                // before that first load (i.e. at launch from a persisted
                // setting). A mid-session reload cannot turn it on; that is
                // surfaced separately via `compiled_decode_restart_required`.
                || previous.effectivePerformance != next.effectivePerformance
            let runtimeConfigInvalidated =
                previous.generation != next.generation
                || previous.concurrency != next.concurrency
            // Compiled decode is a process-startup lever (see above): a change
            // to it only takes effect after restarting Osaurus, so report that
            // explicitly rather than letting the toggle look live.
            let compiledDecodeRestartRequired =
                previous.effectivePerformance.compiledDecode
                != next.effectivePerformance.compiledDecode

            ServerRuntimeSettingsStore.save(next)
            if loadedModelRefreshNeeded {
                await ModelRuntime.shared.clearAll()
            }
            if runtimeConfigInvalidated {
                await ModelRuntime.shared.invalidateConfig()
            }

            let effects: [String: Any] = [
                "loaded_model_refresh_needed": loadedModelRefreshNeeded,
                "runtime_config_invalidated": runtimeConfigInvalidated,
                "compiled_decode_restart_required": compiledDecodeRestartRequired,
                "network_restart_rejected": false,
                "validation_warnings":
                    validationIssues
                    .filter { $0.severity == .warning }
                    .map(Self.settingsIssueJSONObject),
            ]
            let body = Self.runtimeSettingsResponseBody(
                settings: next,
                previous: previous,
                effects: effects
            )
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
                requestBody: parsedBody.text,
                responseBody: body,
                responseStatus: 200,
                startTime: logStartTime
            )
        }
    }

    private static func runtimeSettingsResponseBody(
        settings: VMLXServerRuntimeSettings,
        previous: VMLXServerRuntimeSettings?,
        effects: [String: Any]
    ) -> String {
        var obj: [String: Any] = [
            "status": "ok",
            "timestamp": Date().ISO8601Format(),
            "settings": runtimeSettingsJSONObject(settings),
            "effects": effects,
        ]
        if let previous {
            obj["previous_settings"] = runtimeSettingsJSONObject(previous)
        }
        let data = try? JSONSerialization.data(withJSONObject: obj, options: .osaurusCanonical)
        return data.flatMap { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func runtimeSettingsJSONObject(
        _ settings: VMLXServerRuntimeSettings
    ) -> Any {
        guard let data = try? JSONEncoder().encode(settings),
            let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return [:]
        }
        return object
    }

    /// Storage-location standards audit block for `/admin/cache-stats`.
    /// Read-only probe + pure classification; see issue #1422 and
    /// `docs/STORAGE.md` (Storage Location Standards).
    private static func storageLocationsJSONObject() -> [String: Any] {
        StorageLocationStandards.jsonObject(for: StorageLocationStandards.currentReport())
    }

    private static func memorySafetyJSONObject(
        settings: VMLXServerRuntimeSettings,
        plan: VMLXResolvedMemorySafetyPlan,
        memoryStatus: MemoryStatus
    ) -> [String: Any] {
        let memorySafety = settings.memorySafety
        let validationIssues = memorySafety.validationIssues()
        let issues = validationIssues + plan.blockingIssues
        return [
            "mode": memorySafety.mode.rawValue,
            "slider": memorySafety.slider,
            "allowed": plan.blockingIssues.isEmpty,
            "display_summary": plan.displaySummary,
            "resolved_physical_memory_bytes": plan.resolvedPhysicalMemoryBytes,
            "resolved_load_budget_bytes": plan.resolvedLoadBudgetBytes as Any? ?? NSNull(),
            "load_configuration": loadConfigurationJSONObject(plan.loadConfiguration),
            "cache": cacheSettingsJSONObject(plan.cache),
            "concurrency": concurrencySettingsJSONObject(plan.concurrency),
            "memory_status": memoryStatusJSONObject(memoryStatus),
            "warnings": plan.warnings,
            "blocking_issues": plan.blockingIssues.map(settingsIssueJSONObject),
            "validation_issues": validationIssues.map(settingsIssueJSONObject),
            "issues": issues.map(settingsIssueJSONObject),
        ]
    }

    private static func loadConfigurationJSONObject(
        _ configuration: LoadConfiguration
    ) -> [String: Any] {
        [
            "memory_limit": residentCapJSONObject(configuration.memoryLimit),
            "max_resident_bytes": residentCapJSONObject(configuration.maxResidentBytes),
            "use_mmap_safetensors": configuration.useMmapSafetensors,
            "jang_press_policy": jangPressPolicyJSONObject(configuration.jangPress),
            "native_mtp": configuration.nativeMTP,
        ]
    }

    private static func cacheSettingsJSONObject(
        _ cache: VMLXServerCacheSettings
    ) -> [String: Any] {
        [
            "prefix_enabled": cache.prefix.enabled,
            "prefix_memory_limit_mb": cache.prefix.memoryLimitMB as Any? ?? NSNull(),
            "prefix_memory_percent": cache.prefix.memoryPercent as Any? ?? NSNull(),
            "prefix_ttl_minutes": cache.prefix.ttlMinutes as Any? ?? NSNull(),
            "paged_kv_enabled": cache.pagedKV.enabled,
            "paged_kv_block_size": cache.pagedKV.blockSize as Any? ?? NSNull(),
            "paged_kv_max_blocks": cache.pagedKV.maxBlocks as Any? ?? NSNull(),
            "block_disk_enabled": cache.blockDisk.enabled,
            "block_disk_max_size_gb": cache.blockDisk.maxSizeGB as Any? ?? NSNull(),
            "block_disk_directory": cache.blockDisk.directory as Any? ?? NSNull(),
            "legacy_disk_enabled": cache.legacyDisk.enabled,
            "live_kv_codec": cache.liveKVCodec.rawValue,
            "stored_kv_codec": cache.storedKVCodec.rawValue,
            "turbo_quant_key_bits": cache.turboQuantKeyBits as Any? ?? NSNull(),
            "turbo_quant_value_bits": cache.turboQuantValueBits as Any? ?? NSNull(),
            "default_max_kv_size": cache.defaultMaxKVSize as Any? ?? NSNull(),
            "long_prompt_multiplier": cache.longPromptMultiplier,
            "enable_ssm_rederive": cache.enableSSMReDerive,
        ]
    }

    private static func generationDefaultsJSONObject(
        _ defaults: LocalGenerationDefaults.Defaults
    ) -> [String: Any] {
        [
            "max_tokens": defaults.maxTokens as Any? ?? NSNull(),
            "temperature": defaults.temperature as Any? ?? NSNull(),
            "top_p": defaults.topP as Any? ?? NSNull(),
            "top_k": defaults.topK as Any? ?? NSNull(),
            "min_p": defaults.minP as Any? ?? NSNull(),
            "repetition_penalty": defaults.repetitionPenalty as Any? ?? NSNull(),
            "do_sample": defaults.doSample as Any? ?? NSNull(),
        ]
    }

    private static func effectiveGenerationSettingsJSONObject(
        _ settings: MLXBatchAdapter.EffectiveGenerationSettings
    ) -> [String: Any] {
        [
            "stage": settings.stage,
            "temperature": settings.temperature,
            "max_tokens": settings.maxTokens,
            "top_p": settings.topP,
            "top_k": settings.topK,
            "min_p": settings.minP,
            "repetition_penalty": settings.repetitionPenalty as Any? ?? NSNull(),
            "compiled_batch_decode": settings.compiledBatchDecode,
        ]
    }

    private static func concurrencySettingsJSONObject(
        _ concurrency: VMLXServerConcurrencySettings
    ) -> [String: Any] {
        [
            "max_concurrent_sequences": concurrency.maxConcurrentSequences as Any? ?? NSNull(),
            "prefill_batch_size": concurrency.prefillBatchSize as Any? ?? NSNull(),
            "prefill_step_size": concurrency.prefillStepSize as Any? ?? NSNull(),
            "completion_batch_size": concurrency.completionBatchSize as Any? ?? NSNull(),
            "continuous_batching": concurrency.continuousBatching,
            "smelt_mode": concurrency.smeltMode.rawValue,
        ]
    }

    private static func memoryStatusJSONObject(_ status: MemoryStatus) -> [String: Any] {
        [
            "memory_limit": status.memoryLimit,
            "cache_limit": status.cacheLimit,
            "recommended_working_set_bytes": status.recommendedWorkingSetBytes as Any? ?? NSNull(),
            "physical_memory": status.physicalMemory,
            "current_rss": status.currentRSS,
        ]
    }

    private static func residentCapJSONObject(_ cap: ResidentCap) -> [String: Any] {
        switch cap {
        case .unlimited:
            return ["kind": "unlimited", "value": NSNull()]
        case .fraction(let fraction):
            return ["kind": "fraction", "value": fraction]
        case .absolute(let bytes):
            return ["kind": "absolute", "value": bytes]
        }
    }

    private static func jangPressPolicyJSONObject(_ policy: JangPressPolicy) -> [String: Any] {
        switch policy {
        case .disabled:
            return ["kind": "disabled"]
        case .enabled(let coldFraction):
            return ["kind": "enabled", "cold_fraction": coldFraction]
        case .auto(let envFallback):
            return ["kind": "auto", "env_fallback": envFallback]
        }
    }

    private static func settingsIssueJSONObject(
        _ issue: VMLXServerSettingsIssue
    ) -> [String: Any] {
        [
            "severity": issue.severity.rawValue,
            "field": issue.field,
            "message": issue.message,
        ]
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
        // Tie the plugin handler task to the channel lifecycle so a client
        // disconnect / idle-timeout cancels in-flight plugin work instead of
        // leaving it running (and the registry entry pinned) for a dead
        // connection. Mirrors `runRequestTask`.
        let pluginTaskId = UUID()
        let pluginRegistry = requestTasks
        let task = Task {
            defer { pluginRegistry.remove(id: pluginTaskId) }
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

                    guard
                        let resolvedFileURL = Self.containedPluginStaticFileURL(
                            for: fileURL,
                            webDirectory: webDir
                        )
                    else {
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
                    if FileManager.default.fileExists(atPath: resolvedFileURL.path) {
                        return self.serveStaticFile(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            filePath: resolvedFileURL.path,
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
                    let entryURL = webDir.appendingPathComponent(webSpec.entry)
                    guard
                        let resolvedEntryURL = Self.containedPluginStaticFileURL(
                            for: entryURL,
                            webDirectory: webDir
                        )
                    else {
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
                    if FileManager.default.fileExists(atPath: resolvedEntryURL.path) {
                        return self.serveStaticFile(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            filePath: resolvedEntryURL.path,
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
        channelCloseFuture.snapshot()?.whenComplete { _ in task.cancel() }
        requestTasks.insert(id: pluginTaskId, task: task)
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

    /// Resolves symlinks before plugin static serving so path checks use the real filesystem boundary.
    static func containedPluginStaticFileURL(for candidateURL: URL, webDirectory: URL) -> URL? {
        let baseURL = webDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = candidateURL.resolvingSymlinksInPath().standardizedFileURL
        let basePath = baseURL.path
        let resolvedPath = resolvedURL.path

        guard resolvedPath == basePath || resolvedPath.hasPrefix(basePath + "/") else {
            return nil
        }
        return resolvedURL
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
        if path == "/pair" || path == "/pair-invite" || path == "/secure/session" {
            return configuration.maxPairingBodyBytes
        }
        return configuration.maxRequestBodyBytes
    }

    /// Upper bound on the number of request headers we accept. Anything past
    /// this is a malformed/abusive client; a normal request has well under
    /// a few dozen headers.
    static let maxRequestHeaderCount = 200
    /// Upper bound on the total bytes across all header names+values. Bounds
    /// the header-only memory/CPU an unauthenticated peer can force.
    static let maxRequestHeaderBytes = 1 * 1024 * 1024
    /// Maximum structural nesting depth (`{`/`[`) we hand to a JSON decoder.
    /// A body within the size cap can still be a depth bomb that overflows
    /// the decoder's recursion; this is far beyond any real chat/tool payload.
    static let maxJSONNestingDepth = 256

    /// Reply 431 Request Header Fields Too Large and close. Done at `.head`
    /// before any body allocation or routing so a header-flood can't pin
    /// resources.
    private func rejectHeadersTooLarge(context: ChannelHandlerContext, head: HTTPRequestHead) {
        stateRef.value.rejectedTooLarge = true
        stateRef.value.requestBodyBuffer = nil
        let path = normalize(extractPath(from: head.uri))
        let body =
            #"{"error":{"message":"Request header fields too large","type":"request_header_fields_too_large"}}"#
        var headers = [("Content-Type", "application/json; charset=utf-8")]
        headers.append(contentsOf: stateRef.value.corsHeaders)
        let status = HTTPResponseStatus(statusCode: 431, reasonPhrase: "Request Header Fields Too Large")
        sendResponse(
            context: context,
            version: head.version,
            status: status,
            headers: headers,
            body: body
        )
        logRequest(
            method: head.method.rawValue,
            path: path,
            userAgent: head.headers.first(name: "User-Agent"),
            requestBody: nil,
            responseBody: body,
            responseStatus: 431,
            startTime: stateRef.value.requestStartTime
        )
        stateRef.value.requestHead = nil
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
        requestTasks.cancelAll()
        context.close(promise: nil)
    }

    // MARK: - CORS

    /// Best-effort source IP for rate-limiting the pairing endpoints.
    private func remoteIP(_ context: ChannelHandlerContext) -> String {
        context.channel.remoteAddress?.ipAddress ?? "unknown"
    }

    /// Whether the inbound connection is a "trusted local caller" — i.e., a
    /// process on the user's own machine reaching us via 127.0.0.1 / ::1.
    /// Both the auth gate and CORS auto-trust use this predicate so the two
    /// stay in lockstep; flipping `trustLoopback` off (e.g. behind a reverse
    /// proxy) disables both.
    private func isLoopbackConnection(_ context: ChannelHandlerContext) -> Bool {
        // Relay-tunnel traffic reaches us over loopback but is remote in origin
        // (see `relayOriginHeaderName`). Such requests never count as a trusted
        // local caller, so they remain subject to the auth gate, CORS origin
        // rules, and the built-in-agent remote block.
        guard !stateRef.value.isRelayOrigin else { return false }
        return trustLoopback && (context.channel.remoteAddress?.isLoopback ?? false)
    }

    /// Enforce that an agent-scoped access key only addresses its own agent.
    /// Returns a rejection when the validated key's audience is an agent
    /// address that does not match the target agent. Loopback callers,
    /// master-scoped keys, and public routes (no recorded audience) pass
    /// through unrestricted. An unknown agent→address mapping is denied so a
    /// scoped key cannot reach an agent we can't prove it owns.
    private func agentScopeRejection(forAgentId agentId: UUID) -> (code: String, message: String)? {
        Self.agentScopeRejection(
            forAgentId: agentId,
            authedAudience: stateRef.value.authedAudience,
            authedScopeIsMaster: stateRef.value.authedScopeIsMaster
        )
    }

    /// Pure core of the agent-scope check so it can run inside detached request
    /// tasks (which must not touch the event-loop-bound `stateRef`). Callers
    /// capture `authedAudience` / `authedScopeIsMaster` on the event loop and
    /// pass them in.
    static func agentScopeRejection(
        forAgentId agentId: UUID,
        authedAudience: String?,
        authedScopeIsMaster: Bool
    ) -> (code: String, message: String)? {
        guard let aud = authedAudience, !authedScopeIsMaster else { return nil }
        guard let target = AgentIdentityRegistry.shared.address(forAgentId: agentId), aud == target
        else {
            return (
                "agent_scope_denied",
                "This access key is not scoped to the requested agent."
            )
        }
        return nil
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

    /// Enrich an agent-loop request with the agent's system prompt and memory context.
    ///
    /// Goes through `composeChatContext` and injects the rendered prompt +
    /// memory snippet into the outgoing message array. Do not call this from
    /// the strict OpenAI-compatible `/chat/completions` path; that endpoint
    /// passes client messages/tools through unchanged.
    private static func enrichWithAgentContext(
        _ request: ChatCompletionRequest,
        agentId: String?,
        executionMode: ExecutionMode
    ) async -> ChatCompletionRequest {
        guard let agentId, !agentId.isEmpty,
            let agentUUID = UUID(uuidString: agentId)
        else { return request }

        var enriched = request
        let query = request.messages.last(where: { $0.role == "user" })?.content ?? ""
        // Honor the global "Disable tools" switch on the HTTP path too —
        // `effectiveToolsDisabled` does not read it, so it must be folded
        // in here (the app chat path does the same via `chatCfg.disableTools`).
        let globalToolsDisabled = await MainActor.run { ChatConfigurationStore.load().disableTools }
        let composed = await SystemPromptComposer.composeChatContext(
            agentId: agentUUID,
            executionMode: executionMode,
            query: query,
            messages: enriched.messages,
            toolsDisabled: globalToolsDisabled
        )
        if !composed.prompt.isEmpty {
            SystemPromptComposer.injectSystemContent(composed.prompt, into: &enriched.messages)
        }
        // Session-stable memory injection: when the caller supplies a
        // session_id, previously injected prefixes are replayed onto the
        // matching history user messages (the client resends CLEAN history,
        // so without this the prior turn's injected bytes vanish and the
        // paged-KV prefix diverges at that message — re-prefilling the whole
        // last exchange). Without a session_id there is no cross-request
        // identity, so it falls back to plain latest-message injection.
        if let sid = request.session_id, !sid.isEmpty {
            let frozen = await SessionToolStateStore.shared.frozenUserPrefixes(sid)
            if let recorded = SystemPromptComposer.applyFrozenMemoryPrefixes(
                memorySection: composed.memorySection,
                frozen: frozen,
                into: &enriched.messages
            ) {
                await SessionToolStateStore.shared.recordUserPrefix(
                    sid,
                    key: recorded.key,
                    prefix: recorded.prefix
                )
            }
        } else {
            SystemPromptComposer.injectMemoryPrefix(composed.memorySection, into: &enriched.messages)
        }
        // Agent-run / HTTP orchestrators must get the active Subagent
        // tools as callable SCHEMAS too. `composeChatContext` only surfaces the
        // built-in image tools as a prompt-hint capability (not the schema), so
        // without this an agent-run orchestrator is told it can make images /
        // delegate but `image`/`spawn` never reach its `<tools>` block.
        // Per-agent gate: only inject the delegation schemas when THIS agent has
        // actually opted into spawn/image (mirrors the authoritative
        // `resolveTools` strip). Without this, the explicit injection below would
        // re-add tools the per-agent gate just stripped.
        // Mirror the authoritative native-chat `resolveTools` surfacing so the
        // HTTP agent-run path and the in-app chat agree on which subagent tools
        // an agent sees: resolve the per-agent visible delegation set through the
        // shared `SubagentToolVisibility` resolver (the same SSOT the native
        // `resolveTools` strip reads) — Default → main-chat pool / image switch,
        // custom → its own per-agent toggles + spawnable allow-list. There is no
        // global master switch; the per-agent opt-in is the only gate. Without
        // this parity the `/agents/{id}/run` surface drifts from the chat UI
        // (BUG E guard). The tool-name set comes from the capability registry,
        // not a hardcoded list.
        // Installed-capability gate for `image`, mirroring the native
        // `resolveTools` strip: the per-agent switch can be on, but the tool is
        // withheld when no ready image model exists, and narrowed to a
        // generation-only schema when a gen model is present but no edit model
        // is (so the agent-run surface never advertises an edit it can't run).
        let (visibleDelegation, swapImageToGenerationOnly) = await MainActor.run {
            () -> (Set<String>, Bool) in
            let snapshot = AgentConfigSnapshot.capture(agentId: agentUUID)
            let cache = ModelPickerItemCache.shared
            let names = SubagentToolVisibility.visibleDelegationToolNames(
                agentId: agentUUID,
                snapshot: snapshot,
                config: SubagentConfigurationStore.snapshot(),
                hasReadyImageModel: cache.hasReadyImageModel,
                hasReadyAppleScriptModel: cache.hasReadyAppleScriptModel
            )
            let swap = names.contains("image") && !cache.hasReadyImageEditModel
            return (names, swap)
        }
        let delegationSpecs =
            visibleDelegation.isEmpty
            ? []
            : await MainActor.run { () -> [Tool] in
                let raw = ToolRegistry.shared.specs(forTools: Array(visibleDelegation))
                guard swapImageToGenerationOnly else { return raw }
                return raw.map {
                    $0.function.name == "image" ? ImageTool.generationOnlySpec() : $0
                }
            }
        let composedToolNames = Set(composed.tools.map(\.function.name))
        let contextToolsWithDelegation =
            composed.tools + delegationSpecs.filter { !composedToolNames.contains($0.function.name) }
        let mergedTools = await mergeAgentContextTools(
            contextToolsWithDelegation,
            clientTools: request.tools
        )
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

    /// Resolve the sampling values the `/agents/{id}/run` loop should use.
    /// The request body wins when present; the agent's configured value
    /// (`effectiveTemperature` / `effectiveMaxTokens`) is the fallback before
    /// the model-bundle default, matching the in-app Chat and plugin-host
    /// surfaces. A `nil` result means "no explicit value" — the engine then
    /// applies the bundle default.
    @MainActor
    static func resolveAgentSampling(
        request: ChatCompletionRequest,
        agentId: UUID
    ) -> (temperature: Float?, maxTokens: Int?) {
        let manager = AgentManager.shared
        return (
            request.temperature ?? manager.effectiveTemperature(for: agentId),
            request.resolvedMaxTokens ?? manager.effectiveMaxTokens(for: agentId)
        )
    }

    private static func mergeAgentContextTools(
        _ agentTools: [Tool],
        clientTools: [Tool]?
    ) async -> [Tool]? {
        let clientTools = clientTools ?? []
        guard !agentTools.isEmpty || !clientTools.isEmpty else { return nil }
        let clientNames = Set(clientTools.map(\.function.name))
        let contextTools = agentTools.filter { !clientNames.contains($0.function.name) }
        // Sort the union into canonical order so appended client tools don't
        // sit at the tail in a different slot than the next recompose would
        // place them — keeps the `<tools>` block byte-stable for KV reuse.
        return await SystemPromptComposer.canonicalToolOrder(contextTools + clientTools)
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

        // Memory writes against the Default agent must not be reachable from HTTP.
        // The in-app Chat is the only sanctioned writer for the Default agent.
        if let agentUUID = UUID(uuidString: req.agent_id),
            let rejection = Agent.rejectBuiltInForExternalSurface(
                agentUUID,
                source: "http/memory/ingest"
            )
        {
            let bodyJSON = #"{"error":"\#(rejection.code)","message":"\#(rejection.message)"}"#
            sendResponse(
                context: context,
                version: head.version,
                status: .forbidden,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: bodyJSON
            )
            logRequest(
                method: "POST",
                path: "/memory/ingest",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 403,
                startTime: startTime,
                errorMessage: rejection.message
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

        runRequestTask(priority: .userInitiated) {
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

            // I3 — agent-id canonicalization. Recall and the per-agent
            // vector index key off Swift's (uppercase) `UUID.uuidString`, so
            // a lowercase UUID ingested verbatim would write where recall
            // never reads. Canonicalize a valid UUID to its uppercase form;
            // pass non-UUID ids through unchanged.
            let canonicalAgentId = UUID(uuidString: req.agent_id)?.uuidString ?? req.agent_id

            do {
                try db.deleteTranscriptForConversation(req.conversation_id)

                // I1 — idempotency. `episodes` has no `UNIQUE(conversation_id)`,
                // so re-ingesting the same conversation (e.g. re-running a
                // LoCoMo session) would otherwise stack duplicate episodes and
                // pending signals. Clearing both first makes a re-ingest fully
                // replace the conversation's prior memory state. Only when we
                // actually run the extraction pipeline — `skip_extraction`
                // callers explicitly want transcript-only storage untouched.
                if !skipExtraction {
                    try db.deletePendingSignalsForConversation(req.conversation_id)
                    try db.deleteEpisodesForConversation(req.conversation_id)
                }

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
                            agentId: canonicalAgentId
                        )
                        try db.insertTranscriptTurn(
                            agentId: canonicalAgentId,
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
                            agentId: canonicalAgentId,
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
            // bulk imports) don't have to wait for the debounce. We now
            // *await* the outcome (forcing an on-demand cold load if the core
            // model isn't resident) and report it, instead of the old
            // fire-and-forget `flushSession` that returned `{"status":"ok"}`
            // even when the residency gate silently skipped distillation
            // entirely (issue #1632). The response is only written after the
            // distill resolves; cold loads can take tens of seconds, so the
            // benchmark client allows a long (300s) timeout.
            var distillation: DistillOutcome? = nil
            if !skipExtraction {
                distillation = await MemoryService.shared.flushSessionAndWait(
                    agentId: canonicalAgentId,
                    conversationId: req.conversation_id,
                    sessionDate: req.session_date
                )
            }

            // Build via JSONSerialization so the distillation detail string
            // (which can carry an arbitrary error message) is always escaped.
            var payload: [String: Any] = [
                "status": "ok",
                "turns_ingested": req.turns.count,
            ]
            if let distillation {
                payload["distillation"] = distillation.apiStatus
                if let episodeId = distillation.episodeId {
                    payload["episode_id"] = episodeId
                }
            }
            let responseBody: String =
                (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? "{\"status\":\"ok\",\"turns_ingested\":\(req.turns.count)}"
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
        /// Mascot avatar identifier (e.g. "green") so paired peers can render
        /// the agent's own avatar instead of a generic monogram. nil = no
        /// mascot (client falls back to the name's initial). User-uploaded
        /// custom images are intentionally not serialized.
        let avatar: String?
        /// The agent's custom Action Bar (chat quick actions) so a connected
        /// peer can surface the agent's own prompt shortcuts in the empty
        /// state. Omitted (nil) when the agent uses the built-in defaults, so
        /// the client falls back to its neutral chat defaults.
        let chat_quick_actions: [AgentQuickAction]?
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
        /// Connector's ephemeral X25519 public key (base64url). When present,
        /// the connector's signature covers `"<nonce>:<encPub>"` and the
        /// minted key is returned HPKE-sealed instead of in cleartext.
        let encPub: String?
    }

    private struct PairResponse: Codable {
        let agentAddress: String
        let apiKey: String
        let isPermanent: Bool
        /// Agent-key signature over the challenge nonce + agent address so the
        /// connector can verify the responder controls the discovered agent
        /// address (anti-spoofing) and that this response is fresh.
        let serverSignature: String?
        /// HPKE-sealed access key (set when the request carried `encPub`;
        /// `apiKey` is empty in that case so the credential never crosses the
        /// cleartext LAN hop unprotected).
        let sealedApiKey: PairingKeyEnvelope.Sealed?
        /// Secure Channel capability marker: this server requires E2E
        /// encryption for agent run/dispatch and accepts `/secure/session`
        /// handshakes. Diagnostic only.
        let secureChannel: Bool
    }

    /// GET /pair/challenge — issue a single-use, short-lived pairing nonce.
    /// The connector signs this nonce and presents it to `POST /pair`, so a
    /// replayed pairing body is rejected (the nonce is consumed on first use).
    private func handlePairChallengeEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        guard PairingRateLimiter.shared.allow(ip: remoteIP(context)) else {
            sendPairingRateLimited(
                head: head,
                context: context,
                path: "/pair/challenge",
                method: "GET",
                startTime: startTime,
                userAgent: userAgent
            )
            return
        }
        let nonce = PairingChallengeStore.shared.issue()
        var headers = [("Content-Type", "application/json; charset=utf-8")]
        headers.append(contentsOf: stateRef.value.corsHeaders)
        let body = #"{"nonce":"\#(nonce)"}"#
        sendResponse(
            context: context,
            version: head.version,
            status: .ok,
            headers: headers,
            body: body
        )
        logRequest(
            method: "GET",
            path: "/pair/challenge",
            userAgent: userAgent,
            requestBody: nil,
            responseBody: body,
            responseStatus: 200,
            startTime: startTime
        )
    }

    // MARK: - Secure Channel (E2E encryption)

    /// POST /secure/session — Secure Channel handshake. Unauthenticated by
    /// design (it grants nothing: requests still need a valid Bearer inside
    /// the encrypted envelope) but rate-limited like the pairing endpoints.
    /// Signs the transcript with the target agent's key so the client can
    /// verify it is talking to the agent address it pinned at pairing.
    private func handleSecureSessionEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        guard PairingRateLimiter.shared.allow(ip: remoteIP(context)) else {
            sendPairingRateLimited(
                head: head,
                context: context,
                path: "/secure/session",
                method: "POST",
                startTime: startTime,
                userAgent: userAgent
            )
            return
        }

        let data: Data
        if let body = stateRef.value.requestBodyBuffer {
            var bodyCopy = body
            data = Data(bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? [])
        } else {
            data = Data()
        }

        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let logStartTime = startTime
        let logUserAgent = userAgent

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
                    path: "/secure/session",
                    userAgent: logUserAgent,
                    requestBody: nil,
                    responseBody: code == 200 ? "<server-hello>" : body,
                    responseStatus: code,
                    startTime: logStartTime
                )
            }
        }

        guard let hello = try? JSONDecoder().decode(SecureChannel.ClientHello.self, from: data) else {
            reply(status: .badRequest, body: #"{"error":"Invalid handshake request"}"#, code: 400)
            return
        }
        guard hello.v == SecureChannel.version else {
            reply(
                status: .badRequest,
                body: #"{"error":"Unsupported secure channel version"}"#,
                code: 400
            )
            return
        }

        runRequestTask(priority: .userInitiated) {
            // Resolve the agent the client expects to talk to. Any agent with
            // a derived identity can hold sessions; access control happens on
            // the inner request's Bearer, not here.
            let wanted = hello.agentAddress.lowercased()
            let agents = await MainActor.run { AgentManager.shared.agents }
            guard
                let agent = agents.first(where: { $0.agentAddress?.lowercased() == wanted }),
                let agentIndex = agent.agentIndex
            else {
                reply(status: .notFound, body: #"{"error":"Unknown agent address"}"#, code: 404)
                return
            }

            let result: (session: SecureChannelSession, serverHello: SecureChannel.ServerHello)
            do {
                result = try SecureChannel.establishServerSession(hello: hello) { transcript in
                    let signContext = LAContext()
                    signContext.touchIDAuthenticationAllowableReuseDuration = 300
                    signContext.interactionNotAllowed = true
                    var masterKeyData = try MasterKey.getPrivateKey(context: signContext)
                    defer { masterKeyData.zeroOut() }
                    var childKey = AgentKey.derive(masterKey: masterKeyData, index: agentIndex)
                    defer { childKey.zeroOut() }
                    return try signSecureChannelPayload(transcript, privateKey: childKey)
                }
            } catch SecureChannelError.malformedHandshake {
                reply(status: .badRequest, body: #"{"error":"Malformed handshake"}"#, code: 400)
                return
            } catch {
                reply(
                    status: .internalServerError,
                    body: #"{"error":"Failed to establish secure session"}"#,
                    code: 500
                )
                return
            }

            SecureSessionStore.shared.register(result.session)

            let json =
                (try? JSONEncoder.osaurusCanonical().encode(result.serverHello)).map {
                    String(decoding: $0, as: UTF8.self)
                } ?? #"{"error":"Encoding failed"}"#
            reply(status: .ok, body: json, code: 200)
        }
    }

    /// Decrypt a `POST /secure/call` envelope and rewrite it into its inner
    /// request. Returns the rewritten head + normalized path, or `nil` after
    /// sending an error response. Runs synchronously on the event loop —
    /// session lookup and AEAD open are lock-guarded and cheap.
    private func decryptSecureCall(
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) -> (head: HTTPRequestHead, path: String)? {
        let startTime = stateRef.value.requestStartTime
        let userAgent = head.headers.first(name: "User-Agent")

        func reject(status: HTTPResponseStatus, code: String, message: String) {
            var headers = [("Content-Type", "application/json; charset=utf-8")]
            headers.append(contentsOf: stateRef.value.corsHeaders)
            let body = #"{"error":{"code":"\#(code)","message":"\#(message)","type":"secure_channel_error"}}"#
            sendResponse(context: context, version: head.version, status: status, headers: headers, body: body)
            logRequest(
                method: "POST",
                path: "/secure/call",
                userAgent: userAgent,
                requestBody: nil,
                responseBody: body,
                responseStatus: Int(status.code),
                startTime: startTime
            )
        }

        guard let encryptor = responseEncryptor else {
            reject(
                status: .internalServerError,
                code: "secure_channel_unavailable",
                message: "Secure channel is not available on this server"
            )
            return nil
        }

        let data: Data
        if let body = stateRef.value.requestBodyBuffer {
            var bodyCopy = body
            data = Data(bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? [])
        } else {
            data = Data()
        }

        guard let call = try? JSONDecoder().decode(SecureChannel.CallRequest.self, from: data) else {
            reject(status: .badRequest, code: "secure_malformed", message: "Malformed secure call")
            return nil
        }
        guard let session = SecureSessionStore.shared.session(for: call.sid) else {
            // Distinct code so clients know to re-handshake rather than retry.
            reject(
                status: .unauthorized,
                code: "secure_session_unknown",
                message: "Unknown or expired secure session"
            )
            return nil
        }

        let plaintext: Data
        let requestSeq: UInt64
        do {
            (plaintext, requestSeq) = try session.openCall(call)
        } catch SecureChannelError.replayedFrame {
            reject(status: .conflict, code: "secure_replay", message: "Replayed secure call rejected")
            return nil
        } catch SecureChannelError.sessionExpired {
            reject(
                status: .unauthorized,
                code: "secure_session_unknown",
                message: "Unknown or expired secure session"
            )
            return nil
        } catch {
            reject(status: .badRequest, code: "secure_decrypt_failed", message: "Decryption failed")
            return nil
        }

        guard let inner = try? JSONDecoder().decode(SecureChannel.InnerRequest.self, from: plaintext),
            inner.path.hasPrefix("/"),
            !inner.path.hasPrefix("/secure/")
        else {
            reject(status: .badRequest, code: "secure_malformed", message: "Malformed inner request")
            return nil
        }

        let innerBody = inner.body.flatMap { Data(base64urlEncoded: $0) } ?? Data()

        var newHead = HTTPRequestHead(
            version: head.version,
            method: HTTPMethod(rawValue: inner.method),
            uri: inner.path
        )
        var headers = HTTPHeaders()
        // Extra inner headers first, so the controlled transport/security
        // headers below always win. The relay-origin marker, Host, and
        // Content-Length are never inner-controllable: an encrypted caller
        // must not be able to suppress the relay marker (loopback-trust
        // escalation) or desync body framing.
        let reservedNames: Set<String> = [
            "host", "content-length", "connection", "authorization", "accept", "content-type",
            HTTPHandler.relayOriginHeaderName.lowercased(),
        ]
        for (name, value) in inner.headers ?? [:] where !reservedNames.contains(name.lowercased()) {
            headers.add(name: name, value: value)
        }
        if let host = head.headers.first(name: "Host") {
            headers.add(name: "Host", value: host)
        }
        // Preserve the relay-origin marker so downstream header re-reads stay
        // consistent with `state.isRelayOrigin` (set at `.head`).
        if head.headers.first(name: HTTPHandler.relayOriginHeaderName) != nil {
            headers.add(name: HTTPHandler.relayOriginHeaderName, value: "1")
        }
        if let userAgent, headers.first(name: "User-Agent") == nil {
            headers.add(name: "User-Agent", value: userAgent)
        }
        if let authorization = inner.authorization {
            headers.add(name: "Authorization", value: authorization)
        }
        if let accept = inner.accept { headers.add(name: "Accept", value: accept) }
        if let contentType = inner.contentType {
            headers.add(name: "Content-Type", value: contentType)
        }
        headers.add(name: "Content-Length", value: String(innerBody.count))
        newHead.headers = headers

        var bodyBuffer = context.channel.allocator.buffer(capacity: innerBody.count)
        bodyBuffer.writeBytes(innerBody)
        stateRef.value.requestBodyBuffer = bodyBuffer

        // From here on, everything the route writes is sealed for this call.
        encryptor.arm(sealer: session.makeResponseSealer(requestSeq: requestSeq))

        return (newHead, normalize(extractPath(from: inner.path)))
    }

    /// Hard-require gate for `/agents/{id}/run` and `/agents/{id}/dispatch`:
    /// any non-loopback caller (including relay-origin traffic) must arrive
    /// through the Secure Channel. Sends `426 Upgrade Required` and returns
    /// `true` when the request must be rejected. Loopback callers (CLI, App
    /// Intents) stay plaintext; there is deliberately no downgrade path for
    /// remote peers.
    private func sendSecureChannelUpgradeRequiredIfNeeded(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        path: String,
        startTime: Date,
        userAgent: String?
    ) -> Bool {
        if stateRef.value.isSecureChannel { return false }
        if isLoopbackConnection(context) { return false }

        var headers = [("Content-Type", "application/json; charset=utf-8")]
        headers.append(contentsOf: stateRef.value.corsHeaders)
        let body =
            #"{"error":{"code":"secure_channel_required","message":"This peer requires end-to-end encryption for agent requests. Upgrade Osaurus to a version that supports the secure channel.","type":"upgrade_required"}}"#
        sendResponse(
            context: context,
            version: head.version,
            status: .upgradeRequired,
            headers: headers,
            body: body
        )
        logRequest(
            method: head.method.rawValue,
            path: path,
            userAgent: userAgent,
            requestBody: nil,
            responseBody: body,
            responseStatus: 426,
            startTime: startTime
        )
        return true
    }

    /// Emit a 429 for a rate-limited pairing request.
    private func sendPairingRateLimited(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        path: String,
        method: String,
        startTime: Date,
        userAgent: String?
    ) {
        var headers = [("Content-Type", "application/json; charset=utf-8")]
        headers.append(contentsOf: stateRef.value.corsHeaders)
        let body = #"{"error":"Too many pairing attempts. Try again shortly."}"#
        sendResponse(
            context: context,
            version: head.version,
            status: .tooManyRequests,
            headers: headers,
            body: body
        )
        logRequest(
            method: method,
            path: path,
            userAgent: userAgent,
            requestBody: nil,
            responseBody: body,
            responseStatus: 429,
            startTime: startTime
        )
    }

    /// POST /pair — unauthenticated endpoint for cryptographic Bonjour pairing.
    private func handlePairEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let pairingIP = remoteIP(context)
        guard PairingRateLimiter.shared.allow(ip: pairingIP) else {
            sendPairingRateLimited(
                head: head,
                context: context,
                path: "/pair",
                method: "POST",
                startTime: startTime,
                userAgent: userAgent
            )
            return
        }
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

        // Shared error-reply shape (mirrors `handlePairInviteEndpoint`).
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
                    path: "/pair",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: body,
                    responseStatus: code,
                    startTime: logStartTime
                )
            }
        }

        runRequestTask(priority: .userInitiated) {
            // 1. Verify the connector's signature over the nonce. When the
            //    connector supplied an ephemeral encryption key, the signature
            //    covers it too, so a MITM cannot swap in their own key without
            //    also changing the connector address shown in the approval
            //    prompt.
            let signedPayload: Data
            if let encPub = req.encPub, !encPub.isEmpty {
                signedPayload = Data("\(req.nonce):\(encPub)".utf8)
            } else {
                signedPayload = Data(req.nonce.utf8)
            }
            let hexSig = req.signature.hasPrefix("0x") ? String(req.signature.dropFirst(2)) : req.signature
            guard let sigBytes = Data(hexEncoded: hexSig),
                let recovered = try? recoverAddress(
                    payload: signedPayload,
                    signature: sigBytes,
                    domainPrefix: "Osaurus Signed Pairing"
                ),
                recovered == req.connectorAddress
            else {
                reply(status: .unauthorized, body: #"{"error":"Signature verification failed"}"#, code: 401)
                return
            }

            // 1b. Consume the server-issued challenge nonce. The connector must
            //     have fetched it from `GET /pair/challenge`; a sniffed/replayed
            //     `/pair` body fails here because the nonce is single-use and
            //     short-lived. Done after the (cheap) signature check so an
            //     attacker with a bad signature can't burn a valid nonce.
            guard PairingChallengeStore.shared.consume(req.nonce) else {
                reply(
                    status: .unauthorized,
                    body: #"{"error":"Pairing challenge expired or invalid"}"#,
                    code: 401
                )
                return
            }

            // 2. Resolve the target agent.
            let agents = await MainActor.run { AgentManager.shared.agents }
            guard let agentUUID = UUID(uuidString: req.agentId),
                let agent = agents.first(where: { $0.id == agentUUID && $0.bonjourEnabled }),
                let agentAddress = agent.agentAddress
            else {
                reply(
                    status: .notFound,
                    body: #"{"error":"Agent not found or not available for pairing"}"#,
                    code: 404
                )
                return
            }

            // 3. Show the approval popup on the advertiser's device.
            let approval = await PairingPromptService.requestApproval(
                connectorAddress: req.connectorAddress,
                agentName: agent.name
            )

            let isPermanent: Bool
            switch approval {
            case .approved(let permanent):
                isPermanent = permanent
            case .busy:
                // Another approval prompt is already on screen. Tell the
                // connector to retry instead of denying or queueing.
                reply(
                    status: .tooManyRequests,
                    body: #"{"error":"Another pairing request is in progress. Try again shortly."}"#,
                    code: 429
                )
                return
            case .denied:
                // Back off a peer whose request was explicitly denied.
                PairingRateLimiter.shared.penalize(ip: pairingIP)
                reply(status: .forbidden, body: #"{"error":"Pairing denied"}"#, code: 403)
                return
            }

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
                reply(
                    status: .internalServerError,
                    body: #"{"error":"Agent is missing a derived key index"}"#,
                    code: 500
                )
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
                reply(
                    status: .internalServerError,
                    body: #"{"error":"Failed to generate access key"}"#,
                    code: 500
                )
                return
            }

            // Temporary keys are revoked and removed from the key list on app exit.
            if !isPermanent {
                TemporaryPairedKeyStore.shared.register(keyId: keyInfo.id)
            }

            // 4b. Sign a server-identity attestation over the challenge nonce
            //     so the connector can prove this responder controls the
            //     agent address it discovered over Bonjour. Reuses the master
            //     key in the same biometric reuse window opened by the mint
            //     above, so no second prompt is shown.
            let serverSignature: String? = {
                let attestContext = LAContext()
                attestContext.touchIDAuthenticationAllowableReuseDuration = 300
                attestContext.interactionNotAllowed = true
                guard var masterKeyData = try? MasterKey.getPrivateKey(context: attestContext) else {
                    return nil
                }
                defer { masterKeyData.zeroOut() }
                var childKey = AgentKey.derive(masterKey: masterKeyData, index: agentIndex)
                defer { childKey.zeroOut() }
                let payload = pairingServerSigningPayload(agentAddress: agentAddress, nonce: req.nonce)
                guard let sig = try? signPairingServerPayload(payload, privateKey: childKey) else {
                    return nil
                }
                return "0x" + sig.hexEncodedString
            }()

            // 4c. When the connector provided an ephemeral encryption key,
            //     HPKE-seal the minted credential so it never crosses the
            //     cleartext LAN hop in plaintext. Fail closed: if sealing
            //     fails we do NOT fall back to plaintext.
            var sealedApiKey: PairingKeyEnvelope.Sealed?
            var apiKeyForWire = fullKey
            if let encPub = req.encPub, !encPub.isEmpty {
                guard
                    let sealed = try? PairingKeyEnvelope.seal(
                        secret: fullKey,
                        recipientPublicKeyBase64url: encPub,
                        info: PairingKeyEnvelope.info(agentAddress: agentAddress, nonce: req.nonce)
                    )
                else {
                    APIKeyManager.shared.revoke(id: keyInfo.id)
                    reply(status: .badRequest, body: #"{"error":"Invalid encryption key"}"#, code: 400)
                    return
                }
                sealedApiKey = sealed
                apiKeyForWire = ""
            }

            // 5. Return the agent's address, the generated API key, and the permanence flag.
            let response = PairResponse(
                agentAddress: agentAddress,
                apiKey: apiKeyForWire,
                isPermanent: isPermanent,
                serverSignature: serverSignature,
                sealedApiKey: sealedApiKey,
                secureChannel: true
            )
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
                isPermanent: isPermanent,
                serverSignature: serverSignature,
                sealedApiKey: nil,
                secureChannel: true
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
        /// HPKE-sealed access key (set when the redeeming client supplied an
        /// `encPub`; `apiKey` is empty in that case so the relay operator —
        /// who terminates TLS — never sees the credential in plaintext).
        let sealedApiKey: PairingKeyEnvelope.Sealed?
        /// Secure Channel capability marker (see `PairResponse.secureChannel`).
        let secureChannel: Bool
    }

    /// Optional extras the redeeming client may add alongside the exact
    /// invite JSON. Decoded separately so the invite signature check keeps
    /// operating on the canonical `AgentInvite` fields.
    private struct PairInviteRequestExtras: Decodable {
        let encPub: String?
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
        let encPub = (try? JSONDecoder().decode(PairInviteRequestExtras.self, from: data))?.encPub
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

        runRequestTask(priority: .userInitiated) {
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

                // HPKE-seal the credential when the redeemer supplied an
                // ephemeral key so the relay operator (TLS terminates at the
                // relay) never sees it in plaintext. Fail closed: a present
                // but unusable encPub aborts rather than downgrading.
                var sealedApiKey: PairingKeyEnvelope.Sealed?
                var apiKeyForWire = fullKey
                if let encPub, !encPub.isEmpty {
                    guard
                        let sealed = try? PairingKeyEnvelope.seal(
                            secret: fullKey,
                            recipientPublicKeyBase64url: encPub,
                            info: PairingKeyEnvelope.info(
                                agentAddress: agentAddress,
                                nonce: invite.nonce
                            )
                        )
                    else {
                        APIKeyManager.shared.revoke(id: keyInfo.id)
                        await MainActor.run {
                            AgentInviteStore.rollbackConsume(nonce: invite.nonce, for: agent.id)
                        }
                        reply(status: .badRequest, body: #"{"error":"Invalid encryption key"}"#, code: 400)
                        return
                    }
                    sealedApiKey = sealed
                    apiKeyForWire = ""
                }

                func responseBody(apiKey: String, sealed: PairingKeyEnvelope.Sealed?) -> String {
                    let body = PairInviteResponse(
                        agentAddress: agentAddress,
                        agentName: agent.name,
                        agentDescription: agent.description.isEmpty ? nil : agent.description,
                        relayBaseURL: invite.url,
                        apiKey: apiKey,
                        sealedApiKey: sealed,
                        secureChannel: true
                    )
                    return (try? JSONEncoder.osaurusCanonical().encode(body))
                        .map { String(decoding: $0, as: UTF8.self) }
                        ?? #"{"error":"Encoding failed"}"#
                }

                let json = responseBody(apiKey: apiKeyForWire, sealed: sealedApiKey)
                // Redacted twin for the request log — the ring buffer powers
                // the in-app diagnostics panel and must never echo the key.
                let redactedJson = responseBody(apiKey: "<redacted>", sealed: nil)
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

        runRequestTask(priority: .userInitiated) {
            // Built-in agents (the Default agent) live only in-app; the
            // listing endpoint must not advertise them so external clients
            // can never even attempt to address them.
            let agents = await MainActor.run {
                AgentManager.shared.agents.filter { !$0.isBuiltIn }
            }

            let db = MemoryDatabase.shared
            // `memory_entry_count` reflects *stored memory* — distilled
            // episodes plus active pinned facts — not just pinned facts.
            // Counting only pinned facts read 0 for an agent whose sessions
            // distilled into episodes but produced no pinned candidates
            // (issue #1632 U3: "memory_entry_count stays 0").
            var memoryCounts: [String: Int] = [:]
            if db.isOpen {
                if let pinned = try? db.agentIdsWithPinnedFacts() {
                    for (agentId, count) in pinned { memoryCounts[agentId, default: 0] += count }
                }
                if let episodes = try? db.agentIdsWithEpisodes() {
                    for (agentId, count) in episodes { memoryCounts[agentId, default: 0] += count }
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
                    avatar: agent.avatar,
                    chat_quick_actions: agent.chatQuickActions,
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

        // Extract agent ID: /agents/{id}. Resolve the path id as a UUID or a
        // crypto address (the stable identity a paired remote peer knows),
        // mirroring /agents/{id}/run so remote model discovery resolves the
        // agent instead of falling back to ["default"].
        let components = path.split(separator: "/")
        let resolvedAgentId: UUID? =
            components.count == 2
            ? (UUID(uuidString: String(components[1]))
                ?? AgentIdentityRegistry.shared.agentId(forAddress: String(components[1])))
            : nil
        guard components.count == 2, components[0] == "agents", let agentId = resolvedAgentId
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

        // Confine agent-scoped keys to their own agent: a key minted by
        // `/pair` / `/pair-invite` for agent A must not read another agent's
        // metadata (name, description, effective_model). Mirrors the
        // `/agents/{id}/run` scope gate. Loopback callers (authedAudience ==
        // nil) and master-scoped keys are unaffected. Read `stateRef` here on
        // the event loop, before the detached `runRequestTask`.
        if let rejection = agentScopeRejection(forAgentId: agentId) {
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(
                    context: ctx.value,
                    version: head.version,
                    status: .forbidden,
                    headers: headers,
                    body: #"{"error":"\#(rejection.code)","message":"\#(rejection.message)"}"#
                )
            }
            return
        }

        runRequestTask(priority: .userInitiated) {
            // Built-in agents are not exposed via HTTP — return 404 (not 403)
            // so external clients learn the id is unreachable but cannot
            // distinguish "no such agent" from "you are not allowed to see
            // this one". This matches the listing endpoint's filter behavior.
            guard let agent = await MainActor.run(body: { AgentManager.shared.agent(for: agentId) }),
                !agent.isBuiltIn
            else {
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
            // Same stored-memory count as the `/agents` listing (episodes +
            // pinned facts) instead of the pre-fix hardcoded 0 (issue #1632 U3).
            let memoryEntryCount: Int = {
                let db = MemoryDatabase.shared
                guard db.isOpen else { return 0 }
                let episodes = (try? db.episodeCount(agentId: agent.id.uuidString)) ?? 0
                let pinned = (try? db.pinnedFactCount(agentId: agent.id.uuidString)) ?? 0
                return episodes + pinned
            }()
            let item = AgentListItem(
                id: agent.id.uuidString,
                name: agent.name,
                description: agent.description,
                avatar: agent.avatar,
                chat_quick_actions: agent.chatQuickActions,
                default_model: agent.defaultModel,
                effective_model: effectiveModelId,
                supports_thinking: supportsThinking,
                supports_vision: supportsVision,
                is_built_in: agent.isBuiltIn,
                memory_entry_count: memoryEntryCount,
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

    /// Resolve a per-agent host workspace folder (`Agent.hostWorkspaceBookmark`)
    /// into a live `FolderContext` and begin security-scoped access. Returns
    /// nil when the agent has no folder configured, the bookmark is
    /// stale/unresolvable (folder moved or deleted), or access can't be
    /// started. A non-nil result means the caller now HOLDS security-scoped
    /// access and MUST balance it with `stopAccessingSecurityScopedResource()`
    /// on the returned URL once the run finishes.
    private static func resolveAgentHostFolder(
        agentId: UUID
    ) async -> (url: URL, context: FolderContext)? {
        let bookmark = await MainActor.run {
            AgentManager.shared.agent(for: agentId)?.hostWorkspaceBookmark
        }
        guard let bookmark,
            let url = FolderContextService.resolveSecurityScopedURL(from: bookmark),
            url.startAccessingSecurityScopedResource()
        else { return nil }
        let context = await FolderContextService.shared.buildContext(from: url)
        return (url, context)
    }

    /// Make a `/agents/{id}/run` body decodable when the caller omitted the
    /// `model` key. Mode 2 callers intentionally do not send a model (the agent
    /// runs its own effective model server-side), but the shared
    /// `ChatCompletionRequest` decoder requires `model`. Inject an empty string
    /// so decode succeeds; the run handler resolves empty/"default" → the
    /// agent's effective model. Returns the original bytes unchanged when the
    /// body isn't a JSON object or already carries a non-null `model`.
    static func injectingEmptyModelIfMissing(_ data: Data) -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        guard obj["model"] == nil || obj["model"] is NSNull else { return data }
        obj["model"] = ""
        guard let patched = try? JSONSerialization.data(withJSONObject: obj) else { return data }
        return patched
    }

    /// POST /agents/{id}/run — run the full agent chat loop server-side.
    ///
    /// Accepts a `ChatCompletionRequest` body. Runs inference with the agent's
    /// system prompt and executes any tool calls locally on the server, looping
    /// until the model produces a final text response. Streams SSE text deltas
    /// back to the caller — tool invocations are never forwarded to the client.
    /// When the agent has a host workspace folder configured and the caller is
    /// an authenticated remote (Secure Channel, agent-scoped), the run also
    /// gets host file tools (`file_read`/`file_write`/`file_edit`) confined to
    /// that folder.
    private func handleAgentRunEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        path: String,
        startTime: Date,
        userAgent: String?
    ) {
        // Hard-require end-to-end encryption for remote agent runs: a
        // non-loopback plaintext request (including relay-origin traffic)
        // must come back through the Secure Channel. No downgrade path.
        if sendSecureChannelUpgradeRequiredIfNeeded(
            head: head,
            context: context,
            path: path,
            startTime: startTime,
            userAgent: userAgent
        ) {
            return
        }

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

        // `/agents/{id}/run` does NOT require a `model`: a Mode 2 caller omits
        // it on purpose because the agent runs its own effective model
        // server-side. The shared `ChatCompletionRequest` decoder requires
        // `model`, so inject an empty value when the caller omitted it; the
        // resolver below maps empty/"default" → the agent's effective model.
        let runDecodeData = Self.injectingEmptyModelIfMissing(data)
        guard let req = try? JSONDecoder().decode(ChatCompletionRequest.self, from: runDecodeData) else {
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

        // Extract agent identifier: /agents/{id}/run. Accept the local-friendly
        // "default" alias for clients that don't know the built-in UUID yet, a
        // real agent UUID (loopback / local callers), or a crypto address
        // (0x...) — the stable identity a paired remote peer knows and the
        // Secure Channel pins. Mirrors /agents/{id}/dispatch so remote peers can
        // address an agent without learning its host-local UUID. Remote
        // built-in access is still rejected by the guard below.
        let pathComponents = path.split(separator: "/")
        let agentPathIdentifier = pathComponents.count >= 2 ? String(pathComponents[1]) : ""
        let agentId: UUID?
        if agentPathIdentifier.lowercased() == "default" {
            agentId = Agent.defaultId
        } else if let uuid = UUID(uuidString: agentPathIdentifier) {
            agentId = uuid
        } else {
            agentId = AgentIdentityRegistry.shared.agentId(forAddress: agentPathIdentifier)
        }
        guard pathComponents.count >= 2, let agentId else {
            sendResponse(
                context: context,
                version: head.version,
                status: .badRequest,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: #"{"error":"invalid_agent_id","message":"Invalid agent UUID in path"}"#
            )
            return
        }

        // Built-in agents (the Default agent) are not reachable from any
        // remote surface — they exist only inside the in-app Chat. Reject
        // before any enrichment so secrets / system prompts / memory writes
        // for built-ins are unreachable from remote HTTP.
        //
        // Loopback callers are trusted (same machine, no auth) and are allowed
        // to reach the built-in agent so the App Intents "Ask Osaurus" surface
        // can drive the in-app default agent. This exposes the built-in agent's
        // persona/memory/tools to any localhost process, which is acceptable
        // under the existing no-auth-loopback model.
        if !isLoopbackConnection(context),
            let rejection = Agent.rejectBuiltInForExternalSurface(agentId, source: "http/agents/run")
        {
            sendResponse(
                context: context,
                version: head.version,
                status: .forbidden,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body:
                    #"{"error":"\#(rejection.code)","message":"\#(rejection.message)"}"#
            )
            logRequest(
                method: "POST",
                path: path,
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 403,
                startTime: startTime,
                errorMessage: rejection.message
            )
            return
        }

        // Confine agent-scoped keys (e.g. minted by `/pair` or `/pair-invite`)
        // to their own agent so one paired peer cannot drive every agent.
        if let rejection = agentScopeRejection(forAgentId: agentId) {
            sendResponse(
                context: context,
                version: head.version,
                status: .forbidden,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: #"{"error":"\#(rejection.code)","message":"\#(rejection.message)"}"#
            )
            logRequest(
                method: "POST",
                path: path,
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 403,
                startTime: startTime,
                errorMessage: rejection.message
            )
            return
        }

        guard
            let admissionToken = acquireInferenceAdmissionOrReject(
                context: context,
                version: head.version,
                flavor: .openai(type: "server_overloaded"),
                path: path,
                method: "POST",
                userAgent: userAgent,
                requestBody: requestBodyString,
                startTime: startTime
            )
        else { return }

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
        // Agent runs need visible tool progress during prefill/tool waits. The
        // emitted chunk is sanitized: phase, tool name, call id, error state,
        // and end-run status only; raw tool arguments/results stay hidden. Every
        // caller that reaches here is either loopback (trusted same machine) or
        // a Secure-Channel-authenticated remote (the non-loopback plaintext path
        // was rejected above), so streaming the sanitized trace is safe in both
        // cases — and it lets a remote observer watch a file being written, not
        // just the final prose.
        let emitAgentToolTrace = true
        // Host file tools are mounted only for an AUTHENTICATED REMOTE caller
        // (Secure Channel, agent-scoped — enforced by the gates above). A
        // loopback caller is unauthenticated under the no-auth-loopback model,
        // so it never receives the host-folder relaxation.
        let isAuthenticatedRemote = !isLoopbackConnection(context)
        // Stable identity of an authenticated remote caller (for the debounced
        // host toast in the run task); nil for loopback callers.
        let peerCallKey: String? = {
            guard isAuthenticatedRemote else { return nil }
            let info = inboundConnectionInfo()
            return info?.accessKeyId ?? info?.audience ?? "peer"
        }()

        hop { writerBound.value.writeHeaders(ctx.value, extraHeaders: cors) }

        // The model name isn't known until after agent resolution, so the
        // close hook reads it from a lock-protected box: a client hangup
        // flips `disconnected` and cancels the resolved model's generation.
        let disconnected = SendableBool(false)
        let cancelModelBox = SendableStringBox()
        context.channel.closeFuture.whenComplete { _ in
            disconnected.value = true
            if let m = cancelModelBox.value {
                Task { await ModelRuntime.shared.cancelGeneration(name: m) }
            }
        }

        runRequestTask(priority: .userInitiated) {
            defer { admissionToken.release() }
            // HTTP inference bypasses the in-app "generating" dot; drive it for
            // the whole run (incl. remote-peer runs). `defer` balances all exits.
            ServerController.signalGenerationStart()
            defer { ServerController.signalGenerationEnd() }
            // Resolve model: a Mode 2 caller omits `model` (decoded as empty),
            // and older clients send the "default" sentinel. Both resolve to
            // the agent's effective model server-side.
            let model: String
            if req.model.isEmpty || req.model == "default" {
                let agentModel = await MainActor.run { AgentManager.shared.effectiveModel(for: agentId) }
                if let agentModel {
                    model = agentModel
                } else {
                    // No configured default model for this agent (e.g. a fresh
                    // install where the user hasn't pinned one). Fall back to the
                    // currently-loaded model rather than the literal "default":
                    // "default" has no ModelInfo, so `resolveContextWindow` would
                    // collapse the window to the tiny chat-config fallback and the
                    // agent's own system prompt + tools would spuriously trip
                    // `.overBudget` (Context window cannot fit … even after
                    // compaction) on even a one-word message. Mirrors how /health
                    // reports the active model.
                    let currentLoaded = await ModelRuntime.shared.cachedModelSummaries()
                        .first(where: { $0.isCurrent })?.name
                    model = currentLoaded ?? req.model
                }
            } else {
                model = req.model
            }
            cancelModelBox.value = model

            // No model on the request and none resolvable for the agent: fail
            // fast with an in-band SSE error (the 200 head is already on the
            // wire) instead of running the loop with an empty model and hitting
            // an opaque downstream routing failure. An empty resolution is the
            // canonical "agent has no model configured" signal. ("default" is
            // left intact — it resolves to the host's local Foundation model.)
            if model.isEmpty {
                let msg =
                    "This agent has no model configured. Set the agent's default model on the host and try again."
                RemoteAgentRunLog.serverError(
                    "run agent=\(agentId.uuidString) FAILED reqModel=\(req.model.isEmpty ? "<omitted>" : req.model) error=no_model_resolved"
                )
                hop {
                    writerBound.value.writeError(msg, context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: path,
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: logStartTime,
                    errorMessage: msg
                )
                return
            }
            RemoteAgentRunLog.server(
                "run start agent=\(agentId.uuidString) model=\(model) reqModel=\(req.model.isEmpty ? "<omitted>" : req.model)"
            )

            // KPI: one agent run initiated via the HTTP endpoint. The
            // per-turn `message_sent` is emitted separately by ChatEngine on
            // the first (user) turn only.
            Task { @MainActor in FeatureTelemetry.agentRun(source: "http_api") }

            // Debounced host toast: a connected peer is driving one of its
            // agents. Loopback callers (`peerCallKey == nil`) never toast.
            if let peerCallKey {
                await MainActor.run {
                    if let agentName = AgentManager.shared.agent(for: agentId)?.name {
                        PeerCallNotifier.shared.notifyAgentRun(peerKey: peerCallKey, agentName: agentName)
                    }
                }
            }

            // Mount the agent's host workspace folder when an authenticated
            // remote caller drives an agent whose owner granted one. Reachable
            // only past the secure-transport + built-in + agent-scope gates, so
            // the caller is paired and confined to THIS agent. When mounted, the
            // run gets host file tools confined to the folder (see the deny-list
            // relaxation gated on `authenticatedHostFolderRoot`); otherwise it
            // falls back to sandbox/none. Loopback callers never mount it.
            let hostFolder: (url: URL, context: FolderContext)? =
                isAuthenticatedRemote
                ? await Self.resolveAgentHostFolder(agentId: agentId)
                : nil
            // Snapshot/restore the process-wide folder-tool registration around
            // the run (mirrors `AgentLoopEvaluator`) so a concurrent in-app
            // folder session is restored afterward, serialized via
            // `HostFolderRunGate` so two host-folder runs can't corrupt the
            // single global registration.
            let priorFolderContext: FolderContext? = await { () -> FolderContext? in
                guard let hostFolder else { return nil }
                await HostFolderRunGate.shared.acquire()
                return await MainActor.run {
                    let prior = FolderToolManager.shared.registeredContext
                    FolderToolManager.shared.registerFolderTools(for: hostFolder.context)
                    return prior
                }
            }()
            let releaseHostFolder: @Sendable () async -> Void = {
                guard let hostFolder else { return }
                await MainActor.run {
                    FolderToolManager.shared.unregisterFolderTools()
                    if let priorFolderContext {
                        FolderToolManager.shared.registerFolderTools(for: priorFolderContext)
                    }
                }
                hostFolder.url.stopAccessingSecurityScopedResource()
                await HostFolderRunGate.shared.release()
            }

            let executionMode: ExecutionMode = await MainActor.run {
                if let hostFolder {
                    // Host-files feature: full host read+write confined to the
                    // granted folder. Prefer plain `.hostFolder` over the
                    // sandbox-combined mode (which makes the host read-only) so
                    // the agent can actually create/edit files as intended.
                    return .hostFolder(hostFolder.context)
                }
                let autonomousEnabled =
                    AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
                return ToolRegistry.shared.resolveExecutionMode(
                    folderContext: nil,
                    autonomousEnabled: autonomousEnabled
                )
            }

            // Enrich with agent context (system prompt + memory) and use the
            // same composer-resolved tool surface for the model request. The
            // endpoint is still stateless — no SessionToolStateStore,
            // preflight LLM, or frozen per-session schema — but `/agents/{id}/run`
            // is an agent surface, so per-agent gates (Default-agent configure
            // tools, DB, scheduling, speak, render_chart, search_memory) must
            // match the rendered prompt. Bare `alwaysLoadedSpecs` remains the
            // contract for strict OpenAI-compatible `/chat/completions`.
            let enrichedReq = await Self.enrichWithAgentContext(
                req,
                agentId: agentId.uuidString,
                executionMode: executionMode
            )
            var messages = enrichedReq.messages
            let tools = enrichedReq.tools ?? []
            let resolvedToolChoice = enrichedReq.tool_choice

            // Honor the agent's configured sampling when the request omits it,
            // matching the in-app Chat and plugin-host surfaces (which apply
            // `effectiveTemperature` / `effectiveMaxTokens`). The request body
            // still wins when present; the agent config is the fallback before
            // the model-bundle default. Resolved once here because the loop's
            // `modelStep` samples from `req`, not the enriched request.
            let (effectiveTemperature, effectiveMaxTokens) = await MainActor.run {
                Self.resolveAgentSampling(request: req, agentId: agentId)
            }

            let configuredMaxToolAttempts = await MainActor.run {
                ChatConfigurationStore.load().maxToolAttempts ?? 30
            }
            let maxIterations = max(1, min(configuredMaxToolAttempts, 120))
            let requestId = UUID().uuidString
            // Per-request harness state. The agent-run endpoint is stateless
            // across requests by design (see the divergence note above), so a
            // per-request instance is correct — there is no prior listing to
            // survive. Provides within-request dedupe + post-listing nudge.
            let taskState = AgentTaskState()

            // KV-cache-aware history compaction: shared window resolution +
            // reservations via `AgentLoopBudget` (parity with the plugin
            // host's budget manager). The leading system message stays
            // byte-stable; only the conversation tail is trimmed.
            let budgetManager: ContextBudgetManager? = await {
                guard maxIterations > 1 else { return nil }
                let contextWindow = await AgentLoopBudget.resolveContextWindow(modelId: model)
                let toolTokens = await MainActor.run {
                    ToolRegistry.shared.totalEstimatedTokens(for: tools)
                }
                let sysChars =
                    messages.first(where: { $0.role == "system" })?.content?.count ?? 0
                return AgentLoopBudget.makeBudgetManager(
                    contextWindow: contextWindow,
                    systemPromptChars: sysChars,
                    toolTokens: toolTokens,
                    maxResponseTokens: effectiveMaxTokens
                )
            }()
            // Request-scoped sticky compaction: trims stay monotonic across
            // the run's iterations so the token prefix is byte-stable for
            // paged-KV reuse.
            let compactionWatermark = CompactionWatermark()

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

            // Per-iteration assistant prose captured by the modelStep hook so
            // the post-batch framing can attach it to the assistant
            // tool_calls message (mirrors the historical loop local).
            var responseContent = ""

            // Host-side Insights enrichment: accumulate the full visible answer
            // and every executed tool so the `/agents/{id}/run` row isn't empty.
            // The loop invokes its hooks serially, so these plain vars are
            // race-free — same capture pattern as `responseContent` above.
            var loggedResponseText = ""
            var loggedToolCalls: [ToolCallLog] = []

            // Set when a successful `complete`/`clarify` intercept ends the
            // run — the post-loop tail streams this text (the parsed summary
            // or clarifying question) so the client sees a final answer
            // instead of a silent stop. Parity with chat's intercepts.
            var interceptText: String?

            // Intercept post-check shared by the single-call fallback and
            // the serial intercept batch path: a successful `complete` /
            // `clarify` flags `endRun` so the driver exits `.endedBySurface`.
            func interceptAware(
                _ inv: ServiceToolInvocation,
                _ execution: AgentLoopToolExecution
            ) -> AgentLoopToolExecution {
                guard
                    AgentToolLoop.isSuccessfulIntercept(
                        toolName: inv.toolName,
                        result: execution.result
                    )
                else { return execution }
                var ended = execution
                ended.endRun = true
                switch inv.toolName {
                case "complete":
                    interceptText =
                        CompleteTool.parseSummary(from: inv.jsonArguments)
                        ?? "Task completed."
                case "clarify":
                    interceptText = ClarifyTool.parse(argumentsJSON: inv.jsonArguments)?.question
                default:
                    break
                }
                return ended
            }

            // Canonical loop skeleton lives in `AgentToolLoop` (slotting mode:
            // dedupe pass + parallel batch execution). These hooks carry the
            // HTTP surface's specifics — SSE forwarding via the writer, the
            // message-array history, and client-disconnect cancellation.
            let hooks = AgentLoopHooks(
                isCancelled: {
                    // Client hung up between iterations — stop the agent loop.
                    // The close hook already cancelled the model's generation.
                    disconnected.value
                },
                buildMessages: { notices in
                    // Canonical notice contract (shared with chat/plugin):
                    // trim with the system prefix kept byte-stable, then
                    // append driver-staged notices TRANSIENTLY — they ride
                    // exactly one iteration and never persist into
                    // `messages`.
                    AgentLoopBudget.composeIterationMessages(
                        messages,
                        notices: notices,
                        manager: budgetManager,
                        watermark: compactionWatermark
                    )
                },
                modelStep: { msgs, _ in
                    // Keep the requested tool_choice (and therefore the rendered
                    // `<tools>` block) byte-stable across every iteration so the
                    // post-tool finalization step extends the calling step's KV
                    // prefix instead of re-prefilling from scratch.
                    var iterationReq = ChatCompletionRequest(
                        model: model,
                        messages: msgs,
                        temperature: effectiveTemperature,
                        max_tokens: effectiveMaxTokens,
                        stream: true,
                        top_p: req.top_p,
                        top_k: req.top_k,
                        min_p: req.min_p,
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
                    // Label the turn agent-driven for `message_sent` telemetry.
                    // Only the first iteration (trailing `user` message) actually
                    // emits; later tool-result iterations are skipped by the
                    // engine's de-dup rule.
                    iterationReq.isAgentRequest = true

                    responseContent = ""
                    var contentCoalescer = Self.StreamDeltaCoalescer(
                        interval: ServerRuntimeSettingsStore.snapshot().generation.streamInterval
                    )

                    do {
                        let stream = try await chatEngine.streamChat(request: iterationReq)
                        if disconnected.value { throw CancellationError() }
                        for try await delta in stream {
                            if disconnected.value { throw CancellationError() }
                            // Reasoning sentinel must be decoded BEFORE the
                            // generic `isSentinel` filter; emit it on the
                            // OpenAI extended `reasoning_content` channel
                            // and do NOT mix it into `responseContent`.
                            if let reasoning = StreamingReasoningHint.decode(delta) {
                                if let pending = contentCoalescer.flush() {
                                    hop {
                                        writerBound.value.writeContent(
                                            pending,
                                            model: model,
                                            responseId: responseId,
                                            created: created,
                                            context: ctx.value
                                        )
                                    }
                                }
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
                            loggedResponseText += delta
                            if let chunk = contentCoalescer.append(delta) {
                                hop {
                                    writerBound.value.writeContent(
                                        chunk,
                                        model: model,
                                        responseId: responseId,
                                        created: created,
                                        context: ctx.value
                                    )
                                }
                            }
                        }
                        if let pending = contentCoalescer.flush() {
                            hop {
                                writerBound.value.writeContent(
                                    pending,
                                    model: model,
                                    responseId: responseId,
                                    created: created,
                                    context: ctx.value
                                )
                            }
                        }
                    } catch let invs as ServiceToolInvocations {
                        // Local models can emit multiple tool calls in a single
                        // completion; ServiceToolInvocations carries the batch.
                        return .toolCalls(invs.invocations)
                    } catch let inv as ServiceToolInvocation {
                        return .toolCalls([inv])
                    }

                    // Empty turn (0-token / EOS-first, no tool call): don't
                    // record a blank assistant message or end the run on
                    // silence — let the driver nudge-and-retry, then fall back.
                    if responseContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .emptyResponse
                    }
                    // Final text response — done
                    messages.append(ChatMessage(role: "assistant", content: responseContent))
                    return .finalResponse
                },
                executeTool: { inv, callId in
                    // Single-call fallback; the batch executor below is the
                    // normal path for this surface. `isExternalSurface`
                    // marks the execution so the registry's external deny
                    // list (folder write/shell tools) applies.
                    let executions = await ChatExecutionContext.$isExternalSurface.withValue(true) {
                        await AgentToolLoop.runBatchInParallel(
                            [(invocation: inv, callId: callId)],
                            sessionId: requestId,
                            agentId: agentId
                        )
                    }
                    let execution =
                        executions.first
                        ?? AgentLoopToolExecution(
                            result: ToolEnvelope.failure(
                                kind: .executionError,
                                message: "Tool batch returned no result.",
                                tool: inv.toolName
                            ),
                            isError: true
                        )
                    return interceptAware(inv, execution)
                },
                executeBatch: { calls in
                    await ChatExecutionContext.$isExternalSurface.withValue(true) {
                        // Serial fallback when the batch carries a loop-ending
                        // intercept (`complete`/`clarify`): execute in model
                        // order and stop at the first `endRun` — running
                        // siblings in parallel would let calls AFTER the
                        // intercept execute and land in history, where the
                        // serial path (chat/eval parity) stops immediately.
                        if AgentToolLoop.containsIntercept(calls) {
                            var executions: [AgentLoopToolExecution] = []
                            for call in calls {
                                if emitAgentToolTrace {
                                    hop {
                                        writerBound.value.writeAgentToolTrace(
                                            phase: "started",
                                            toolName: call.invocation.toolName,
                                            callId: call.callId,
                                            model: model,
                                            responseId: responseId,
                                            created: created,
                                            context: ctx.value
                                        )
                                    }
                                }
                                let single =
                                    await AgentToolLoop.runBatchInParallel(
                                        [(invocation: call.invocation, callId: call.callId)],
                                        sessionId: requestId,
                                        agentId: agentId
                                    ).first ?? AgentLoopToolExecution(result: "")
                                let execution = interceptAware(call.invocation, single)
                                if emitAgentToolTrace {
                                    RemoteAgentRunLog.server(
                                        "tool completed agent=\(agentId.uuidString) name=\(call.invocation.toolName) "
                                            + "callId=\(call.callId) isError=\(execution.isError) endRun=\(execution.endRun)"
                                    )
                                    hop {
                                        writerBound.value.writeAgentToolTrace(
                                            phase: "completed",
                                            toolName: call.invocation.toolName,
                                            callId: call.callId,
                                            isError: execution.isError,
                                            endRun: execution.endRun,
                                            model: model,
                                            responseId: responseId,
                                            created: created,
                                            context: ctx.value
                                        )
                                    }
                                }
                                executions.append(execution)
                                if execution.endRun { break }
                            }
                            return executions
                        }
                        if emitAgentToolTrace {
                            for call in calls {
                                RemoteAgentRunLog.server(
                                    "tool started agent=\(agentId.uuidString) name=\(call.invocation.toolName) callId=\(call.callId)"
                                )
                                hop {
                                    writerBound.value.writeAgentToolTrace(
                                        phase: "started",
                                        toolName: call.invocation.toolName,
                                        callId: call.callId,
                                        model: model,
                                        responseId: responseId,
                                        created: created,
                                        context: ctx.value
                                    )
                                }
                            }
                        }
                        // Two-phase canonical batch: approvals resolve serially
                        // in model order FIRST (no stacked/racing permission
                        // prompts), then the approved set runs in parallel via
                        // a TaskGroup so wall-clock time stays proportional to
                        // the slowest call; results come back in model order.
                        return await AgentToolLoop.runBatchInParallel(
                            calls,
                            sessionId: requestId,
                            agentId: agentId
                        )
                    }
                },
                onBatchComplete: { outcomes in
                    var assistantToolCalls: [ToolCall] = []
                    var toolResultsByCallId: [(String, String)] = []
                    for outcome in outcomes {
                        if emitAgentToolTrace {
                            RemoteAgentRunLog.server(
                                "tool completed agent=\(agentId.uuidString) name=\(outcome.invocation.toolName) "
                                    + "callId=\(outcome.callId) isError=\(outcome.wasError)"
                            )
                            hop {
                                writerBound.value.writeAgentToolTrace(
                                    phase: "completed",
                                    toolName: outcome.invocation.toolName,
                                    callId: outcome.callId,
                                    isError: outcome.wasError,
                                    endRun: false,
                                    model: model,
                                    responseId: responseId,
                                    created: created,
                                    context: ctx.value
                                )
                            }
                        }
                        assistantToolCalls.append(
                            ToolCall(
                                id: outcome.callId,
                                type: "function",
                                function: ToolCallFunction(
                                    name: outcome.invocation.toolName,
                                    arguments: outcome.invocation.jsonArguments
                                )
                            )
                        )
                        toolResultsByCallId.append((outcome.callId, outcome.result))
                        // Host-only: full tool detail (args + result). The peer
                        // still sees only the sanitized SSE trace emitted above.
                        loggedToolCalls.append(
                            ToolCallLog(
                                name: outcome.invocation.toolName,
                                arguments: outcome.invocation.jsonArguments,
                                result: outcome.result,
                                isError: outcome.wasError
                            )
                        )
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
                },
                emitFallbackText: { text in
                    // Empty-turn recovery exhausted: stream a visible fallback
                    // so the client never receives an empty assistant message.
                    if text == AgentToolLoop.emptyToolTaskFallback {
                        messages.append(ChatMessage(role: "assistant", content: text))
                        loggedResponseText += text
                        return
                    }
                    hop {
                        writerBound.value.writeContent(
                            text,
                            model: model,
                            responseId: responseId,
                            created: created,
                            context: ctx.value
                        )
                    }
                    messages.append(ChatMessage(role: "assistant", content: text))
                    loggedResponseText += text
                }
            )

            let exitState: AgentToolLoop.Exit
            do {
                // Bind the host-folder root for the whole loop so the deny-list
                // relaxation (`isDeniedForCurrentSurface`) and the host file
                // tools see it; `nil` when no folder is mounted, leaving the
                // external-surface denial fully intact. Child tasks spawned by
                // the parallel batch executor inherit the task-local.
                let runResult = try await ChatExecutionContext.$authenticatedHostFolderRoot
                    .withValue(hostFolder?.url) {
                        try await AgentToolLoop.run(
                            policy: AgentLoopPolicy(
                                maxIterations: maxIterations,
                                stopOnToolRejection: false,
                                dedupeNoticeEnabled: false,
                                maxDataMovementSteps: min(16, maxIterations)
                            ),
                            state: taskState,
                            hooks: hooks
                        )
                    }
                exitState = runResult.exit
                RemoteAgentRunLog.server(
                    "run loop done agent=\(agentId.uuidString) model=\(model) exit=\(String(describing: exitState))"
                )
            } catch {
                await releaseHostFolder()
                RemoteAgentRunLog.serverError(
                    "run loop FAILED agent=\(agentId.uuidString) model=\(model) error=\(error.localizedDescription)"
                )
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
                    responseBody: loggedResponseText.isEmpty ? nil : loggedResponseText,
                    responseStatus: 200,
                    startTime: logStartTime,
                    toolCalls: loggedToolCalls.isEmpty ? nil : loggedToolCalls,
                    errorMessage: error.localizedDescription
                )
                return
            }
            // Tools have finished executing (the loop is done); release the
            // host folder before streaming the tail so the gate isn't held
            // across the final prose write. Runs exactly once per request —
            // the catch path above returns after its own release.
            await releaseHostFolder()

            // Even fully-compacted history can't fit the window: the
            // driver ended the run before sending a doomed request.
            // Surface the distinct in-band SSE error (the 200 head is
            // already on the wire) instead of a silent stop.
            if exitState == .overBudget {
                hop {
                    writerBound.value.writeError(AgentToolLoop.overBudgetMessage, context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: path,
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: loggedResponseText.isEmpty ? nil : loggedResponseText,
                    responseStatus: 200,
                    startTime: logStartTime,
                    toolCalls: loggedToolCalls.isEmpty ? nil : loggedToolCalls,
                    errorMessage: AgentToolLoop.overBudgetMessage
                )
                return
            }

            if exitState == .emptyResponseExhausted {
                hop {
                    writerBound.value.writeError(AgentToolLoop.emptyToolTaskFallback, context: ctx.value)
                    writerBound.value.writeEnd(ctx.value)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: path,
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: loggedResponseText.isEmpty ? nil : loggedResponseText,
                    responseStatus: 200,
                    startTime: logStartTime,
                    model: model,
                    toolCalls: loggedToolCalls.isEmpty ? nil : loggedToolCalls,
                    errorMessage: AgentToolLoop.emptyToolTaskFallback
                )
                return
            }
            // If we exited via the iteration cap without producing a
            // final text turn (i.e. the last loop body still required
            // tools), stream a synthetic notice so the client sees a
            // reason instead of a silent stop.
            if exitState == .iterationCapReached {
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
                loggedResponseText += notice
            }
            // A successful `complete`/`clarify` intercept ended the run:
            // stream the parsed summary/question as the final content so
            // the stateless client gets the same terminal text a chat user
            // would see in the banner/prompt UI.
            if exitState == .endedBySurface, let text = interceptText, !text.isEmpty {
                hop {
                    writerBound.value.writeContent(
                        text,
                        model: model,
                        responseId: responseId,
                        created: created,
                        context: ctx.value
                    )
                }
                loggedResponseText += text
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
                responseBody: loggedResponseText.isEmpty ? nil : loggedResponseText,
                responseStatus: 200,
                startTime: logStartTime,
                model: model,
                toolCalls: loggedToolCalls.isEmpty ? nil : loggedToolCalls
            )
        }
    }

    // MARK: - Dispatch & Task Endpoints

    nonisolated static func shouldBindExternalSurfaceForDispatch(isLoopback: Bool) -> Bool {
        !isLoopback
    }

    /// POST /agents/{identifier}/dispatch — dispatch work/chat task
    /// The identifier can be an agent UUID or a crypto address (0x...).
    private func handleDispatchEndpoint(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        path: String,
        startTime: Date,
        userAgent: String?
    ) {
        // Same hard-require as `/agents/{id}/run`: remote dispatch must be
        // end-to-end encrypted.
        if sendSecureChannelUpgradeRequiredIfNeeded(
            head: head,
            context: context,
            path: path,
            startTime: startTime,
            userAgent: userAgent
        ) {
            return
        }

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

        // Loopback callers (same machine, no auth) are allowed to dispatch to
        // the built-in agent so App Intents "Run Osaurus Agent" / "Ask Osaurus"
        // can drive it as a detached background task. Remote callers remain
        // blocked from the built-in agent.
        let isLoopback = isLoopbackConnection(context)
        // Capture the validated key's scope on the event loop; the resolution
        // below runs in a detached task that must not touch `stateRef`.
        let authedAudience = stateRef.value.authedAudience
        let authedScopeIsMaster = stateRef.value.authedScopeIsMaster

        runRequestTask(priority: .userInitiated) {
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

            // Confine agent-scoped keys to their own agent (relay/LAN paired
            // peers). Runs off the event loop, so use the captured scope.
            if let rejection = Self.agentScopeRejection(
                forAgentId: agentId,
                authedAudience: authedAudience,
                authedScopeIsMaster: authedScopeIsMaster
            ) {
                let bodyJSON = #"{"error":"\#(rejection.code)","message":"\#(rejection.message)"}"#
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .forbidden,
                        headers: headers,
                        body: bodyJSON
                    )
                    logSelf.logRequest(
                        method: "POST",
                        path: path,
                        userAgent: logUserAgent,
                        requestBody: requestBodyString,
                        responseStatus: 403,
                        startTime: logStartTime,
                        errorMessage: rejection.message
                    )
                }
                return
            }

            if !isLoopback,
                let rejection = Agent.rejectBuiltInForExternalSurface(
                    agentId,
                    source: "http/agents/dispatch"
                )
            {
                let bodyJSON =
                    #"{"error":"\#(rejection.code)","message":"\#(rejection.message)"}"#
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    self.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: .forbidden,
                        headers: headers,
                        body: bodyJSON
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: path,
                    userAgent: logUserAgent,
                    requestBody: requestBodyString,
                    responseStatus: 403,
                    startTime: logStartTime,
                    errorMessage: rejection.message
                )
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
                externalSessionKey: externalSessionKey,
                externalSurface: Self.shouldBindExternalSurfaceForDispatch(isLoopback: isLoopback)
            )

            let handle: DispatchHandle?
            if Self.shouldBindExternalSurfaceForDispatch(isLoopback: isLoopback) {
                handle = await ChatExecutionContext.$isExternalSurface.withValue(true) {
                    await TaskDispatcher.shared.dispatch(request)
                }
            } else {
                handle = await TaskDispatcher.shared.dispatch(request)
            }
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

        runRequestTask(priority: .userInitiated) {
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

        runRequestTask(priority: .userInitiated) {
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

        runRequestTask(priority: .userInitiated) {
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

        runRequestTask(priority: .userInitiated) {
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

    // MARK: - Image generation (/v1/images/*)

    private func requestBodyData() -> (data: Data, string: String?) {
        if let body = stateRef.value.requestBodyBuffer {
            var copy = body
            let bytes = copy.readBytes(length: copy.readableBytes) ?? []
            let data = Data(bytes)
            return (data, String(decoding: data, as: UTF8.self))
        }
        return (Data(), nil)
    }

    private func sendImageError(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        message: String,
        path: String,
        startTime: Date,
        userAgent: String?,
        requestBody: String?
    ) {
        let body = #"{"error":{"message":"\#(Self.jsonEscape(message))","type":"invalid_request_error"}}"#
        var headers = [("Content-Type", "application/json; charset=utf-8")]
        headers.append(contentsOf: stateRef.value.corsHeaders)
        sendResponse(context: context, version: head.version, status: status, headers: headers, body: body)
        logRequest(
            method: "POST",
            path: path,
            userAgent: userAgent,
            requestBody: requestBody,
            responseStatus: Int(status.code),
            startTime: startTime,
            errorMessage: message
        )
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Decode an image input field — a `data:` URI, a `file://` URL, or raw
    /// base64 — into bytes the service can stage for the engine.
    static func decodeImageInput(_ value: String) -> Data? {
        if value.hasPrefix("data:") {
            guard let comma = value.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(value[value.index(after: comma)...]))
        }
        if value.hasPrefix("file://"), let url = URL(string: value) {
            return try? Data(contentsOf: url)
        }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return nil  // remote fetch unsupported for the local image engine
        }
        return Data(base64Encoded: value)
    }

    /// Resolve width/height from explicit fields or an OpenAI-style `WxH` size.
    static func resolveImageSize(size: String?, width: Int?, height: Int?) -> (Int?, Int?) {
        if let width, let height { return (width, height) }
        if let size {
            let parts = size.lowercased().split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                return (w, h)
            }
        }
        return (width, height)
    }

    /// Clamp a caller-supplied image dimension to the same 256–1024 / multiple-of-16
    /// envelope the agent `image` tool enforces
    /// (`NativeImageTools.clampedDimension`). The public REST endpoints previously
    /// passed `width`/`height` through unclamped, so an oversized request could OOM
    /// or trip the GPU watchdog on the exclusive Metal lane.
    static func clampImageDimension(_ value: Int) -> Int {
        let bounded = min(1024, max(256, value))
        let rounded = (bounded / 16) * 16
        return max(256, rounded)
    }

    /// Clamp denoising steps to the advertised 1–50 range (mirrors the agent path).
    static func clampImageSteps(_ value: Int) -> Int { min(50, max(1, value)) }

    private static func imageOutputFormat(_ raw: String?) -> ImageOutputFormat {
        switch raw?.lowercased() {
        case "jpeg", "jpg": return .jpeg
        case "webp": return .webp
        default: return .png
        }
    }

    /// Build the per-image result object honoring `response_format`.
    private static func imageResult(for image: GeneratedImage, responseFormat: String) -> ImageResultDTO {
        if responseFormat == "b64_json", let data = try? Data(contentsOf: image.url) {
            return ImageResultDTO(url: nil, b64_json: data.base64EncodedString(), seed: image.seed)
        }
        return ImageResultDTO(url: image.url.absoluteString, b64_json: nil, seed: image.seed)
    }

    private static func imageErrorStatus(message: String, hfAuth: Bool) -> HTTPResponseStatus {
        if hfAuth { return HTTPResponseStatus(statusCode: 402) }
        let m = message.lowercased()
        if m.contains("not found") { return .notFound }
        if m.contains("incomplete") { return .conflict }
        if m.contains("not implemented") { return .notImplemented }
        if m.contains("invalid request") || m.contains("wrong model kind") { return .badRequest }
        return .internalServerError
    }

    func handleImageModels(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        runRequestTask(priority: .userInitiated) {
            let models: [ImageModelInfo]
            do {
                models = try await ImageGenerationService.shared.availableModels()
            } catch {
                models = []
            }
            let dtos = models.map { m in
                ImageModelDTO(
                    id: m.id,
                    object: "model",
                    display_name: m.displayName,
                    kind: m.kind,
                    ready: m.ready,
                    quantization_bits: m.quantizationBits,
                    capabilities: ImageCapabilitiesDTO(
                        text_to_image: m.capabilities.textToImage,
                        image_edit: m.capabilities.imageEdit,
                        upscale: m.capabilities.upscale,
                        negative_prompt: m.capabilities.negativePrompt,
                        mask: m.capabilities.mask,
                        multiple_source_images: m.capabilities.multipleSourceImages,
                        lora: m.capabilities.lora
                    ),
                    defaults: ImageDefaultsDTO(
                        steps: m.defaultSteps,
                        guidance: m.defaultGuidance.map { Double($0) }
                    ),
                    limits: ImageLimitsDTO(
                        min_steps: 1,
                        max_steps: 50,
                        size_multiple: 16,
                        max_pixels: 1024 * 1024,
                        supported_sizes: ["512x512", "768x768", "1024x1024"]
                    ),
                    blocked_reasons: m.blockedReasons
                )
            }
            let response = ImageModelsResponseDTO(object: "list", data: dtos)
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(response))
                .map { String(decoding: $0, as: UTF8.self) } ?? #"{"object":"list","data":[]}"#
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(context: ctx.value, version: head.version, status: .ok, headers: headers, body: json)
            }
            logSelf.logRequest(
                method: "GET",
                path: "/images/models",
                userAgent: userAgent,
                requestBody: nil,
                responseBody: json,
                responseStatus: 200,
                startTime: startTime
            )
        }
    }

    func handleImageGenerations(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let (data, bodyString) = requestBodyData()
        guard let req = try? JSONDecoder().decode(ImageGenerationRequestDTO.self, from: data) else {
            sendImageError(
                head: head,
                context: context,
                status: .badRequest,
                message: "Invalid request body",
                path: "/images/generations",
                startTime: startTime,
                userAgent: userAgent,
                requestBody: bodyString
            )
            return
        }
        // Resolve the model: explicit request value wins; otherwise fall back to
        // the configured default (Settings → Agent Delegation), matching the
        // agent `image` tool.
        let trimmedModel = req.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let modelId =
                (trimmedModel?.isEmpty == false ? trimmedModel : nil)
                    ?? SubagentConfigurationStore.snapshot().defaultImageGenerationModelId,
            !modelId.isEmpty
        else {
            sendImageError(
                head: head,
                context: context,
                status: .badRequest,
                message:
                    "No image model specified and no default image generation model is configured (Settings → Agent Delegation).",
                path: "/images/generations",
                startTime: startTime,
                userAgent: userAgent,
                requestBody: bodyString
            )
            return
        }
        let (w, h) = Self.resolveImageSize(size: req.size, width: req.width, height: req.height)
        let params = ImageGenerationParameters(
            model: modelId,
            prompt: req.prompt,
            negativePrompt: req.negative_prompt,
            width: w.map(Self.clampImageDimension),
            height: h.map(Self.clampImageDimension),
            steps: req.steps.map(Self.clampImageSteps),
            guidance: req.guidance.map { Float($0) },
            seed: req.seed,
            // Multi-image (`n` > 1) is force-capped to 1: the service generates the
            // N images sequentially in one job WITHOUT a GPU drain between them, which
            // reliably trips the MLX `tryCoalescingPreviousComputeCommandEncoder`
            // assertion (reproduced at n=2). Re-enable once the per-image drain lands
            // in the multi-image loop (see docs/REMAINING_WORK.md).
            numImages: 1,
            outputFormat: Self.imageOutputFormat(req.output_format)
        )
        let jobID = Self.shortId(prefix: "img")
        runImageJob(
            head: head,
            context: context,
            startTime: startTime,
            userAgent: userAgent,
            path: "/images/generations",
            requestBody: bodyString,
            streaming: req.stream ?? false,
            responseFormat: req.response_format ?? "url",
            jobID: jobID
        ) { await ImageGenerationService.shared.generate(params, jobID: jobID) }
    }

    func handleImageEdits(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let (data, bodyString) = requestBodyData()
        guard let req = try? JSONDecoder().decode(ImageEditRequestDTO.self, from: data) else {
            sendImageError(
                head: head,
                context: context,
                status: .badRequest,
                message: "Invalid request body",
                path: "/images/edits",
                startTime: startTime,
                userAgent: userAgent,
                requestBody: bodyString
            )
            return
        }
        // Prefer the ordered `images` list; fall back to the single `image`.
        let rawSources = req.images ?? [req.image].compactMap { $0 }
        let sources = rawSources.compactMap { Self.decodeImageInput($0) }
        guard !sources.isEmpty else {
            sendImageError(
                head: head,
                context: context,
                status: .badRequest,
                message: "edit requires a source image",
                path: "/images/edits",
                startTime: startTime,
                userAgent: userAgent,
                requestBody: bodyString
            )
            return
        }
        // No model exposes a real mask path today — reject masks up front.
        if req.mask != nil {
            sendImageError(
                head: head,
                context: context,
                status: .notImplemented,
                message: "mask editing is not supported by this model",
                path: "/images/edits",
                startTime: startTime,
                userAgent: userAgent,
                requestBody: bodyString
            )
            return
        }
        // Resolve the model: explicit request value wins; otherwise fall back to
        // the configured default edit model (Settings → Agent Delegation),
        // matching the agent `image` tool (edit mode).
        let trimmedEditModel = req.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let editModelId =
                (trimmedEditModel?.isEmpty == false ? trimmedEditModel : nil)
                    ?? SubagentConfigurationStore.snapshot().defaultImageEditModelId,
            !editModelId.isEmpty
        else {
            sendImageError(
                head: head,
                context: context,
                status: .badRequest,
                message:
                    "No image model specified and no default image edit model is configured (Settings → Agent Delegation).",
                path: "/images/edits",
                startTime: startTime,
                userAgent: userAgent,
                requestBody: bodyString
            )
            return
        }
        let (w, h) = Self.resolveImageSize(size: req.size, width: req.width, height: req.height)
        let params = ImageEditParameters(
            model: editModelId,
            prompt: req.prompt,
            sourceImages: sources,
            maskImage: nil,
            negativePrompt: req.negative_prompt,
            strength: req.strength.map { Float($0) } ?? 0.75,
            width: w.map(Self.clampImageDimension),
            height: h.map(Self.clampImageDimension),
            steps: req.steps.map(Self.clampImageSteps),
            guidance: req.guidance.map { Float($0) },
            seed: req.seed,
            outputFormat: Self.imageOutputFormat(req.output_format)
        )
        let jobID = Self.shortId(prefix: "img")
        runImageJob(
            head: head,
            context: context,
            startTime: startTime,
            userAgent: userAgent,
            path: "/images/edits",
            requestBody: bodyString,
            streaming: req.stream ?? false,
            responseFormat: req.response_format ?? "url",
            jobID: jobID
        ) { await ImageGenerationService.shared.edit(params, jobID: jobID) }
    }

    func handleImageUpscale(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let (data, bodyString) = requestBodyData()
        guard let req = try? JSONDecoder().decode(ImageUpscaleRequestDTO.self, from: data),
            let source = Self.decodeImageInput(req.image)
        else {
            sendImageError(
                head: head,
                context: context,
                status: .badRequest,
                message: "Invalid request body",
                path: "/images/upscale",
                startTime: startTime,
                userAgent: userAgent,
                requestBody: bodyString
            )
            return
        }
        let params = ImageUpscaleParameters(
            model: req.model,
            sourceImage: source,
            scale: req.scale ?? 4,
            steps: req.steps,
            seed: req.seed,
            outputFormat: Self.imageOutputFormat(req.output_format)
        )
        let jobID = Self.shortId(prefix: "img")
        runImageJob(
            head: head,
            context: context,
            startTime: startTime,
            userAgent: userAgent,
            path: "/images/upscale",
            requestBody: bodyString,
            streaming: req.stream ?? false,
            responseFormat: req.response_format ?? "url",
            jobID: jobID
        ) { await ImageGenerationService.shared.upscale(params, jobID: jobID) }
    }

    func handleImageCancel(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let (data, bodyString) = requestBodyData()
        guard let req = try? JSONDecoder().decode(ImageCancelRequestDTO.self, from: data) else {
            sendImageError(
                head: head,
                context: context,
                status: .badRequest,
                message: "Invalid request body",
                path: "/images/cancel",
                startTime: startTime,
                userAgent: userAgent,
                requestBody: bodyString
            )
            return
        }
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        runRequestTask(priority: .userInitiated) {
            await ImageGenerationService.shared.cancel(jobID: req.job_id)
            let json = #"{"type":"cancelled","job_id":"\#(Self.jsonEscape(req.job_id))"}"#
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(context: ctx.value, version: head.version, status: .ok, headers: headers, body: json)
            }
            logSelf.logRequest(
                method: "POST",
                path: "/images/cancel",
                userAgent: userAgent,
                requestBody: bodyString,
                responseBody: json,
                responseStatus: 200,
                startTime: startTime
            )
        }
    }

    /// Shared driver for the three image endpoints: streams SSE progress when
    /// `streaming`, otherwise buffers to a single OpenAI-shaped JSON response.
    private func runImageJob(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        path: String,
        requestBody: String?,
        streaming: Bool,
        responseFormat: String,
        jobID: String,
        build: @escaping @Sendable () async -> AsyncThrowingStream<ImageGenerationEvent, Error>
    ) {
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self

        if streaming {
            // The writer is confined to the event loop; wrap it in a
            // NIOLoopBound so it can cross into the `@Sendable` hop closures
            // (same pattern as the chat SSE path).
            let writer = NIOLoopBound(SSEResponseWriter(), eventLoop: loop)
            hop { writer.value.writeHeaders(ctx.value, extraHeaders: cors) }
            func emit(_ event: ImageStreamEventDTO) {
                let json =
                    (try? JSONEncoder.osaurusCanonical().encode(event))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                hop { writer.value.writeRawJSONData(json, context: ctx.value) }
            }
            runRequestTask(priority: .userInitiated) {
                emit(ImageStreamEventDTO(type: "queued", job_id: jobID))
                let stream = await build()
                do {
                    for try await event in stream {
                        switch event {
                        case .loadingModel(let model):
                            emit(ImageStreamEventDTO(type: "loading_model", job_id: jobID, model: model))
                        case .step(let step, let total, let eta):
                            emit(
                                ImageStreamEventDTO(
                                    type: "step",
                                    job_id: jobID,
                                    step: step,
                                    total: total,
                                    progress: total > 0 ? Double(step) / Double(total) : nil,
                                    eta_seconds: eta
                                )
                            )
                        case .preview(let pngData, let step):
                            let uri = "data:image/png;base64," + pngData.base64EncodedString()
                            emit(ImageStreamEventDTO(type: "preview", job_id: jobID, step: step, image: uri))
                        case .completed(let images):
                            let results = images.map { Self.imageResult(for: $0, responseFormat: responseFormat) }
                            emit(ImageStreamEventDTO(type: "completed", job_id: jobID, images: results))
                        case .failed(let message, let hfAuth):
                            emit(ImageStreamEventDTO(type: "error", job_id: jobID, message: message, hf_auth: hfAuth))
                        case .cancelled:
                            emit(ImageStreamEventDTO(type: "cancelled", job_id: jobID))
                        }
                    }
                } catch {
                    emit(
                        ImageStreamEventDTO(
                            type: "error",
                            job_id: jobID,
                            message: String(describing: error),
                            hf_auth: false
                        )
                    )
                }
                hop { writer.value.writeEnd(ctx.value) }
                logSelf.logRequest(
                    method: "POST",
                    path: path,
                    userAgent: userAgent,
                    requestBody: requestBody,
                    responseBody: "[stream]",
                    responseStatus: 200,
                    startTime: startTime
                )
            }
            return
        }

        // Non-streaming: collect to a single response.
        runImageNonStreaming(
            head: head,
            ctx: ctx,
            hop: hop,
            cors: cors,
            logSelf: logSelf,
            startTime: startTime,
            userAgent: userAgent,
            path: path,
            requestBody: requestBody,
            responseFormat: responseFormat,
            build: build
        )
    }

    private func runImageNonStreaming(
        head: HTTPRequestHead,
        ctx: NIOLoopBound<ChannelHandlerContext>,
        hop: @escaping (@escaping @Sendable () -> Void) -> Void,
        cors: [(String, String)],
        logSelf: HTTPHandler,
        startTime: Date,
        userAgent: String?,
        path: String,
        requestBody: String?,
        responseFormat: String,
        build: @escaping @Sendable () async -> AsyncThrowingStream<ImageGenerationEvent, Error>
    ) {
        runRequestTask(priority: .userInitiated) {
            var produced: [GeneratedImage] = []
            var failure: (message: String, hfAuth: Bool)?
            let stream = await build()
            do {
                for try await event in stream {
                    switch event {
                    case .completed(let images): produced = images
                    case .failed(let message, let hfAuth): failure = (message, hfAuth)
                    default: break
                    }
                }
            } catch {
                failure = (String(describing: error), false)
            }

            if let failure {
                let status = Self.imageErrorStatus(message: failure.message, hfAuth: failure.hfAuth)
                let body =
                    #"{"error":{"message":"\#(Self.jsonEscape(failure.message))","type":"invalid_request_error"}}"#
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
                }
                logSelf.logRequest(
                    method: "POST",
                    path: path,
                    userAgent: userAgent,
                    requestBody: requestBody,
                    responseStatus: Int(status.code),
                    startTime: startTime,
                    errorMessage: failure.message
                )
                return
            }

            let results = produced.map { Self.imageResult(for: $0, responseFormat: responseFormat) }
            let response = ImagesResponseDTO(created: Int(Date().timeIntervalSince1970), data: results)
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(response))
                .map { String(decoding: $0, as: UTF8.self) } ?? #"{"created":0,"data":[]}"#
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                self.sendResponse(context: ctx.value, version: head.version, status: .ok, headers: headers, body: json)
            }
            logSelf.logRequest(
                method: "POST",
                path: path,
                userAgent: userAgent,
                requestBody: requestBody,
                responseBody: json,
                responseStatus: 200,
                startTime: startTime
            )
        }
    }

    // MARK: - Legacy Completions (/v1/completions)
    // `CompletionRequest` lives in OpenAIAPI.swift alongside
    // `ChatCompletionRequest`. The response DTOs below are encode-only.

    private struct CompletionChoiceDTO: Encodable {
        let text: String
        let index: Int
        let finish_reason: String?
    }
    private struct CompletionUsageDTO: Encodable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
    private struct CompletionResponseDTO: Encodable {
        let id: String
        let object: String
        let created: Int
        let model: String
        let choices: [CompletionChoiceDTO]
        let usage: CompletionUsageDTO?
    }

    private static func encodeCompletionJSON(_ dto: CompletionResponseDTO) -> String? {
        guard let data = try? JSONEncoder().encode(dto) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// OpenAI-legacy `/v1/completions`: raw-prompt completion with a
    /// `text_completion` response shape. Routes through the chat-template-
    /// bypassing raw generation path so FIM prompts reach the model verbatim.
    private func handleCompletions(
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

        guard let req = try? JSONDecoder().decode(CompletionRequest.self, from: data) else {
            let body = Self.errorBody(
                .openai(type: "invalid_request_error"),
                message: "Invalid request format: 'prompt' is required"
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
                path: "/completions",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid completions request"
            )
            return
        }

        if let unsupported = req.unsupportedFIMReason {
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
                path: "/completions",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: unsupported
            )
            return
        }

        guard !req.prompt.isEmpty else {
            let body = Self.errorBody(
                .openai(type: "invalid_request_error"),
                message: "Invalid request format: 'prompt' is required"
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
                path: "/completions",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400,
                startTime: startTime,
                errorMessage: "Invalid completions request"
            )
            return
        }

        let accept = head.headers.first(name: "Accept") ?? ""
        let wantsSSE = (req.stream ?? false) || accept.contains("text/event-stream")
        let created = Int(Date().timeIntervalSince1970)
        let responseId = Self.shortId(prefix: "cmpl-", length: 12)
        let model = req.model
        let prompt = req.prompt
        let stop = req.stop
        let params = GenerationParameters(
            temperature: req.temperature,
            maxTokens: req.resolvedMaxTokens,
            maxTokensExplicit: req.maxTokens != nil,
            topPOverride: req.topP,
            topKOverride: req.topK
        )
        let promptTokens = TokenEstimator.estimate(prompt)
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        let version = head.version
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString

        guard
            let admissionToken = acquireInferenceAdmissionOrReject(
                context: context,
                version: head.version,
                flavor: .openai(type: "server_overloaded"),
                path: "/completions",
                method: "POST",
                userAgent: userAgent,
                requestBody: requestBodyString,
                startTime: startTime
            )
        else { return }

        if wantsSSE {
            let writer = SSEResponseWriter()
            let writerBound = NIOLoopBound(writer, eventLoop: loop)
            hop { writerBound.value.writeHeaders(ctx.value, extraHeaders: cors) }
            let disconnected = installStreamingDisconnectHook(context: context, model: model)
            let keepaliveTask = Self.startSSEKeepalive(
                writer: writerBound,
                channel: context.channel,
                loop: loop,
                ctx: ctx,
                disconnected: disconnected
            )
            runRequestTask(priority: .userInitiated) {
                defer { keepaliveTask.cancel() }
                defer { admissionToken.release() }
                var accumulated = ""
                let finishReason = "stop"
                do {
                    let stream = try await MLXService.shared.streamRawCompletion(
                        prompt: prompt,
                        parameters: params,
                        requestedModel: model,
                        stopSequences: stop
                    )
                    if disconnected.value { throw CancellationError() }
                    // `streamRawCompletion` yields only plain generated text
                    // (reasoning / tool / stats events are dropped upstream in
                    // `ModelRuntime.streamRawText`), so no sentinel filtering is
                    // needed here.
                    for try await delta in stream {
                        if disconnected.value { throw CancellationError() }
                        if delta.isEmpty { continue }
                        accumulated += delta
                        let chunk = CompletionResponseDTO(
                            id: responseId,
                            object: "text_completion",
                            created: created,
                            model: model,
                            choices: [CompletionChoiceDTO(text: delta, index: 0, finish_reason: nil)],
                            usage: nil
                        )
                        if let json = Self.encodeCompletionJSON(chunk) {
                            hop { writerBound.value.writeRawJSONData(json, context: ctx.value) }
                        }
                    }
                } catch {
                    hop { writerBound.value.writeError(error.localizedDescription, context: ctx.value) }
                }
                let final = CompletionResponseDTO(
                    id: responseId,
                    object: "text_completion",
                    created: created,
                    model: model,
                    choices: [CompletionChoiceDTO(text: "", index: 0, finish_reason: finishReason)],
                    usage: nil
                )
                hop {
                    if let json = Self.encodeCompletionJSON(final) {
                        writerBound.value.writeRawJSONData(json, context: ctx.value)
                    }
                    writerBound.value.writeEnd(ctx.value)
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/completions",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: 200,
                    startTime: startTime,
                    model: model,
                    tokensInput: promptTokens,
                    tokensOutput: TokenEstimator.estimate(accumulated),
                    temperature: req.temperature,
                    maxTokens: req.resolvedMaxTokens
                )
            }
            return
        }

        // Non-streaming
        runRequestTask(priority: .userInitiated) {
            defer { admissionToken.release() }
            do {
                let stream = try await MLXService.shared.streamRawCompletion(
                    prompt: prompt,
                    parameters: params,
                    requestedModel: model,
                    stopSequences: stop
                )
                var text = ""
                for try await delta in stream {
                    text += delta
                }
                let completionTokens = TokenEstimator.estimate(text)
                let response = CompletionResponseDTO(
                    id: responseId,
                    object: "text_completion",
                    created: created,
                    model: model,
                    choices: [CompletionChoiceDTO(text: text, index: 0, finish_reason: "stop")],
                    usage: CompletionUsageDTO(
                        prompt_tokens: promptTokens,
                        completion_tokens: completionTokens,
                        total_tokens: promptTokens + completionTokens
                    )
                )
                let body = Self.encodeCompletionJSON(response) ?? "{}"
                var headers: [(String, String)] = [("Content-Type", "application/json")]
                headers.append(contentsOf: cors)
                let headersCopy = headers
                hop {
                    Self.writeFullResponse(
                        ctx: ctx,
                        version: version,
                        status: .ok,
                        headers: headersCopy,
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/completions",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseBody: body,
                    responseStatus: 200,
                    startTime: startTime,
                    model: model,
                    tokensInput: promptTokens,
                    tokensOutput: completionTokens,
                    temperature: req.temperature,
                    maxTokens: req.resolvedMaxTokens,
                    finishReason: .stop
                )
            } catch {
                let message = error.localizedDescription
                let status = Self.localRuntimeHTTPStatus(for: error)
                let body = Self.errorBody(.openai(type: Self.openAIErrorType(for: error)), message: message)
                hop {
                    Self.writeFullResponse(
                        ctx: ctx,
                        version: version,
                        status: status,
                        headers: [("Content-Type", "application/json; charset=utf-8")],
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/completions",
                    userAgent: logUserAgent,
                    requestBody: logRequestBody,
                    responseStatus: Int(status.code),
                    startTime: startTime,
                    model: model,
                    errorMessage: message
                )
            }
        }
    }

    /// Write a complete HTTP response (head + body + end, then close) on the
    /// event loop. Must be called from within a `hop { }` so `ctx.value` is
    /// touched on its loop. Mirrors the inline write the chat path uses.
    private static func writeFullResponse(
        ctx: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: String
    ) {
        var responseHead = HTTPResponseHead(version: version, status: status)
        var buffer = ctx.value.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        var nioHeaders = HTTPHeaders()
        for (name, value) in headers { nioHeaders.add(name: name, value: value) }
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

    /// Concurrency ceiling for simultaneous HTTP inference requests, keyed to
    /// the batch engine's effective `maxConcurrentSequences`. Sized with
    /// headroom so normal concurrent use is never throttled, but a pathological
    /// fan-out (hundreds of streams) is refused with `503` before it
    /// oversubscribes MLX / unified memory.
    static func httpInferenceAdmissionLimit() -> Int {
        let snapshot = ServerRuntimeSettingsStore.snapshot()
        let batch = InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
            in: .standard,
            runtime: snapshot
        )
        return max(batch, 1) * 8 + 4
    }

    /// Acquire one inference-admission slot for an MLX-bearing route, or reject
    /// the request with a protocol-correct 503 + `Retry-After` and return `nil`.
    ///
    /// All MLX-bearing routes (`/chat/completions`, `/completions`, `/messages`,
    /// `/responses`, Ollama `/chat` + `/generate`, agent-run) share this single
    /// ceiling so a burst across mixed protocols can't collectively fan out
    /// unbounded into the batch engine and oversubscribe unified memory.
    ///
    /// The returned `Token` releases exactly once and self-releases on `deinit`;
    /// capture it in the generation task (`defer { token.release() }`) so the
    /// slot frees on every exit path, including cancellation.
    func acquireInferenceAdmissionOrReject(
        context: ChannelHandlerContext,
        version: HTTPVersion,
        flavor: HTTPErrorFlavor,
        path: String,
        method: String,
        userAgent: String?,
        requestBody: String?,
        startTime: Date
    ) -> HTTPInferenceAdmission.Token? {
        let limit = Self.httpInferenceAdmissionLimit()
        if let token = HTTPInferenceAdmission.shared.tryAcquireToken(limit: limit) {
            return token
        }
        let body = Self.errorBody(
            flavor,
            message:
                "Server is at inference capacity (\(limit) concurrent requests). Retry shortly."
        )
        sendResponse(
            context: context,
            version: version,
            status: .serviceUnavailable,
            headers: [
                ("Content-Type", "application/json; charset=utf-8"),
                ("Retry-After", "1"),
            ] + stateRef.value.corsHeaders,
            body: body
        )
        logRequest(
            method: method,
            path: path,
            userAgent: userAgent,
            requestBody: requestBody,
            responseStatus: 503,
            startTime: startTime,
            errorMessage: "inference admission saturated (limit \(limit))"
        )
        return nil
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

        // The Default (built-in) agent is unreachable from external HTTP.
        // Silently drop the header if it points at the Default id so that
        // memory writes and per-agent persistence never touch the built-in
        // agent's data. Inference itself is unaffected — model selection
        // and tools still work, just unattributed to the default.
        let rawMemoryAgentId = head.headers.first(name: "X-Osaurus-Agent-Id")
        let memoryAgentId: String? = {
            guard let raw = rawMemoryAgentId else { return nil }
            if let uuid = UUID(uuidString: raw), uuid == Agent.defaultId { return nil }
            return raw
        }()

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

        // HTTP inference admission control. A real concurrency ceiling keyed to
        // the batch engine's capacity so a burst of concurrent streams can't
        // fan out unbounded into MLX and oversubscribe unified memory. When
        // saturated we return 503 + Retry-After instead of admitting the work.
        // Acquired here (synchronously, on the channel) and released in the
        // generation task's `defer` on every exit path below.
        let admissionLimit = Self.httpInferenceAdmissionLimit()
        guard HTTPInferenceAdmission.shared.tryAcquire(limit: admissionLimit) else {
            let body = Self.errorBody(
                .openai(type: "server_overloaded"),
                message:
                    "Server is at inference capacity (\(admissionLimit) concurrent requests). Retry shortly."
            )
            sendResponse(
                context: context,
                version: head.version,
                status: .serviceUnavailable,
                headers: [
                    ("Content-Type", "application/json; charset=utf-8"),
                    ("Retry-After", "1"),
                ] + stateRef.value.corsHeaders,
                body: body
            )
            logRequest(
                method: "POST",
                path: "/chat/completions",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 503,
                startTime: startTime,
                errorMessage: "inference admission saturated (limit \(admissionLimit))"
            )
            return
        }

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
            let logTemperature = req.temperature
            let logMaxTokens = req.resolvedMaxTokens
            let logSelf = self
            let disconnected = SendableBool(false)
            let channelClosed = SendableBool(false)
            context.channel.closeFuture.whenComplete { _ in
                channelClosed.value = true
                disconnected.value = true
            }
            // SSE keepalive: emit a `: ping` comment line every 15s so
            // intermediate proxies / load balancers do not idle out long
            // tool-execution / reasoning pauses. Channel close futures and
            // write failures handle disconnect cancellation; the keepalive
            // cadence must not be shortened into a 250ms busy heartbeat.
            let keepaliveTask = Self.startSSEKeepalive(
                writer: writerBound,
                channel: context.channel,
                loop: loop,
                ctx: ctx,
                disconnected: disconnected
            )
            runRequestTask(priority: .userInitiated) {
                defer { keepaliveTask.cancel() }
                defer { HTTPInferenceAdmission.shared.release() }
                // Same menu-bar "generating" dot for host-side server inference
                // (incl. remote Mode-1 chat completions over the Secure Channel).
                ServerController.signalGenerationStart()
                defer { ServerController.signalGenerationEnd() }
                let wasResidentBeforeStream = await ModelRuntime.shared.isResident(name: model)
                var emittedSemanticDelta = false
                func markSemanticDeltaIfConnected() {
                    if self._isChannelActive.value && !disconnected.value && !channelClosed.value {
                        emittedSemanticDelta = true
                    }
                }
                defer {
                    if !wasResidentBeforeStream && !emittedSemanticDelta
                        && (disconnected.value || channelClosed.value)
                    {
                        Task {
                            await ModelRuntime.shared.unload(name: model)
                        }
                    }
                }
                do {
                    httpTrace.mark("http_task_start")
                    let chatEngine = self.chatEngine
                    let enrichedReq = req
                    httpTrace.mark("http_context_passthrough_done")
                    httpTrace.set("http_enriched_message_count", enrichedReq.messages.count)

                    // Compute prefix evidence from the exact request sent to
                    // the OpenAI-compatible server path. Agent context is
                    // intentionally not injected here; the app chat and
                    // /agents/{id}/run paths own composed context.
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
                    try Task.checkCancellation()
                    let stream = try await chatEngine.streamChat(request: enrichedReq)
                    httpTrace.mark("http_stream_chat_ready")
                    if disconnected.value { throw CancellationError() }
                    var accumulatedContent = ""
                    var accumulatedReasoning = ""
                    var contentCoalescer = Self.StreamDeltaCoalescer(
                        interval: ServerRuntimeSettingsStore.snapshot().generation.streamInterval
                    )
                    var authoritativeCompletionTokens: Int?
                    var authoritativeTokensPerSecond: Double?
                    var streamFinishReason = "stop"
                    for try await delta in stream {
                        try Task.checkCancellation()
                        if disconnected.value { throw CancellationError() }
                        if let reasoning = StreamingReasoningHint.decode(delta) {
                            httpTrace.markFirstSemanticDelta("reasoning")
                            markSemanticDeltaIfConnected()
                            accumulatedReasoning += reasoning
                            if let pending = contentCoalescer.flush() {
                                hop {
                                    writerBound.value.writeContent(
                                        pending,
                                        model: model,
                                        responseId: responseId,
                                        created: created,
                                        context: ctx.value
                                    )
                                }
                            }
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
                        if let progress = StreamingPrefillProgressHint.decode(delta) {
                            hop {
                                writerBound.value.writePrefillProgress(
                                    progress,
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
                            authoritativeTokensPerSecond = stats.tokensPerSecond
                            if let stopReason = stats.stopReason {
                                streamFinishReason = stopReason
                            }
                            continue
                        }
                        if StreamingToolHint.isSentinel(delta) { continue }
                        httpTrace.markFirstSemanticDelta("content")
                        markSemanticDeltaIfConnected()
                        accumulatedContent += delta
                        if let chunk = contentCoalescer.append(delta) {
                            hop {
                                writerBound.value.writeContent(
                                    chunk,
                                    model: model,
                                    responseId: responseId,
                                    created: created,
                                    context: ctx.value
                                )
                            }
                        }
                        if disconnected.value { throw CancellationError() }
                    }
                    if disconnected.value { throw CancellationError() }
                    if let pending = contentCoalescer.flush() {
                        hop {
                            writerBound.value.writeContent(
                                pending,
                                model: model,
                                responseId: responseId,
                                created: created,
                                context: ctx.value
                            )
                        }
                    }
                    let terminalMessage = ChatMessage(
                        role: "assistant",
                        content: accumulatedContent,
                        tool_calls: nil,
                        tool_call_id: nil,
                        reasoning_content: accumulatedReasoning.isEmpty ? nil : accumulatedReasoning
                    )
                    if let error = Self.emptyToolTaskCompletionError(
                        requestMessages: enrichedReq.messages,
                        responseMessage: terminalMessage
                    ) {
                        let message = error.localizedDescription
                        hop {
                            writerBound.value.writeError(message, context: ctx.value)
                            writerBound.value.writeEnd(ctx.value)
                        }
                        httpTrace.mark("http_sse_error_written")
                        httpTrace.emit(finishReason: "error", responseStatus: 200, errorMessage: message)
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
                            errorMessage: message
                        )
                        return
                    }
                    let includeUsage = req.stream_options?.include_usage == true
                    let promptTokens = Self.estimatePromptTokens(enrichedReq.messages)
                    let completionTokens =
                        authoritativeCompletionTokens ?? TokenEstimator.estimate(accumulatedContent)
                    httpTrace.set("http_prompt_tokens_estimate", promptTokens)
                    httpTrace.set("http_completion_tokens", completionTokens)
                    let finalStreamFinishReason = streamFinishReason
                    let finalTokensPerSecond = authoritativeTokensPerSecond
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
                                tokensPerSecond: finalTokensPerSecond,
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
                    markSemanticDeltaIfConnected()
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
                    markSemanticDeltaIfConnected()
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
            let logTemperature = req.temperature
            let logMaxTokens = req.resolvedMaxTokens
            let logSelf = self
            let responseFinished = SendableBool(false)
            let wasResidentBeforeComplete = SendableBool(false)
            context.channel.closeFuture.whenComplete { _ in
                guard !responseFinished.value else { return }
                Task {
                    await ModelRuntime.shared.cancelGeneration(name: model)
                    if !wasResidentBeforeComplete.value {
                        await ModelRuntime.shared.unload(name: model)
                    }
                }
            }
            runRequestTask(priority: .userInitiated) {
                defer { HTTPInferenceAdmission.shared.release() }
                // Same menu-bar "generating" dot (non-streaming path).
                ServerController.signalGenerationStart()
                defer { ServerController.signalGenerationEnd() }
                do {
                    httpTrace.mark("http_task_start")
                    wasResidentBeforeComplete.value = await ModelRuntime.shared.isResident(name: model)
                    let chatEngine = self.chatEngine
                    let enrichedReq = req
                    httpTrace.mark("http_context_passthrough_done")
                    httpTrace.set("http_enriched_message_count", enrichedReq.messages.count)
                    httpTrace.mark("http_complete_chat_start")
                    try Task.checkCancellation()
                    var resp = try await chatEngine.completeChat(request: enrichedReq)
                    try Task.checkCancellation()
                    httpTrace.mark("http_complete_chat_done")
                    // Compute prefix evidence from the exact request sent to
                    // the OpenAI-compatible server path. Agent context is
                    // intentionally not injected here; the app chat and
                    // /agents/{id}/run paths own composed context.
                    let sysContent = enrichedReq.messages.first(where: { $0.role == "system" })?.content ?? ""
                    resp.prefix_hash = ModelRuntime.computePrefixHash(
                        systemContent: sysContent,
                        tools: enrichedReq.tools ?? []
                    )
                    if let error = Self.emptyToolTaskCompletionError(
                        requestMessages: enrichedReq.messages,
                        responseMessage: resp.choices.first?.message
                    ) {
                        throw error
                    }
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
                        responseFinished.value = true
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
                        status = Self.localRuntimeHTTPStatus(for: error)
                        errorType = Self.openAIErrorType(for: error)
                        message = error.localizedDescription
                    }
                    let body = Self.errorBody(.openai(type: errorType), message: message)
                    let actualStatus = Int(status.code)
                    let headers: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")]
                    let headersCopy = headers
                    hop {
                        responseFinished.value = true
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

        guard
            let admissionToken = acquireInferenceAdmissionOrReject(
                context: context,
                version: head.version,
                flavor: .openai(type: "server_overloaded"),
                path: "/chat",
                method: "POST",
                userAgent: userAgent,
                requestBody: requestBodyString,
                startTime: startTime
            )
        else { return }

        let shouldStream = req.stream ?? true
        if !shouldStream {
            handleOllamaChatNonStreaming(
                head: head,
                context: context,
                startTime: startTime,
                userAgent: userAgent,
                requestBodyString: requestBodyString,
                request: req,
                admissionToken: admissionToken
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
        let logTemperature = req.temperature
        let logMaxTokens = req.resolvedMaxTokens
        let logSelf = self
        let disconnected = installStreamingDisconnectHook(context: context, model: req.model)
        runRequestTask(priority: .userInitiated) {
            defer { admissionToken.release() }
            let wasResidentBeforeStream = await ModelRuntime.shared.isResident(name: req.model)
            var emittedSemanticDelta = false
            func markSemanticDeltaIfChannelActive() {
                if self._isChannelActive.value {
                    emittedSemanticDelta = true
                }
            }
            defer {
                if !wasResidentBeforeStream && !emittedSemanticDelta
                    && (!self._isChannelActive.value || Task.isCancelled)
                {
                    Task {
                        await ModelRuntime.shared.unload(name: req.model)
                    }
                }
            }
            do {
                let chatEngine = self.chatEngine
                try Task.checkCancellation()
                let stream = try await chatEngine.streamChat(request: req)
                if disconnected.value { throw CancellationError() }
                var contentCoalescer = Self.StreamDeltaCoalescer(
                    interval: ServerRuntimeSettingsStore.snapshot().generation.streamInterval
                )
                for try await delta in stream {
                    try Task.checkCancellation()
                    if disconnected.value { throw CancellationError() }
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
                    if let chunk = contentCoalescer.append(delta) {
                        markSemanticDeltaIfChannelActive()
                        hop {
                            writerBound.value.writeContent(
                                chunk,
                                model: req.model,
                                responseId: "",
                                created: Int(Date().timeIntervalSince1970),
                                context: ctx.value
                            )
                        }
                    }
                }
                if let pending = contentCoalescer.flush() {
                    hop {
                        writerBound.value.writeContent(
                            pending,
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
        request: ChatCompletionRequest,
        admissionToken: HTTPInferenceAdmission.Token
    ) {
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        runRequestTask(priority: .userInitiated) {
            defer { admissionToken.release() }
            do {
                try Task.checkCancellation()
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
                    temperature: request.temperature,
                    maxTokens: request.max_tokens,
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
                    temperature: request.temperature,
                    maxTokens: request.max_tokens,
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
                    temperature: request.temperature,
                    maxTokens: request.max_tokens,
                    finishReason: .toolCalls
                )
            } catch {
                let body = Self.ollamaGenerateErrorJSON(
                    error.localizedDescription,
                    type: Self.ollamaErrorType(for: error)
                )
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                let status = Self.localRuntimeHTTPStatus(for: error)
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: status,
                        headers: headers,
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/chat",
                    userAgent: userAgent,
                    requestBody: requestBodyString,
                    responseStatus: Int(status.code),
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

        guard
            let admissionToken = acquireInferenceAdmissionOrReject(
                context: context,
                version: head.version,
                flavor: .openai(type: "server_overloaded"),
                path: "/generate",
                method: "POST",
                userAgent: userAgent,
                requestBody: requestBodyString,
                startTime: startTime
            )
        else { return }

        let shouldStream = ollama.stream ?? true
        if !shouldStream {
            handleOllamaGenerateNonStreaming(
                head: head,
                context: context,
                startTime: startTime,
                userAgent: userAgent,
                requestBodyString: requestBodyString,
                request: chatRequest,
                admissionToken: admissionToken
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
        let logTemperature = chatRequest.temperature
        let logMaxTokens = chatRequest.max_tokens
        let logSelf = self
        let disconnected = installStreamingDisconnectHook(context: context, model: chatRequest.model)
        runRequestTask(priority: .userInitiated) {
            defer { admissionToken.release() }
            do {
                try Task.checkCancellation()
                let stream = try await self.chatEngine.streamChat(request: chatRequest)
                if disconnected.value { throw CancellationError() }
                var contentCoalescer = Self.StreamDeltaCoalescer(
                    interval: ServerRuntimeSettingsStore.snapshot().generation.streamInterval
                )
                for try await delta in stream {
                    if disconnected.value { throw CancellationError() }
                    if StreamingReasoningHint.decode(delta) != nil { continue }
                    if StreamingStatsHint.decode(delta) != nil { continue }
                    if StreamingToolHint.isSentinel(delta) { continue }
                    if let chunk = contentCoalescer.append(delta) {
                        hop {
                            writerBound.value.writeContent(
                                chunk,
                                model: chatRequest.model,
                                created: Int(Date().timeIntervalSince1970),
                                context: ctx.value
                            )
                        }
                    }
                }
                if let pending = contentCoalescer.flush() {
                    hop {
                        writerBound.value.writeContent(
                            pending,
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
        request: ChatCompletionRequest,
        admissionToken: HTTPInferenceAdmission.Token
    ) {
        let cors = stateRef.value.corsHeaders
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = Self.makeHop(channel: context.channel, loop: loop)
        let logSelf = self
        runRequestTask(priority: .userInitiated) {
            defer { admissionToken.release() }
            do {
                try Task.checkCancellation()
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
                    temperature: request.temperature,
                    maxTokens: request.max_tokens,
                    finishReason: .stop
                )
            } catch {
                let body = Self.ollamaGenerateErrorJSON(
                    error.localizedDescription,
                    type: Self.ollamaErrorType(for: error)
                )
                let headers = [("Content-Type", "application/json; charset=utf-8")] + cors
                let status = Self.localRuntimeHTTPStatus(for: error)
                hop {
                    logSelf.sendResponse(
                        context: ctx.value,
                        version: head.version,
                        status: status,
                        headers: headers,
                        body: body
                    )
                }
                logSelf.logRequest(
                    method: "POST",
                    path: "/generate",
                    userAgent: userAgent,
                    requestBody: requestBodyString,
                    responseStatus: Int(status.code),
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

    private static func ollamaGenerateErrorJSON(_ message: String, type: String = "internal_error") -> String {
        let object: [String: Any] = [
            "error": [
                "message": message,
                "type": type,
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
    /// Install a channel-close hook for a streaming route: flips the returned
    /// flag and cancels the model's in-flight generation the moment the client
    /// disconnects, so a hangup stops GPU work on every streaming path. The
    /// `/chat/completions` streamer wires this inline; this is the shared
    /// version for the Anthropic / Responses / Ollama streamers. The streaming
    /// loop must poll the flag and `throw CancellationError()` when it's set.
    private func installStreamingDisconnectHook(
        context: ChannelHandlerContext,
        model: String
    ) -> SendableBool {
        let disconnected = SendableBool(false)
        context.channel.closeFuture.whenComplete { _ in
            disconnected.value = true
            // Cancel decode on hangup so the GPU isn't left generating into a
            // closed socket. Safe/no-op if generation already finished.
            Task { await ModelRuntime.shared.cancelGeneration(name: model) }
        }
        return disconnected
    }

    private static func startSSEKeepalive(
        writer: NIOLoopBound<SSEResponseWriter>,
        channel: Channel,
        loop: EventLoop,
        ctx: NIOLoopBound<ChannelHandlerContext>,
        disconnected: SendableBool? = nil,
        intervalNanoseconds: UInt64 = 15_000_000_000
    ) -> Task<Void, Never> {
        Task<Void, Never>(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                if Task.isCancelled { return }
                guard channel.isActive else {
                    disconnected?.value = true
                    return
                }
                loop.execute {
                    guard channel.isActive else {
                        disconnected?.value = true
                        return
                    }
                    var buf = channel.allocator.buffer(capacity: 16)
                    buf.writeString(": ping\n\n")
                    let promise = loop.makePromise(of: Void.self)
                    promise.futureResult.whenFailure { _ in
                        disconnected?.value = true
                        ctx.value.close(promise: nil)
                    }
                    ctx.value.writeAndFlush(
                        NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))),
                        promise: promise
                    )
                    ctx.value.read()
                }
            }
        }
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

        runRequestTask(priority: .userInitiated) {
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

            // Diagnostics surface (hang/overload triage without scraping logs):
            // HTTP admission depth, distillation queue, sandbox state, the last
            // recovered MLX error, live chat count, vector-index failures, and
            // the last RAM feasibility verdict.
            let httpInflight = HTTPInferenceAdmission.shared.inflightCount
            let httpLimit = Self.httpInferenceAdmissionLimit()
            let chatActive = await InferenceLoadCoordinator.shared.activeCount
            let distill = await DistillationCoordinator.shared.snapshot()
            let indexFailures = await MemorySearchService.shared.indexFailures()
            let sandboxStatus = await MainActor.run {
                String(describing: SandboxManager.State.shared.status)
            }
            let mlxLastError: Any = MLXErrorRecovery.lastError as Any? ?? NSNull()
            let ramSnapshot = await ModelRuntime.shared.lastRAMFeasibilitySnapshot()
            let ramFeasibility: Any
            if let f = ramSnapshot {
                ramFeasibility =
                    [
                        "model": f.modelName,
                        "verdict": f.verdict.rawValue,
                        "incoming_weights_bytes": f.incomingWeightsBytes,
                        "incoming_load_footprint_bytes": f.incomingLoadFootprintBytes,
                        "resident_weights_bytes": f.residentWeightsBytes,
                        "kv_headroom_bytes": f.kvHeadroomBytes,
                        "projected_bytes": f.projectedBytes,
                        "physical_memory_bytes": f.physicalMemoryBytes,
                        "available_memory_bytes": f.availableMemoryBytes,
                        "required_available_bytes": f.requiredAvailableBytes,
                        "soft_limit_bytes": f.softLimitBytes,
                        "hard_limit_bytes": f.hardLimitBytes,
                    ] as [String: Any]
            } else {
                ramFeasibility = NSNull()
            }

            let memoryConfig = MemoryConfigurationStore.load()
            let localModelScan: Any = ModelManager.localModelsScanDiagnosticJSONObject() as Any? ?? NSNull()
            let obj: [String: Any] = [
                "status": "healthy",
                "timestamp": Date().ISO8601Format(),
                "loaded": loaded,
                "current_model": current,
                "inflight": inflightObj,
                "resident_models": residentModels,
                "memory_enabled": memoryConfig.enabled,
                "memory_database_open": MemoryDatabase.shared.isOpen,
                "http_inflight": httpInflight,
                "http_inference_limit": httpLimit,
                "chat_active": chatActive,
                "distillation": ["queued": distill.queued, "active": distill.active],
                "sandbox_status": sandboxStatus,
                "mlx_last_error": mlxLastError,
                "index_failures": indexFailures,
                "local_model_scan": localModelScan,
                "ram_feasibility": ramFeasibility,
                "persistence": PersistenceHealth.shared.snapshot(),
            ]

            // A served /health means the process is alive and responsive —
            // clear any crash-loop safe mode and bring skipped subsystems back.
            await MainActor.run { LaunchGuard.noteHealthyHealthCheck() }
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

        runRequestTask(priority: .userInitiated) {
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

        runRequestTask(priority: .userInitiated) {
            let now = Date().ISO8601Format()

            // Get local models
            var models = MLXService.getAvailableModels().map { name -> OpenAIModel in
                var m = OpenAIModel(from: name)
                m.name = name
                m.model = name
                m.modified_at = now
                m.size = 0
                m.digest = ""
                m.details = ModelDetails.localMLXModelDetails(for: name)
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

        runRequestTask(priority: .userInitiated) {
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
        runRequestTask(priority: .userInitiated) {
            // External callers never see app-only tool classes; `/mcp/call`
            // refuses the same deny list too.
            let entries = await MainActor.run {
                ToolRegistry.shared.listTools().filter {
                    $0.enabled && !ToolRegistry.externallyDeniedToolNames.contains($0.name)
                }
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

        // Tool calls attributed to the Default agent are not exposable
        // externally. A PRESENT header must parse to a valid custom-agent
        // UUID — a malformed value used to skip the guard entirely, which
        // was a trivial bypass. Unattributed (no header) calls keep
        // working for the documented MCP bridge flow: they execute with NO
        // agent context bound, so they can never act as the built-in
        // agent, and the external deny list below blocks workspace-
        // mutating tool classes regardless.
        if let header = head.headers.first(name: "X-Osaurus-Agent-Id") {
            let agentUUID = UUID(uuidString: header)
            let rejection: (code: String, message: String)? = {
                if agentUUID == nil {
                    return (
                        "invalid_agent",
                        "X-Osaurus-Agent-Id must be a valid agent UUID."
                    )
                }
                if let guardError = Agent.rejectBuiltInForExternalSurface(
                    agentUUID,
                    source: "http/mcp/call"
                ) {
                    return (guardError.code, guardError.message)
                }
                return nil
            }()
            if let rejection {
                let bodyJSON = #"{"error":"\#(rejection.code)","message":"\#(rejection.message)"}"#
                sendResponse(
                    context: context,
                    version: head.version,
                    status: .forbidden,
                    headers: [("Content-Type", "application/json; charset=utf-8")],
                    body: bodyJSON
                )
                logRequest(
                    method: "POST",
                    path: "/mcp/call",
                    userAgent: userAgent,
                    requestBody: requestBodyString,
                    responseStatus: 403,
                    startTime: startTime,
                    errorMessage: rejection.message
                )
                return
            }
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

        // External deny list: app-only tool classes are never invocable
        // through the MCP bridge (they're also hidden from `/mcp/tools`).
        // Refuse before any schema validation or gating.
        if ToolRegistry.externallyDeniedToolNames.contains(req.name) {
            let message =
                "'\(req.name)' is not available to external callers. App-only tools can only run from the Osaurus app."
            let bodyJSON = #"{"error":"tool_not_exposable","message":"\#(message)"}"#
            sendResponse(
                context: context,
                version: head.version,
                status: .forbidden,
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: bodyJSON
            )
            logRequest(
                method: "POST",
                path: "/mcp/call",
                userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 403,
                startTime: startTime,
                errorMessage: message
            )
            return
        }

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
        runRequestTask(priority: .userInitiated) {
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

                // Belt-and-braces: the registry re-checks the external deny
                // list under this flag even if a new entry point forgets
                // the name-based preflight above.
                let result = try await ChatExecutionContext.$isExternalSurface.withValue(true) {
                    try await ToolRegistry.shared.execute(name: toolName, argumentsJSON: argsJSON)
                }
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

        guard
            let admissionToken = acquireInferenceAdmissionOrReject(
                context: context,
                version: head.version,
                flavor: .anthropic(errorType: "overloaded_error"),
                path: "/messages",
                method: "POST",
                userAgent: userAgent,
                requestBody: requestBodyString,
                startTime: startTime
            )
        else { return }

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
                requestBodyString: requestBodyString,
                admissionToken: admissionToken
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
                requestBodyString: requestBodyString,
                admissionToken: admissionToken
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
        requestBodyString: String?,
        admissionToken: HTTPInferenceAdmission.Token
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
        let disconnected = installStreamingDisconnectHook(context: context, model: model)

        runRequestTask(priority: .userInitiated) {
            defer { admissionToken.release() }
            let wasResidentBeforeStream = await ModelRuntime.shared.isResident(name: model)
            var emittedSemanticDelta = false
            func markSemanticDeltaIfChannelActive() {
                if self._isChannelActive.value {
                    emittedSemanticDelta = true
                }
            }
            defer {
                if !wasResidentBeforeStream && !emittedSemanticDelta
                    && (!self._isChannelActive.value || Task.isCancelled)
                {
                    Task {
                        await ModelRuntime.shared.unload(name: model)
                    }
                }
            }
            do {
                let chatEngine = self.chatEngine
                try Task.checkCancellation()
                let stream = try await chatEngine.streamChat(request: internalReq)
                if disconnected.value { throw CancellationError() }
                var contentCoalescer = Self.StreamDeltaCoalescer(
                    interval: ServerRuntimeSettingsStore.snapshot().generation.streamInterval
                )
                for try await delta in stream {
                    try Task.checkCancellation()
                    if disconnected.value { throw CancellationError() }
                    // Reasoning sentinel must be decoded BEFORE the
                    // generic `isSentinel` filter, otherwise it gets
                    // dropped together with tool/stats hints.
                    if let reasoning = StreamingReasoningHint.decode(delta) {
                        markSemanticDeltaIfChannelActive()
                        if let pending = contentCoalescer.flush() {
                            hop {
                                writerBound.value.writeTextDelta(pending, context: ctx.value)
                            }
                        }
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
                    if let chunk = contentCoalescer.append(delta) {
                        markSemanticDeltaIfChannelActive()
                        hop {
                            writerBound.value.writeTextDelta(chunk, context: ctx.value)
                        }
                    }
                }
                if let pending = contentCoalescer.flush() {
                    markSemanticDeltaIfChannelActive()
                    hop {
                        writerBound.value.writeTextDelta(pending, context: ctx.value)
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
                markSemanticDeltaIfChannelActive()
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
                markSemanticDeltaIfChannelActive()
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
        requestBodyString: String?,
        admissionToken: HTTPInferenceAdmission.Token
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

        runRequestTask(priority: .userInitiated) {
            defer { admissionToken.release() }
            do {
                let chatEngine = self.chatEngine
                try Task.checkCancellation()
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
                let errorResp = AnthropicError(
                    message: error.localizedDescription,
                    errorType: Self.anthropicErrorType(for: error)
                )
                let errorJson =
                    (try? JSONEncoder.osaurusCanonical().encode(errorResp))
                    .map { String(decoding: $0, as: UTF8.self) }
                    ?? #"{"type":"error","error":{"type":"api_error","message":"Internal error"}}"#
                var headers: [(String, String)] = [("Content-Type", "application/json")]
                headers.append(contentsOf: cors)
                let headersCopy = headers
                let body = errorJson
                let status = Self.localRuntimeHTTPStatus(for: error)

                hop {
                    var responseHead = HTTPResponseHead(
                        version: head.version,
                        status: status
                    )
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
                    responseStatus: Int(status.code),
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

        runRequestTask(priority: .userInitiated) {
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

        guard
            let admissionToken = acquireInferenceAdmissionOrReject(
                context: context,
                version: head.version,
                flavor: .openResponses(code: "server_overloaded"),
                path: "/responses",
                method: "POST",
                userAgent: userAgent,
                requestBody: requestBodyString,
                startTime: startTime
            )
        else { return }

        if wantsStream {
            handleOpenResponsesStreaming(
                request: openResponsesReq,
                internalReq: internalReq,
                responseId: responseId,
                model: model,
                context: context,
                startTime: startTime,
                userAgent: userAgent,
                requestBodyString: requestBodyString,
                admissionToken: admissionToken
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
                requestBodyString: requestBodyString,
                admissionToken: admissionToken
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
        requestBodyString: String?,
        admissionToken: HTTPInferenceAdmission.Token
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
                        case .reasoning(let reasoning):
                            return acc + TokenEstimator.estimate(reasoning.encrypted_content ?? "")
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
        let disconnected = installStreamingDisconnectHook(context: context, model: model)

        runRequestTask(priority: .userInitiated) {
            defer { admissionToken.release() }
            let wasResidentBeforeStream = await ModelRuntime.shared.isResident(name: model)
            var emittedSemanticDelta = false
            func markSemanticDeltaIfChannelActive() {
                if self._isChannelActive.value {
                    emittedSemanticDelta = true
                }
            }
            defer {
                if !wasResidentBeforeStream && !emittedSemanticDelta
                    && (!self._isChannelActive.value || Task.isCancelled)
                {
                    Task {
                        await ModelRuntime.shared.unload(name: model)
                    }
                }
            }
            do {
                let chatEngine = self.chatEngine
                try Task.checkCancellation()
                let stream = try await chatEngine.streamChat(request: internalReq)
                if disconnected.value { throw CancellationError() }
                var contentCoalescer = Self.StreamDeltaCoalescer(
                    interval: ServerRuntimeSettingsStore.snapshot().generation.streamInterval
                )
                for try await delta in stream {
                    try Task.checkCancellation()
                    if disconnected.value { throw CancellationError() }
                    // Reasoning sentinel must be decoded BEFORE the
                    // generic `isSentinel` filter, otherwise it gets
                    // dropped together with tool/stats hints.
                    if let reasoning = StreamingReasoningHint.decode(delta) {
                        markSemanticDeltaIfChannelActive()
                        if let pending = contentCoalescer.flush() {
                            outputText.append(pending)
                            hop {
                                // First non-reasoning chunk: close the
                                // reasoning item (if any) then open the
                                // message item so the text deltas land on
                                // the message item.
                                writerBound.value.writeReasoningItemDone(context: ctx.value)
                                if !messageItemOpen.value {
                                    messageItemOpen.value = true
                                    writerBound.value.writeMessageItemAdded(itemId: itemId, context: ctx.value)
                                    writerBound.value.writeContentPartAdded(context: ctx.value)
                                }
                                writerBound.value.writeTextDelta(pending, context: ctx.value)
                            }
                        }
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
                    if let chunk = contentCoalescer.append(delta) {
                        markSemanticDeltaIfChannelActive()
                        outputText.append(chunk)
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
                            writerBound.value.writeTextDelta(chunk, context: ctx.value)
                        }
                    }
                }
                if let pending = contentCoalescer.flush() {
                    markSemanticDeltaIfChannelActive()
                    outputText.append(pending)
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
                        writerBound.value.writeTextDelta(pending, context: ctx.value)
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
                markSemanticDeltaIfChannelActive()
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
                markSemanticDeltaIfChannelActive()
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
        requestBodyString: String?,
        admissionToken: HTTPInferenceAdmission.Token
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

        runRequestTask(priority: .userInitiated) {
            defer { admissionToken.release() }
            do {
                let chatEngine = self.chatEngine
                try Task.checkCancellation()
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
                let errorResp = OpenResponsesErrorResponse(
                    code: Self.openResponsesErrorCode(for: error),
                    message: error.localizedDescription
                )
                let errorJson =
                    (try? JSONEncoder.osaurusCanonical().encode(errorResp))
                    .map { String(decoding: $0, as: UTF8.self) }
                    ?? #"{"error":{"type":"error","code":"api_error","message":"Internal error"}}"#
                var headers: [(String, String)] = [("Content-Type", "application/json")]
                headers.append(contentsOf: cors)
                let headersCopy = headers
                let body = errorJson
                let status = Self.localRuntimeHTTPStatus(for: error)

                hop {
                    var responseHead = HTTPResponseHead(
                        version: head.version,
                        status: status
                    )
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
                    responseStatus: Int(status.code),
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
        var usage: [String: Any] = [
            "prompt_tokens": response.usage.prompt_tokens,
            "completion_tokens": response.usage.completion_tokens,
            "total_tokens": response.usage.total_tokens,
        ]
        if let tokensPerSecond = response.usage.tokens_per_second {
            usage["tokens_per_second"] = tokensPerSecond
        }

        var object: [String: Any] = [
            "id": response.id,
            "object": response.object,
            "created": response.created,
            "model": response.model,
            "choices": response.choices.map(chatChoiceJSONObject(_:)),
            "usage": usage,
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
            errorMessage: errorMessage,
            connection: inboundConnectionInfo()
        )
    }

    /// Attribution metadata for an inbound request, built by the auth gate and
    /// read through the off-loop-safe box. Lets the host's Remote Connections
    /// view tie `.httpAPI` traffic to a specific paired access key (by nonce)
    /// and shows the transport (Secure Channel vs direct) in Insights. Returns
    /// nil for loopback / public routes that carried no token.
    private func inboundConnectionInfo() -> RequestConnectionInfo? {
        let info = _inboundConnection.value
        return (info?.isEmpty == true) ? nil : info
    }
}
