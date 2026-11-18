//
//  EmailChannelTransportRuntime.swift
//  osaurus
//
//  Checks the Email channel's watched mailboxes. Each account + mailbox is
//  one poll scope (`emailchannel:<account id>:<mailbox>`) on a
//  `SourceRuntimeSupervisor`, read through the same fetchers automations
//  used (`MailboxFetcherFactory`): IMAP with a `{uidvalidity, last_uid}`
//  cursor, Mail with the newest received date. A check hands the new mail
//  to `EmailChannelService.ingest` and only then commits the cursor, so a
//  failed ingest is checked again and the Message-ID dedupe keeps it from
//  being answered twice.
//
//  A mailbox added while the app runs starts at its newest message. At
//  launch the saved cursor is kept and the account's catch-up policy
//  decides what happens to mail that arrived while the app was closed.
//  An account problem that would fail the same way again (refused sign-in,
//  no password) pauses that account's checks until it is edited, the
//  channel is saved, or Check Now.
//

import Foundation
import os

actor EmailChannelTransportRuntime {
    static let shared = EmailChannelTransportRuntime()
    static let transportId = "email_poll"
    static let ownerPrefix = "emailchannel:"

    /// The last Mail check was refused Automation permission (AppleScript
    /// -1743); read by diagnostics.
    private static let automationDeniedFlag = OSAllocatedUnfairLock(initialState: false)
    nonisolated static var lastAutomationDenied: Bool { automationDeniedFlag.withLock { $0 } }

    private struct Scope {
        var account: EmailChannelAccount
        var mailbox: String
    }

    private let service: EmailChannelService
    private let health: AgentChannelTransportHealthCenter
    private let makeFetcher: @Sendable (SourceConnection) -> (any MailboxFetching)?
    private let loadState: @Sendable (String) async -> JSONValue?
    private let saveState: @Sendable (JSONValue?, String) async -> Void
    private let awaitReady: @Sendable () async -> Void
    private var supervisor: SourceRuntimeSupervisor?

    private var scopes: [String: Scope] = [:]
    /// Scopes paused by an account problem, with the reason.
    private var halted: [String: String] = [:]
    /// Conditions that block a check without being a failure (Mail closed).
    private var waiting: [String: String] = [:]
    private var failures: [String: Int] = [:]
    private var lastCounts: [String: AgentChannelReceiveBatchSummary] = [:]
    private var started = false
    private var observers: [NSObjectProtocol] = []

    init(
        service: EmailChannelService = .shared,
        health: AgentChannelTransportHealthCenter = .shared,
        makeFetcher: @escaping @Sendable (SourceConnection) -> (any MailboxFetching)? = {
            MailboxFetcherFactory.fetcher(for: $0)
        },
        loadState: @escaping @Sendable (String) async -> JSONValue? = { scope in
            await EventManager.shared.sourceState(scope: scope)
        },
        saveState: @escaping @Sendable (JSONValue?, String) async -> Void = { state, scope in
            await EventManager.shared.setSourceState(state, scope: scope)
        },
        awaitReady: @escaping @Sendable () async -> Void = { await EventManager.shared.awaitLoaded() }
    ) {
        self.service = service
        self.health = health
        self.makeFetcher = makeFetcher
        self.loadState = loadState
        self.saveState = saveState
        self.awaitReady = awaitReady
    }

    static func scopeKey(connectionId: String, mailbox: String) -> String {
        ownerPrefix + connectionId + ":" + mailbox
    }

    static func transportId(roomId: String) -> String {
        "\(transportId):\(roomId)"
    }

    var scopeKeys: Set<String> { Set(scopes.keys) }

    // MARK: - Lifecycle

    /// Makes the running scopes match `email.json`. At launch saved cursors
    /// are kept; afterwards a newly watched mailbox starts at its newest mail.
    func refresh(atLaunch: Bool = false) async {
        if atLaunch { await awaitReady() }
        let config = service.configuration()
        var wanted: [String: Scope] = [:]
        for account in config.accounts where account.canStartReceive() {
            for mailbox in account.effectiveMailboxes {
                wanted[Self.scopeKey(connectionId: account.connectionId, mailbox: mailbox)] = Scope(
                    account: account, mailbox: mailbox)
            }
        }
        if !atLaunch, started {
            for key in wanted.keys where scopes[key] == nil { await saveState(nil, key) }
        }
        for key in scopes.keys where wanted[key] == nil {
            halted.removeValue(forKey: key)
            waiting.removeValue(forKey: key)
            failures.removeValue(forKey: key)
            lastCounts.removeValue(forKey: key)
            if let room = Self.roomId(scope: key), let account = scopes[key]?.account {
                await health.clear(connectionId: account.channelConnectionId, transportId: Self.transportId(roomId: room))
            }
        }
        // Saving the channel is a reason to try paused accounts again.
        halted = [:]
        scopes = wanted
        started = true

        let supervisor = runtimeSupervisor()
        let registered = wanted.map { key, scope in
            SourceRuntimeScope(
                key: key, mode: .poll(interval: TimeInterval(scope.account.pollIntervalSeconds)),
                catchUp: scope.account.catchUp, driver: EmailChannelScopeDriver(runtime: self))
        }
        await supervisor.register(registered, owner: Self.ownerPrefix)
    }

    /// Re-reads the channel when it is saved or a mail account changes.
    func observeChanges() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.sourceConnectionsChanged, .emailChannelConfigurationChanged] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    Task { await self?.refresh() }
                })
        }
    }

    func stop() async {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        await supervisor?.stopAll()
        for (key, scope) in scopes {
            if let room = Self.roomId(scope: key) {
                await health.clear(
                    connectionId: scope.account.channelConnectionId, transportId: Self.transportId(roomId: room))
            }
        }
        scopes = [:]
        halted = [:]
        waiting = [:]
        failures = [:]
        started = false
    }

    /// Checks every watched mailbox now, paused ones included.
    func checkNow() async {
        halted = [:]
        guard let supervisor else { return }
        for key in scopes.keys { await supervisor.tickNow(key) }
    }

    private func runtimeSupervisor() -> SourceRuntimeSupervisor {
        if let supervisor { return supervisor }
        let load = loadState
        let save = saveState
        let made = SourceRuntimeSupervisor(
            host: SourceRuntimeHost(
                loadState: { await load($0) },
                saveState: { state, scope in await save(state, scope) },
                submit: { _ in }))
        supervisor = made
        return made
    }

    nonisolated static func roomId(scope: String) -> String? {
        guard scope.hasPrefix(ownerPrefix) else { return nil }
        let parts = scope.dropFirst(ownerPrefix.count)
        guard let colon = parts.firstIndex(of: ":") else { return nil }
        return EmailChannelConfiguration.roomId(
            connectionId: String(parts[..<colon]), mailbox: String(parts[parts.index(after: colon)...]))
    }

    // MARK: - Tick

    fileprivate func tick(_ context: SourceTickContext) async throws -> SourceTickResult {
        guard let scope = scopes[context.scope], halted[context.scope] == nil else { return SourceTickResult() }
        guard let connection = await service.connectionLookup(scope.account.connectionId),
            let fetcher = makeFetcher(connection)
        else { throw EmailFetchError.accountMissing }

        let options = MailboxFetchOptions(
            unreadOnly: scope.account.unreadOnly, includeBody: scope.account.includeBody,
            limit: MailboxFetchOptions.defaultLimit)
        let result: MailboxFetchResult
        do {
            result = try await fetcher.fetch(mailbox: scope.mailbox, cursor: context.state, options: options)
            waiting.removeValue(forKey: context.scope)
            if case .mailApp = connection.config { Self.automationDeniedFlag.withLock { $0 = false } }
        } catch let error as EmailFetchError where error.haltsChecks {
            halted[context.scope] =
                error.localizedDescription + " "
                + L("Checks are paused until the account is edited or you press Check Now.")
            return SourceTickResult()
        } catch let error as EmailFetchError where error.isWaitingOnTheUser {
            if error == .automationDenied { Self.automationDeniedFlag.withLock { $0 = true } }
            waiting[context.scope] = error.localizedDescription
            return SourceTickResult()
        }

        var messages = result.messages.filter { !scope.account.unreadOnly || !$0.isRead }
        if context.isFirstTick, context.state != nil {
            switch scope.account.catchUp {
            case .sinceCursor: break
            case .latestOnly: messages = messages.last.map { [$0] } ?? []
            case .skip: messages = []
            }
        }
        if !messages.isEmpty {
            lastCounts[context.scope] = try await service.ingest(
                messages, connection: connection, account: scope.account, mailbox: scope.mailbox)
        }
        return SourceTickResult(state: result.cursor)
    }

    // MARK: - Health

    fileprivate func apply(_ report: SourceRuntimeReport, scope key: String) async {
        guard let scope = scopes[key], let room = Self.roomId(scope: key) else { return }
        let transport = Self.transportId(roomId: room)
        let connectionId = scope.account.channelConnectionId
        let counts = lastCounts[key]
        var state: AgentChannelTransportHealthState
        switch report {
        case .ticking, .connecting, .connected, .disconnected:
            return
        case .stopped:
            await health.clear(connectionId: connectionId, transportId: transport)
            return
        case .ticked(let at, let next):
            failures[key] = 0
            if let reason = halted[key] {
                state = Self.state(connectionId, transport, .failed, .error, L("Checks paused"), reason, running: false)
                state.lastFailureAt = at
            } else if let reason = waiting[key] {
                state = Self.state(connectionId, transport, .degraded, .warning, L("Waiting"), reason, running: true)
                state.nextRetryAt = next
            } else {
                state = Self.state(connectionId, transport, .healthy, .info, L("Checking for new mail"), nil, running: true)
                state.lastSuccessAt = at
                state.nextRetryAt = next
            }
        case .failed(let at, let error, let next):
            let count = (failures[key] ?? 0) + 1
            failures[key] = count
            state = Self.state(connectionId, transport, .degraded, .warning, L("Check failed"), error, running: true)
            state.lastFailureAt = at
            state.nextRetryAt = next
            state.consecutiveFailures = count
        }
        state.lastReceivedCount = counts?.received ?? 0
        state.lastStoredCount = counts?.stored ?? 0
        state.dispatchAttemptedCount = counts?.dispatchAttempted ?? 0
        state.dispatchSuppressedCount = counts?.dispatchSuppressed ?? 0
        await health.update(state)
    }

    private static func state(
        _ connectionId: String, _ transport: String, _ status: AgentChannelTransportHealthStatus, _ severity: AgentChannelTransportHealthSeverity,
        _ summary: String, _ detail: String?, running: Bool
    ) -> AgentChannelTransportHealthState {
        AgentChannelTransportHealthState(
            connectionId: connectionId, transportId: transport, provider: .email,
            status: status, severity: severity, summary: summary, detail: detail, isRunning: running,
            receiveEnabled: true)
    }
}

/// The supervisor's handle on one watched mailbox; work hops to the runtime.
private struct EmailChannelScopeDriver: SourceRuntimeDriver {
    weak var runtime: EmailChannelTransportRuntime?

    func tick(_ context: SourceTickContext) async throws -> SourceTickResult {
        guard let runtime else { return SourceTickResult() }
        return try await runtime.tick(context)
    }

    func report(_ report: SourceRuntimeReport, scope: String) async {
        await runtime?.apply(report, scope: scope)
    }
}
