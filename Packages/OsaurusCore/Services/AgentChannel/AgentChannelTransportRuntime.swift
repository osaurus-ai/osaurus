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
    private let whatsappConfiguration: @Sendable () -> WhatsAppConnectionConfiguration
    private let whatsappHelperAvailable: @Sendable () -> Bool
    private let whatsappRuntime: any AgentChannelReceiveTransportRuntime
    private let emailRuntime: EmailChannelTransportRuntime
    private let extraAccounts: @Sendable (AgentChannelKind) -> [ChannelAccount]
    /// Extra bots and workspaces, by connection id.
    private var accountRuntimes: [String: AccountRuntime] = [:]
    private var observingAccounts = false
    private var slackStarted = false
    private var telegramStarted = false
    private var discordStarted = false
    private var discordPresenceStarted = false
    private var imessageStarted = false
    private var whatsappStarted = false
    private var whatsappMediaSignature = ""

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
        imessageRuntime: any AgentChannelReceiveTransportRuntime = IMessageWatchTransportRuntime(),
        whatsappConfiguration: @escaping @Sendable () -> WhatsAppConnectionConfiguration = {
            WhatsAppConnectionService.shared.configuration()
        },
        whatsappHelperAvailable: @escaping @Sendable () -> Bool = {
            WhatsAppConnectionService.shared.helperAvailable()
        },
        whatsappRuntime: any AgentChannelReceiveTransportRuntime = WhatsAppWatchTransportRuntime(),
        emailRuntime: EmailChannelTransportRuntime = .shared,
        extraAccounts: @escaping @Sendable (AgentChannelKind) -> [ChannelAccount] = { kind in
            ChannelAccounts.accounts(kind: kind).filter { !$0.isPrimary }
        }
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
        self.whatsappConfiguration = whatsappConfiguration
        self.whatsappHelperAvailable = whatsappHelperAvailable
        self.whatsappRuntime = whatsappRuntime
        self.emailRuntime = emailRuntime
        self.extraAccounts = extraAccounts
    }

    func startFromLaunch() async {
        observeAccountChanges()
        await refreshSlackRuntime()
        await refreshTelegramRuntime()
        await refreshDiscordRuntime()
        await refreshIMessageRuntime()
        await refreshWhatsAppRuntime()
        await emailRuntime.observeChanges()
        await emailRuntime.refresh(atLaunch: true)
    }

    /// Mailbox checks follow `email.json`; saving it or editing an account
    /// also refreshes on its own.
    func refreshEmailRuntime() async {
        await emailRuntime.refresh()
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

        await refreshAccountRuntimes(kind: .slack, now: now)
    }

    /// Re-checks every extra account when a bot session or an account's
    /// settings change.
    private func observeAccountChanges() {
        guard !observingAccounts else { return }
        observingAccounts = true
        for name in [Notification.Name.signInSessionsDidChange, .channelAccountSettingsChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.refreshAccountRuntimes() }
            }
        }
    }

    /// Starts each extra account's listener that can run and stops the
    /// rest, including those of removed accounts.
    func refreshAccountRuntimes(now: Date = Date()) async {
        for kind in [AgentChannelKind.discord, .telegram, .slack] {
            await refreshAccountRuntimes(kind: kind, now: now)
        }
    }

    private func refreshAccountRuntimes(kind: AgentChannelKind, now: Date) async {
        let accounts = extraAccounts(kind)
        let prefix = ChannelAccounts.extraPrefix(kind)
        var desired: [String: AccountRuntime.Plan] = [:]
        for account in accounts {
            if let plan = AccountRuntime.plan(for: account) { desired[account.connectionId] = plan }
        }
        for (id, runtime) in accountRuntimes where id.hasPrefix(prefix) {
            if let plan = desired[id], plan == runtime.plan { continue }
            accountRuntimes[id] = nil
            await runtime.stop(now: now)
            if desired[id] == nil { ChannelAccountServices.forget(id) }
        }
        for (id, plan) in desired where accountRuntimes[id] == nil {
            guard let runtime = AccountRuntime.make(connectionId: id, kind: kind, plan: plan) else { continue }
            accountRuntimes[id] = runtime
            await runtime.start()
        }
    }

    /// Temporarily stop the Telegram long-poll runtime so another consumer
    /// (settings discovery issuing its own getUpdates) does not conflict
    /// with it. Resume with `refreshTelegramRuntime()`.
    func suspendTelegramRuntime(
        connectionId: String = TelegramConnectionService.nativeConnectionId, now: Date = Date()
    ) async {
        guard connectionId == TelegramConnectionService.nativeConnectionId else {
            await accountRuntimes.removeValue(forKey: connectionId)?.stop(now: now)
            return
        }
        guard telegramStarted else { return }
        telegramStarted = false
        await telegramRuntime.stop(now: now)
    }

    func refreshTelegramRuntime(now: Date = Date()) async {
        await refreshAccountRuntimes(kind: .telegram, now: now)
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
        await refreshAccountRuntimes(kind: .discord, now: now)
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

    func refreshWhatsAppRuntime(now: Date = Date()) async {
        let configuration = whatsappConfiguration()
        // Media-download parameters bind at `watch.subscribe` time (unlike
        // allowlists, which the session re-reads per event), so a running
        // session must bounce when they change.
        let mediaSignature = "\(configuration.attachmentIngestionEnabled)|\(configuration.maxAttachmentBytes)"
        // Linked-session state is probed inside the runtime's supervision
        // loop (it can change at any time when the phone unlinks); the
        // supervisor only gates on the static preconditions.
        if whatsappHelperAvailable() && configuration.canStartReceive() {
            if whatsappStarted {
                guard mediaSignature != whatsappMediaSignature else { return }
                await whatsappRuntime.stop(now: now)
            }
            whatsappStarted = true
            whatsappMediaSignature = mediaSignature
            await whatsappRuntime.start(pollInterval: 5)
            return
        }
        guard whatsappStarted else { return }
        whatsappStarted = false
        await whatsappRuntime.stop(now: now)
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
        if whatsappStarted {
            whatsappStarted = false
            await whatsappRuntime.stop(now: now)
        }
        await emailRuntime.stop()
        for runtime in accountRuntimes.values {
            await runtime.stop(now: now)
        }
        accountRuntimes.removeAll()
    }
}

