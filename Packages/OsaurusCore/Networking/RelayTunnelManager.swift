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

        guard OsaurusIdentity.exists() else {
            for agent in agents { agentStatuses[agent.id] = .error("No identity") }
            return
        }

        let context = OsaurusIdentityContext.biometric()
        let masterKey: Data
        do {
            masterKey = try MasterKey.getPrivateKey(context: context)
        } catch {
            for agent in agents { agentStatuses[agent.id] = .error("Auth failed") }
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        var authAgents: [[String: Any]] = []

        for agent in agents {
            guard let index = agent.agentIndex, let address = agent.agentAddress else { continue }
            let message = "osaurus-tunnel:\(address):\(timestamp)"
            do {
                let childKey = AgentKey.derive(masterKey: masterKey, index: index)
                let sig = try signEIP191Message(message, privateKey: childKey)
                let sigHex = "0x" + sig.hexEncodedString
                authAgents.append(["address": address, "signature": sigHex])
            } catch {
                agentStatuses[agent.id] = .error("Signing failed")
            }
        }

        guard !authAgents.isEmpty else { return }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: Self.relayURL)
        self.urlSession = session
        self.webSocketTask = task
        task.resume()

        let authFrame: [String: Any] = [
            "type": "auth",
            "agents": authAgents,
            "timestamp": timestamp,
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: authFrame)
            try await task.send(.string(String(data: data, encoding: .utf8)!))
        } catch {
            handleDisconnect()
            return
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
            guard let responseStr = await Self.proxyRequest(frame, localPort: port, agentUUID: agentUUID) else {
                return
            }
            ws?.send(.string(responseStr)) { _ in }
        }
    }

    /// Resolve an agent crypto address to its UUID string via the pre-built lookup table.
    private func resolveAgentId(for address: String?) -> String? {
        guard let address else { return nil }
        guard let uuid = addressToAgentId[address.lowercased()] else { return nil }
        return uuid.uuidString
    }

    /// Proxy a relay request frame to the local Osaurus server and produce the JSON response string.
    /// Runs entirely off @MainActor -- no instance state is accessed.
    private static func proxyRequest(
        _ frame: RelayRequestFrame,
        localPort: Int,
        agentUUID: String?
    ) async -> String? {
        guard let localURL = URL(string: "http://127.0.0.1:\(localPort)\(frame.path)") else {
            return encodeResponse(
                RelayResponseFrame(
                    id: frame.id,
                    status: 502,
                    headers: ["content-type": "application/json"],
                    body: "{\"error\":\"invalid_path\"}"
                )
            )
        }

        var request = URLRequest(url: localURL)
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

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 502

            var responseHeaders: [String: String] = [:]
            if let allHeaders = httpResponse?.allHeaderFields {
                for (key, value) in allHeaders {
                    responseHeaders[String(describing: key).lowercased()] = String(describing: value)
                }
            }

            return encodeResponse(
                RelayResponseFrame(
                    id: frame.id,
                    status: status,
                    headers: responseHeaders,
                    body: String(data: data, encoding: .utf8) ?? ""
                )
            )
        } catch {
            return encodeResponse(
                RelayResponseFrame(
                    id: frame.id,
                    status: 502,
                    headers: ["content-type": "application/json"],
                    body: "{\"error\":\"local_server_error\"}"
                )
            )
        }
    }

    private static func encodeResponse(_ frame: RelayResponseFrame) -> String? {
        guard let data = try? JSONEncoder().encode(frame) else { return nil }
        return String(data: data, encoding: .utf8)
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

        guard OsaurusIdentity.exists() else {
            agentStatuses[agentId] = .error("No identity")
            return
        }

        let context = OsaurusIdentityContext.biometric()
        let masterKey: Data
        do {
            masterKey = try MasterKey.getPrivateKey(context: context)
        } catch {
            agentStatuses[agentId] = .error("Auth failed")
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let message = "osaurus-tunnel:\(address):\(timestamp)"
        do {
            let childKey = AgentKey.derive(masterKey: masterKey, index: index)
            let sig = try signEIP191Message(message, privateKey: childKey)
            let sigHex = "0x" + sig.hexEncodedString

            let frame: [String: Any] = [
                "type": "add_agent",
                "address": address,
                "signature": sigHex,
                "timestamp": timestamp,
            ]
            sendJSON(frame)
        } catch {
            agentStatuses[agentId] = .error("Signing failed")
        }
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
