//
//  DiscordGatewayPresenceRuntimeTests.swift
//  osaurusTests
//
//  Injected-WebSocket coverage for the presence-only Discord Gateway session:
//  identify, heartbeat, reconnect, backoff, and shutdown behavior.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct DiscordGatewayPresenceRuntimeTests {

    private static let hello = #"{"op":10,"d":{"heartbeat_interval":45000}}"#

    // MARK: - Payload decoding and encoding

    @Test func decodePayloadReadsOpcodeSequenceAndHeartbeatInterval() throws {
        let hello = try DiscordGatewayPresenceRuntime.decodePayload(Self.hello)
        #expect(hello == DiscordGatewayInboundPayload(opcode: 10, sequence: nil, heartbeatIntervalMs: 45_000))

        let dispatch = try DiscordGatewayPresenceRuntime.decodePayload(#"{"op":0,"s":42,"t":"READY","d":{}}"#)
        #expect(dispatch.opcode == 0)
        #expect(dispatch.sequence == 42)

        #expect(throws: DiscordGatewayPresenceError.invalidPayload) {
            _ = try DiscordGatewayPresenceRuntime.decodePayload("not json")
        }
    }

    @Test func identifyPayloadCarriesTokenZeroIntentsAndOnlinePresence() throws {
        let text = try DiscordGatewayPresenceRuntime.identifyPayload(token: "bot-token-123")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        #expect(object["op"] as? Int == 2)
        let inner = try #require(object["d"] as? [String: Any])
        #expect(inner["token"] as? String == "bot-token-123")
        #expect(inner["intents"] as? Int == 0)
        let presence = try #require(inner["presence"] as? [String: Any])
        #expect(presence["status"] as? String == "online")
        #expect(presence["afk"] as? Bool == false)
    }

    @Test func heartbeatPayloadEncodesSequenceOrNull() throws {
        #expect(try DiscordGatewayPresenceRuntime.heartbeatPayload(sequence: nil) == #"{"d":null,"op":1}"#)
        #expect(try DiscordGatewayPresenceRuntime.heartbeatPayload(sequence: 7) == #"{"d":7,"op":1}"#)
    }

    // MARK: - Session behavior

    @Test func sessionIdentifiesAsOnlineAfterHello() async throws {
        let socket = FakeGatewaySocket(scripted: [Self.hello])
        let runtime = makeRuntime(sockets: [socket])

        let delay = await runtime.runSession(maxEvents: 0, jitter: 0)

        #expect(delay == 1)
        let sent = socket.sentTexts
        #expect(sent.count == 1)
        let identify = try #require(
            try JSONSerialization.jsonObject(with: Data(sent[0].utf8)) as? [String: Any]
        )
        #expect(identify["op"] as? Int == 2)
        #expect(socket.wasCancelled)
    }

    @Test func serverHeartbeatRequestGetsImmediateReplyWithLastSequence() async throws {
        let socket = FakeGatewaySocket(scripted: [
            Self.hello,
            #"{"op":0,"s":7,"t":"READY","d":{}}"#,
            #"{"op":1}"#,
        ])
        let runtime = makeRuntime(sockets: [socket])

        _ = await runtime.runSession(maxEvents: 2, jitter: 0)

        let sent = socket.sentTexts
        #expect(sent.count == 2)
        #expect(sent[1] == #"{"d":7,"op":1}"#)
    }

    @Test func reconnectRequestReconnectsPromptlyWithoutFailurePenalty() async throws {
        let socket = FakeGatewaySocket(scripted: [Self.hello, #"{"op":7}"#])
        let runtime = makeRuntime(sockets: [socket])

        let delay = await runtime.runSession(jitter: 1)

        #expect(delay == 1)
        #expect(socket.wasCancelled)
    }

    @Test func repeatedFailuresBackOffExponentially() async throws {
        // Neither socket opens with Hello, so both sessions fail.
        let runtime = makeRuntime(sockets: [
            FakeGatewaySocket(scripted: [#"{"op":11}"#]),
            FakeGatewaySocket(scripted: [#"{"op":11}"#]),
        ])

        let first = await runtime.runSession(jitter: 0.5)
        let second = await runtime.runSession(jitter: 0.5)

        #expect(first >= 1)
        #expect(second > first)
    }

    @Test func missingBotTokenSkipsConnectingEntirely() async throws {
        let factory = FakeGatewaySocketFactory(sockets: [])
        let runtime = DiscordGatewayPresenceRuntime(
            client: FakeGatewayAPIClient(),
            tokenProvider: { nil },
            webSocketFactory: factory,
            sleeper: HangingSleeper()
        )

        let delay = await runtime.runSession(jitter: 0)

        #expect(delay == 60)
        #expect(factory.connectCount == 0)
    }

    @Test func stopCancelsSocketHeartbeatsAndWorker() async throws {
        // After Hello the socket hangs on receive, like a live idle Gateway.
        let socket = FakeGatewaySocket(scripted: [Self.hello], hangWhenDrained: true)
        let runtime = makeRuntime(sockets: [socket])

        await runtime.start()
        // Give the session a moment to connect and identify.
        for _ in 0 ..< 200 where socket.sentTexts.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(socket.sentTexts.count == 1)

        await runtime.stop()

        #expect(socket.wasCancelled)
    }

    // MARK: - Fixtures

    private func makeRuntime(sockets: [FakeGatewaySocket]) -> DiscordGatewayPresenceRuntime {
        DiscordGatewayPresenceRuntime(
            client: FakeGatewayAPIClient(),
            tokenProvider: { "discord-bot-token-super-secret" },
            webSocketFactory: FakeGatewaySocketFactory(sockets: sockets),
            sleeper: HangingSleeper()
        )
    }
}

/// Sleeper that parks until cancelled, so heartbeat/reconnect timers never
/// fire on their own during tests.
private struct HangingSleeper: AgentChannelTransportSleeping {
    func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}

private final class FakeGatewaySocket: DiscordGatewayWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [String]
    private var sent: [String] = []
    private var cancelled = false
    private let hangWhenDrained: Bool

    init(scripted: [String], hangWhenDrained: Bool = false) {
        self.scripted = scripted
        self.hangWhenDrained = hangWhenDrained
    }

    func receiveText() async throws -> String {
        let next: String? = lock.withLock {
            scripted.isEmpty ? nil : scripted.removeFirst()
        }
        if let next { return next }
        if hangWhenDrained {
            // Mimics an idle Gateway; only cancellation ends the wait.
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
        throw URLError(.networkConnectionLost)
    }

    func sendText(_ text: String) async throws {
        lock.withLock { sent.append(text) }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var sentTexts: [String] { lock.withLock { sent } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
}

private final class FakeGatewaySocketFactory: DiscordGatewayWebSocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [FakeGatewaySocket]
    private var connects = 0

    init(sockets: [FakeGatewaySocket]) {
        self.sockets = sockets
    }

    func connect(to url: URL) -> any DiscordGatewayWebSocket {
        lock.withLock {
            connects += 1
            guard !sockets.isEmpty else {
                return FakeGatewaySocket(scripted: [])
            }
            return sockets.removeFirst()
        }
    }

    var connectCount: Int { lock.withLock { connects } }
}

private struct FakeGatewayAPIClient: DiscordAPIClientProtocol {
    func currentUser(token: String) async throws -> DiscordBotIdentity {
        DiscordBotIdentity(id: "1", username: "bot", globalName: "Bot", bot: true)
    }

    func gatewayURL(token: String) async throws -> URL {
        URL(string: "wss://gateway.test/?v=10&encoding=json")!
    }

    func guild(id: String, token: String) async throws -> DiscordGuild {
        throw DiscordAPIError.invalidResponse("not used")
    }

    func channels(guildId: String, token: String) async throws -> [DiscordChannel] {
        throw DiscordAPIError.invalidResponse("not used")
    }

    func messages(channelId: String, token: String, limit: Int) async throws -> [DiscordMessage] {
        throw DiscordAPIError.invalidResponse("not used")
    }

    func sendMessage(channelId: String, content: String, token: String) async throws -> DiscordMessage {
        throw DiscordAPIError.invalidResponse("not used")
    }
}
