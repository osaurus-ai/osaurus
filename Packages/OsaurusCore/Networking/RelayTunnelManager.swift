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
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            return try await session.data(for: request)
        }
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

    private init() {
        configuration = RelayConfigurationStore.load()
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

        let session = URLSession(configuration: .default)
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

    /// Decode a request frame, resolve the agent UUID, and dispatch to a detached task
    /// so the HTTP round-trip runs off @MainActor and multiple requests multiplex concurrently.
    private func dispatchRequest(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(RelayRequestFrame.self, from: data) else { return }

        let agentUUID = resolveAgentId(for: frame.headers["x-agent-address"])
        let port = localPort
        let ws = webSocketTask

        Task.detached(priority: .userInitiated) {
            await Self.proxyRequest(frame, localPort: port, agentUUID: agentUUID, webSocket: ws)
        }
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
        guard let request = buildLocalRequest(from: frame, localPort: localPort, agentUUID: agentUUID) else {
            sendErrorResponse(id: frame.id, error: "invalid_path", via: webSocket)
            return
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 502
            let headers = flattenHeaders(httpResponse?.allHeaderFields)
            let contentType = headers["content-type"] ?? ""

            if contentType.contains("text/event-stream") || contentType.contains("application/x-ndjson") {
                await relayStreamingResponse(
                    id: frame.id,
                    status: status,
                    headers: headers,
                    contentType: contentType,
                    bytes: bytes,
                    via: webSocket
                )
            } else {
                await relayBufferedResponse(
                    id: frame.id,
                    status: status,
                    headers: headers,
                    bytes: bytes,
                    via: webSocket
                )
            }
        } catch {
            sendErrorResponse(id: frame.id, error: "local_server_error", via: webSocket)
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
    private static func relayStreamingResponse(
        id: String,
        status: Int,
        headers: [String: String],
        contentType: String,
        bytes: URLSession.AsyncBytes,
        via webSocket: URLSessionWebSocketTask?
    ) async {
        sendFrame(RelayStreamStartFrame(id: id, status: status, headers: headers), via: webSocket)

        let flushThreshold = 16 * 1024
        var buffer = Data()
        func flush() {
            guard let chunk = takeUTF8Prefix(&buffer), !chunk.isEmpty else { return }
            sendFrame(RelayStreamChunkFrame(id: id, data: chunk), via: webSocket)
        }

        do {
            for try await byte in bytes {
                buffer.append(byte)
                // Newline flush keeps SSE/NDJSON latency low; size flush bounds
                // memory for long lines.
                if byte == 0x0A || buffer.count >= flushThreshold {
                    flush()
                }
            }
        } catch {
            // Stream interrupted — forward what we have and close cleanly.
        }
        flush()

        sendFrame(RelayStreamEndFrame(id: id), via: webSocket)
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

    private static func relayBufferedResponse(
        id: String,
        status: Int,
        headers: [String: String],
        bytes: URLSession.AsyncBytes,
        via webSocket: URLSessionWebSocketTask?
    ) async {
        var allData = Data()
        do {
            for try await byte in bytes {
                allData.append(byte)
            }
        } catch {
            // Partial read — send whatever we collected
        }
        // Text passes through as-is; anything not valid UTF-8 (images, audio,
        // multipart) is base64-encoded with `bodyEncoding` so it is no longer
        // silently corrupted into "" by lossy string conversion.
        if let text = String(data: allData, encoding: .utf8) {
            sendFrame(
                RelayResponseFrame(
                    id: id,
                    status: status,
                    headers: headers,
                    body: text,
                    bodyEncoding: nil
                ),
                via: webSocket
            )
        } else {
            sendFrame(
                RelayResponseFrame(
                    id: id,
                    status: status,
                    headers: headers,
                    body: allData.base64EncodedString(),
                    bodyEncoding: "base64"
                ),
                via: webSocket
            )
        }
    }

    private static func sendErrorResponse(id: String, error: String, via webSocket: URLSessionWebSocketTask?) {
        sendFrame(
            RelayResponseFrame(
                id: id,
                status: 502,
                headers: ["content-type": "application/json"],
                body: "{\"error\":\"\(error)\"}",
                bodyEncoding: nil
            ),
            via: webSocket
        )
    }

    private static func sendFrame<T: Encodable>(_ frame: T, via webSocket: URLSessionWebSocketTask?) {
        guard let data = try? JSONEncoder.osaurusCanonical().encode(frame),
            let str = String(data: data, encoding: .utf8)
        else { return }
        webSocket?.send(.string(str)) { _ in }
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
