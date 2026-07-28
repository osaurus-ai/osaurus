//
//  DiscordGatewayPresenceRuntime.swift
//  osaurus
//
//  Presence-only Discord Gateway session.
//
//  Discord shows a bot as online only while an identified Gateway WebSocket
//  is heartbeating; the REST polling receive path never opens one, so the bot
//  looked permanently offline even when receive was healthy. This runtime
//  opens a minimal intents-0 session whose sole job is to set the bot's
//  presence to `online` while Osaurus runs. It receives no message events —
//  inbound messages keep flowing through `DiscordPollingTransportRuntime` —
//  and it deliberately does not publish transport health: platform presence
//  is cosmetic and must not be conflated with receive diagnostics.
//

import Foundation

// MARK: - WebSocket abstraction

protocol DiscordGatewayWebSocket: Sendable {
    func receiveText() async throws -> String
    func sendText(_ text: String) async throws
    func cancel()
}

protocol DiscordGatewayWebSocketFactory: Sendable {
    func connect(to url: URL) -> any DiscordGatewayWebSocket
}

struct URLSessionDiscordGatewayWebSocketFactory: DiscordGatewayWebSocketFactory {
    private let sessionProvider: @Sendable () -> URLSession

    init(sessionProvider: @escaping @Sendable () -> URLSession = { GlobalProxySettings.sharedSession() }) {
        self.sessionProvider = sessionProvider
    }

    func connect(to url: URL) -> any DiscordGatewayWebSocket {
        URLSessionDiscordGatewayWebSocket(url: url, session: sessionProvider())
    }
}

