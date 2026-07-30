//
//  AgentChannelCredentialAvailability.swift
//  osaurus
//
//  Cached credential-availability snapshot for the native channel
//  providers. `AgentChannelAutoDestinationResolver.liveSources()` is reached
//  from MainActor paths — system-prompt preview composition, Settings
//  reloads, tool-availability recomputes — and previously probed the
//  Keychain (`SecItemCopyMatching`) and the iMessage helper digest on every
//  call. Under securityd contention those synchronous probes blocked the
//  main thread for seconds (Sentry APPLE-MACOS-1B5).
//
//  This cache makes the availability answer non-blocking: reads return the
//  last known value immediately; live probes run off the main thread and
//  are seeded at launch, refreshed after any credential mutation, and
//  re-validated opportunistically when a cached value goes stale.
//

import Foundation

final class AgentChannelCredentialAvailability: @unchecked Sendable {
    static let shared = AgentChannelCredentialAvailability()

    enum Provider: String, CaseIterable, Sendable {
        case discord
        case slack
        case telegram
        case imessage
    }

    /// How long a cached answer is trusted before an off-main revalidation
    /// is scheduled on the next read. Mutation hooks refresh eagerly, so
    /// this is only a safety net against a missed invalidation path.
    private let staleAfter: TimeInterval

    private struct Entry {
        var value: Bool
        var readAt: Date
    }

    private let lock = NSLock()
    private var entries: [Provider: Entry] = [:]
    private var refreshInFlight: Set<Provider> = []
    /// Test seam: replaces the live Keychain/filesystem probe.
    private let probe: @Sendable (Provider) -> Bool

    init(
        staleAfter: TimeInterval = 60,
        probe: @escaping @Sendable (Provider) -> Bool = AgentChannelCredentialAvailability.liveProbe
    ) {
        self.staleAfter = staleAfter
        self.probe = probe
    }

    // MARK: - Non-blocking read

    /// Return the cached availability without any blocking I/O.
    ///
    /// - Cached and fresh: returns the cached value.
    /// - Cached but stale: returns the cached value and schedules one
    ///   off-main revalidation.
    /// - Never probed: on the main thread, pessimistically returns `false`
    ///   and schedules the probe (a derived destination appearing a moment
    ///   after launch is acceptable; a beachball is not). Off the main
    ///   thread, probes synchronously — Keychain I/O is safe there and the
    ///   caller needs a correct answer (publish authorization).
    func hasCredential(_ provider: Provider) -> Bool {
        let now = Date()
        lock.lock()
        let entry = entries[provider]
        lock.unlock()

        if let entry {
            if now.timeIntervalSince(entry.readAt) > staleAfter {
                scheduleRefresh(provider)
            }
            return entry.value
        }

        if Thread.isMainThread {
            scheduleRefresh(provider)
            return false
        }
        return refreshNow(provider)
    }

    // MARK: - Maintenance

    /// Probe every provider off the main thread. Called once at launch so
    /// the first MainActor read already has a seeded answer.
    func seedAllInBackground() {
        for provider in Provider.allCases {
            scheduleRefresh(provider)
        }
    }

    /// Re-probe after a credential mutation (token saved/deleted, helper
    /// installed). Never blocks the caller.
    func invalidate(_ provider: Provider) {
        scheduleRefresh(provider, force: true)
    }

    /// Synchronously probe and cache. Must not run on the main thread.
    @discardableResult
    func refreshNow(_ provider: Provider) -> Bool {
        let value = probe(provider)
        lock.lock()
        entries[provider] = Entry(value: value, readAt: Date())
        lock.unlock()
        return value
    }

    private func scheduleRefresh(_ provider: Provider, force: Bool = false) {
        lock.lock()
        if !force, refreshInFlight.contains(provider) {
            lock.unlock()
            return
        }
        refreshInFlight.insert(provider)
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            self.refreshNow(provider)
            self.clearInFlight(provider)
        }
    }

    private func clearInFlight(_ provider: Provider) {
        lock.lock()
        refreshInFlight.remove(provider)
        lock.unlock()
    }

    // MARK: - Live probes

    /// The blocking sources of truth. Keychain-backed for the bot-token
    /// providers; a bundled-executable digest verification for iMessage.
    private static let liveProbe: @Sendable (Provider) -> Bool = { provider in
        switch provider {
        case .discord:
            return DiscordConnectionService.shared.hasBotToken()
        case .slack:
            return SlackConnectionService.shared.hasBotToken()
        case .telegram:
            return TelegramConnectionService.shared.hasBotToken()
        case .imessage:
            return IMessageConnectionService.shared.helperAvailable()
        }
    }
}
