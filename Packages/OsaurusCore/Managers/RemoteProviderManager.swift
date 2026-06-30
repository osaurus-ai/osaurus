//
//  RemoteProviderManager.swift
//  osaurus
//
//  Manages remote OpenAI-compatible API provider connections.
//

import AppKit
import Foundation

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
            saveUserProviderConfiguration()
            // KPI: a user-configured remote provider. Only the closed-enum
            // type is captured. Ephemeral Bonjour-discovered providers are
            // excluded — they aren't a deliberate configuration action.
            FeatureTelemetry.remoteProviderAdded(providerType: provider.providerType.rawValue)
        }

        // Save API key to Keychain if provided
        if let apiKey = apiKey, !apiKey.isEmpty {
            RemoteProviderKeychain.saveAPIKey(apiKey, for: provider.id)
        }
        if let oauthTokens {
            RemoteProviderKeychain.saveOAuthTokens(oauthTokens, for: provider.id)
            RemoteProviderKeychain.deleteAPIKey(for: provider.id)
        }

        // Initialize state
        providerStates[provider.id] = RemoteProviderState(providerId: provider.id)

        // Auto-connect if enabled
        if provider.enabled {
            Task {
                try? await connect(providerId: provider.id)
            }
        }

        notifyStatusChanged()
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
        saveUserProviderConfiguration()

        // Update API key if provided (nil means no change, empty string means clear)
        if let apiKey = apiKey {
            if apiKey.isEmpty {
                RemoteProviderKeychain.deleteAPIKey(for: provider.id)
            } else {
                RemoteProviderKeychain.saveAPIKey(apiKey, for: provider.id)
            }
        }
        if let oauthTokens {
            RemoteProviderKeychain.saveOAuthTokens(oauthTokens, for: provider.id)
            RemoteProviderKeychain.deleteAPIKey(for: provider.id)
        }

        // Reconnect if was connected and still enabled
        if wasConnected && provider.enabled {
            Task {
                try? await connect(providerId: provider.id)
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
                    await RemoteProviderKeychain.saveOAuthTokensOffMainActor(refreshed, for: provider.id)
                }
            } else if provider.authType == .xaiOAuth {
                if let tokens = await provider.getOAuthTokensOffMainActor(), tokens.isExpired {
                    let refreshed = try await XAIOAuthService.refresh(tokens)
                    await RemoteProviderKeychain.saveOAuthTokensOffMainActor(refreshed, for: provider.id)
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
                    discoveredModels = try await RemoteProviderService.fetchModels(from: provider)
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

            // Update state to connected
            state.isConnecting = false
            state.isConnected = true
            state.discoveredModels = models
            state.lastConnectedAt = Date()
            state.lastError = nil
            state.lastReplayDiagnostics = nil
            providerStates[providerId] = state

            print("[Osaurus] Remote Provider '\(provider.name)': Connected with \(models.count) models")

            notifyStatusChanged()
            notifyModelsChanged()

        } catch {
            let errorMessage = userFacingErrorMessage(error, for: provider)
            // Update state with error
            state.isConnecting = false
            state.isConnected = false
            state.lastError = errorMessage
            state.lastReplayDiagnostics = (error as? RemoteProviderServiceError)?.replayDiagnostics
            state.discoveredModels = []
            providerStates[providerId] = state

            // Clean up — invalidate URLSession before discarding
            if let service = services.removeValue(forKey: providerId) {
                Task { await service.invalidateSession() }
            }

            print("[Osaurus] Remote Provider '\(provider.name)': Connection failed - \(errorMessage)")

            notifyStatusChanged()
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
        for provider in configuration.enabledProviders {
            // The managed Osaurus Router gets bounded retry so a transient
            // launch failure (offline, server 5xx, cold start) doesn't leave
            // the model picker without Osaurus options until a manual refresh.
            if provider.id == Self.osaurusRouterProviderId {
                await connectOsaurusRouterWithRetry()
                continue
            }
            do {
                try await connect(providerId: provider.id)
            } catch {
                print("[Osaurus] Failed to auto-connect to '\(provider.name)': \(error)")
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
            // a pure connect that tests can drain.
            osaurusRouterEnableTask = Task { [weak self] in
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
                await routerRetryBackoff(forAttempt: attempt)
                // Another path (picker/credits/activation/identity event) may
                // have connected while we waited — don't pile on a duplicate.
                if providerStates[Self.osaurusRouterProviderId]?.isConnected == true { return }
            }
        }
    }

    /// Exponential backoff between router connect attempts; honors the test seam.
    private func routerRetryBackoff(forAttempt attempt: Int) async {
        let delay = Self.osaurusRouterConnectRetryBaseDelay * pow(2.0, Double(attempt - 1))
        if let testRetrySleepOverride {
            await testRetrySleepOverride(delay)
        } else {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
            case .noIdentity, .invalidURL, .unauthorized,
                .belowMinimumTopUp, .insufficientFunds, .accountFrozen:
                return false
            }
        }
        if let serviceError = error as? RemoteProviderServiceError {
            switch serviceError {
            case .invalidResponse:
                return true
            case .invalidURL, .notConnected, .requestFailed, .requestFailedWithDiagnostics,
                .streamingError, .noModelsAvailable:
                return false
            }
        }
        return false
    }

    /// Observe identity creation/wipe and app re-activation so the managed
    /// Osaurus Router (re)connects without waiting for a user-driven refresh.
    private func registerIdentityAndActivationObservers() {
        observeOnMain(.osaurusIdentityChanged) { await $0.handleIdentityChanged() }
        observeOnMain(NSApplication.didBecomeActiveNotification) { await $0.handleAppDidBecomeActive() }
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
    /// configuration churn) on every activation.
    func handleAppDidBecomeActive() async {
        guard identityExists() else { return }
        guard providerStates[Self.osaurusRouterProviderId]?.isConnected != true else { return }
        await connectOsaurusRouterIfPossible()
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

    /// Get all connected services
    public func connectedServices() -> [RemoteProviderService] {
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

    /// Get all available models synchronously from cached state
    public func cachedAvailableModels() -> [(providerId: UUID, providerName: String, models: [String])] {
        ensureManagedOsaurusRouterProviderIfNeeded()
        var result: [(providerId: UUID, providerName: String, models: [String])] = []

        for provider in configuration.providers {
            if let state = providerStates[provider.id], state.isConnected {
                // Create prefixed model names
                let prefix = provider.name
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .replacingOccurrences(of: "/", with: "-")
                let prefixedModels = state.discoveredModels.map { "\(prefix)/\($0)" }
                result.append((providerId: provider.id, providerName: provider.name, models: prefixedModels))
            }
        }

        return result
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

    /// Metadata for an Osaurus Router model by its unprefixed id (the id as it
    /// appears in `discoveredModels`, e.g. "<upstream>/model-b"). Returns nil for
    /// non-router models or before the router has connected.
    ///
    /// Intentionally `internal`: `OsaurusRouterModel` is an internal type, and
    /// the only caller (`ModelPickerItemCache`) lives in this module.
    func osaurusRouterMetadata(for unprefixedModelId: String) -> OsaurusRouterModel? {
        osaurusRouterModelCatalog[unprefixedModelId]
    }

    /// Find the service that handles a given model
    public func findService(forModel model: String) -> RemoteProviderService? {
        for service in services.values where service.handles(requestedModel: model) {
            return service
        }
        return nil
    }

    // MARK: - Test Connection

    /// Test connection to a provider configuration without persisting
    public func testConnection(
        host: String,
        providerProtocol: RemoteProviderProtocol,
        port: Int?,
        basePath: String,
        authType: RemoteProviderAuthType,
        providerType: RemoteProviderType = .openaiLegacy,
        apiKey: String?,
        headers: [String: String],
        manualModelIds: [String] = []
    ) async throws -> [String] {
        if authType == .openAICodexOAuth && providerType == .openAICodex {
            // testConnection runs before sign-in (no OAuth tokens exist yet), so
            // we can't query the live /models endpoint here. The static fallback
            // is enough to render the "test succeeded" UI; the real catalog is
            // fetched on connect via RemoteProviderService.fetchModels.
            return OpenAICodexOAuthService.supportedModels
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
                    throw error.attachingReplayDiagnostics(diagnostics)
                } catch {
                    throw RemoteProviderServiceError.requestFailedWithDiagnostics(
                        "Invalid /models response: \(ProviderDiagnosticRedactor.safe(error.localizedDescription, maxLength: 240))",
                        diagnostics
                    )
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
        // Restore the master switch to its default (on) so a test that toggled
        // it off can't bleed into another test's managed-router expectations.
        isOsaurusRouterEnabled = true
        UserDefaults.standard.removeObject(forKey: OsaurusRouter.enabledDefaultsKey)
        osaurusRouterModelCatalog = [:]
        testFetchModelsOverride = nil
        testConnectionTransportOverride = nil
        testIdentityExistsOverride = nil
        testRetrySleepOverride = nil
    }
}

// MARK: - OpenAI Models Integration

extension RemoteProviderManager {
    /// Get OpenAI-compatible model objects for all connected providers
    func getOpenAIModels() -> [OpenAIModel] {
        var models: [OpenAIModel] = []

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
                var model = OpenAIModel(modelName: prefixedId)
                model.owned_by = provider.name
                models.append(model)
            }
        }

        return models
    }
}
