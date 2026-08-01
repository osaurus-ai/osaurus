//
//  RemoteProviderManager.swift
//  osaurus
//
//  Manages remote OpenAI-compatible API provider connections.
//

import AppKit
import Foundation
import Network

/// Notification posted when remote provider connection status changes
extension Foundation.Notification.Name {
    static let remoteProviderStatusChanged = Foundation.Notification.Name("RemoteProviderStatusChanged")
    static let remoteProviderModelsChanged = Foundation.Notification.Name("RemoteProviderModelsChanged")
}

/// Errors for remote provider operations
public enum RemoteProviderError: LocalizedError {
    case providerNotFound
    case providerDisabled
    case notConnected
    case invalidURL
    case timeout
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .providerNotFound:
            return "Provider not found"
        case .providerDisabled:
            return "Provider is disabled"
        case .notConnected:
            return "Not connected to provider"
        case .invalidURL:
            return "Invalid server URL"
        case .timeout:
            return "Request timed out"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        }
    }
}

/// Manages all remote OpenAI-compatible API provider connections
@MainActor
public final class RemoteProviderManager: ObservableObject {
    public static let shared = RemoteProviderManager()
    public static let osaurusRouterProviderId = UUID(uuidString: "2CFBD528-62FD-4EF0-A143-3FE532F03840")!
    /// Product-selected temporary model for the first-run local-download
    /// experience. Match by final path component because Router ids are
    /// provider-prefixed (for example `osaurus/deepseek-ai/...`).
    static let firstRunOsaurusModelSlug = "deepseek-v4-flash"

    /// Current configuration
    @Published public private(set) var configuration: RemoteProviderConfiguration

    /// SwiftUI mirror of `OsaurusRouter.isEnabled` (UserDefaults). The default
    /// expression runs before `init`'s body, so the first
    /// `ensureManagedOsaurusRouterProviderIfNeeded()` already sees it. Mutate
    /// only via `setOsaurusRouterEnabled(_:)` to keep persistence, the managed
    /// provider, and the picker in lockstep.
    @Published public private(set) var isOsaurusRouterEnabled: Bool = OsaurusRouter.isEnabled

    /// Runtime state for each provider
    @Published public private(set) var providerStates: [UUID: RemoteProviderState] = [:]

    /// Connectivity-driven offline mode, fed by the network path monitor
    /// below. While true, the manager exposes no remote chat services or
    /// cached remote models, so cloud entries vanish from every model picker
    /// and chat routing without disconnecting providers or erasing their
    /// catalogs — they come back as-is on the recovery edge. Starts false
    /// (the monitor's baseline reading arrives asynchronously) so launch
    /// never flickers through a spurious offline state.
    @Published public private(set) var isOffline: Bool = false

    /// Active service instances keyed by provider ID
    private var services: [UUID: RemoteProviderService] = [:]

    /// Provider IDs created from Bonjour discovery — not persisted to disk
    private var ephemeralProviderIds: Set<UUID> = []

    /// Per-model metadata for the managed Osaurus Router, keyed by unprefixed
    /// model id (e.g. "<upstream>/model-b"). Captured from `/models` on
    /// connect/refetch so the picker can show provider, pricing, and context
    /// without a second request. Empty until the router connects.
    private var osaurusRouterModelCatalog: [String: OsaurusRouterModel] = [:]

    private init() {
        self.configuration = RemoteProviderConfigurationStore.load()
        ensureManagedOsaurusRouterProviderIfNeeded()

        // Initialize states for all providers
        for provider in configuration.providers {
            providerStates[provider.id] = RemoteProviderState(providerId: provider.id)
        }

        registerIdentityAndActivationObservers()
        startNetworkRecoveryMonitor()
    }

    /// Test seam: overrides `OsaurusIdentity.exists()` for the identity-gated
    /// connect/ensure paths so router lifecycle tests don't depend on whether
    /// the test machine happens to have a real master key installed.
    var testIdentityExistsOverride: Bool?

    private func identityExists() -> Bool {
        // `existsCached()` (not `exists()`): this gate runs inside
        // `ensureManagedOsaurusRouterProviderIfNeeded`, which fires on every
        // model-picker recompute. A synchronous keychain probe here hangs the
        // UI; the cached value is updated in-process on identity create/wipe.
        testIdentityExistsOverride ?? OsaurusIdentity.existsCached()
    }

    private static func isManagedOsaurusRouterProvider(_ provider: RemoteProvider) -> Bool {
        provider.id == osaurusRouterProviderId || provider.providerType == .osaurusRouter
    }

    private static func makeManagedOsaurusRouterProvider() -> RemoteProvider {
        RemoteProvider(
            id: osaurusRouterProviderId,
            name: "Osaurus",
            host: OsaurusRouter.defaultBaseURL.host ?? "router.osaurus.ai",
            providerProtocol: OsaurusRouter.defaultBaseURL.scheme == "http" ? .http : .https,
            port: OsaurusRouter.defaultBaseURL.port,
            basePath: "",
            authType: .none,
            providerType: .osaurusRouter,
            enabled: true,
            autoConnect: true,
            timeout: 120
        )
    }

    private func ensureManagedOsaurusRouterProviderIfNeeded() {
        // A disabled router behaves exactly like a missing identity: drop the
        // managed provider, its state, and any live service. This is what
        // removes Osaurus from the model picker and makes every
        // `connectOsaurusRouter*` path no-op while the user has it off.
        guard isOsaurusRouterEnabled, identityExists() else {
            configuration.providers.removeAll(where: Self.isManagedOsaurusRouterProvider)
            providerStates.removeValue(forKey: Self.osaurusRouterProviderId)
            if let service = services.removeValue(forKey: Self.osaurusRouterProviderId) {
                Task { await service.invalidateSession() }
            }
            return
        }

        let provider = Self.makeManagedOsaurusRouterProvider()
        configuration.providers.removeAll(where: Self.isManagedOsaurusRouterProvider)
        configuration.add(provider)
        if providerStates[provider.id] == nil {
            providerStates[provider.id] = RemoteProviderState(providerId: provider.id)
        }
    }

    private func saveUserProviderConfiguration() {
        var persisted = configuration
        persisted.providers.removeAll(where: Self.isManagedOsaurusRouterProvider)
        RemoteProviderConfigurationStore.save(persisted)
    }

    // MARK: - Provider Management

    /// Returns true if the provider was created ephemerally from Bonjour discovery
    public func isEphemeral(id: UUID) -> Bool {
        ephemeralProviderIds.contains(id)
    }

    /// Add a new provider. Pass `isEphemeral: true` for Bonjour-discovered providers so they
    /// are held only in memory and removed when the agent is deselected or goes offline.
    public func addProvider(
        _ provider: RemoteProvider,
        apiKey: String?,
        oauthTokens: RemoteProviderOAuthTokens? = nil,
        isEphemeral: Bool = false
    ) {
        configuration.add(provider)
        if isEphemeral {
            ephemeralProviderIds.insert(provider.id)
        } else {
            // KPI: a user-configured remote provider. Only the closed-enum
            // type is captured. Ephemeral Bonjour-discovered providers are
            // excluded — they aren't a deliberate configuration action.
            FeatureTelemetry.remoteProviderAdded(providerType: provider.providerType.rawValue)
        }

        // Initialize state
        providerStates[provider.id] = RemoteProviderState(providerId: provider.id)

        // Save credentials off the main thread — SecItemAdd/SecItemUpdate can
        // block for seconds under securityd contention. The on-disk provider
        // record is persisted only after the keychain writes land, so an
        // interrupted add can never leave an enabled provider on disk without
        // its credentials, and auto-connect reads the fresh key.
        let providerId = provider.id
        let shouldConnect = provider.enabled
        let persistsToDisk = !isEphemeral
        Keychain.performInBackground {
            var credentialsDurable = true
            if let apiKey = apiKey, !apiKey.isEmpty {
                credentialsDurable =
                    RemoteProviderKeychain.saveAPIKey(apiKey, for: providerId) && credentialsDurable
            }
            if let oauthTokens {
                credentialsDurable =
                    RemoteProviderKeychain.saveOAuthTokens(oauthTokens, for: providerId)
                    && credentialsDurable
                RemoteProviderKeychain.deleteAPIKey(for: providerId)
            }
            Task { @MainActor in
                RemoteProviderManager.shared.finishCredentialStaging(
                    providerId: providerId,
                    credentialsDurable: credentialsDurable,
                    persistsToDisk: persistsToDisk,
                    connect: shouldConnect
                )
            }
        }

        notifyStatusChanged()
    }

