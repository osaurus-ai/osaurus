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

// MARK: - Relay Frame Types

private struct RelayRequestFrame: Decodable {
    let type: String
    let id: String
    let method: String
    let path: String
    let headers: [String: String]
    let body: String?
}

private struct RelayResponseFrame: Encodable {
    let type = "response"
    let id: String
    let status: Int
    let headers: [String: String]
    let body: String
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
    /// Set before expecting a `challenge` frame; consumed when the nonce arrives.
    private var pendingNonceHandler: ((String) -> Void)?

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
                addAgentToTunnel(agentId: agentId)
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
        pendingNonceHandler = nil
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

        guard let masterKey = obtainMasterKey() else {
            for agent in agents { agentStatuses[agent.id] = .error("No identity") }
            return
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: Self.relayURL)
        self.urlSession = session
        self.webSocketTask = task
        task.resume()

        pendingNonceHandler = { [weak self] nonce in
            guard let self else { return }
            let timestamp = Int(Date().timeIntervalSince1970)
            var authAgents: [[String: Any]] = []

            for agent in agents {
                guard let index = agent.agentIndex, let address = agent.agentAddress else { continue }
                do {
                    let sigHex = try Self.signAgentAuth(
                        address: address,
                        nonce: nonce,
                        timestamp: timestamp,
                        masterKey: masterKey,
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
        let handler = pendingNonceHandler
        pendingNonceHandler = nil
        handler?(nonce)
    }

    private func handleAuthOk(_ json: [String: Any]) {
        isConnected = true
        reconnectDelay = 1

        guard let agents = json["agents"] as? [[String: Any]] else { return }
        for agentInfo in agents {
            guard let address = agentInfo["address"] as? String,
                let url = agentInfo["url"] as? String
            else { continue }

            let lower = address.lowercased()
            authenticatedAgents.insert(lower)

            if let agent = findAgent(byAddress: lower) {
                addressToAgentId[lower] = agent.id
                agentStatuses[agent.id] = .connected(url: url)
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
        pendingNonceHandler = nil
    }

    private func handleAgentAdded(_ json: [String: Any]) {
        guard let address = json["address"] as? String,
            let url = json["url"] as? String
        else { return }

        let lower = address.lowercased()
        authenticatedAgents.insert(lower)
        if let agent = findAgent(byAddress: lower) {
            addressToAgentId[lower] = agent.id
            agentStatuses[agent.id] = .connected(url: url)
        }
    }

    private func handleAgentRemoved(_ json: [String: Any]) {
        guard let address = json["address"] as? String else { return }
        let lower = address.lowercased()
        authenticatedAgents.remove(lower)
        if let agentId = addressToAgentId.removeValue(forKey: lower) {
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
        if let body = frame.body, !body.isEmpty {
            request.httpBody = body.data(using: .utf8)
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

    private static func relayStreamingResponse(
        id: String,
        status: Int,
        headers: [String: String],
        contentType: String,
        bytes: URLSession.AsyncBytes,
        via webSocket: URLSessionWebSocketTask?
    ) async {
        sendFrame(RelayStreamStartFrame(id: id, status: status, headers: headers), via: webSocket)

        let isSSE = contentType.contains("text/event-stream")
        var eventBuffer = ""

        do {
            for try await line in bytes.lines {
                if isSSE {
                    if line.isEmpty && !eventBuffer.isEmpty {
                        sendFrame(
                            RelayStreamChunkFrame(id: id, data: eventBuffer + "\n"),
                            via: webSocket
                        )
                        eventBuffer = ""
                    } else if !line.isEmpty {
                        eventBuffer += line + "\n"
                    }
                } else if !line.isEmpty {
                    sendFrame(RelayStreamChunkFrame(id: id, data: line + "\n"), via: webSocket)
                }
            }
        } catch {
            // Stream interrupted — flush what we have and close cleanly
        }

        if !eventBuffer.isEmpty {
            sendFrame(RelayStreamChunkFrame(id: id, data: eventBuffer), via: webSocket)
        }

        sendFrame(RelayStreamEndFrame(id: id), via: webSocket)
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
        sendFrame(
            RelayResponseFrame(
                id: id,
                status: status,
                headers: headers,
                body: String(data: allData, encoding: .utf8) ?? ""
            ),
            via: webSocket
        )
    }

    private static func sendErrorResponse(id: String, error: String, via webSocket: URLSessionWebSocketTask?) {
        sendFrame(
            RelayResponseFrame(
                id: id,
                status: 502,
                headers: ["content-type": "application/json"],
                body: "{\"error\":\"\(error)\"}"
            ),
            via: webSocket
        )
    }

    private static func sendFrame<T: Encodable>(_ frame: T, via webSocket: URLSessionWebSocketTask?) {
        guard let data = try? JSONEncoder().encode(frame),
            let str = String(data: data, encoding: .utf8)
        else { return }
        webSocket?.send(.string(str)) { _ in }
    }

    // MARK: - Mid-Session Agent Management

    private func addAgentToTunnel(agentId: UUID) {
        guard let agent = AgentManager.shared.agent(for: agentId),
            let index = agent.agentIndex,
            let address = agent.agentAddress
        else {
            agentStatuses[agentId] = .error("No identity")
            return
        }

        guard let masterKey = obtainMasterKey() else {
            agentStatuses[agentId] = .error("No identity")
            return
        }

        pendingNonceHandler = { [weak self] nonce in
            guard let self else { return }
            let timestamp = Int(Date().timeIntervalSince1970)
            do {
                let sigHex = try Self.signAgentAuth(
                    address: address,
                    nonce: nonce,
                    timestamp: timestamp,
                    masterKey: masterKey,
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
    }

    // MARK: - Reconnect

    private func handleDisconnect() {
        isConnected = false
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        authenticatedAgents.removeAll()
        addressToAgentId.removeAll()
        pendingNonceHandler = nil

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

    private func obtainMasterKey() -> Data? {
        guard OsaurusIdentity.exists() else { return nil }
        let context = OsaurusIdentityContext.biometric()
        return try? MasterKey.getPrivateKey(context: context)
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
        guard let data = try? JSONSerialization.data(withJSONObject: object),
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
}
