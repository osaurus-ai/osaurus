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
    private let discordConfiguration: @Sendable () -> DiscordConnectionConfiguration
    private let discordHasBotToken: @Sendable () -> Bool
    private let discordRuntime: any AgentChannelReceiveTransportRuntime
    private let discordPresenceRuntime: any DiscordGatewayPresenceMaintaining
    private let imessageConfiguration: @Sendable () -> IMessageConnectionConfiguration
    private let imessageHelperAvailable: @Sendable () -> Bool
    private let imessageRuntime: any AgentChannelReceiveTransportRuntime
    private var additionalSlackRuntimes: [String: SlackSocketModeTransportRuntime] = [:]
    private var slackStarted = false
    private var telegramStarted = false
    private var discordStarted = false
    private var discordPresenceStarted = false
    private var imessageStarted = false

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
        telegramRuntime: any AgentChannelReceiveTransportRuntime = TelegramLongPollTransportRuntime(),
        discordConfiguration: @escaping @Sendable () -> DiscordConnectionConfiguration = {
            DiscordConnectionService.shared.configuration()
        },
        discordHasBotToken: @escaping @Sendable () -> Bool = {
            DiscordConnectionService.shared.hasBotToken()
        },
        discordRuntime: any AgentChannelReceiveTransportRuntime = DiscordPollingTransportRuntime(),
        discordPresenceRuntime: any DiscordGatewayPresenceMaintaining = DiscordGatewayPresenceRuntime(),
        imessageConfiguration: @escaping @Sendable () -> IMessageConnectionConfiguration = {
            IMessageConnectionService.shared.configuration()
        },
        imessageHelperAvailable: @escaping @Sendable () -> Bool = {
            IMessageConnectionService.shared.helperAvailable()
        },
        imessageRuntime: any AgentChannelReceiveTransportRuntime = IMessageWatchTransportRuntime()
    ) {
        self.slackConfiguration = slackConfiguration
        self.slackHasBotToken = slackHasBotToken
        self.slackHasAppToken = slackHasAppToken
        self.slackRuntime = slackRuntime
        self.telegramConfiguration = telegramConfiguration
        self.telegramHasBotToken = telegramHasBotToken
        self.telegramRuntime = telegramRuntime
        self.discordConfiguration = discordConfiguration
        self.discordHasBotToken = discordHasBotToken
        self.discordRuntime = discordRuntime
        self.discordPresenceRuntime = discordPresenceRuntime
        self.imessageConfiguration = imessageConfiguration
        self.imessageHelperAvailable = imessageHelperAvailable
        self.imessageRuntime = imessageRuntime
    }

    func startFromLaunch() async {
        await refreshSlackRuntime()
        await refreshTelegramRuntime()
        await refreshDiscordRuntime()
        await refreshIMessageRuntime()
    }

    func refreshSlackRuntime(now: Date = Date()) async {
        let configuration = slackConfiguration()
        if slackHasBotToken()
            && slackHasAppToken()
            && !configuration.readableChannelIds.isEmpty
            && !configuration.senderAllowlist.isEmpty {
            if !slackStarted {
                slackStarted = true
                await slackRuntime.start(pollInterval: 1)
            }
        } else if slackStarted {
            slackStarted = false
            await slackRuntime.stop(now: now)
        }

        await refreshAdditionalSlackRuntimes(configuration: configuration, now: now)
    }

    private func refreshAdditionalSlackRuntimes(
        configuration: SlackConnectionConfiguration,
        now: Date
    ) async {
        let desired = Set<String>(configuration.workspaceAccounts.compactMap { account in
            guard !account.readableChannelIds.isEmpty,
                  !account.senderAllowlist.isEmpty,
                  SlackConnectionService.shared.socketModeAppToken(teamId: account.teamId) != nil
            else { return nil }
            return account.teamId
        })
        for teamId in additionalSlackRuntimes.keys where !desired.contains(teamId) {
            if let runtime = additionalSlackRuntimes.removeValue(forKey: teamId) {
                await runtime.stop(now: now)
            }
        }
        for teamId in desired where additionalSlackRuntimes[teamId] == nil {
            let runtime = SlackSocketModeTransportRuntime(teamId: teamId)
            additionalSlackRuntimes[teamId] = runtime
            await runtime.start(pollInterval: 1)
        }
    }

    /// Temporarily stop the Telegram long-poll runtime so another consumer
    /// (settings discovery issuing its own getUpdates) does not conflict
    /// with it. Resume with `refreshTelegramRuntime()`.
    func suspendTelegramRuntime(now: Date = Date()) async {
        guard telegramStarted else { return }
        telegramStarted = false
        await telegramRuntime.stop(now: now)
    }

    func refreshTelegramRuntime(now: Date = Date()) async {
        let configuration = telegramConfiguration()
        if configuration.canStartLongPolling(hasBotToken: telegramHasBotToken()) {
            guard !telegramStarted else { return }
            telegramStarted = true
            await telegramRuntime.start(pollInterval: 0)
            return
        }

        guard telegramStarted else { return }
        telegramStarted = false
        await telegramRuntime.stop(now: now)
    }

    func refreshDiscordRuntime(now: Date = Date()) async {
        let configuration = discordConfiguration()
        // Platform presence only needs the bot token — a send-only Discord
        // setup should still show the bot online while Osaurus runs.
        if discordHasBotToken() {
            if !discordPresenceStarted {
                discordPresenceStarted = true
                await discordPresenceRuntime.start()
            }
        } else if discordPresenceStarted {
            discordPresenceStarted = false
            await discordPresenceRuntime.stop()
        }
        if discordHasBotToken()
            && !configuration.readableChannelIds.isEmpty
            && !configuration.senderAllowlist.isEmpty {
            guard !discordStarted else { return }
            discordStarted = true
            await discordRuntime.start(pollInterval: 3)
            return
        }
        guard discordStarted else { return }
        discordStarted = false
        await discordRuntime.stop(now: now)
    }

    func refreshIMessageRuntime(now: Date = Date()) async {
        let configuration = imessageConfiguration()
        if imessageHelperAvailable() && configuration.canStartReceive() {
            guard !imessageStarted else { return }
            imessageStarted = true
            await imessageRuntime.start(pollInterval: TimeInterval(configuration.pollIntervalSeconds))
            return
        }
        guard imessageStarted else { return }
        imessageStarted = false
        await imessageRuntime.stop(now: now)
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
        if discordStarted {
            discordStarted = false
            await discordRuntime.stop(now: now)
        }
        if discordPresenceStarted {
            discordPresenceStarted = false
            await discordPresenceRuntime.stop()
        }
        if imessageStarted {
            imessageStarted = false
            await imessageRuntime.stop(now: now)
        }
        for runtime in additionalSlackRuntimes.values {
            await runtime.stop(now: now)
        }
        additionalSlackRuntimes.removeAll()
    }
}