    /// Completion hop for `addProvider`/`updateProvider` credential staging:
    /// persists the provider record after its secrets are durable, surfaces a
    /// failed keychain write on the provider state (the in-memory session
    /// still works; relaunch durability is what failed), and kicks the
    /// requested connect.
    private func finishCredentialStaging(
        providerId: UUID,
        credentialsDurable: Bool,
        persistsToDisk: Bool,
        connect shouldConnect: Bool
    ) {
        if !credentialsDurable, !KeychainQueryHelpers.disablesKeychainForProcess {
            providerStates[providerId]?.lastError =
                "Could not save credentials to the Keychain — they may not survive relaunch."
            notifyStatusChanged()
        }
        if persistsToDisk {
            saveUserProviderConfiguration()
        }
        if shouldConnect {
            Task { @MainActor in
                try? await RemoteProviderManager.shared.connect(providerId: providerId)
            }
        }
    }

    /// Update an existing provider
    public func updateProvider(
        _ provider: RemoteProvider,
        apiKey: String?,
        oauthTokens: RemoteProviderOAuthTokens? = nil
    ) {
        let wasConnected = providerStates[provider.id]?.isConnected ?? false

        // Disconnect if connected
        if wasConnected {
            disconnect(providerId: provider.id)
        }

        configuration.update(provider)

        // Update credentials off the main thread (nil apiKey means no change,
        // empty string means clear). SecItemUpdate can block for seconds under
        // securityd contention — a recurring app-hang source on the save
        // button. The updated on-disk record is persisted only after the
        // keychain writes land, and reconnect waits for them so connect()
        // reads the fresh key.
        let providerId = provider.id
        let shouldReconnect = wasConnected && provider.enabled
        Keychain.performInBackground {
            var credentialsDurable = true
            if let apiKey = apiKey {
                if apiKey.isEmpty {
                    RemoteProviderKeychain.deleteAPIKey(for: providerId)
                } else {
                    credentialsDurable =
                        RemoteProviderKeychain.saveAPIKey(apiKey, for: providerId)
                        && credentialsDurable
                }
            }
            if let oauthTokens {
                credentialsDurable =
                    RemoteProviderKeychain.saveOAuthTokens(oauthTokens, for: providerId)
                    && credentialsDurable
                RemoteProviderKeychain.deleteAPIKey(for: providerId)
            }
            Task { @MainActor in
                RemoteProviderManager.shared.finishCredentialStaging(
                    providerId: providerId,
                    credentialsDurable: credentialsDurable,
                    persistsToDisk: true,
                    connect: shouldReconnect
                )
            }
        }

        notifyStatusChanged()
    }

    /// Remove a provider
    public func removeProvider(id: UUID) {
        // Disconnect first
        disconnect(providerId: id)

        // Remove from configuration (also cleans up Keychain)
        configuration.remove(id: id)
        ephemeralProviderIds.remove(id)
        saveUserProviderConfiguration()

        // Clean up state
        providerStates.removeValue(forKey: id)

        notifyStatusChanged()
        notifyModelsChanged()
    }

    /// Set enabled state for a provider
    /// When enabled is true, automatically connects to the provider
    /// When enabled is false, disconnects from the provider
    public func setEnabled(_ enabled: Bool, for providerId: UUID) {
        configuration.setEnabled(enabled, for: providerId)
        saveUserProviderConfiguration()

        if enabled {
            // Always auto-connect when toggled ON
            Task {
                try? await connect(providerId: providerId)
            }
        } else {
            disconnect(providerId: providerId)
        }

        notifyStatusChanged()
    }

    /// Reorder providers to match `orderedIds` and persist. Omitted IDs keep
    /// their relative position after the requested ones, so a partial list never
    /// drops providers. Connection state is untouched — only display order moves.
    public func reorder(orderedIds: [UUID]) {
        configuration.reorder(orderedIds: orderedIds)
        saveUserProviderConfiguration()
        notifyStatusChanged()
    }

    // MARK: - Connection Management

    /// Connect to a provider (fetch models and create service)
    public func connect(providerId: UUID) async throws {
        guard let provider = configuration.provider(id: providerId) else {
            throw RemoteProviderError.providerNotFound
        }

        guard provider.enabled else {
            throw RemoteProviderError.providerDisabled
        }

        // Update state to connecting
        var state = providerStates[providerId] ?? RemoteProviderState(providerId: providerId)
        state.isConnecting = true
        state.lastError = nil
        state.lastReplayDiagnostics = nil
        providerStates[providerId] = state

        do {
            if provider.authType == .openAICodexOAuth {
                if let tokens = await provider.getOAuthTokensOffMainActor(), tokens.isExpired {
                    let refreshed = try await OpenAICodexOAuthService.refresh(tokens)
                    if !(await RemoteProviderKeychain.saveOAuthTokensOffMainActor(
                        refreshed, for: provider.id)),
                        !KeychainQueryHelpers.disablesKeychainForProcess {
                        NSLog("RemoteProviderManager: failed to persist refreshed OAuth tokens")
                    }
                }
            } else if provider.authType == .xaiOAuth {
                if let tokens = await provider.getOAuthTokensOffMainActor(), tokens.isExpired {
                    let refreshed = try await XAIOAuthService.refresh(tokens)
                    if !(await RemoteProviderKeychain.saveOAuthTokensOffMainActor(
                        refreshed, for: provider.id)),
                        !KeychainQueryHelpers.disablesKeychainForProcess {
                        NSLog("RemoteProviderManager: failed to persist refreshed OAuth tokens")
                    }
                }
            }

            // Fetch models from the provider and merge any manually configured deployment IDs.
            let discoveredModels: [String]
            do {
                if let override = testFetchModelsOverride {
                    discoveredModels = try await override(provider)
                } else if provider.providerType == .osaurusRouter {
                    // The discovery variant also captures pricing/provider/context
                    // metadata for the picker, in the same request.
                    let discovery = try await RemoteProviderService.fetchOsaurusRouterModelsDiscovery(
                        from: provider
                    )
                    discoveredModels = discovery.models
                    osaurusRouterModelCatalog = discovery.catalog
                } else {
                    discoveredModels = try await withRateLimitRetry {
                        try await RemoteProviderService.fetchModels(from: provider)
                    }
                }
            } catch {
                if provider.providerType == .azureOpenAI && !provider.manualModelIds.isEmpty {
                    discoveredModels = []
                } else {
                    throw error
                }
            }
            let models = provider.mergedModelIds(discovered: discoveredModels)
            let resolvedHeaders = await provider.resolvedHeadersOffMainActor()
            let cachedOAuthTokens =
                (provider.authType == .openAICodexOAuth || provider.authType == .xaiOAuth)
                ? await provider.getOAuthTokensOffMainActor()
                : nil

            // Create service instance with headers resolved without holding
            // @MainActor in synchronous Keychain calls.
            let service = RemoteProviderService(
                provider: provider,
                models: models,
                resolvedHeaders: resolvedHeaders,
                cachedOAuthTokens: cachedOAuthTokens
            )
            services[providerId] = service
            if provider.providerType == .osaurusRouter {
                // Push the vision-capability set so the service can gate
                // multimodal user content per model on the Router wire.
                await service.updateOsaurusRouterVisionModels(
                    Self.visionModelIds(in: osaurusRouterModelCatalog)
                )
            }

            // Update state to connected
            state.isConnecting = false
            state.isConnected = true
            state.discoveredModels = models
            state.lastConnectedAt = Date()
            state.lastError = nil
            state.lastReplayDiagnostics = nil
            state.lastFailureWasTransient = false
            state.requiresAuth = false
            providerStates[providerId] = state

            print("[Osaurus] Remote Provider '\(provider.name)': Connected with \(models.count) models")

            notifyStatusChanged()
            notifyModelsChanged()

        } catch {
            // Dead OAuth tokens (invalid_grant / 401): clear them and set the
            // durable requiresAuth state instead of a generic connect error.
            if Self.isPermanentOAuthFailure(error) {
                handlePermanentOAuthFailure(providerId: providerId)
                print(
                    "[Osaurus] Remote Provider '\(provider.name)': OAuth refresh failed permanently — sign-in required"
                )
                throw error
            }
            let errorMessage = userFacingErrorMessage(error, for: provider)
            // Update state with error
            state.isConnecting = false
            state.isConnected = false
            state.lastError = errorMessage
            state.lastReplayDiagnostics = (error as? RemoteProviderServiceError)?.replayDiagnostics
            state.discoveredModels = []
            state.lastFailureWasTransient = Self.isTransientConnectError(error)
            providerStates[providerId] = state

            // Clean up — invalidate URLSession before discarding
            if let service = services.removeValue(forKey: providerId) {
                Task { await service.invalidateSession() }
            }

            print("[Osaurus] Remote Provider '\(provider.name)': Connection failed - \(errorMessage)")

            notifyStatusChanged()
            // `state.discoveredModels` was cleared above. Notify the shared
            // picker cache as well so a previously connected provider cannot
            // leave stale model rows behind after a failed reconnect.
            notifyModelsChanged()
            throw error
        }
    }

