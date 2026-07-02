//
//  AgentChannelTransportRuntime.swift
//  osaurus
//
//  Provider-neutral receive transport runtime primitives.
//

import Foundation

enum AgentChannelTransportStepDisposition: String, Codable, Sendable {
    case skipped
    case succeeded
    case failed
    case conflict
}

struct AgentChannelTransportStepResult: Equatable, Sendable {
    var disposition: AgentChannelTransportStepDisposition
    var health: AgentChannelTransportHealthState
    var received: Int
    var stored: Int
    var dispatchAttempted: Int
    var dispatchSuppressed: Int
    var retryDelay: TimeInterval?

    init(
        disposition: AgentChannelTransportStepDisposition,
        health: AgentChannelTransportHealthState,
        received: Int = 0,
        stored: Int = 0,
        dispatchAttempted: Int = 0,
        dispatchSuppressed: Int = 0,
        retryDelay: TimeInterval? = nil
    ) {
        self.disposition = disposition
        self.health = health
        self.received = max(0, received)
        self.stored = max(0, stored)
        self.dispatchAttempted = max(0, dispatchAttempted)
        self.dispatchSuppressed = max(0, dispatchSuppressed)
        self.retryDelay = retryDelay.map { max(0, $0) }
    }
}

struct AgentChannelTransportBackoffPolicy: Codable, Equatable, Sendable {
    var initialDelay: TimeInterval
    var multiplier: Double
    var maxDelay: TimeInterval
    var jitterFraction: Double

    init(
        initialDelay: TimeInterval = 1,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 60,
        jitterFraction: Double = 0.2
    ) {
        self.initialDelay = max(0, initialDelay)
        self.multiplier = max(1, multiplier)
        self.maxDelay = max(0, maxDelay)
        self.jitterFraction = min(max(jitterFraction, 0), 1)
    }

    func delay(consecutiveFailures: Int, jitter: Double) -> TimeInterval {
        guard maxDelay > 0 else { return 0 }
        let failures = max(1, consecutiveFailures)
        let exponent = min(max(0, failures - 1), 30)
        let exponential = initialDelay * pow(multiplier, Double(exponent))
        let capped = min(maxDelay, max(0, exponential))
        let normalizedJitter = min(max(jitter, 0), 1)
        let jitterScale = 1 + ((normalizedJitter * 2) - 1) * jitterFraction
        return min(maxDelay, max(0, capped * jitterScale))
    }
}

protocol AgentChannelTransportSleeping: Sendable {
    func sleep(for duration: TimeInterval) async throws
}

struct AgentChannelTransportTaskSleeper: AgentChannelTransportSleeping {
    func sleep(for duration: TimeInterval) async throws {
        let clamped = min(max(duration, 0), 3_600)
        guard clamped > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64((clamped * 1_000_000_000).rounded()))
    }
}

protocol AgentChannelReceiveTransportRuntime: Sendable {
    func start(pollInterval: TimeInterval) async
    func stop(now: Date) async
}

actor AgentChannelTransportSupervisor {
    static let shared = AgentChannelTransportSupervisor()

    private let slackConfiguration: @Sendable () -> SlackConnectionConfiguration
    private let slackHasBotToken: @Sendable () -> Bool
    private let slackHasAppToken: @Sendable () -> Bool
    private let slackRuntime: any AgentChannelReceiveTransportRuntime
    private let telegramConfiguration: @Sendable () -> TelegramConnectionConfiguration
    private let telegramHasBotToken: @Sendable () -> Bool
    private let telegramRuntime: any AgentChannelReceiveTransportRuntime
    private var slackStarted = false
    private var telegramStarted = false

    init(
        slackConfiguration: @escaping @Sendable () -> SlackConnectionConfiguration = {
            SlackConnectionService.shared.configuration()
        },
        slackHasBotToken: @escaping @Sendable () -> Bool = {
            SlackConnectionService.shared.hasBotToken()
        },
        slackHasAppToken: @escaping @Sendable () -> Bool = {
            SlackConnectionService.shared.hasAppToken()
        },
        slackRuntime: any AgentChannelReceiveTransportRuntime = SlackSocketModeTransportRuntime(),
        telegramConfiguration: @escaping @Sendable () -> TelegramConnectionConfiguration = {
            TelegramConnectionService.shared.configuration()
        },
        telegramHasBotToken: @escaping @Sendable () -> Bool = {
            TelegramConnectionService.shared.hasBotToken()
        },
        telegramRuntime: any AgentChannelReceiveTransportRuntime = TelegramLongPollTransportRuntime()
    ) {
        self.slackConfiguration = slackConfiguration
        self.slackHasBotToken = slackHasBotToken
        self.slackHasAppToken = slackHasAppToken
        self.slackRuntime = slackRuntime
        self.telegramConfiguration = telegramConfiguration
        self.telegramHasBotToken = telegramHasBotToken
        self.telegramRuntime = telegramRuntime
    }

    func startFromLaunch() async {
        await refreshSlackRuntime()
        await refreshTelegramRuntime()
    }

    func refreshSlackRuntime(now: Date = Date()) async {
        let configuration = slackConfiguration()
        if slackHasBotToken()
            && slackHasAppToken()
            && !configuration.readableChannelIds.isEmpty
            && !configuration.senderAllowlist.isEmpty {
            guard !slackStarted else { return }
            slackStarted = true
            await slackRuntime.start(pollInterval: 1)
            return
        }

        guard slackStarted else { return }
        slackStarted = false
        await slackRuntime.stop(now: now)
    }

    func refreshTelegramRuntime(now: Date = Date()) async {
        let configuration = telegramConfiguration()
        if configuration.receiveStorageEnabled
            && configuration.longPollingEnabled
            && telegramHasBotToken()
            && !configuration.readableChatIds.isEmpty
            && !configuration.senderAllowlist.isEmpty {
            guard !telegramStarted else { return }
            telegramStarted = true
            await telegramRuntime.start(pollInterval: 0)
            return
        }

        guard telegramStarted else { return }
        telegramStarted = false
        await telegramRuntime.stop(now: now)
    }

    func stop(now: Date = Date()) async {
        if slackStarted {
            slackStarted = false
            await slackRuntime.stop(now: now)
        }
        if telegramStarted {
            telegramStarted = false
            await telegramRuntime.stop(now: now)
        }
    }
}
