//
//  RelayTunnelManager.swift
//  osaurus
//
//  Manages a single WebSocket tunnel to the osaurus-relay service.
//  Authenticates agents via EIP-191 signed messages, forwards inbound
//  HTTP requests to the local server, and handles keepalive + reconnect.
//

import Foundation
import LocalAuthentication

// MARK: - Agent Relay Status

public enum AgentRelayStatus: Equatable {
    case disconnected
    case connecting
    case connected(url: String)
    case error(String)
}

// MARK: - Public URL Probe

/// Captures the public-route verdict separately from tunnel auth so callers can
/// keep the UI out of a false-green state until the HTTPS route works.
struct RelayPublicRouteCheckResult: Equatable, Sendable {
    let reachable: Bool
    let statusCode: Int?
    let failureDescription: String?
}

/// Performs the cheap public `/health` request that proves the relay hostname
/// can actually proxy back to the local Osaurus server.
struct RelayPublicURLProbe: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let timeout: TimeInterval = 8
    private let transport: Transport

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    static func live() -> RelayPublicURLProbe {
        RelayPublicURLProbe { request in
            let session = Self.makeHealthCheckSession()
            defer { session.finishTasksAndInvalidate() }
            return try await session.data(for: request)
        }
    }

    static func makeHealthCheckSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return GlobalProxySettings.makeSession(base: config)
    }

    static func makeHealthRequest(baseURL: String) -> URLRequest? {
        guard let base = URL(string: baseURL),
            let scheme = base.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            base.host?.isEmpty == false
        else { return nil }
        let healthURL = base.appendingPathComponent("health")
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("OsaurusRelayHealthCheck/1", forHTTPHeaderField: "User-Agent")
        return request
    }

    func check(
        baseURL: String,
        attempts: Int = 3,
        retryDelayNanoseconds: UInt64 = 1_000_000_000
    ) async -> RelayPublicRouteCheckResult {
        guard let request = Self.makeHealthRequest(baseURL: baseURL) else {
            return RelayPublicRouteCheckResult(
                reachable: false,
                statusCode: nil,
                failureDescription: "Public link URL is invalid."
            )
        }

        let maxAttempts = max(1, attempts)
        var lastResult = RelayPublicRouteCheckResult(
            reachable: false,
            statusCode: nil,
            failureDescription: "Public link check did not run."
        )

        for attempt in 1 ... maxAttempts {
            guard !Task.isCancelled else { return lastResult }

            do {
                let (_, response) = try await transport(request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                if statusCode == 200 {
                    return RelayPublicRouteCheckResult(
                        reachable: true,
                        statusCode: statusCode,
                        failureDescription: nil
                    )
                }
                lastResult = RelayPublicRouteCheckResult(
                    reachable: false,
                    statusCode: statusCode,
                    failureDescription: "Public link health check returned HTTP \(statusCode ?? 0)."
                )
            } catch {
                lastResult = RelayPublicRouteCheckResult(
                    reachable: false,
                    statusCode: nil,
                    failureDescription: "Public link check failed: \(error.localizedDescription)"
                )
            }

            if attempt < maxAttempts, retryDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                guard !Task.isCancelled else { return lastResult }
            }
        }

        return lastResult
    }
}

// MARK: - Relay Frame Types

private struct RelayRequestFrame: Decodable {
    let type: String
    let id: String
    let method: String
    let path: String
    let headers: [String: String]
    let body: String?
    /// When `"base64"`, `body` is base64-encoded raw bytes (binary-safe mode).
    /// Absent/other values mean UTF-8 text (legacy mode).
    let bodyEncoding: String?
}

private struct RelayResponseFrame: Encodable {
    let type = "response"
    let id: String
    let status: Int
    let headers: [String: String]
    let body: String
    /// Set to `"base64"` when `body` carries base64-encoded raw bytes. Bodies
    /// that are not valid UTF-8 (images, audio, etc.) were previously mangled
    /// through `String(data:encoding:) ?? ""`; base64 keeps them intact for
    /// relays that understand the field. Omitted for plain text bodies.
    let bodyEncoding: String?
}

private struct RelayStreamStartFrame: Encodable {
    let type = "stream_start"
    let id: String
    let status: Int
    let headers: [String: String]
}

private struct RelayStreamChunkFrame: Encodable {
    let type = "stream_chunk"
    let id: String
    let data: String
}

private struct RelayStreamEndFrame: Encodable {
    let type = "stream_end"
    let id: String
}