    /// Disconnect from a provider
    public func disconnect(providerId: UUID) {
        // Invalidate the URLSession before discarding the service to prevent leaking
        if let service = services.removeValue(forKey: providerId) {
            Task { await service.invalidateSession() }
        }

        // Update state
        if var state = providerStates[providerId] {
            state.isConnected = false
            state.isConnecting = false
            state.discoveredModels = []
            providerStates[providerId] = state
        }

        if let provider = configuration.provider(id: providerId) {
            if provider.providerType == .osaurusRouter {
                osaurusRouterModelCatalog = [:]
            }
            print("[Osaurus] Remote Provider '\(provider.name)': Disconnected")
        }

        notifyStatusChanged()
        notifyModelsChanged()
    }

    /// Reconnect to a provider
    public func reconnect(providerId: UUID) async throws {
        disconnect(providerId: providerId)
        try await connect(providerId: providerId)
    }

    /// Connect to all enabled providers on app launch
    public func connectEnabledProviders() async {
        ensureManagedOsaurusRouterProviderIfNeeded()
        // Honor the per-provider "Auto-connect" setting: only providers the
        // user left enabled AND auto-connect connect at launch. A provider
        // that is enabled but has auto-connect off stays dormant until the
        // user (or the model picker) connects it explicitly. The managed
        // Osaurus Router keeps `autoConnect: true`, so it's still included.
        //
        // Connects run in parallel: model discovery is network-bound and
        // `connect`'s awaits suspend off the main actor, so N providers reach
        // the picker in ~max(latency) instead of sum(latency) — and the
        // router's bounded retry backoff no longer delays every other
        // provider behind it. State writes stay on @MainActor inside
        // `connect` itself.
        await withTaskGroup(of: Void.self) { group in
            for provider in configuration.autoConnectProviders {
                // The managed Osaurus Router gets bounded retry so a transient
                // launch failure (offline, server 5xx, cold start) doesn't leave
                // the model picker without Osaurus options until a manual refresh.
                if provider.id == Self.osaurusRouterProviderId {
                    group.addTask { await self.connectOsaurusRouterWithRetry() }
                    continue
                }
                let providerId = provider.id
                let providerName = provider.name
                group.addTask {
                    await self.connectProviderWithTransientRetry(
                        providerId: providerId, providerName: providerName)
                }
            }
        }
    }

    /// Launch connect for a user-configured provider with bounded retry on
    /// *transient* failures (offline at launch, DNS not up yet, server 5xx),
    /// mirroring the managed router's behavior. Terminal failures (auth, bad
    /// config) stop immediately — a retry cannot fix them, and the network /
    /// wake / activation recovery sweeps handle anything transient that
    /// outlives the retry budget.
    private func connectProviderWithTransientRetry(
        providerId: UUID,
        providerName: String,
        maxAttempts: Int = RemoteProviderManager.osaurusRouterConnectMaxAttempts
    ) async {
        let attempts = max(1, maxAttempts)
        for attempt in 1 ... attempts {
            do {
                try await connect(providerId: providerId)
                return
            } catch {
                guard Self.isTransientConnectError(error), attempt < attempts else {
                    print("[Osaurus] Failed to auto-connect to '\(providerName)': \(error)")
                    return
                }
                await routerRetryBackoff(forAttempt: attempt, after: error)
                // Another path (picker, activation, network recovery) may have
                // connected while we waited — don't pile on a duplicate.
                if providerStates[providerId]?.isConnected == true { return }
            }
        }
    }

    public func connectOsaurusRouterIfPossible() async {
        guard managedRouterNeedsConnect() else { return }
        try? await connect(providerId: Self.osaurusRouterProviderId)
    }

    /// User-facing master switch for the managed Osaurus Router. Disabling drops
    /// the managed provider (see `ensureManagedOsaurusRouterProviderIfNeeded`)
    /// and clears credits state; enabling re-injects it and reconnects with the
    /// usual bounded retry. Idempotent.
    public func setOsaurusRouterEnabled(_ enabled: Bool) {
        guard enabled != isOsaurusRouterEnabled else { return }
        OsaurusRouter.setEnabled(enabled)
        isOsaurusRouterEnabled = enabled

        // Inject (enable) or drop (disable) the managed provider and its live
        // URLSession to match the new state.
        ensureManagedOsaurusRouterProviderIfNeeded()

        if enabled {
            // Balance/usage refresh is owned by the Credits view, so this stays
            // a connect task that tests can drain. A first-launch welcome claim
            // must settle before that connect is allowed to discover models.
            osaurusRouterEnableTask = Task { [weak self] in
                _ = await WelcomeCreditService.shared.claimIfNeeded()
                await self?.connectOsaurusRouterWithRetry()
            }
        } else {
            osaurusRouterEnableTask?.cancel()
            osaurusRouterEnableTask = nil
            OsaurusRouterAccountService.shared.clearForDisabledRouter()
        }

        // Rebuild the picker and refresh status UI. Open chats observe
        // `.remoteProviderModelsChanged` and fall back off an Osaurus model when
        // it disappears.
        notifyModelsChanged()
        notifyStatusChanged()
    }

    // MARK: - Osaurus Router connect retry & recovery

    /// Total attempts (including the first) for the launch-time router connect.
    public static let osaurusRouterConnectMaxAttempts = 3
    /// Base delay for exponential backoff between router connect retries.
    static let osaurusRouterConnectRetryBaseDelay: TimeInterval = 1.0
    /// Test seam: replaces the real backoff sleep so retry tests don't wait on
    /// wall-clock time.
    var testRetrySleepOverride: (@MainActor (TimeInterval) async -> Void)?

    /// Inject (or drop) the managed router for the current identity state and
    /// report whether a fresh connect should be attempted — i.e. it exists and
    /// isn't already connected or connecting. Shared by the single-shot and
    /// retrying entry points so their preconditions can't drift apart.
    private func managedRouterNeedsConnect() -> Bool {
        guard !RouterCreditAcquisitionCoordinator.shared.blocksGeneralSignedRequests else {
            return false
        }
        ensureManagedOsaurusRouterProviderIfNeeded()
        guard configuration.provider(id: Self.osaurusRouterProviderId) != nil else { return false }
        let state = providerStates[Self.osaurusRouterProviderId]
        return state?.isConnected != true && state?.isConnecting != true
    }

