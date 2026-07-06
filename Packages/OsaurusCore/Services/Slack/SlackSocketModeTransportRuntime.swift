//
//  SlackSocketModeTransportRuntime.swift
//  osaurus
//
//  Desktop Slack Socket Mode receive runtime for native Agent Channels.
//

import Foundation

protocol SlackSocketModeWebSocket: Sendable {
    func receiveText() async throws -> String
    func sendText(_ text: String) async throws
    func cancel()
}

protocol SlackSocketModeWebSocketFactory: Sendable {
    func connect(to url: URL) -> any SlackSocketModeWebSocket
}

struct URLSessionSlackSocketModeWebSocketFactory: SlackSocketModeWebSocketFactory {
    private let sessionProvider: @Sendable () -> URLSession

    init(sessionProvider: @escaping @Sendable () -> URLSession = { GlobalProxySettings.sharedSession() }) {
        self.sessionProvider = sessionProvider
    }

    func connect(to url: URL) -> any SlackSocketModeWebSocket {
        URLSessionSlackSocketModeWebSocket(url: url, session: sessionProvider())
    }
}

final class URLSessionSlackSocketModeWebSocket: SlackSocketModeWebSocket, @unchecked Sendable {
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
                        continuation.resume(throwing: SlackSocketModeTransportError.invalidEnvelope)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                @unknown default:
                    continuation.resume(throwing: SlackSocketModeTransportError.invalidEnvelope)
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

enum SlackSocketModeTransportError: LocalizedError, Equatable, Sendable {
    case missingAppToken
    case receiveNotConfigured
    case invalidEnvelope
    case disconnected(String?)

    var errorDescription: String? {
        switch self {
        case .missingAppToken:
            return "Slack Socket Mode app token is not configured."
        case .receiveNotConfigured:
            return "Slack Socket Mode receive requires readable channels and authorized sender IDs."
        case .invalidEnvelope:
            return "Slack Socket Mode envelope could not be decoded."
        case .disconnected(let reason):
            return reason.map { "Slack Socket Mode disconnected: \($0)" }
                ?? "Slack Socket Mode disconnected."
        }
    }
}

struct SlackSocketModeProcessResult: Equatable, Sendable {
    var received: Int
    var stored: Int
    var dispatchSuppressed: Int
}

actor SlackSocketModeTransportRuntime {
    static let transportId = "slack_socket_mode"

    private let service: SlackConnectionService
    private let client: SlackAPIClientProtocol
    private let webSocketFactory: any SlackSocketModeWebSocketFactory
    private let healthCenter: AgentChannelTransportHealthCenter
    private let backoffPolicy: AgentChannelTransportBackoffPolicy
    private let sleeper: any AgentChannelTransportSleeping
    private var worker: Task<Void, Never>?
    private var currentSocket: (any SlackSocketModeWebSocket)?
    private var consecutiveFailures = 0
    private var lastHealth: AgentChannelTransportHealthState

    init(
        service: SlackConnectionService = .shared,
        client: SlackAPIClientProtocol = SlackAPIClient(),
        webSocketFactory: any SlackSocketModeWebSocketFactory = URLSessionSlackSocketModeWebSocketFactory(),
        healthCenter: AgentChannelTransportHealthCenter = .shared,
        backoffPolicy: AgentChannelTransportBackoffPolicy = AgentChannelTransportBackoffPolicy(),
        sleeper: any AgentChannelTransportSleeping = AgentChannelTransportTaskSleeper()
    ) {
        self.service = service
        self.client = client
        self.webSocketFactory = webSocketFactory
        self.healthCenter = healthCenter
        self.backoffPolicy = backoffPolicy
        self.sleeper = sleeper
        self.lastHealth = AgentChannelTransportHealthState(
            connectionId: AgentChannelConnection.nativeSlackConnectionId,
            transportId: Self.transportId,
            provider: .slack,
            status: .idle,
            severity: .info,
            summary: "Slack Socket Mode is idle.",
            isRunning: false,
            receiveEnabled: false
        )
    }

    func health() -> AgentChannelTransportHealthState {
        lastHealth
    }

    func start(pollInterval: TimeInterval = 1) {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.runLoop(pollInterval: pollInterval)
        }
    }

    func stop(now: Date = Date()) async {
        let oldWorker = worker
        worker = nil
        currentSocket?.cancel()
        currentSocket = nil
        oldWorker?.cancel()
        await oldWorker?.value
        consecutiveFailures = 0
        await publish(
            AgentChannelTransportHealthState(
                connectionId: AgentChannelConnection.nativeSlackConnectionId,
                transportId: Self.transportId,
                provider: .slack,
                status: .idle,
                severity: .info,
                summary: "Slack Socket Mode is idle.",
                isRunning: false,
                receiveEnabled: service.hasAppToken(),
                updatedAt: now
            )
        )
    }