final class URLSessionDiscordGatewayWebSocket: DiscordGatewayWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession) {
        self.task = session.webSocketTask(with: url)
        self.task.resume()
    }

    func receiveText() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            task.receive { result in
                switch result {
                case .success(.string(let text)):
                    continuation.resume(returning: text)
                case .success(.data(let data)):
                    if let text = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: DiscordGatewayPresenceError.invalidPayload)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                @unknown default:
                    continuation.resume(throwing: DiscordGatewayPresenceError.invalidPayload)
                }
            }
        }
    }

    func sendText(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.send(.string(text)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

// MARK: - Errors and payload model

enum DiscordGatewayPresenceError: LocalizedError, Equatable, Sendable {
    case missingBotToken
    case invalidPayload
    case helloExpected
    case reconnectRequested
    case invalidSession

    var errorDescription: String? {
        switch self {
        case .missingBotToken:
            return "Discord bot token is not configured."
        case .invalidPayload:
            return "Discord Gateway payload could not be decoded."
        case .helloExpected:
            return "Discord Gateway did not open with a Hello payload."
        case .reconnectRequested:
            return "Discord requested a Gateway reconnect."
        case .invalidSession:
            return "Discord invalidated the Gateway session."
        }
    }
}

struct DiscordGatewayInboundPayload: Equatable, Sendable {
    var opcode: Int
    var sequence: Int?
    var heartbeatIntervalMs: Int?
}

/// Lifecycle surface the transport supervisor drives. Kept minimal so tests
/// can substitute a spy without a WebSocket.
protocol DiscordGatewayPresenceMaintaining: Sendable {
    func start() async
    func stop() async
}

// MARK: - Runtime

actor DiscordGatewayPresenceRuntime: DiscordGatewayPresenceMaintaining {
    static let transportId = "discord_gateway_presence"

    private let client: DiscordAPIClientProtocol
    private let tokenProvider: @Sendable () -> String?
    private let webSocketFactory: any DiscordGatewayWebSocketFactory
    private let backoffPolicy: AgentChannelTransportBackoffPolicy
    private let sleeper: any AgentChannelTransportSleeping
    private var worker: Task<Void, Never>?
    private var heartbeatWorker: Task<Void, Never>?
    private var currentSocket: (any DiscordGatewayWebSocket)?
    private var consecutiveFailures = 0
    private var lastSequence: Int?

    init(
        client: DiscordAPIClientProtocol = DiscordAPIClient(),
        tokenProvider: @escaping @Sendable () -> String? = {
            KeychainDiscordCredentialStorage().botToken()
        },
        webSocketFactory: any DiscordGatewayWebSocketFactory = URLSessionDiscordGatewayWebSocketFactory(),
        backoffPolicy: AgentChannelTransportBackoffPolicy = AgentChannelTransportBackoffPolicy(),
        sleeper: any AgentChannelTransportSleeping = AgentChannelTransportTaskSleeper()
    ) {
        self.client = client
        self.tokenProvider = tokenProvider
        self.webSocketFactory = webSocketFactory
        self.backoffPolicy = backoffPolicy
        self.sleeper = sleeper
    }

    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() async {
        let oldWorker = worker
        worker = nil
        stopHeartbeats()
        currentSocket?.cancel()
        currentSocket = nil
        oldWorker?.cancel()
        await oldWorker?.value
        consecutiveFailures = 0
        lastSequence = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let delay = await runSession()
            do {
                try await sleeper.sleep(for: delay)
            } catch {
                break
            }
        }
    }

    /// Runs one Gateway session until it disconnects, then returns the delay
    /// to wait before reconnecting. `maxEvents` lets tests bound the receive
    /// loop; production passes nil and stays connected until an error, a
    /// server-side reconnect request, or `stop()`.
    @discardableResult
    func runSession(
        maxEvents: Int? = nil,
        jitter: Double = Double.random(in: 0 ... 1)
    ) async -> TimeInterval {
        guard let token = tokenProvider() else {
            consecutiveFailures = 0
            return 60
        }
        do {
            let url = try await client.gatewayURL(token: token)
            let socket = webSocketFactory.connect(to: url)
            currentSocket = socket

            // The first payload must be Hello (op 10) with the heartbeat cadence.
            let hello = try Self.decodePayload(try await socket.receiveText())
            guard hello.opcode == 10, let intervalMs = hello.heartbeatIntervalMs, intervalMs > 0 else {
                throw DiscordGatewayPresenceError.helloExpected
            }

            try await socket.sendText(Self.identifyPayload(token: token))
            consecutiveFailures = 0
            startHeartbeats(socket: socket, intervalMs: intervalMs)

            var events = 0
            while !Task.isCancelled {
                if let maxEvents, events >= maxEvents { break }
                let payload = try Self.decodePayload(try await socket.receiveText())
                events += 1
                switch payload.opcode {
                case 0:
                    if let sequence = payload.sequence {
                        lastSequence = sequence
                    }
                case 1:
                    // Server-requested immediate heartbeat.
                    try await socket.sendText(Self.heartbeatPayload(sequence: lastSequence))
                case 7:
                    throw DiscordGatewayPresenceError.reconnectRequested
                case 9:
                    throw DiscordGatewayPresenceError.invalidSession
                default:
                    break  // Heartbeat ACK (11) and anything else needs no action.
                }
            }
            teardownSession()
            return 1
        } catch DiscordGatewayPresenceError.reconnectRequested,
                DiscordGatewayPresenceError.invalidSession {
            // Routine server-side session recycling — reconnect promptly
            // without a failure penalty.
            teardownSession()
            consecutiveFailures = 0
            lastSequence = nil
            return 1
        } catch is CancellationError {
            teardownSession()
            return 1
        } catch {
            teardownSession()
            consecutiveFailures += 1
            return backoffPolicy.delay(consecutiveFailures: consecutiveFailures, jitter: jitter)
        }
    }

    private func teardownSession() {
        stopHeartbeats()
        currentSocket?.cancel()
        currentSocket = nil
    }

    private func startHeartbeats(socket: any DiscordGatewayWebSocket, intervalMs: Int) {
        stopHeartbeats()
        let interval = Double(intervalMs) / 1_000
        let sleeper = self.sleeper
        heartbeatWorker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleeper.sleep(for: interval)
                    guard let self else { return }
                    try await socket.sendText(Self.heartbeatPayload(sequence: await self.lastSequence))
                } catch {
                    return
                }
            }
        }
    }

    private func stopHeartbeats() {
        heartbeatWorker?.cancel()
        heartbeatWorker = nil
    }

    // MARK: - Payloads

    static func decodePayload(_ text: String) throws -> DiscordGatewayInboundPayload {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let opcode = object["op"] as? Int
        else {
            throw DiscordGatewayPresenceError.invalidPayload
        }
        let inner = object["d"] as? [String: Any]
        return DiscordGatewayInboundPayload(
            opcode: opcode,
            sequence: object["s"] as? Int,
            heartbeatIntervalMs: inner?["heartbeat_interval"] as? Int
        )
    }

    static func identifyPayload(token: String) throws -> String {
        // Intents 0: this session receives no guild/message events at all.
        // Presence rides on the identify payload so the bot is online from
        // the first heartbeat.
        let payload: [String: Any] = [
            "op": 2,
            "d": [
                "token": token,
                "intents": 0,
                "properties": [
                    "os": "macos",
                    "browser": "osaurus",
                    "device": "osaurus",
                ],
                "presence": [
                    "status": "online",
                    "since": NSNull(),
                    "activities": [] as [Any],
                    "afk": false,
                ],
            ],
        ]
        return try encode(payload)
    }

    static func heartbeatPayload(sequence: Int?) throws -> String {
        try encode(["op": 1, "d": sequence.map { $0 as Any } ?? NSNull()])
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DiscordGatewayPresenceError.invalidPayload
        }
        return text
    }
}