/// Async sink for one serialized WebSocket text frame. Returns `false` when the
/// frame could not be handed to the transport (no socket or a send error), so
/// streaming callers can stop instead of pumping more bytes into a dead socket.
///
/// Routing every frame through this seam (instead of calling
/// `URLSessionWebSocketTask.send` directly) gives the relay path three
/// properties the old fire-and-forget send lacked: backpressure (the next frame
/// is enqueued only after the transport accepts the previous one), ordering
/// (per-request awaits preserve `stream_start` -> `stream_chunk`* ->
/// `stream_end`), and fail-fast (a mid-stream send error stops the loop). It is
/// also the unit-test seam: tests drive `relayStreamingResponse` with a
/// recording sink instead of a live WebSocket.
typealias RelayFrameSink = @Sendable (_ json: String) async -> Bool

// MARK: - Relay Tunnel Manager

@MainActor
public final class RelayTunnelManager: ObservableObject {
    public static let shared = RelayTunnelManager()

    private static let relayURL = URL(string: "wss://agent.osaurus.ai/tunnel/connect")!

    // MARK: - Published State

    @Published public private(set) var agentStatuses: [UUID: AgentRelayStatus] = [:]
    @Published public private(set) var isConnected = false

    // MARK: - Private State

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var configuration = RelayConfiguration.default
    private var reconnectDelay: TimeInterval = 1
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var localPort: Int = 1337
    private var authenticatedAgents: Set<String> = []
    /// O(1) lookup from lowercased agent address to agent UUID, built at auth time.
    private var addressToAgentId: [String: UUID] = [:]
    /// FIFO queue of challenge handlers. The relay answers challenges in the
    /// order they are requested (one on socket open, one per
    /// `request_challenge`), so each inbound `challenge` frame consumes the
    /// oldest handler. A single-slot value here used to let a concurrent
    /// `addAgentToTunnel()` clobber the `connect()` handler, permanently
    /// stalling tunnel auth.
    private var pendingNonceHandlers: [(String) -> Void] = []
    /// Bounded retry budget for `auth_error` frames (e.g. transient clock
    /// skew). Reset on a successful auth.
    private var authErrorRetries = 0
    private static let maxAuthErrorRetries = 3
    /// Public-link checks run after relay auth so green UI means the public
    /// HTTPS route, not just the WebSocket auth handshake, is usable.
    private let publicURLProbe = RelayPublicURLProbe.live()
    private var publicCheckTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingPublicCheckURLs: [UUID: String] = [:]

    /// In-flight proxied requests keyed by relay frame `id`. Tracking these lets
    /// teardown (`disconnectAll`/`handleDisconnect`/`handleAuthError`), per-agent
    /// removal, and an initiator `cancel` frame cancel the detached proxy task.
    /// Cancelling the task drops the `URLSession.AsyncBytes` loop, which closes
    /// the loopback connection so the run endpoint's `closeFuture` cancels model
    /// generation and unloads -- no zombie loads on a dead tunnel.
    struct InFlightRequest {
        let agentUUID: String?
        let task: Task<Void, Never>
    }
    var inFlightRequests: [String: InFlightRequest] = [:]

    /// Upper bound on concurrently-proxied relay requests. The local server's
    /// own concurrency limits bound generation and `URLSession` bounds loopback
    /// connections, but a misbehaving or hostile relay could still enqueue
    /// unbounded proxy tasks; past this many in-flight, new requests are
    /// rejected with a 503 frame so the host can't be driven into unbounded
    /// task/memory growth. Generous enough that legitimate multi-agent /
    /// multi-peer traffic never hits it — real concurrent generation is far
    /// lower than this.
    static let maxConcurrentInFlightRequests = 64

    private init() {
        configuration = RelayConfigurationStore.load()
    }

    nonisolated static func makeWebSocketSession() -> URLSession {
        GlobalProxySettings.makeSession(base: .default)
    }

    // MARK: - Public API

    /// Enable or disable tunneling for an agent. Persists the setting and connects/disconnects as needed.
    public func setTunnelEnabled(_ enabled: Bool, for agentId: UUID) {
        configuration.setEnabled(enabled, for: agentId)
        RelayConfigurationStore.save(configuration)

        if enabled {
            agentStatuses[agentId] = .connecting
            if isConnected {
                Task { await addAgentToTunnel(agentId: agentId) }
            } else {
                Task { await connect() }
            }
        } else {
            if isConnected {
                removeAgentFromTunnel(agentId: agentId)
            }
            agentStatuses[agentId] = .disconnected
        }
    }