/// The listeners of one extra bot or workspace.
private struct AccountRuntime {
    /// What the account can run; a change restarts its listeners.
    struct Plan: Equatable {
        var receive: Bool
        var presence: Bool
        var signature: String
    }

    let plan: Plan
    let receive: (any AgentChannelReceiveTransportRuntime)?
    let presence: DiscordGatewayPresenceRuntime?
    let pollInterval: TimeInterval

    static func plan(for account: ChannelAccount) -> Plan? {
        let id = account.connectionId
        switch account.kind {
        case .discord:
            guard let service = ChannelAccountServices.discord(id), let token = service.savedBotToken() else {
                return nil
            }
            let config = service.configuration()
            let receive = !config.readableChannelIds.isEmpty && !config.senderAllowlist.isEmpty
            return Plan(receive: receive, presence: true, signature: String(token.hashValue))
        case .telegram:
            guard let service = ChannelAccountServices.telegram(id) else { return nil }
            let hasToken = service.hasBotToken()
            guard hasToken else { return nil }
            let receive = service.configuration().canStartLongPolling(hasBotToken: true)
            return receive ? Plan(receive: true, presence: false, signature: "") : nil
        case .slack:
            guard let service = ChannelAccountServices.slack(id), service.hasBotToken(), service.hasAppToken()
            else { return nil }
            let config = service.configuration()
            guard !config.readableChannelIds.isEmpty, !config.senderAllowlist.isEmpty else { return nil }
            return Plan(receive: true, presence: false, signature: "")
        default:
            return nil
        }
    }

    static func make(connectionId: String, kind: AgentChannelKind, plan: Plan) -> AccountRuntime? {
        switch kind {
        case .discord:
            guard let service = ChannelAccountServices.discord(connectionId) else { return nil }
            return AccountRuntime(
                plan: plan,
                receive: plan.receive ? DiscordPollingTransportRuntime(service: service) : nil,
                presence: plan.presence
                    ? DiscordGatewayPresenceRuntime(tokenProvider: { service.savedBotToken() }) : nil,
                pollInterval: 3)
        case .telegram:
            guard let service = ChannelAccountServices.telegram(connectionId) else { return nil }
            return AccountRuntime(
                plan: plan, receive: TelegramLongPollTransportRuntime(service: service), presence: nil,
                pollInterval: 0)
        case .slack:
            guard let service = ChannelAccountServices.slack(connectionId) else { return nil }
            return AccountRuntime(
                plan: plan, receive: SlackSocketModeTransportRuntime(service: service), presence: nil,
                pollInterval: 1)
        default:
            return nil
        }
    }

    func start() async {
        await presence?.start()
        await receive?.start(pollInterval: pollInterval)
    }

    func stop(now: Date) async {
        await receive?.stop(now: now)
        await presence?.stop()
    }
}