    func runStep(
        maxMessages: Int? = nil,
        now: Date = Date(),
        jitter: Double = Double.random(in: 0 ... 1)
    ) async -> AgentChannelTransportStepResult {
        let configuration = service.configuration()
        guard let appToken = service.socketModeAppToken() else {
            consecutiveFailures = 0
            let health = await publish(
                AgentChannelTransportHealthState(
                    connectionId: AgentChannelConnection.nativeSlackConnectionId,
                    transportId: Self.transportId,
                    provider: .slack,
                    status: .disabled,
                    severity: .info,
                    summary: "Slack Socket Mode app token is not configured.",
                    isRunning: false,
                    receiveEnabled: false,
                    updatedAt: now
                )
            )
            return AgentChannelTransportStepResult(disposition: .skipped, health: health)
        }
        guard !configuration.readableChannelIds.isEmpty,
              !configuration.senderAllowlist.isEmpty
        else {
            consecutiveFailures = 0
            let health = await publish(
                AgentChannelTransportHealthState(
                    connectionId: AgentChannelConnection.nativeSlackConnectionId,
                    transportId: Self.transportId,
                    provider: .slack,
                    status: .disabled,
                    severity: .warning,
                    summary: "Slack Socket Mode receive requires readable channels and authorized sender IDs.",
                    isRunning: false,
                    receiveEnabled: true,
                    updatedAt: now
                )
            )
            return AgentChannelTransportStepResult(disposition: .skipped, health: health)
        }

        do {
            try await service.ensureBotIdentity()
            let url = try await client.openSocketModeConnection(appToken: appToken)
            let socket = webSocketFactory.connect(to: url)
            currentSocket = socket
            consecutiveFailures = 0
            _ = await publish(
                AgentChannelTransportHealthState(
                    connectionId: AgentChannelConnection.nativeSlackConnectionId,
                    transportId: Self.transportId,
                    provider: .slack,
                    status: .healthy,
                    severity: .info,
                    summary: "Slack Socket Mode is connected.",
                    isRunning: worker != nil,
                    receiveEnabled: true,
                    lastSuccessAt: now,
                    updatedAt: now
                )
            )

            var received = 0
            var stored = 0
            var suppressed = 0
            while !Task.isCancelled {
                if let maxMessages, received >= maxMessages {
                    break
                }
                let text = try await socket.receiveText()
                let result = try await processEnvelope(text, socket: socket)
                received += result.received
                stored += result.stored
                suppressed += result.dispatchSuppressed
            }
            currentSocket = nil
            let health = await publish(
                AgentChannelTransportHealthState(
                    connectionId: AgentChannelConnection.nativeSlackConnectionId,
                    transportId: Self.transportId,
                    provider: .slack,
                    status: .healthy,
                    severity: .info,
                    summary: "Slack Socket Mode processed inbound events.",
                    isRunning: worker != nil,
                    receiveEnabled: true,
                    lastSuccessAt: now,
                    lastReceivedCount: received,
                    lastStoredCount: stored,
                    dispatchSuppressedCount: suppressed,
                    updatedAt: now
                )
            )
            return AgentChannelTransportStepResult(
                disposition: .succeeded,
                health: health,
                received: received,
                stored: stored,
                dispatchAttempted: 0,
                dispatchSuppressed: suppressed
            )
        } catch is CancellationError {
            currentSocket?.cancel()
            currentSocket = nil
            let health = await publish(lastHealth)
            return AgentChannelTransportStepResult(disposition: .skipped, health: health)
        } catch SlackSocketModeTransportError.disconnected(let reason) where Self.isPlannedRefresh(reason) {
            // Slack periodically asks Socket Mode clients to reconnect
            // (`refresh_requested`). That is routine operation, not a failure:
            // reconnect promptly without a backoff or failure penalty.
            currentSocket?.cancel()
            currentSocket = nil
            consecutiveFailures = 0
            let health = await publish(
                AgentChannelTransportHealthState(
                    connectionId: AgentChannelConnection.nativeSlackConnectionId,
                    transportId: Self.transportId,
                    provider: .slack,
                    status: .healthy,
                    severity: .info,
                    summary: "Slack requested a Socket Mode connection refresh; reconnecting.",
                    isRunning: worker != nil,
                    receiveEnabled: true,
                    lastSuccessAt: now,
                    updatedAt: now
                )
            )
            return AgentChannelTransportStepResult(
                disposition: .succeeded,
                health: health,
                retryDelay: 1
            )
        } catch SlackAPIError.rateLimited(let message, let retryAfter) {
            currentSocket?.cancel()
            currentSocket = nil
            consecutiveFailures += 1
            let backoffDelay = backoffPolicy.delay(consecutiveFailures: consecutiveFailures, jitter: jitter)
            // Honor Slack's Retry-After when it is longer than our computed
            // backoff, bounded to the sleeper's clamp window.
            let delay = min(max(backoffDelay, retryAfter ?? 0), 3_600)
            let health = await publish(
                AgentChannelTransportHealthState(
                    connectionId: AgentChannelConnection.nativeSlackConnectionId,
                    transportId: Self.transportId,
                    provider: .slack,
                    status: .degraded,
                    severity: .warning,
                    summary: "Slack is rate limiting Socket Mode connections.",
                    detail: service.redactSecrets(in: message),
                    isRunning: worker != nil,
                    receiveEnabled: true,
                    lastFailureAt: now,
                    nextRetryAt: now.addingTimeInterval(delay),
                    consecutiveFailures: consecutiveFailures,
                    updatedAt: now
                )
            )
            return AgentChannelTransportStepResult(
                disposition: .failed,
                health: health,
                retryDelay: delay
            )
        } catch {
            currentSocket?.cancel()
            currentSocket = nil
            consecutiveFailures += 1
            let delay = backoffPolicy.delay(consecutiveFailures: consecutiveFailures, jitter: jitter)
            let health = await publish(
                AgentChannelTransportHealthState(
                    connectionId: AgentChannelConnection.nativeSlackConnectionId,
                    transportId: Self.transportId,
                    provider: .slack,
                    status: .failed,
                    severity: .warning,
                    summary: "Slack Socket Mode receive failed.",
                    detail: service.redactSecrets(in: error.localizedDescription),
                    isRunning: worker != nil,
                    receiveEnabled: true,
                    lastFailureAt: now,
                    nextRetryAt: now.addingTimeInterval(delay),
                    consecutiveFailures: consecutiveFailures,
                    updatedAt: now
                )
            )
            return AgentChannelTransportStepResult(
                disposition: .failed,
                health: health,
                retryDelay: delay
            )
        }
    }