    public func isTunnelEnabled(for agentId: UUID) -> Bool {
        configuration.isEnabled(for: agentId)
    }

    /// Called when the local server starts -- reconnects tunnels for any previously-enabled agents.
    public func reconnectIfNeeded(port: Int) {
        localPort = port
        configuration = RelayConfigurationStore.load()
        let enabled = configuration.enabledAgentIds
        guard !enabled.isEmpty else { return }

        for id in enabled {
            agentStatuses[id] = .connecting
        }
        shouldReconnect = true
        Task { await connect() }
    }

    /// Called when the local server stops -- tears down the tunnel.
    public func disconnectAll() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        cancelAllInFlightRequests()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        authenticatedAgents.removeAll()
        addressToAgentId.removeAll()
        pendingNonceHandlers.removeAll()
        cancelAllPublicChecks()
        for id in agentStatuses.keys {
            agentStatuses[id] = .disconnected
        }
    }

    /// Update the local port (called when server configuration changes).
    public func updatePort(_ port: Int) {
        localPort = port
    }

    // MARK: - Connection Lifecycle

    private func connect() async {
        guard webSocketTask == nil || !isConnected else { return }

        let enabled = configuration.enabledAgentIds
        guard !enabled.isEmpty else { return }

        for id in enabled {
            ensureAgentIdentity(id)
        }

        let agents = AgentManager.shared.agents.filter { agent in
            enabled.contains(agent.id) && agent.agentAddress != nil && agent.agentIndex != nil
        }
        guard !agents.isEmpty else {
            for id in enabled {
                let agent = AgentManager.shared.agent(for: id)
                if agent?.agentAddress == nil {
                    agentStatuses[id] = .error("No identity")
                }
            }
            return
        }

        guard let masterKey = await obtainMasterKey() else {
            for agent in agents { agentStatuses[agent.id] = .error("No identity") }
            return
        }

        // Re-check after the suspension: another connect may have won the race
        guard webSocketTask == nil || !isConnected else { return }

        let session = Self.makeWebSocketSession()
        let task = session.webSocketTask(with: Self.relayURL)
        self.urlSession = session
        self.webSocketTask = task
        task.resume()

        // `keyBox` is captured by reference; the handler zeroes the key bytes
        // after signing so master-key material doesn't outlive its single use
        // inside a long-lived closure.
        var keyBox: Data? = masterKey
        pendingNonceHandlers.append { [weak self] nonce in
            guard let self else {
                keyBox?.zeroOut()
                keyBox = nil
                return
            }
            defer {
                keyBox?.zeroOut()
                keyBox = nil
            }
            guard let signingKey = keyBox else { return }

            let timestamp = Int(Date().timeIntervalSince1970)
            var authAgents: [[String: Any]] = []

            for agent in agents {
                guard let index = agent.agentIndex, let address = agent.agentAddress else { continue }
                do {
                    let sigHex = try Self.signAgentAuth(
                        address: address,
                        nonce: nonce,
                        timestamp: timestamp,
                        masterKey: signingKey,
                        agentIndex: index
                    )
                    authAgents.append(["address": address, "signature": sigHex])
                } catch {
                    self.agentStatuses[agent.id] = .error("Signing failed")
                }
            }

            guard !authAgents.isEmpty else { return }

            self.sendJSON([
                "type": "auth",
                "agents": authAgents,
                "nonce": nonce,
                "timestamp": timestamp,
            ])
        }

        startReceiving()
    }

    private func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    self.handleMessage(message)
                } catch {
                    self.handleDisconnect()
                    break
                }
            }
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        switch type {
        case "challenge":
            handleChallenge(json)
        case "auth_ok":
            handleAuthOk(json)
        case "auth_error":
            handleAuthError(json)
        case "agent_added":
            handleAgentAdded(json)
        case "agent_removed":
            handleAgentRemoved(json)
        case "ping":
            handlePing(json)
        case "request":
            dispatchRequest(data)
        case "cancel":
            // Forward-compatible: because the relay multiplexes every request on
            // one shared WebSocket, a per-request initiator hangup can only reach
            // the host as a `cancel` frame. Handling it now means host generation
            // stops the instant the relay forwards a disconnect; until the relay
            // emits this frame the case is dormant.
            if let cancelId = json["id"] as? String {
                cancelInFlightRequest(id: cancelId)
            }
        case "error":
            let errorMsg = json["error"] as? String ?? "unknown"
            print("[Relay] Error frame: \(errorMsg)")
        default:
            break
        }
    }

    private func handleChallenge(_ json: [String: Any]) {
        guard let nonce = json["nonce"] as? String else { return }
        guard !pendingNonceHandlers.isEmpty else { return }
        let handler = pendingNonceHandlers.removeFirst()
        handler(nonce)
    }

    private func handleAuthOk(_ json: [String: Any]) {
        isConnected = true
        reconnectDelay = 1
        authErrorRetries = 0

        guard let agents = json["agents"] as? [[String: Any]] else { return }
        for agentInfo in agents {
            guard let address = agentInfo["address"] as? String,
                let url = agentInfo["url"] as? String
            else { continue }

            let lower = address.lowercased()
            authenticatedAgents.insert(lower)

            if let agent = findAgent(byAddress: lower) {
                addressToAgentId[lower] = agent.id
                beginPublicRouteCheck(for: agent.id, url: url)
            }
        }
    }

    private func handleAuthError(_ json: [String: Any]) {
        let error = json["error"] as? String ?? "auth_failed"
        print("[Relay] Auth error: \(error)")
        for id in configuration.enabledAgentIds {
            agentStatuses[id] = .error(error)
        }
        cancelAllInFlightRequests()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        authenticatedAgents.removeAll()
        addressToAgentId.removeAll()
        pendingNonceHandlers.removeAll()
        cancelAllPublicChecks()

        // An auth_error used to permanently kill the tunnel: the receive loop
        // exits (webSocketTask is nil) and nothing rescheduled a connect, so a
        // transient failure (clock skew, relay restart mid-handshake) required
        // an app restart. Retry with backoff, bounded so a genuinely bad
        // signature doesn't hammer the relay forever.
        guard shouldReconnect, authErrorRetries < Self.maxAuthErrorRetries else { return }
        authErrorRetries += 1
        for id in configuration.enabledAgentIds {
            agentStatuses[id] = .connecting
        }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.reconnectDelay
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.reconnectDelay = min(self.reconnectDelay * 2, 60)
            await self.connect()
        }
    }

    private func handleAgentAdded(_ json: [String: Any]) {
        guard let address = json["address"] as? String,
            let url = json["url"] as? String
        else { return }

        let lower = address.lowercased()
        authenticatedAgents.insert(lower)
        if let agent = findAgent(byAddress: lower) {
            addressToAgentId[lower] = agent.id
            beginPublicRouteCheck(for: agent.id, url: url)
        }
    }

    private func handleAgentRemoved(_ json: [String: Any]) {
        guard let address = json["address"] as? String else { return }
        let lower = address.lowercased()
        authenticatedAgents.remove(lower)
        if let agentId = addressToAgentId.removeValue(forKey: lower) {
            cancelInFlightRequests(forAgentUUID: agentId.uuidString)
            cancelPublicCheck(for: agentId)
            agentStatuses[agentId] = .disconnected
        }
    }

    private func handlePing(_ json: [String: Any]) {
        let ts = json["ts"] as? Int ?? Int(Date().timeIntervalSince1970)
        let pong: [String: Any] = ["type": "pong", "ts": ts]
        sendJSON(pong)
    }

    // MARK: - Request Proxying

    /// Decode a request frame, resolve the agent UUID, and dispatch to a detached
    /// task so the HTTP round-trip runs off @MainActor and multiple requests
    /// multiplex concurrently. The task is tracked in `inFlightRequests` so
    /// teardown, per-agent removal, or a `cancel` frame can interrupt it.
    private func dispatchRequest(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(RelayRequestFrame.self, from: data) else { return }

        // Defend against a misbehaving/hostile relay flooding the host: past the
        // in-flight cap, reject new requests with a single 503 frame instead of
        // spawning more proxy tasks and loopback connections. Fire-and-forget is
        // correct here — it is one terminal frame, not a stream.
        if let rejection = inFlightCapacityRejection(id: frame.id) {
            sendJSON(rejection)
            return
        }

        let agentUUID = resolveAgentId(for: frame.headers["x-agent-address"])
        let port = localPort
        let ws = webSocketTask
        let requestId = frame.id

        // Track the task so teardown / per-agent removal / a `cancel` frame can
        // interrupt it. The detached task runs off @MainActor; it hops back to
        // clear its own registry slot when the round-trip finishes. Storing
        // happens synchronously here, before the detached task can possibly
        // complete its network round-trip, so there is no store-vs-clear race.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.proxyRequest(frame, localPort: port, agentUUID: agentUUID, webSocket: ws)
            await self?.clearInFlightRequest(id: requestId)
        }
        inFlightRequests[requestId] = InFlightRequest(agentUUID: agentUUID, task: task)
    }

    /// Remove a completed request's registry slot (called from the proxy task
    /// after the round-trip ends). Hops to @MainActor via the actor isolation.
    private func clearInFlightRequest(id: String) {
        inFlightRequests[id] = nil
    }

    /// Cancel a single in-flight request by frame id. Used by the `cancel` frame
    /// handler so a relayed initiator hangup stops host generation.
    func cancelInFlightRequest(id: String) {
        if let entry = inFlightRequests.removeValue(forKey: id) {
            entry.task.cancel()
        }
    }

    /// Cancel every tracked in-flight request. Called on tunnel teardown and
    /// re-auth so the host never keeps generating into a dead socket.
    func cancelAllInFlightRequests() {
        let entries = inFlightRequests
        inFlightRequests.removeAll()
        for (_, entry) in entries {
            entry.task.cancel()
        }
    }

    /// Cancel in-flight requests bound to a specific agent (by resolved UUID
    /// string), used when an agent is removed from the tunnel.
    private func cancelInFlightRequests(forAgentUUID agentUUID: String) {
        let matching = inFlightRequests.filter { $0.value.agentUUID == agentUUID }
        for (id, entry) in matching {
            inFlightRequests[id] = nil
            entry.task.cancel()
        }
    }

    /// The relay `response` frame to send when the in-flight cap is reached, or
    /// `nil` when there is capacity for one more request. Kept pure + internal
    /// so the cap policy is unit-testable without a live tunnel. A 503 lets the
    /// relay close the initiator's request promptly with a retry-able status
    /// instead of leaving it to hang until a timeout.
    func inFlightCapacityRejection(id: String) -> [String: Any]? {
        guard inFlightRequests.count >= Self.maxConcurrentInFlightRequests else { return nil }
        return [
            "type": "response",
            "id": id,
            "status": 503,
            "headers": ["content-type": "application/json"],
            "body": #"{"error":"host_busy","message":"Too many concurrent relay requests; retry shortly."}"#,
        ]
    }

    /// Resolve an agent crypto address to its UUID string via the pre-built lookup table.
    private func resolveAgentId(for address: String?) -> String? {
        guard let address else { return nil }
        guard let uuid = addressToAgentId[address.lowercased()] else { return nil }
        return uuid.uuidString
    }

    /// Proxy a relay request frame to the local Osaurus server and send result frames
    /// through the WebSocket. Detects streaming responses (SSE / NDJSON) and uses the
    /// relay streaming protocol (stream_start / stream_chunk / stream_end) so chunks
    /// are forwarded incrementally instead of buffered.
    private static func proxyRequest(
        _ frame: RelayRequestFrame,
        localPort: Int,
        agentUUID: String?,
        webSocket: URLSessionWebSocketTask?
    ) async {
        let sink = webSocketSink(webSocket)
        guard let request = buildLocalRequest(from: frame, localPort: localPort, agentUUID: agentUUID) else {
            await sendErrorResponse(id: frame.id, error: "invalid_path", via: sink)
            return
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 502
            let headers = flattenHeaders(httpResponse?.allHeaderFields)
            // Lowercase the value (headers["content-type"] is already a
            // lowercased key) so detection is robust to mixed-case content
            // types from future/SDK responses, not just the encryptor's
            // lowercase output.
            let contentType = (headers["content-type"] ?? "").lowercased()

            if contentType.contains("text/event-stream") || contentType.contains("application/x-ndjson") {
                await relayStreamingResponse(
                    id: frame.id,
                    status: status,
                    headers: headers,
                    bytes: bytes,
                    via: sink
                )
            } else {
                await relayBufferedResponse(
                    id: frame.id,
                    status: status,
                    headers: headers,
                    bytes: bytes,
                    via: sink
                )
            }
        } catch {
            if Task.isCancelled { return }
            await sendErrorResponse(id: frame.id, error: "local_server_error", via: sink)
        }
    }

    private static func buildLocalRequest(
        from frame: RelayRequestFrame,
        localPort: Int,
        agentUUID: String?
    ) -> URLRequest? {
        guard let url = URL(string: "http://127.0.0.1:\(localPort)\(frame.path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = frame.method
        for (key, value) in frame.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let agentUUID {
            request.setValue(agentUUID, forHTTPHeaderField: "X-Osaurus-Agent-Id")
        }
        // Stamp the relay-origin marker LAST (after caller headers) so the
        // local server never treats this loopback request as a trusted local
        // caller. `setValue` overwrites any value a remote caller tried to
        // smuggle in through the relay frame, so the marker cannot be removed.
        request.setValue("1", forHTTPHeaderField: HTTPHandler.relayOriginHeaderName)
        if let body = frame.body, !body.isEmpty {
            if frame.bodyEncoding == "base64" {
                // Binary-safe mode: reject the frame if the relay claims base64
                // but the payload doesn't decode, rather than forwarding junk.
                guard let decoded = Data(base64Encoded: body) else { return nil }
                request.httpBody = decoded
            } else {
                request.httpBody = body.data(using: .utf8)
            }
        }
        return request
    }

    private static func flattenHeaders(_ allHeaders: [AnyHashable: Any]?) -> [String: String] {
        guard let allHeaders else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in allHeaders {
            result[String(describing: key).lowercased()] = String(describing: value)
        }
        return result
    }

    /// Forward a streaming (SSE / NDJSON) response verbatim. The previous
    /// implementation re-split the stream with `bytes.lines`, which destroyed
    /// multi-line SSE events (`event:` + `data:`, multi-`data:` events, and
    /// comment keepalives) and re-invented event boundaries. Instead, forward
    /// the raw byte stream in UTF-8-safe chunks, flushing on every newline for
    /// low latency, so the public caller sees exactly what the local server
    /// produced.
    ///
    /// Generic over the byte sequence so unit tests can drive it with a synthetic
    /// `AsyncStream<UInt8>` and a recording `RelayFrameSink`; production passes
    /// `URLSession.AsyncBytes`.
    static func relayStreamingResponse<Bytes: AsyncSequence>(
        id: String,
        status: Int,
        headers: [String: String],
        bytes: Bytes,
        via sink: RelayFrameSink
    ) async where Bytes.Element == UInt8 {
        // Fail-fast: if the opening frame can't be sent, the socket is gone --
        // don't bother reading the local stream.
        guard await sendFrame(RelayStreamStartFrame(id: id, status: status, headers: headers), via: sink) else {
            return
        }

        let flushThreshold = 16 * 1024
        var buffer = Data()
        /// Flush the longest valid-UTF-8 prefix, leaving any split trailing
        /// multi-byte sequence buffered for the next flush. Returns `false` if a
        /// send failed (caller must stop).
        func flushValidPrefix() async -> Bool {
            guard let chunk = takeUTF8Prefix(&buffer), !chunk.isEmpty else { return true }
            return await sendFrame(RelayStreamChunkFrame(id: id, data: chunk), via: sink)
        }

        var sendFailed = false
        do {
            for try await byte in bytes {
                // Prompt cancellation: a cancelled proxy task (tunnel teardown,
                // per-agent removal, initiator cancel) stops reading and drops
                // the byte stream, closing the loopback connection so the run
                // endpoint cancels generation. The socket is gone, so emit no
                // further frames.
                if Task.isCancelled { return }
                buffer.append(byte)
                // Newline flush keeps SSE/NDJSON latency low; size flush bounds
                // memory for long lines.
                if byte == 0x0A || buffer.count >= flushThreshold {
                    if !(await flushValidPrefix()) {
                        sendFailed = true
                        break
                    }
                }
            }
        } catch {
            // A cancelled read also surfaces here (e.g. URLError.cancelled);
            // treat it like cancellation and emit nothing further.
            if Task.isCancelled { return }
            // Otherwise the local stream errored mid-flight: fall through to
            // flush what we have and send stream_end so the initiator gets a
            // prompt close (and detects the missing `fin` as truncation) rather
            // than hanging until a relay timeout.
        }

        if sendFailed { return }

        // Final flush of the valid prefix.
        if !(await flushValidPrefix()) { return }
        // Forward any remaining bytes (an incomplete trailing multi-byte
        // sequence at end-of-stream) instead of silently dropping them. The
        // encrypted SSE wire is ASCII so this never triggers there, but general
        // UTF-8 SSE must not lose its tail. Lossy decode replaces invalid bytes
        // rather than discarding them.
        if !buffer.isEmpty {
            let tail = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: false)
            if !tail.isEmpty, !(await sendFrame(RelayStreamChunkFrame(id: id, data: tail), via: sink)) {
                return
            }
        }

        _ = await sendFrame(RelayStreamEndFrame(id: id), via: sink)
    }

    /// Pop the longest valid-UTF-8 prefix from `data` as a String, leaving any
    /// trailing bytes of a split multi-byte character in place for the next
    /// flush. Returns nil when no valid prefix exists yet. Internal for tests.
    nonisolated static func takeUTF8Prefix(_ data: inout Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let s = String(data: data, encoding: .utf8) {
            data.removeAll(keepingCapacity: true)
            return s
        }
        // A UTF-8 code point is at most 4 bytes; back off up to 3 bytes to
        // find a clean boundary.
        for back in 1 ... 3 where data.count > back {
            let prefix = data.prefix(data.count - back)
            if let s = String(data: prefix, encoding: .utf8) {
                data.removeFirst(data.count - back)
                return s
            }
        }
        return nil
    }

    static func relayBufferedResponse<Bytes: AsyncSequence>(
        id: String,
        status: Int,
        headers: [String: String],
        bytes: Bytes,
        via sink: RelayFrameSink
    ) async where Bytes.Element == UInt8 {
        var allData = Data()
        do {
            for try await byte in bytes {
                // A buffered response is a single atomic frame; a cancelled
                // request means the initiator is gone, so deliver nothing
                // (a partial body sent as a complete `response` would be wrong).
                if Task.isCancelled { return }
                allData.append(byte)
            }
        } catch {
            if Task.isCancelled { return }
            // Partial read on a genuine error — send whatever we collected.
        }
        // Text passes through as-is; anything not valid UTF-8 (images, audio,
        // multipart) is base64-encoded with `bodyEncoding` so it is no longer
        // silently corrupted into "" by lossy string conversion.
        if let text = String(data: allData, encoding: .utf8) {
            _ = await sendFrame(
                RelayResponseFrame(
                    id: id,
                    status: status,
                    headers: headers,
                    body: text,
                    bodyEncoding: nil
                ),
                via: sink
            )
        } else {
            _ = await sendFrame(
                RelayResponseFrame(
                    id: id,
                    status: status,
                    headers: headers,
                    body: allData.base64EncodedString(),
                    bodyEncoding: "base64"
                ),
                via: sink
            )
        }
    }

    private static func sendErrorResponse(id: String, error: String, via sink: RelayFrameSink) async {
        _ = await sendFrame(
            RelayResponseFrame(
                id: id,
                status: 502,
                headers: ["content-type": "application/json"],
                body: "{\"error\":\"\(error)\"}",
                bodyEncoding: nil
            ),
            via: sink
        )
    }

    /// Production sink: awaits the WebSocket send so frames are ordered and
    /// backpressured, and reports failure (no socket / send threw) so streaming
    /// callers stop. Control frames (auth/pong/add_agent) stay on the
    /// fire-and-forget `sendJSON` path -- they are single frames, not streams.
    private static func webSocketSink(_ webSocket: URLSessionWebSocketTask?) -> RelayFrameSink {
        return { @Sendable str in
            guard let webSocket else { return false }
            do {
                try await webSocket.send(.string(str))
                return true
            } catch {
                return false
            }
        }
    }

    /// Encode a frame and hand it to the sink. Returns `false` if encoding fails
    /// or the sink reports the transport is gone.
    private static func sendFrame<T: Encodable>(_ frame: T, via sink: RelayFrameSink) async -> Bool {
        guard let data = try? JSONEncoder.osaurusCanonical().encode(frame),
            let str = String(data: data, encoding: .utf8)
        else { return false }
        return await sink(str)
    }

    // MARK: - Mid-Session Agent Management

    private func addAgentToTunnel(agentId: UUID) async {
        ensureAgentIdentity(agentId)

        guard let agent = AgentManager.shared.agent(for: agentId),
            let index = agent.agentIndex,
            let address = agent.agentAddress
        else {
            agentStatuses[agentId] = .error("No identity")
            return
        }

        guard let masterKey = await obtainMasterKey() else {
            agentStatuses[agentId] = .error("No identity")
            return
        }

        var keyBox: Data? = masterKey
        pendingNonceHandlers.append { [weak self] nonce in
            guard let self else {
                keyBox?.zeroOut()
                keyBox = nil
                return
            }
            defer {
                keyBox?.zeroOut()
                keyBox = nil
            }
            guard let signingKey = keyBox else { return }

            let timestamp = Int(Date().timeIntervalSince1970)
            do {
                let sigHex = try Self.signAgentAuth(
                    address: address,
                    nonce: nonce,
                    timestamp: timestamp,
                    masterKey: signingKey,
                    agentIndex: index
                )
                self.sendJSON([
                    "type": "add_agent",
                    "address": address,
                    "signature": sigHex,
                    "nonce": nonce,
                    "timestamp": timestamp,
                ])
            } catch {
                self.agentStatuses[agentId] = .error("Signing failed")
            }
        }

        sendJSON(["type": "request_challenge"])
    }

    private func removeAgentFromTunnel(agentId: UUID) {
        guard let agent = AgentManager.shared.agent(for: agentId),
            let address = agent.agentAddress
        else { return }

        let frame: [String: Any] = [
            "type": "remove_agent",
            "address": address,
        ]
        sendJSON(frame)
        let lower = address.lowercased()
        authenticatedAgents.remove(lower)
        addressToAgentId.removeValue(forKey: lower)
        cancelInFlightRequests(forAgentUUID: agentId.uuidString)
        cancelPublicCheck(for: agentId)
    }

    /// Attempt to auto-assign a cryptographic identity if the agent is missing one.
    private func ensureAgentIdentity(_ agentId: UUID) {
        guard let agent = AgentManager.shared.agent(for: agentId),
            agent.agentAddress == nil || agent.agentIndex == nil
        else { return }
        try? AgentManager.shared.assignAddress(to: agent)
    }

    // MARK: - Reconnect

    private func handleDisconnect() {
        isConnected = false
        cancelAllInFlightRequests()
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        authenticatedAgents.removeAll()
        addressToAgentId.removeAll()
        pendingNonceHandlers.removeAll()
        cancelAllPublicChecks()

        for id in configuration.enabledAgentIds {
            if agentStatuses[id] != .disconnected {
                agentStatuses[id] = .connecting
            }
        }

        guard shouldReconnect else { return }

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.reconnectDelay
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.reconnectDelay = min(self.reconnectDelay * 2, 60)
            await self.connect()
        }
    }

    // MARK: - Helpers

    /// Fetch the master key off the main actor. The keychain lookups behind
    /// this round-trip to securityd over blocking XPC, which can stall the
    /// main thread for seconds when the daemon is busy.
    private func obtainMasterKey() async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard OsaurusIdentity.exists() else { return nil }
            let context = OsaurusIdentityContext.biometric()
            return try? MasterKey.getPrivateKey(context: context)
        }.value
    }

    private static func signAgentAuth(
        address: String,
        nonce: String,
        timestamp: Int,
        masterKey: Data,
        agentIndex: UInt32
    ) throws -> String {
        let message = "osaurus-tunnel:\(address):\(nonce):\(timestamp)"
        let childKey = AgentKey.derive(masterKey: masterKey, index: agentIndex)
        let sig = try signEIP191Message(message, privateKey: childKey)
        return "0x" + sig.hexEncodedString
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .osaurusCanonical),
            let str = String(data: data, encoding: .utf8)
        else { return }
        webSocketTask?.send(.string(str)) { error in
            if let error {
                print("[Relay] Send error: \(error.localizedDescription)")
            }
        }
    }

    /// O(n) scan used only during auth events (rare), never on the request hot path.
    private func findAgent(byAddress address: String) -> Agent? {
        let lower = address.lowercased()
        return AgentManager.shared.agents.first { agent in
            agent.agentAddress?.lowercased() == lower
        }
    }

    private func beginPublicRouteCheck(for agentId: UUID, url: String) {
        agentStatuses[agentId] = .connecting
        pendingPublicCheckURLs[agentId] = url
        publicCheckTasks[agentId]?.cancel()

        let probe = publicURLProbe
        publicCheckTasks[agentId] = Task { [weak self] in
            let result = await probe.check(baseURL: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishPublicRouteCheck(for: agentId, url: url, result: result)
            }
        }
    }

    private func finishPublicRouteCheck(
        for agentId: UUID,
        url: String,
        result: RelayPublicRouteCheckResult
    ) {
        publicCheckTasks[agentId] = nil

        guard configuration.isEnabled(for: agentId),
            pendingPublicCheckURLs[agentId] == url,
            isConnected,
            webSocketTask != nil
        else { return }

        pendingPublicCheckURLs[agentId] = nil
        if result.reachable {
            agentStatuses[agentId] = .connected(url: url)
        } else {
            let message =
                result.failureDescription
                ?? "Public link check failed before the relay could reach the local server."
            agentStatuses[agentId] = .error(message)
        }
    }

    private func cancelPublicCheck(for agentId: UUID) {
        publicCheckTasks[agentId]?.cancel()
        publicCheckTasks[agentId] = nil
        pendingPublicCheckURLs[agentId] = nil
    }

    private func cancelAllPublicChecks() {
        for task in publicCheckTasks.values {
            task.cancel()
        }
        publicCheckTasks.removeAll()
        pendingPublicCheckURLs.removeAll()
    }
}