    /// Connect the managed Osaurus Router with bounded retry on *transient*
    /// failures (offline at launch, server 5xx, timeouts). Terminal failures
    /// (no identity, auth, other 4xx, bad config) stop immediately because a
    /// retry cannot fix them. This is the launch entry point; the single-shot
    /// `connectOsaurusRouterIfPossible()` remains for event-driven triggers.
    public func connectOsaurusRouterWithRetry(
        maxAttempts: Int = RemoteProviderManager.osaurusRouterConnectMaxAttempts
    ) async {
        guard managedRouterNeedsConnect() else { return }

        let attempts = max(1, maxAttempts)
        for attempt in 1 ... attempts {
            do {
                try await connect(providerId: Self.osaurusRouterProviderId)
                return
            } catch {
                // Stop on terminal errors or once attempts are exhausted.
                guard Self.isTransientConnectError(error), attempt < attempts else { return }
                await routerRetryBackoff(forAttempt: attempt, after: error)
                // Another path (picker/credits/activation/identity event) may
                // have connected while we waited — don't pile on a duplicate.
                if providerStates[Self.osaurusRouterProviderId]?.isConnected == true { return }
            }
        }
    }

    /// Backoff between router connect attempts: exponential, but never shorter
    /// than the server's `Retry-After` hint when the failure was a typed
    /// rate-limit (retrying earlier would just burn an attempt on a guaranteed
    /// 429). Capped at `connectRateLimitMaxDelay` so a hostile hint can't pin
    /// the connect task. Honors the test seam.
    private func routerRetryBackoff(forAttempt attempt: Int, after error: Error? = nil) async {
        let backoff = Self.osaurusRouterConnectRetryBaseDelay * pow(2.0, Double(attempt - 1))
        let delay = min(
            max(Self.retryAfterHint(from: error) ?? 0, backoff),
            Self.connectRateLimitMaxDelay
        )
        if let testRetrySleepOverride {
            await testRetrySleepOverride(delay)
        } else {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Extract a server-provided Retry-After hint from a typed rate-limit
    /// error, in seconds. Nil for every other error shape.
    static func retryAfterHint(from error: Error?) -> TimeInterval? {
        if let serviceError = error as? RemoteProviderServiceError,
            case .rateLimited(let retryAfter, _) = serviceError
        {
            return retryAfter
        }
        if let routerError = error as? OsaurusRouterAPIError,
            case .rateLimited(let retryAfter) = routerError
        {
            return retryAfter.flatMap(TimeInterval.init)
        }
        return nil
    }

    /// Total attempts (including the first) for the connect-phase model
    /// discovery request when the provider answers 429/503.
    static let connectRateLimitMaxAttempts = 3
    /// Ceiling on any single Retry-After / backoff wait during connect, so a
    /// hostile or misconfigured `Retry-After: 86400` can't pin the connect
    /// task for a day.
    static let connectRateLimitMaxDelay: TimeInterval = 15

    /// Bounded retry for the *idempotent* connect-phase discovery request.
    /// Retries only on the typed `.rateLimited` error (429, or 503 from the
    /// discovery GET), waiting `max(Retry-After, exponential backoff)` capped
    /// at `connectRateLimitMaxDelay`. Everything else propagates immediately.
    func withRateLimitRetry<T: Sendable>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as RemoteProviderServiceError {
                guard case .rateLimited(let retryAfter, _) = error,
                    attempt < Self.connectRateLimitMaxAttempts
                else { throw error }
                let backoff = Self.osaurusRouterConnectRetryBaseDelay * pow(2.0, Double(attempt - 1))
                let delay = min(max(retryAfter ?? backoff, backoff), Self.connectRateLimitMaxDelay)
                if let testRetrySleepOverride {
                    await testRetrySleepOverride(delay)
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                attempt += 1
            }
        }
    }

    /// Whether a router connect error is worth retrying. Transient = network
    /// loss / timeout / DNS / TLS and server-side 5xx / rate-limit. Terminal =
    /// identity / auth / other 4xx / config, plus anything unrecognized
    /// (e.g. a biometric/Keychain failure, which a tight retry loop must not
    /// hammer — the app-activation observer recovers those instead).
    static func isTransientConnectError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .timedOut, .networkConnectionLost,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                .secureConnectionFailed, .resourceUnavailable, .badServerResponse:
                return true
            default:
                return false
            }
        }
        if let routerError = error as? OsaurusRouterAPIError {
            switch routerError {
            case .transport, .invalidResponse, .rateLimited:
                return true
            case .server(_, _, let status):
                return status >= 500
            case .noIdentity, .firstActionPending, .invalidURL, .unauthorized,
                .belowMinimumTopUp, .insufficientFunds, .accountFrozen,
                .paidWebDisabled, .idempotencyConflict:
                return false
            }
        }
        if let serviceError = error as? RemoteProviderServiceError {
            switch serviceError {
            case .invalidResponse, .rateLimited:
                return true
            case .invalidURL, .notConnected, .requestFailed, .requestFailedWithDiagnostics,
                .streamingError, .noModelsAvailable, .unsupportedParameter, .mcpEndpointDetected:
                return false
            }
        }
        return false
    }

    /// True when an OAuth token-refresh failure means the stored tokens are
    /// permanently dead (`invalid_grant` / `invalid_token` on HTTP 400/401)
    /// and the user must sign in again. Mirrors
    /// `MCPOAuthService.isPermanentAuthFailure` for the remote-provider OAuth
    /// flavors (Codex, xAI). Errors from those services carry the upstream
    /// status/body in their message (e.g. "HTTP 400: {\"error\":\"invalid_grant\"}").
    nonisolated static func isPermanentOAuthFailure(_ error: Error) -> Bool {
        let message: String
        switch error {
        case OpenAICodexOAuthError.tokenRequestFailed(let m): message = m
        case XAIOAuthError.tokenRequestFailed(let m): message = m
        default: return false
        }
        let lowered = message.lowercased()
        guard lowered.contains("http 400") || lowered.contains("http 401") else { return false }
        return lowered.contains("invalid_grant") || lowered.contains("invalid_token")
    }

    /// Permanent OAuth failure: clear the dead tokens and set a durable
    /// `requiresAuth` state so the UI offers "Sign in again" instead of an
    /// error message that retrying can never fix. Mirrors
    /// `MCPProviderManager.handlePermanentOAuthFailure`.
    public func handlePermanentOAuthFailure(providerId: UUID) {
        RemoteProviderKeychain.deleteOAuthTokens(for: providerId)
        if let service = services.removeValue(forKey: providerId) {
            Task { await service.invalidateSession() }
        }
        var state = providerStates[providerId] ?? RemoteProviderState(providerId: providerId)
        state.requiresAuth = true
        state.isConnected = false
        state.isConnecting = false
        state.lastError = L("Session expired — please sign in again.")
        state.lastFailureWasTransient = false
        state.discoveredModels = []
        providerStates[providerId] = state
        notifyStatusChanged()
        notifyModelsChanged()
    }

    /// Observe identity creation/wipe, app re-activation, and wake-from-sleep
    /// so providers (re)connect without waiting for a user-driven refresh.
    private func registerIdentityAndActivationObservers() {
        observeOnMain(.osaurusIdentityChanged) { await $0.handleIdentityChanged() }
        observeOnMain(.routerCreditAcquisitionResolved) {
            await $0.connectOsaurusRouterIfPossible()
        }
        observeOnMain(NSApplication.didBecomeActiveNotification) { await $0.handleAppDidBecomeActive() }
        // Wake is a recovery opportunity: connects that failed as the machine
        // slept (or right before) are transient by nature. NSWorkspace posts
        // wake through its own notification center, not `.default`.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleTransientRecoverySweep()
            }
        }
    }

    /// Add a main-queue notification observer that hops onto the MainActor and
    /// invokes `handler` with a strong (but cycle-free) reference to self — the
    /// handler receives the manager as an argument rather than capturing it.
    private func observeOnMain(
        _ name: Foundation.Notification.Name,
        _ handler: @escaping @MainActor (RemoteProviderManager) async -> Void
    ) {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await handler(self)
            }
        }
    }

    /// Identity was created or wiped. When present, inject + connect the managed
    /// router; when gone, `ensureManagedOsaurusRouterProviderIfNeeded` drops it
    /// and we post `.remoteProviderModelsChanged` so the picker rebuilds without
    /// the now-invalid Osaurus options.
    func handleIdentityChanged() async {
        ensureManagedOsaurusRouterProviderIfNeeded()
        if identityExists() {
            await connectOsaurusRouterIfPossible()
        } else {
            notifyModelsChanged()
        }
    }

    /// App regained focus. Retry the router connect only when it isn't already
    /// connected, so a launch that failed while offline recovers on the next
    /// activation. The `isConnected` short-circuit avoids re-running
    /// `ensureManagedOsaurusRouterProviderIfNeeded` (and its `@Published`
    /// configuration churn) on every activation. Activation is also a recovery
    /// opportunity for user-configured providers whose last failure was
    /// transient (the sweep is a no-op when nothing failed transiently).
    func handleAppDidBecomeActive() async {
        await reconnectTransientlyFailedProviders()
        guard identityExists() else { return }
        guard providerStates[Self.osaurusRouterProviderId]?.isConnected != true else { return }
        await connectOsaurusRouterIfPossible()
    }

    // MARK: - Network-recovery auto-reconnect

    /// Path monitor driving auto-reconnect: when connectivity returns after an
    /// outage, providers whose last connect failed *transiently* (see
    /// `RemoteProviderState.lastFailureWasTransient`) are reconnected without
    /// waiting for app re-activation or a manual toggle.
    private nonisolated(unsafe) var networkPathMonitor: NWPathMonitor?
    /// Last observed satisfied-ness; reconnects fire only on the
    /// unsatisfied → satisfied edge, never on the initial baseline reading or
    /// on repeated satisfied updates (interface changes, DNS churn, …).
    private var lastNetworkPathWasSatisfied: Bool?
    private var networkRecoveryTask: Task<Void, Never>?

    private func startNetworkRecoveryMonitor() {
        let monitor = NWPathMonitor()
        networkPathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "ai.osaurus.provider.pathmonitor"))
    }

    /// Internal (not private) so offline-mode tests can drive connectivity
    /// edges without a real `NWPath`.
    func handleNetworkPathUpdate(satisfied: Bool) {
        defer { lastNetworkPathWasSatisfied = satisfied }
        if isOffline == satisfied {
            isOffline = !satisfied
            // Remote models are gated on `isOffline` (see
            // `cachedAvailableModels()` / `connectedServices()`); rebuild the
            // pickers on both edges so cloud entries disappear the moment the
            // network drops and reappear the moment it returns.
            notifyModelsChanged()
        }
        // Reconnects fire on the recovery edge (down → up) and on the very
        // first satisfied observation. The first baseline matters at launch:
        // providers that failed transiently moments before the monitor
        // produced its baseline would otherwise stay down until the *next*
        // full outage/recovery cycle. The sweep only touches providers whose
        // last failure was transient, so a healthy launch is a no-op.
        guard satisfied, lastNetworkPathWasSatisfied != true else { return }
        // Debounce flapping paths — replace any in-flight sweep.
        scheduleTransientRecoverySweep()
    }

    /// Schedule a debounced sweep reconnecting transiently-failed providers.
    /// Shared by the network-path recovery edge and the wake observer.
    func scheduleTransientRecoverySweep() {
        networkRecoveryTask?.cancel()
        let settleDelay = testNetworkRecoverySettleDelayOverride ?? 2.0
        networkRecoveryTask = Task { [weak self] in
            // Give routing/DNS a moment to settle after the path flips; an
            // immediate connect after wake often fails on stale DNS.
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.reconnectTransientlyFailedProviders()
        }
    }

    /// Test seam: shrink the recovery settle delay so sweep tests don't wait
    /// on wall-clock time.
    var testNetworkRecoverySettleDelayOverride: TimeInterval?

    /// Await the in-flight recovery sweep, if any. Test-only.
    func _testAwaitNetworkRecoverySweep() async {
        await networkRecoveryTask?.value
    }

    /// Reconnect every auto-connect provider whose last failure was transient
    /// and which isn't connected or mid-connect. Sequential like the launch
    /// path; each `connect` re-evaluates state so concurrent triggers stay
    /// idempotent.
    func reconnectTransientlyFailedProviders() async {
        for provider in configuration.autoConnectProviders {
            guard !Task.isCancelled else { return }
            let state = providerStates[provider.id]
            guard state?.isConnected != true, state?.isConnecting != true,
                state?.lastFailureWasTransient == true
            else { continue }
            try? await connect(providerId: provider.id)
        }
    }

    private var refreshConnectedTask: Task<Void, Never>?

    /// Connect kicked off by `setOsaurusRouterEnabled(true)`. Retained so tests
    /// can await it; nil when idle or after a disable.
    private var osaurusRouterEnableTask: Task<Void, Never>?

    /// Last successful refetch per provider for throttling
    private var lastModelRefetchAt: [UUID: Date] = [:]

    static let modelRefetchThrottle: TimeInterval = 10

    /// Test seam: when set, used in place of `RemoteProviderService.fetchModels`.
    var testFetchModelsOverride: (@MainActor (RemoteProvider) async throws -> [String])?
    var testConnectionTransportOverride: (@MainActor (URLRequest) async throws -> (Data, URLResponse))?

    /// Re-query `/models` for one connected provider without tearing down its
    /// service, flipping `isConnecting`, or refreshing OAuth.
    public func refetchModels(providerId: UUID) async {
        guard let provider = configuration.provider(id: providerId),
            provider.enabled,
            var state = providerStates[providerId],
            state.isConnected
        else { return }

        let discovered: [String]
        do {
            if let override = testFetchModelsOverride {
                discovered = try await override(provider)
            } else if provider.providerType == .osaurusRouter {
                let discovery = try await RemoteProviderService.fetchOsaurusRouterModelsDiscovery(
                    from: provider
                )
                discovered = discovery.models
                // Refresh metadata even when the id set is unchanged: pricing or
                // capabilities may have moved without a new/removed model.
                osaurusRouterModelCatalog = discovery.catalog
                if let service = services[providerId] {
                    await service.updateOsaurusRouterVisionModels(
                        Self.visionModelIds(in: discovery.catalog)
                    )
                }
            } else {
                discovered = try await RemoteProviderService.fetchModels(from: provider)
            }
        } catch {
            return
        }

        let merged = provider.mergedModelIds(discovered: discovered)
        lastModelRefetchAt[providerId] = Date()
        guard merged != state.discoveredModels else { return }

        state.discoveredModels = merged
        providerStates[providerId] = state
        if let service = services[providerId] {
            await service.updateModels(merged)
        }
        notifyModelsChanged()
    }

    /// Refresh every enabled provider's model list, coalesced and throttled.
    /// Called from the picker-open path.
    public func refreshConnectedProviders() async {
        await connectOsaurusRouterIfPossible()

        if let existing = refreshConnectedTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            let throttle = Self.modelRefetchThrottle
            let dueIds: [UUID] = self.configuration.enabledProviders.compactMap { provider in
                let lastRefetch = self.lastModelRefetchAt[provider.id]
                let isThrottled = lastRefetch.map { now.timeIntervalSince($0) < throttle } ?? false
                if isThrottled {
                    return nil
                }
                return provider.id
            }
            for id in dueIds {
                await self.refetchModels(providerId: id)
            }
        }
        refreshConnectedTask = task
        await task.value
        refreshConnectedTask = nil
    }

    /// Disconnect from all providers
    public func disconnectAll() {
        for providerId in services.keys {
            disconnect(providerId: providerId)
        }
    }

    // MARK: - Service Access

    /// Get the service for a provider
    public func service(for providerId: UUID) -> RemoteProviderService? {
        return services[providerId]
    }

    /// Get all connected services. Empty while offline: a remote request
    /// cannot succeed without a network path, so chat routing sees no remote
    /// services instead of dispatching a send that is guaranteed to fail.
    public func connectedServices() -> [RemoteProviderService] {
        guard !isOffline else { return [] }
        return Array(services.values)
    }

    /// Get all available models across all connected providers (with prefixes)
    public func allAvailableModels() -> [String] {
        var models: [String] = []
        for (providerId, service) in services {
            if let state = providerStates[providerId], state.isConnected {
                Task {
                    let prefixedModels = await service.getPrefixedModels()
                    models.append(contentsOf: prefixedModels)
                }
            }
        }
        return models
    }

    /// One connected provider's cached model list plus its route identity.
    /// `providerType` and `host` let consumers (the model picker cache)
    /// distinguish the ChatGPT/Codex OAuth route from the official
    /// `api.openai.com` API-key route, so the same slug never receives the
    /// wrong provider's capability set.
    public struct CachedProviderModels: Sendable {
        public let providerId: UUID
        public let providerName: String
        public let providerType: RemoteProviderType
        public let host: String
        public let models: [String]
    }

    /// One exact connected provider/model pair exposed to subagent spawning.
    /// `id` is UUID-backed and therefore remains stable across provider rename;
    /// `pickerModelId` preserves the existing human-readable chat picker id.
    struct ConnectedSpawnModelTarget: Sendable, Equatable {
        let id: String
        let providerId: UUID
        let providerName: String
        let modelId: String
        let pickerModelId: String
    }

    /// Immutable lookup snapshot for one connected spawn catalog refresh.
    ///
    /// SwiftUI may ask for the same row identity many times while laying out a
    /// picker. Indexing once keeps those body reads independent from
    /// `RemoteProviderManager.shared` initialization and avoids rebuilding the
    /// complete provider/model catalog per row.
    struct ConnectedSpawnModelTargetIndex: Sendable {
        private struct PickerKey: Hashable, Sendable {
            let providerId: UUID
            let pickerModelId: String
        }

        static let empty = ConnectedSpawnModelTargetIndex(targets: [])

        private let canonicalTargets: [String: ConnectedSpawnModelTarget]
        private let targetIDsByPicker: [PickerKey: String]
        private let uniqueLegacyTargets: [String: ConnectedSpawnModelTarget]

        init(targets: [ConnectedSpawnModelTarget]) {
            var canonicalTargets: [String: ConnectedSpawnModelTarget] = [:]
            var targetIDsByPicker: [PickerKey: String] = [:]
            var legacyBuckets: [String: [ConnectedSpawnModelTarget]] = [:]

            for target in targets {
                canonicalTargets[target.id] = target
                targetIDsByPicker[
                    PickerKey(
                        providerId: target.providerId,
                        pickerModelId: target.pickerModelId
                    )
                ] = target.id
                legacyBuckets[target.pickerModelId, default: []].append(target)
            }

            self.canonicalTargets = canonicalTargets
            self.targetIDsByPicker = targetIDsByPicker
            self.uniqueLegacyTargets = legacyBuckets.compactMapValues { matches in
                matches.count == 1 ? matches[0] : nil
            }
        }

        func target(forStoredId id: String) -> ConnectedSpawnModelTarget? {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let parsed = SpawnRemoteModelIdentity.parse(trimmed),
                let canonicalID = SpawnRemoteModelIdentity.make(
                    providerId: parsed.providerId,
                    modelId: parsed.modelId
                )
            {
                return canonicalTargets[canonicalID]
            }
            return uniqueLegacyTargets[trimmed]
        }

        func targetID(
            forPickerModelId pickerModelId: String,
            providerId: UUID
        ) -> String? {
            targetIDsByPicker[
                PickerKey(providerId: providerId, pickerModelId: pickerModelId)
            ]
        }
    }

    /// Get all available models synchronously from cached state. Empty while
    /// offline so the model picker (via `ModelPickerItemCache`) hides every
    /// cloud model and chat sessions fall back to Foundation/local; the
    /// underlying provider states are untouched, so the same models reappear
    /// on the connectivity-recovery edge.
    public func cachedAvailableModels() -> [CachedProviderModels] {
        guard !isOffline else { return [] }
        ensureManagedOsaurusRouterProviderIfNeeded()
        var result: [CachedProviderModels] = []

        for provider in configuration.providers {
            if let state = providerStates[provider.id], state.isConnected {
                // Create prefixed model names. This remains the normal chat
                // picker contract; spawn persistence uses the separate
                // UUID-backed identity below.
                let prefix = Self.pickerPrefix(for: provider.name)
                let prefixedModels = state.discoveredModels.map { "\(prefix)/\($0)" }
                result.append(
                    CachedProviderModels(
                        providerId: provider.id,
                        providerName: provider.name,
                        providerType: provider.providerType,
                        host: provider.host,
                        models: prefixedModels
                    )
                )
            }
        }

        return result
    }

    /// Current spawn-only remote catalog. A connected state without its live
    /// service is not dispatchable, so it is deliberately omitted.
    func connectedSpawnModelTargets() -> [ConnectedSpawnModelTarget] {
        guard !isOffline else { return [] }
        return configuration.providers.flatMap { provider -> [ConnectedSpawnModelTarget] in
            guard
                providerStates[provider.id]?.isConnected == true,
                services[provider.id] != nil,
                let models = providerStates[provider.id]?.discoveredModels
            else {
                return []
            }
            let pickerPrefix = Self.pickerPrefix(for: provider.name)
            return models.compactMap { modelId in
                guard
                    let id = SpawnRemoteModelIdentity.make(
                        providerId: provider.id,
                        modelId: modelId
                    )
                else {
                    return nil
                }
                return ConnectedSpawnModelTarget(
                    id: id,
                    providerId: provider.id,
                    providerName: provider.name,
                    modelId: modelId,
                    pickerModelId: "\(pickerPrefix)/\(modelId)"
                )
            }
        }
    }

    /// Capture one indexed view of the current connected spawn catalog.
    func connectedSpawnModelTargetIndex() -> ConnectedSpawnModelTargetIndex {
        ConnectedSpawnModelTargetIndex(targets: connectedSpawnModelTargets())
    }

    /// Resolve a canonical UUID-backed spawn id, or one unambiguous legacy
    /// name-prefixed id, against current connected service truth. Legacy ids
    /// normalize to the canonical id before the model request is routed.
    func connectedSpawnModelTarget(
        forStoredId id: String
    ) -> ConnectedSpawnModelTarget? {
        connectedSpawnModelTargetIndex().target(forStoredId: id)
    }

    /// Convert one current normal-chat picker item to its spawn-only stable id.
    /// This does not mutate the chat picker id or any ordinary chat setting.
    func spawnTargetId(
        forPickerModelId pickerModelId: String,
        providerId: UUID
    ) -> String? {
        connectedSpawnModelTargetIndex().targetID(
            forPickerModelId: pickerModelId,
            providerId: providerId
        )
    }

    nonisolated static func pickerPrefix(for providerName: String) -> String {
        providerName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    /// The first chat-capable model id for `providerId`, prefixed exactly as the
    /// model picker lists it (e.g. "openai-chatgpt/gpt-5.5"). Skips embedding /
    /// reranker ids via the same heuristic the picker uses. `nil` until the
    /// provider connects and its catalog is discovered.
    ///
    /// Used to pin the new agent's default model when the user connected a
    /// bring-your-own-key / OAuth provider in onboarding. Falls back to the
    /// first model when none pass the heuristic, so the agent is never left
    /// without a default while the provider exposes any model at all.
    public func firstChatCapableModelId(forProviderId providerId: UUID) -> String? {
        guard
            let entry = cachedAvailableModels().first(where: {
                $0.providerId == providerId
            })
        else { return nil }
        return entry.models.first { !ModelPickerItem.isLikelyEmbeddingOrRerankerID($0) }
            ?? entry.models.first
    }

    /// DeepSeek V4 Flash for first-run Cloud, with the normal chat-capable
    /// provider fallback if the Router temporarily omits that model.
    public func firstRunOsaurusRouterModelId() -> String? {
        guard
            let entry = cachedAvailableModels().first(where: {
                $0.providerId == Self.osaurusRouterProviderId
            })
        else { return nil }
        return entry.models.first(where: Self.isFirstRunOsaurusModelId)
            ?? entry.models.first { !ModelPickerItem.isLikelyEmbeddingOrRerankerID($0) }
            ?? entry.models.first
    }

    static func isFirstRunOsaurusModelId(_ id: String) -> Bool {
        id.split(separator: "/").last?.lowercased() == firstRunOsaurusModelSlug
    }

    /// Metadata for an Osaurus Router model by its unprefixed id (the id as it
    /// appears in `discoveredModels`, e.g. "<upstream>/model-b"). Returns nil for
    /// non-router models or before the router has connected.
    ///
    /// Intentionally `internal`: `OsaurusRouterModel` is an internal type, and
    /// the only caller (`ModelPickerItemCache`) lives in this module.
    func osaurusRouterMetadata(for unprefixedModelId: String) -> OsaurusRouterModel? {
        osaurusRouterModelCatalog[unprefixedModelId]
    }

    /// Unprefixed model ids in `catalog` that advertise image/vision input.
    /// Pushed to the router's `RemoteProviderService` so the wire layer can
    /// keep user media multimodal only for models that accept it.
    nonisolated static func visionModelIds(in catalog: [String: OsaurusRouterModel]) -> Set<String> {
        Set(catalog.compactMap { id, model in model.supportsVision ? id : nil })
    }

    /// Find the service that handles a given model
    public func findService(forModel model: String) -> RemoteProviderService? {
        for service in services.values where service.handles(requestedModel: model) {
            return service
        }
        return nil
    }

    // MARK: - Test Connection

    /// Test connection to a provider configuration without persisting.
    ///
    /// Pass `providerId` when testing an existing provider so OAuth-backed
    /// providers (ChatGPT/Codex) can query the live model catalog with the
    /// stored tokens instead of the static fallback.
    public func testConnection(
        host: String,
        providerProtocol: RemoteProviderProtocol,
        port: Int?,
        basePath: String,
        authType: RemoteProviderAuthType,
        providerType: RemoteProviderType = .openaiLegacy,
        apiKey: String?,
        headers: [String: String],
        manualModelIds: [String] = [],
        providerId: UUID? = nil
    ) async throws -> [String] {
        if authType == .openAICodexOAuth && providerType == .openAICodex {
            // Prefer the live catalog when OAuth tokens are already stored
            // (re-testing an existing connection), so the Test badge matches
            // the models the connected provider actually exposes. Before
            // sign-in there are no tokens, so fall back to the static list to
            // keep the "test succeeded" UI usable; the real catalog is fetched
            // on connect via RemoteProviderService.fetchModels.
            guard let providerId else {
                return OpenAICodexOAuthService.supportedModels
            }
            let storedTokens = await RemoteProviderKeychain.runOffCooperativeExecutor {
                RemoteProviderKeychain.getOAuthTokens(for: providerId)
            }
            guard var tokens = storedTokens else {
                return OpenAICodexOAuthService.supportedModels
            }
            if tokens.isExpired {
                let refreshed = try await OpenAICodexOAuthService.refresh(tokens)
                _ = await RemoteProviderKeychain.saveOAuthTokensOffMainActor(refreshed, for: providerId)
                tokens = refreshed
            }
            return await OpenAICodexOAuthService.availableModels(for: tokens)
        }

        if authType == .xaiOAuth {
            // xAI OAuth tokens cannot list models (HTTP 403); use the built-in
            // catalog, matching RemoteProviderService.fetchModels.
            return XAIOAuthService.supportedModels
        }

        // Build temporary provider for testing
        let tempProvider = RemoteProvider(
            name: "Test",
            host: host,
            providerProtocol: providerProtocol,
            port: port,
            basePath: basePath,
            customHeaders: headers,
            authType: authType,
            providerType: providerType,
            enabled: true,
            autoConnect: false,
            timeout: 30,
            manualModelIds: manualModelIds
        )

        // Manually add API key to headers for test (since it's not in Keychain)
        var testHeaders = headers
        if authType == .apiKey, let apiKey = apiKey, !apiKey.isEmpty {
            switch providerType {
            case .anthropic:
                if testHeaders["x-api-key"] == nil {
                    testHeaders["x-api-key"] = apiKey
                }
                // Add required Anthropic version header if not already set
                if testHeaders["anthropic-version"] == nil {
                    testHeaders["anthropic-version"] = "2023-06-01"
                }
            case .gemini:
                if testHeaders["x-goog-api-key"] == nil {
                    testHeaders["x-goog-api-key"] = apiKey
                }
            case .azureOpenAI:
                if testHeaders["api-key"] == nil {
                    testHeaders["api-key"] = apiKey
                }
            case .openaiLegacy, .openResponses, .openAICodex, .osaurus, .osaurusRouter:
                if testHeaders["Authorization"] == nil {
                    testHeaders["Authorization"] = "Bearer \(apiKey)"
                }
            }
        }

        // Anthropic uses /models endpoint (same as OpenAI-compatible providers)
        if providerType == .anthropic {
            return try await testAnthropicConnection(tempProvider: tempProvider, testHeaders: testHeaders)
        }

        // OpenAI-compatible and Gemini providers use /models endpoint
        guard let url = tempProvider.url(for: "/models") else {
            print("[Osaurus] Test Connection: Invalid URL")
            throw RemoteProviderError.invalidURL
        }

        print("[Osaurus] Test Connection: Requesting \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        // Add headers
        for (key, value) in testHeaders {
            let logValue = RemoteProviderHeaderRedactor.valueForLogging(
                headerName: key,
                value: value,
                configuredSecretHeaderKeys: tempProvider.secretHeaderKeys
            )
            print("[Osaurus] Test Connection: Adding header \(key)=\(logValue)")
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response): (Data, URLResponse)
            do {
                if let override = testConnectionTransportOverride {
                    (data, response) = try await override(request)
                } else {
                    (data, response) = try await GlobalProxySettings.sharedSession().data(for: request)
                }
            } catch {
                let diagnostics = ProviderReplayDiagnosticBundle(
                    phase: "test_model_discovery",
                    request: request,
                    transportError: error,
                    configuredSecretHeaderKeys: tempProvider.secretHeaderKeys
                )
                throw RemoteProviderServiceError.requestFailedWithDiagnostics(
                    "Network error: \(ProviderDiagnosticRedactor.safe(error.localizedDescription, maxLength: 240))",
                    diagnostics
                )
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[Osaurus] Test Connection: Invalid response type")
                let diagnostics = ProviderReplayDiagnosticBundle(
                    phase: "test_model_discovery",
                    request: request,
                    configuredSecretHeaderKeys: tempProvider.secretHeaderKeys
                )
                throw RemoteProviderServiceError.invalidResponse.attachingReplayDiagnostics(diagnostics)
            }

            print("[Osaurus] Test Connection: HTTP \(httpResponse.statusCode)")
            let diagnostics = ProviderReplayDiagnosticBundle(
                phase: "test_model_discovery",
                request: request,
                response: httpResponse,
                responseData: data,
                configuredSecretHeaderKeys: tempProvider.secretHeaderKeys
            )

            // Parse models response based on provider type
            if providerType == .gemini {
                if httpResponse.statusCode >= 400 {
                    let errorMessage = extractErrorMessage(from: data, statusCode: httpResponse.statusCode)
                    print("[Osaurus] Test Connection: Error response: \(errorMessage)")
                    throw RemoteProviderServiceError.requestFailedWithDiagnostics(
                        ProviderDiagnosticRedactor.safe(errorMessage, maxLength: 500),
                        diagnostics
                    )
                }

                let modelsResponse = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
                let models = (modelsResponse.models ?? [])
                    .filter { model in
                        guard let methods = model.supportedGenerationMethods else { return false }
                        return methods.contains("generateContent")
                    }
                    .map { $0.modelId }
                print("[Osaurus] Test Connection (Gemini): Success - found \(models.count) models")
                return models
            } else {
                let models: [String]
                do {
                    models = try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
                        data: data,
                        statusCode: httpResponse.statusCode,
                        provider: tempProvider
                    )
                } catch let error as RemoteProviderServiceError {
                    if httpResponse.statusCode >= 400,
                        let refined = await RemoteProviderService.refineMCPServerMisconfiguration(
                            for: tempProvider,
                            headers: testHeaders
                        )
                    {
                        throw refined
                    }
                    throw error.attachingReplayDiagnostics(diagnostics)
                } catch {
                    throw RemoteProviderServiceError.requestFailedWithDiagnostics(
                        "Invalid /models response: \(ProviderDiagnosticRedactor.safe(error.localizedDescription, maxLength: 240))",
                        diagnostics
                    )
                }
                // Fireworks: augment with the serverless catalog so the Test
                // badge matches what connect will discover. Best-effort — a
                // catalog failure keeps the plain /models result.
                if RemoteProviderService.isFireworksProvider(tempProvider) {
                    do {
                        let catalog = try await RemoteProviderService.fetchFireworksCatalogModels(
                            headers: testHeaders,
                            timeout: 30,
                            transport: testConnectionTransportOverride
                        )
                        let merged = RemoteProviderService.mergeFireworksModelIds(
                            discovered: models,
                            catalog: catalog
                        )
                        print("[Osaurus] Test Connection: Success - found \(merged.count) models")
                        return merged
                    } catch {
                        print("[Osaurus] Test Connection: Fireworks catalog unavailable, using /models only")
                    }
                }
                print("[Osaurus] Test Connection: Success - found \(models.count) models")
                return models
            }
        } catch let error as RemoteProviderServiceError {
            throw error
        } catch let error as RemoteProviderError {
            throw error
        } catch {
            print("[Osaurus] Test Connection: Network error: \(error)")
            throw RemoteProviderError.connectionFailed(error.localizedDescription)
        }
    }

    /// Extract a human-readable error message from API error response data
    private func extractErrorMessage(from data: Data, statusCode: Int) -> String {
        // Try to parse as JSON error response (OpenAI/xAI format)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // OpenAI/xAI format: {"error": {"message": "...", "type": "...", "code": "..."}}
            if let error = json["error"] as? [String: Any] {
                if let message = error["message"] as? String {
                    // Include error code if available for more context
                    if let code = error["code"] as? String {
                        return "\(message) (code: \(code))"
                    }
                    return message
                }
            }
            // Alternative format: {"message": "..."}
            if let message = json["message"] as? String {
                return message
            }
            // Alternative format: {"detail": "..."}
            if let detail = json["detail"] as? String {
                return detail
            }
        }

        // Fallback to raw string if JSON parsing fails
        if let rawMessage = String(data: data, encoding: .utf8), !rawMessage.isEmpty {
            // Truncate very long error messages
            let truncated = rawMessage.count > 200 ? String(rawMessage.prefix(200)) + "..." : rawMessage
            return "HTTP \(statusCode): \(truncated)"
        }

        return "HTTP \(statusCode): Unknown error"
    }

    /// Test Anthropic connection by fetching models from the /models endpoint
    private func testAnthropicConnection(
        tempProvider: RemoteProvider,
        testHeaders: [String: String]
    ) async throws -> [String] {
        guard let baseURL = tempProvider.url(for: "/models") else {
            print("[Osaurus] Test Connection (Anthropic): Invalid URL")
            throw RemoteProviderError.invalidURL
        }

        print("[Osaurus] Test Connection (Anthropic): Requesting \(baseURL.absoluteString)")

        do {
            let models = try await RemoteProviderService.fetchAnthropicModels(
                baseURL: baseURL,
                headers: testHeaders
            )
            print("[Osaurus] Test Connection (Anthropic): Success - found \(models.count) models")
            return models
        } catch {
            print("[Osaurus] Test Connection (Anthropic): Error: \(error)")
            throw RemoteProviderError.connectionFailed(error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    private func notifyStatusChanged() {
        NotificationCenter.default.post(name: .remoteProviderStatusChanged, object: nil)
    }

    private func notifyModelsChanged() {
        NotificationCenter.default.post(name: .remoteProviderModelsChanged, object: nil)
    }

    private func userFacingErrorMessage(_ error: Error, for provider: RemoteProvider) -> String {
        guard provider.authType == .openAICodexOAuth || provider.providerType == .openAICodex else {
            return error.localizedDescription
        }
        return OpenAICodexOAuthService.diagnosticMessage(for: error)
    }

    // MARK: - Test Helpers

    /// Insert a fake connected provider directly into state, optionally with a
    /// matching service instance for tests that assert routing state. Test-only.
    @discardableResult
    func _testInstallConnectedProvider(
        _ provider: RemoteProvider,
        discoveredModels: [String],
        installService: Bool = false
    ) -> RemoteProviderService? {
        configuration.add(provider)
        ephemeralProviderIds.insert(provider.id)
        var state = RemoteProviderState(providerId: provider.id)
        state.isConnected = true
        state.discoveredModels = discoveredModels
        state.lastConnectedAt = Date()
        providerStates[provider.id] = state

        guard installService else { return nil }

        let service = RemoteProviderService(
            provider: provider,
            models: discoveredModels,
            resolvedHeaders: provider.resolvedHeaders()
        )
        services[provider.id] = service
        return service
    }

    /// Mutate a test-installed provider's state. Test-only.
    func _testSetState(_ state: RemoteProviderState, for id: UUID) {
        providerStates[id] = state
    }

    /// Replace the persisted record for a test-installed provider while
    /// preserving its UUID-backed live state/service. Used to prove that a
    /// display-name edit cannot invalidate or retarget a spawn identity.
    func _testUpdateProviderRecord(_ provider: RemoteProvider) {
        configuration.update(provider)
    }

    /// Await the connect spawned by the last `setOsaurusRouterEnabled(true)` so
    /// toggle tests can assert a deterministic post-connect state. Test-only.
    func _testAwaitRouterEnableWork() async {
        await osaurusRouterEnableTask?.value
    }

    /// Tear down test state added by `_testInstallConnectedProvider` and
    /// reset throttle / in-flight task so each test starts clean.
    func _testRemoveProviders(ids: [UUID]) {
        for id in ids {
            configuration.remove(id: id)
            ephemeralProviderIds.remove(id)
            providerStates.removeValue(forKey: id)
            lastModelRefetchAt.removeValue(forKey: id)
            if let service = services.removeValue(forKey: id) {
                Task { await service.invalidateSession() }
            }
        }
        refreshConnectedTask = nil
        osaurusRouterEnableTask?.cancel()
        osaurusRouterEnableTask = nil
        // Reset connectivity state so an offline-mode test can't leak its
        // simulated path edges (or a pending recovery sweep) into later tests.
        networkRecoveryTask?.cancel()
        networkRecoveryTask = nil
        lastNetworkPathWasSatisfied = nil
        isOffline = false
        // Restore the master switch to its default (on) so a test that toggled
        // it off can't bleed into another test's managed-router expectations.
        isOsaurusRouterEnabled = true
        UserDefaults.standard.removeObject(forKey: OsaurusRouter.enabledDefaultsKey)
        osaurusRouterModelCatalog = [:]
        testFetchModelsOverride = nil
        testConnectionTransportOverride = nil
        testIdentityExistsOverride = nil
        testRetrySleepOverride = nil
        testNetworkRecoverySettleDelayOverride = nil
    }
}

// MARK: - OpenAI Models Integration

extension RemoteProviderManager {
    /// Get OpenAI-compatible model objects for all connected providers.
    /// Remote models are hidden from API listings by default; only models
    /// the user exposed in Server > Models are returned.
    func getOpenAIModels() -> [OpenAIModel] {
        var models: [OpenAIModel] = []
        let exposure = ModelExposureStore.shared

        for provider in configuration.providers {
            guard let state = providerStates[provider.id], state.isConnected else {
                continue
            }

            let prefix = provider.name
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "/", with: "-")

            for modelId in state.discoveredModels {
                let prefixedId = "\(prefix)/\(modelId)"
                guard exposure.isExposed(id: prefixedId, kind: .remote) else { continue }
                var model = OpenAIModel(modelName: prefixedId)
                model.owned_by = provider.name
                models.append(model)
            }
        }

        return models
    }
}