    func processEnvelope(
        _ text: String,
        socket: any SlackSocketModeWebSocket
    ) async throws -> SlackSocketModeProcessResult {
        guard let data = text.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SlackSocketModeTransportError.invalidEnvelope
        }

        if envelope["type"] as? String == "disconnect" {
            throw SlackSocketModeTransportError.disconnected(envelope["reason"] as? String)
        }

        let envelopeId = envelope["envelope_id"] as? String

        guard let payloadObject = envelope["payload"],
              JSONSerialization.isValidJSONObject(payloadObject),
              let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject)
        else {
            try await acknowledge(envelopeId, socket: socket)
            return SlackSocketModeProcessResult(received: 0, stored: 0, dispatchSuppressed: 0)
        }

        guard let slackEnvelope = try? JSONDecoder().decode(SlackEventEnvelope.self, from: payloadData) else {
            try await acknowledge(envelopeId, socket: socket)
            return SlackSocketModeProcessResult(received: 1, stored: 0, dispatchSuppressed: 0)
        }

        // Store before acking so a persistence failure leaves the envelope
        // un-acked and Slack redelivers it; event-id dedupe absorbs retries
        // of envelopes that were stored but whose ack did not reach Slack.
        let stored = try service.recordInboundEvent(slackEnvelope) != nil ? 1 : 0
        try await acknowledge(envelopeId, socket: socket)
        return SlackSocketModeProcessResult(
            received: 1,
            stored: stored,
            dispatchSuppressed: stored
        )
    }

    private func acknowledge(
        _ envelopeId: String?,
        socket: any SlackSocketModeWebSocket
    ) async throws {
        guard let envelopeId = envelopeId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !envelopeId.isEmpty
        else { return }
        try await socket.sendText(Self.ackPayload(envelopeId: envelopeId))
    }

    private func runLoop(pollInterval: TimeInterval) async {
        while !Task.isCancelled {
            let result = await runStep()
            let delay = max(result.retryDelay ?? pollInterval, 1)
            do {
                try await sleeper.sleep(for: delay)
            } catch {
                break
            }
        }
    }

    @discardableResult
    private func publish(_ health: AgentChannelTransportHealthState) async -> AgentChannelTransportHealthState {
        lastHealth = health
        await healthCenter.update(health)
        return health
    }

    private static func isPlannedRefresh(_ reason: String?) -> Bool {
        reason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "refresh_requested"
    }

    private static func ackPayload(envelopeId: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["envelope_id": envelopeId],
            options: .sortedKeys
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw SlackSocketModeTransportError.invalidEnvelope
        }
        return text
    }
}

extension SlackSocketModeTransportRuntime: AgentChannelReceiveTransportRuntime {}
