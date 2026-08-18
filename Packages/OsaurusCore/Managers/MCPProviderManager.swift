//
//  MCPProviderManager.swift
//  osaurus
//
//  Manages remote MCP provider connections and tool execution.
//

import AppKit
import Foundation
import MCP
import Network

/// Notification posted when provider connection status changes
extension Foundation.Notification.Name {
    static let mcpProviderStatusChanged = Foundation.Notification.Name("MCPProviderStatusChanged")
}

/// Cross-actor cancellation token for one provider connection attempt. The
/// launch lock makes host child admission atomic with cancellation: either the
/// child starts and disconnect can see its registered runner, or cancellation
/// wins and no child is launched.
final class MCPConnectionOperation: @unchecked Sendable {
    let providerId: UUID
    let generation: UInt64

    private let lock = NSLock()
    private var cancelled = false

    init(providerId: UUID, generation: UInt64) {
        self.providerId = providerId
        self.generation = generation
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func checkCancellation() throws {
        guard !isCancelled else { throw CancellationError() }
    }

    func withLaunchPermission(_ launch: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try launch()
    }
}

/// Manages all remote MCP provider connections
@MainActor
public final class MCPProviderManager: ObservableObject {
    public static let shared = MCPProviderManager()

    /// Current configuration
    @Published public private(set) var configuration: MCPProviderConfiguration

    /// Runtime state for each provider
    @Published public private(set) var providerStates: [UUID: MCPProviderState] = [:]

    /// Active MCP clients keyed by provider ID
    private var clients: [UUID: MCP.Client] = [:]
    private var clientGenerations: [UUID: UInt64] = [:]

    /// A monotonically increasing generation plus the currently in-flight
    /// operation prevent a suspended connection from committing after a
    /// disconnect or a newer connection attempt.
    private var connectionGenerations: [UUID: UInt64] = [:]
    private var activeConnectionOperations: [UUID: MCPConnectionOperation] = [:]
    private var disconnectEpochs: [UUID: UInt64] = [:]

    /// Discovered MCP tools keyed by provider ID
    private var discoveredTools: [UUID: [MCP.Tool]] = [:]

    /// Registered tool instances keyed by provider ID
    private var registeredTools: [UUID: [MCPProviderTool]] = [:]
    private var registeredToolGenerations: [UUID: UInt64] = [:]

    /// Host-resident stdio subprocess owners keyed by provider ID. Held so
    /// `disconnect(...)` can terminate them — the subprocess only stays
    /// alive while we hold the runner.
    private var hostStdioRunners: [UUID: MCPStdioHostRunner] = [:]

    /// Sandbox-resident stdio subprocess owners keyed by provider ID. Same
    /// lifecycle as `hostStdioRunners` but routed through the container.
    private var sandboxStdioRunners: [UUID: SandboxStdioRunner] = [:]
    private var stdioRunnerOperations: [UUID: MCPConnectionOperation] = [:]
    private var stdioRunnerTokens: [UUID: UUID] = [:]

    private init() {
        self.configuration = MCPProviderConfigurationStore.load()

        // Initialize states for all providers
        for provider in configuration.providers {
            providerStates[provider.id] = MCPProviderState(providerId: provider.id)
        }

        registerRecoveryObservers()
        startNetworkRecoveryMonitor()
    }

    // MARK: - Provider Management

    /// Add a new provider
    public func addProvider(_ provider: MCPProvider, token: String?) {
        configuration.add(provider)
        // KPI: a user-configured MCP tool provider. Only the transport kind
        // is captured — never the command, URL, or args.
        FeatureTelemetry.mcpProviderAdded(transport: provider.transport.rawValue)

        // Initialize state
        providerStates[provider.id] = MCPProviderState(providerId: provider.id)

        // Save the token off the main thread (SecItemAdd/SecItemUpdate can
        // block for seconds under securityd contention). The on-disk provider
        // record is persisted only after the keychain write lands, so an
        // interrupted add can never leave an enabled provider on disk without
        // its token, and auto-connect reads the fresh credential.
        let providerId = provider.id
        let shouldConnect = provider.enabled
        Keychain.performInBackground {
            var credentialsDurable = true
            if let token = token, !token.isEmpty {
                credentialsDurable = MCPProviderKeychain.saveToken(token, for: providerId)
            }
            Task { @MainActor in
                MCPProviderManager.shared.finishCredentialStaging(
                    providerId: providerId,
                    credentialsDurable: credentialsDurable,
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
        connect shouldConnect: Bool
    ) {
        if !credentialsDurable, !KeychainQueryHelpers.disablesKeychainForProcess {
            providerStates[providerId]?.lastError =
                "Could not save credentials to the Keychain — they may not survive relaunch."
            notifyStatusChanged()
        }
        MCPProviderConfigurationStore.save(configuration)
        if shouldConnect {
            Task {
                try? await connect(providerId: providerId)
            }
        }
    }

    /// Update an existing provider
    public func updateProvider(_ provider: MCPProvider, token: String?) {
        let wasConnected = providerStates[provider.id]?.isConnected ?? false
        let wasConnecting = providerStates[provider.id]?.isConnecting ?? false

        // Cancel both established and in-flight runtimes before replacing the
        // configuration snapshot they were built from.
        if wasConnected || wasConnecting
            || activeConnectionOperations[provider.id] != nil
            || clients[provider.id] != nil
            || hostStdioRunners[provider.id] != nil
            || sandboxStdioRunners[provider.id] != nil {
            disconnect(providerId: provider.id)
        }

        let previous = configuration.provider(id: provider.id)
        configuration.update(provider)

        // Update credentials off the main thread; persist the updated record
        // only after the keychain mutations land, and reconnect after both so
        // connect() reads the fresh token.
        let providerId = provider.id
        let shouldReconnect = (wasConnected || wasConnecting) && provider.enabled
        let dropsOAuth = previous?.authType == .oauth && provider.authType != .oauth
        Keychain.performInBackground {
            var credentialsDurable = true
            // Update token if provided (empty string means clear token)
            if let token = token {
                if token.isEmpty {
                    MCPProviderKeychain.deleteToken(for: providerId)
                } else {
                    credentialsDurable = MCPProviderKeychain.saveToken(token, for: providerId)
                }
            }

            // If the user switched away from OAuth, drop any cached tokens
            // for this provider.
            if dropsOAuth {
                MCPProviderKeychain.deleteOAuthTokens(for: providerId)
                MCPProviderKeychain.deleteOAuthClientSecret(for: providerId)
            }

            Task { @MainActor in
                MCPProviderManager.shared.finishCredentialStaging(
                    providerId: providerId,
                    credentialsDurable: credentialsDurable,
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
        MCPProviderConfigurationStore.save(configuration)

        // Clean up state
        providerStates.removeValue(forKey: id)

        notifyStatusChanged()
    }

    /// Returns providers associated with a plugin id.
    public func providers(forPluginId pluginId: String) -> [MCPProvider] {
        configuration.providers.filter { $0.pluginId == pluginId }
    }

    /// Remove every provider installed by a plugin. Returns the number deleted.
    @discardableResult
    public func deleteByPluginId(_ pluginId: String) -> Int {
        let matches = providers(forPluginId: pluginId)
        for provider in matches {
            removeProvider(id: provider.id)
        }
        return matches.count
    }

    /// Set enabled state for a provider
    /// When enabled is true, automatically connects to the provider
    /// When enabled is false, disconnects from the provider
    public func setEnabled(_ enabled: Bool, for providerId: UUID) {
        configuration.setEnabled(enabled, for: providerId)
        MCPProviderConfigurationStore.save(configuration)

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

    // MARK: - Connection Management

    @discardableResult
    func beginConnectionOperation(providerId: UUID) -> MCPConnectionOperation {
        activeConnectionOperations[providerId]?.cancel()
        let generation = (connectionGenerations[providerId] ?? 0) &+ 1
        connectionGenerations[providerId] = generation
        let operation = MCPConnectionOperation(providerId: providerId, generation: generation)
        activeConnectionOperations[providerId] = operation
        return operation
    }

    func connectionOperationIsCurrent(_ operation: MCPConnectionOperation) -> Bool {
        activeConnectionOperations[operation.providerId] === operation
            && connectionGenerations[operation.providerId] == operation.generation
            && !operation.isCancelled
    }

    private func requireCurrentConnectionOperation(_ operation: MCPConnectionOperation) throws {
        try Task.checkCancellation()
        try operation.checkCancellation()
        guard connectionOperationIsCurrent(operation) else { throw CancellationError() }
    }

    private func finishConnectionOperation(_ operation: MCPConnectionOperation) {
        guard activeConnectionOperations[operation.providerId] === operation else { return }
        activeConnectionOperations.removeValue(forKey: operation.providerId)
    }

    private func invalidateConnectionOperation(providerId: UUID) {
        activeConnectionOperations.removeValue(forKey: providerId)?.cancel()
        stdioRunnerOperations[providerId]?.cancel()
        connectionGenerations[providerId] = (connectionGenerations[providerId] ?? 0) &+ 1
        disconnectEpochs[providerId] = (disconnectEpochs[providerId] ?? 0) &+ 1
    }

    /// Connect to a provider
    public func connect(providerId: UUID) async throws {
        guard let provider = configuration.provider(id: providerId) else {
            throw MCPProviderError.providerNotFound
        }
        let operation = beginConnectionOperation(providerId: providerId)
        defer { finishConnectionOperation(operation) }
        try await performConnect(
            provider: provider,
            allowOAuthRetry: true,
            operation: operation
        )
    }

    private func performConnect(
        provider: MCPProvider,
        allowOAuthRetry: Bool,
        operation: MCPConnectionOperation
    ) async throws {
        let providerId = provider.id

        try requireCurrentConnectionOperation(operation)
        guard provider.enabled else {
            throw MCPProviderError.providerDisabled
        }

        // Update state to connecting
        var state = providerStates[providerId] ?? MCPProviderState(providerId: providerId)
        state.isConnecting = true
        state.lastError = nil
        state.lastFailureWasTransient = false
        // Clear any stale "needs auth" state from a prior attempt — we'll re-set it below
        // if this attempt also surfaces a 401.
        state.requiresAuth = false
        state.resourceMetadataURL = nil
        providerStates[providerId] = state

        // Held outside the do/catch so the failure path can tear the
        // half-connected client down. Without this, a failed HTTP connect
        // leaked the transport's URLSession — and, with streaming enabled,
        // the SDK's SSE retry loop kept reconnecting forever with stale
        // credentials because nobody ever called `disconnect()`.
        var attemptClient: MCP.Client?

        do {
            // Create authenticated transport
            let transport = try await createTransport(for: provider, operation: operation)
            try requireCurrentConnectionOperation(operation)

            // Create MCP client
            let client = MCP.Client(
                name: "Osaurus",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            )
            attemptClient = client

            // Connect under a timeout. Without this, a stdio subprocess that
            // spawned successfully but never speaks MCP would leave the card
            // stuck on "Connecting…" indefinitely. `discoverTools` already
            // uses `withTimeout` for the second leg of the handshake — we
            // mirror that for the first.
            try await withTimeout(seconds: provider.discoveryTimeout) {
                _ = try await client.connect(transport: transport)
            }
            try requireCurrentConnectionOperation(operation)

            // Store client, tearing down any client we're replacing (a
            // connect on an already-connected provider must not leak the
            // old transport's URLSession / SSE loop).
            if let replaced = clients[providerId], replaced !== client {
                Task.detached { await replaced.disconnect() }
            }
            clients[providerId] = client
            clientGenerations[providerId] = operation.generation

            await registerRemoteToolListChangedHandler(
                client: client,
                providerId: providerId,
                generation: operation.generation
            )
            try requireCurrentConnectionOperation(operation)

            // Discover tools
            try await discoverTools(
                for: providerId,
                client: client,
                provider: provider,
                operation: operation
            )
            try requireCurrentConnectionOperation(operation)

            guard commitConnectedState(provider: provider, operation: operation) else {
                throw CancellationError()
            }
            notifyStatusChanged()

        } catch {
            let connectionError = error
            guard connectionOperationIsCurrent(operation), !Task.isCancelled else {
                await cleanupConnectAttempt(
                    providerId: providerId,
                    attemptClient: attemptClient,
                    operation: operation,
                    clearCurrentResources: false
                )
                throw CancellationError()
            }

            // Stdio transports talk to a local subprocess, not an HTTP server,
            // so there's no 401 to probe — the error is either a spawn
            // failure or a protocol mismatch.
            let authFailure: MCPAuthFailureProbeResult? =
                provider.transport == .http
                ? await probeAuthFailure(for: provider)
                : nil
            guard connectionOperationIsCurrent(operation), !Task.isCancelled else {
                await cleanupConnectAttempt(
                    providerId: providerId,
                    attemptClient: attemptClient,
                    operation: operation,
                    clearCurrentResources: false
                )
                throw CancellationError()
            }

            if let authFailure {
                // Try one refresh+retry for OAuth providers when we already have tokens.
                // Off the main actor: the Keychain read blocks on securityd XPC + decrypt.
                if allowOAuthRetry,
                    provider.authType == .oauth,
                    let tokens = await Task.detached(
                        priority: .userInitiated,
                        operation: { MCPProviderKeychain.getOAuthTokens(for: providerId) }
                    ).value,
                    tokens.refreshToken?.isEmpty == false {
                    guard connectionOperationIsCurrent(operation), !Task.isCancelled else {
                        await cleanupConnectAttempt(
                            providerId: providerId,
                            attemptClient: attemptClient,
                            operation: operation,
                            clearCurrentResources: false
                        )
                        throw CancellationError()
                    }
                    do {
                        _ = try await MCPOAuthService.refresh(provider: provider, tokens: tokens)
                        try requireCurrentConnectionOperation(operation)
                        await cleanupConnectAttempt(
                            providerId: providerId,
                            attemptClient: attemptClient,
                            operation: operation,
                            clearCurrentResources: true
                        )
                        // Re-enter without retry budget so we can't loop.
                        try await performConnect(
                            provider: provider,
                            allowOAuthRetry: false,
                            operation: operation
                        )
                        return
                    } catch let refreshError {
                        guard connectionOperationIsCurrent(operation), !Task.isCancelled else {
                            await cleanupConnectAttempt(
                                providerId: providerId,
                                attemptClient: attemptClient,
                                operation: operation,
                                clearCurrentResources: false
                            )
                            throw CancellationError()
                        }
                        if MCPOAuthService.isPermanentAuthFailure(refreshError) {
                            handlePermanentOAuthFailure(providerId: providerId)
                        }
                        // Fall through and surface the original auth challenge.
                    }
                }

                state = providerStates[providerId] ?? MCPProviderState(providerId: providerId)
                state.requiresAuth = true
                state.resourceMetadataURL = authFailure.challenge?.resourceMetadataURL
                state.lastError = MCPAuthFailureProbe.failureDescription(
                    authType: provider.authType,
                    probe: authFailure
                )
            } else {
                state = providerStates[providerId] ?? MCPProviderState(providerId: providerId)
                state.lastError = connectionError.localizedDescription
            }

            state.isConnecting = false
            state.isConnected = false
            state.discoveredToolCount = 0
            state.discoveredToolNames = []
            // An auth challenge is terminal (requires sign-in); everything
            // else is classified so the launch/network/wake/activation
            // recovery paths know whether a retry can help.
            state.lastFailureWasTransient =
                authFailure == nil && Self.isTransientConnectError(connectionError)
            providerStates[providerId] = state

            await cleanupConnectAttempt(
                providerId: providerId,
                attemptClient: attemptClient,
                operation: operation,
                clearCurrentResources: true
            )

            print("[Osaurus] MCP Provider '\(provider.name)': Connection failed - \(connectionError)")
            notifyStatusChanged()
            throw connectionError
        }
    }

    private func cleanupConnectAttempt(
        providerId: UUID,
        attemptClient: MCP.Client?,
        operation: MCPConnectionOperation,
        clearCurrentResources: Bool
    ) async {
        let mayClearCurrentResources =
            clearCurrentResources && connectionOperationIsCurrent(operation)
        var teardown: [MCP.Client] = []
        if let attemptClient { teardown.append(attemptClient) }

        let ownsStoredClient = clientGenerations[providerId] == operation.generation
        if mayClearCurrentResources || ownsStoredClient {
            if let storedClient = clients.removeValue(forKey: providerId),
                storedClient !== attemptClient {
                teardown.append(storedClient)
            }
            clientGenerations.removeValue(forKey: providerId)
        }

        let ownsRegisteredTools = registeredToolGenerations[providerId] == operation.generation
        var catalogChanged = false
        if mayClearCurrentResources || ownsRegisteredTools {
            if let tools = registeredTools[providerId] {
                ToolRegistry.shared.unregister(names: tools.map(\.name))
                catalogChanged = true
            }
            discoveredTools.removeValue(forKey: providerId)
            registeredTools.removeValue(forKey: providerId)
            registeredToolGenerations.removeValue(forKey: providerId)
        }

        stopStdioRunners(
            for: providerId,
            operation: mayClearCurrentResources ? nil : operation
        )
        for client in teardown {
            await client.disconnect()
        }
        if catalogChanged {
            await publishToolCatalogChanged()
        }
    }

    @discardableResult
    func commitConnectedState(
        provider: MCPProvider,
        operation: MCPConnectionOperation
    ) -> Bool {
        guard !Task.isCancelled,
            connectionOperationIsCurrent(operation),
            var updatedState = providerStates[provider.id]
        else { return false }
        updatedState.isConnecting = false
        updatedState.isConnected = true
        updatedState.lastConnectedAt = Date()
        updatedState.lastError = nil
        updatedState.requiresAuth = false
        updatedState.resourceMetadataURL = nil
        updatedState.lastFailureWasTransient = false
        providerStates[provider.id] = updatedState
        print(
            "[Osaurus] MCP Provider '\(provider.name)': Connected with \(updatedState.discoveredToolCount) tools"
        )
        return true
    }

    /// Disconnect from a provider
    public func disconnect(providerId: UUID) {
        // Invalidate first so any suspended connect/retry observes cancellation
        // before it can publish a client, tools, or connected state.
        invalidateConnectionOperation(providerId: providerId)

        // Unregister tools
        if let tools = registeredTools[providerId] {
            let toolNames = tools.map { $0.name }
            ToolRegistry.shared.unregister(names: toolNames)
        }

        // Clean up. HTTP transports must be disconnected explicitly:
        // dropping the reference alone never invalidates the transport's
        // URLSession, and with streaming enabled the SDK's SSE retry loop
        // keeps reconnecting every few seconds forever.
        if let client = clients.removeValue(forKey: providerId) {
            Task.detached { await client.disconnect() }
        }
        clientGenerations.removeValue(forKey: providerId)
        discoveredTools.removeValue(forKey: providerId)
        registeredTools.removeValue(forKey: providerId)
        registeredToolGenerations.removeValue(forKey: providerId)

        // Tear down any stdio subprocesses owned by this provider.
        stopStdioRunners(for: providerId)

        // Update state
        if var state = providerStates[providerId] {
            state.isConnected = false
            state.isConnecting = false
            state.discoveredToolCount = 0
            state.discoveredToolNames = []
            // Disconnecting clears any "needs auth" flag; the next connect attempt
            // will re-detect it if the server still demands sign-in.
            state.requiresAuth = false
            state.resourceMetadataURL = nil
            providerStates[providerId] = state
        }

        if let provider = configuration.provider(id: providerId) {
            print("[Osaurus] MCP Provider '\(provider.name)': Disconnected")
        }

        scheduleToolCatalogChanged()
        notifyStatusChanged()
    }

    /// Reconnect to a provider
    public func reconnect(providerId: UUID) async throws {
        disconnect(providerId: providerId)
        try await connect(providerId: providerId)
    }

    /// Connect providers at app launch.
    ///
    /// Honors the per-provider "Auto-connect" setting: only providers the
    /// user left enabled AND auto-connect connect at launch — an enabled
    /// provider with auto-connect off stays dormant until connected
    /// explicitly, matching `RemoteProviderManager`.
    ///
    /// Connects run concurrently: each provider already has its own
    /// discovery timeout, and one slow or unreachable MCP server must not
    /// delay every other provider (or, upstream, the remote model
    /// providers). Transient failures get bounded retry; the network / wake /
    /// activation recovery sweeps handle anything that outlives the budget.
    public func connectEnabledProviders() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in configuration.autoConnectProviders {
                let providerId = provider.id
                let providerName = provider.name
                group.addTask {
                    await self.connectProviderWithTransientRetry(
                        providerId: providerId, providerName: providerName)
                }
            }
        }
    }

    /// Total attempts (including the first) for a launch-time connect.
    static let connectMaxAttempts = 3
    /// Base delay for exponential backoff between connect retries.
    static let connectRetryBaseDelay: TimeInterval = 1.0

    /// Test seam: replaces the real backoff sleep so retry tests don't wait
    /// on wall-clock time.
    var testRetrySleepOverride: (@MainActor (TimeInterval) async -> Void)?

    /// Test seam: when set, used in place of the real `connect(providerId:)`
    /// by the launch/recovery paths so orchestration tests don't open
    /// network connections.
    var testConnectOverride: (@MainActor (UUID) async throws -> Void)?

    /// Connect one provider with bounded retry on *transient* failures
    /// (offline at launch, DNS not up yet, handshake timeout). Terminal
    /// failures — auth challenges, bad config, protocol mismatch — stop
    /// immediately because a retry cannot fix them.
    private func connectProviderWithTransientRetry(
        providerId: UUID,
        providerName: String,
        maxAttempts: Int = MCPProviderManager.connectMaxAttempts
    ) async {
        let attempts = max(1, maxAttempts)
        let disconnectEpoch = disconnectEpochs[providerId] ?? 0
        for attempt in 1 ... attempts {
            guard (disconnectEpochs[providerId] ?? 0) == disconnectEpoch,
                configuration.provider(id: providerId)?.enabled == true,
                !Task.isCancelled
            else { return }
            do {
                if let testConnectOverride {
                    try await testConnectOverride(providerId)
                } else {
                    try await connect(providerId: providerId)
                }
                return
            } catch {
                let transient =
                    Self.isTransientConnectError(error)
                    && providerStates[providerId]?.requiresAuth != true
                guard transient, attempt < attempts else {
                    print("[Osaurus] Failed to auto-connect to '\(providerName)': \(error)")
                    return
                }
                let delay = Self.connectRetryBaseDelay * pow(2.0, Double(attempt - 1))
                if let testRetrySleepOverride {
                    await testRetrySleepOverride(delay)
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard (disconnectEpochs[providerId] ?? 0) == disconnectEpoch,
                    configuration.provider(id: providerId)?.enabled == true,
                    !Task.isCancelled
                else { return }
                // Another path (manual connect, OAuth sign-in) may have
                // connected while we waited — don't pile on a duplicate.
                if providerStates[providerId]?.isConnected == true
                    || providerStates[providerId]?.isConnecting == true {
                    return
                }
            }
        }
    }

    /// Whether a connect error is worth retrying. Transient = network loss /
    /// timeout / DNS / TLS and the handshake/discovery timeout. Terminal =
    /// auth challenges, spawn failures, protocol errors, plus anything
    /// unrecognized (a tight retry loop must not hammer those).
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
        if let providerError = error as? MCPProviderError, case .timeout = providerError {
            return true
        }
        return false
    }

    // MARK: - Transient-failure recovery
    //
    // Mirrors `RemoteProviderManager`'s recovery machinery: providers whose
    // last connect failed transiently are reconnected on the network
    // recovery edge (and first satisfied baseline), on wake from sleep, and
    // on app re-activation — without the user toggling anything.

    nonisolated(unsafe) private var networkPathMonitor: NWPathMonitor?
    /// Last observed satisfied-ness; reconnect sweeps fire on the
    /// unsatisfied → satisfied edge and on the very first satisfied
    /// observation (providers can fail transiently before the monitor
    /// produces its baseline at launch).
    private var lastNetworkPathWasSatisfied: Bool?  // swiftlint:disable:this discouraged_optional_boolean
    private var networkRecoveryTask: Task<Void, Never>?

    /// Test seam: shrink the recovery settle delay so sweep tests don't wait
    /// on wall-clock time.
    var testNetworkRecoverySettleDelayOverride: TimeInterval?

    private func registerRecoveryObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reconnectTransientlyFailedProviders()
            }
        }
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

    private func startNetworkRecoveryMonitor() {
        let monitor = NWPathMonitor()
        networkPathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "ai.osaurus.mcp.pathmonitor"))
    }

    /// Internal (not private) so tests can drive connectivity edges without
    /// a real `NWPath`.
    func handleNetworkPathUpdate(satisfied: Bool) {
        defer { lastNetworkPathWasSatisfied = satisfied }
        guard satisfied, lastNetworkPathWasSatisfied != true else { return }
        scheduleTransientRecoverySweep()
    }

    /// Schedule a debounced sweep reconnecting transiently-failed providers.
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

    /// Reconnect every enabled auto-connect provider whose last failure was
    /// transient and which isn't connected, mid-connect, or waiting on a
    /// sign-in. Each `connect` re-evaluates state so concurrent triggers
    /// stay idempotent.
    func reconnectTransientlyFailedProviders() async {
        for provider in configuration.autoConnectProviders {
            guard !Task.isCancelled else { return }
            let state = providerStates[provider.id]
            guard state?.isConnected != true, state?.isConnecting != true,
                state?.lastFailureWasTransient == true, state?.requiresAuth != true
            else { continue }
            if let testConnectOverride {
                try? await testConnectOverride(provider.id)
            } else {
                try? await connect(providerId: provider.id)
            }
        }
    }

    /// Await the in-flight recovery sweep, if any. Test-only.
    func _testAwaitNetworkRecoverySweep() async {
        await networkRecoveryTask?.value
    }

    // MARK: - Test Helpers

    /// Add providers to the in-memory configuration without touching disk,
    /// Keychain, or the network. Test-only.
    func _testInstallProviders(_ providers: [MCPProvider]) {
        for provider in providers {
            configuration.add(provider)
            if providerStates[provider.id] == nil {
                providerStates[provider.id] = MCPProviderState(providerId: provider.id)
            }
        }
    }

    /// Mutate a test-installed provider's runtime state. Test-only.
    func _testSetState(_ state: MCPProviderState, for id: UUID) {
        providerStates[id] = state
    }

    /// Tear down test providers and reset seams/recovery state so each test
    /// starts clean. Test-only.
    func _testRemoveProviders(ids: [UUID]) {
        configuration.providers.removeAll { ids.contains($0.id) }
        for id in ids {
            disconnect(providerId: id)
            providerStates.removeValue(forKey: id)
            connectionGenerations.removeValue(forKey: id)
            disconnectEpochs.removeValue(forKey: id)
        }
        networkRecoveryTask?.cancel()
        networkRecoveryTask = nil
        lastNetworkPathWasSatisfied = nil
        testConnectOverride = nil
        testRetrySleepOverride = nil
        testNetworkRecoverySettleDelayOverride = nil
    }

    func _testInvalidateConnectionOperation(providerId: UUID) {
        invalidateConnectionOperation(providerId: providerId)
    }

    func _testRegisterStdioRunnerOperation(_ operation: MCPConnectionOperation) -> UUID {
        let token = UUID()
        stdioRunnerOperations[operation.providerId] = operation
        stdioRunnerTokens[operation.providerId] = token
        return token
    }

    func _testHandleStdioProcessExit(
        providerId: UUID,
        runnerToken: UUID,
        exitCode: Int32 = 1,
        stderrTail: String = "fixture exit"
    ) {
        handleStdioProcessExit(
            providerId: providerId,
            runnerToken: runnerToken,
            exitCode: exitCode,
            stderrTail: stderrTail
        )
    }

    /// Disconnect from all providers
    public func disconnectAll() {
        let providerIds = Set(clients.keys)
            .union(activeConnectionOperations.keys)
            .union(hostStdioRunners.keys)
            .union(sandboxStdioRunners.keys)
        for providerId in providerIds {
            disconnect(providerId: providerId)
        }
    }

    /// Quit-path teardown: disconnect every provider AND await each stdio
    /// subprocess owner's `stop()` so child `Process`es are reaped instead
    /// of orphaned. `disconnectAll()` only fire-and-forgets the runner stops
    /// (fine for an interactive disconnect, but at quit the app can exit
    /// before those detached tasks run). We snapshot + detach the runners
    /// first so the synchronous `disconnect` path below doesn't double-stop
    /// them, then await the real teardown.
    public func shutdownAllStdioRunners() async {
        let hostRunners = Array(hostStdioRunners.values)
        let sandboxRunners = Array(sandboxStdioRunners.values)
        hostStdioRunners.removeAll()
        sandboxStdioRunners.removeAll()
        stdioRunnerOperations.removeAll()
        stdioRunnerTokens.removeAll()

        disconnectAll()

        for runner in hostRunners {
            await runner.stop()
        }
        for runner in sandboxRunners {
            await runner.stop()
        }
    }

    // MARK: - Tool Execution

    /// Execute a tool on a provider.
    ///
    /// Remote streamable-HTTP servers expire their `Mcp-Session-Id` after
    /// idle periods or restarts, and OAuth access tokens baked into the
    /// transport at connect time go stale. Both used to strand the provider
    /// in a "Connected" state whose every tool call failed until the user
    /// manually reconnected. We now reconnect once (which rebuilds the
    /// transport with fresh auth and a fresh session) and retry the call.
    public func executeTool(providerId: UUID, toolName: String, argumentsJSON: String) async throws -> String {
        guard let provider = configuration.provider(id: providerId) else {
            throw MCPProviderError.providerNotFound
        }

        // A missing client on an enabled provider (transient connect failure
        // at launch, earlier session loss) is recoverable — reconnect instead
        // of failing the model's tool call outright.
        if clients[providerId] == nil, provider.enabled {
            try await connect(providerId: providerId)
        }
        guard let client = clients[providerId] else {
            throw MCPProviderError.notConnected
        }

        let arguments = try MCPProviderTool.convertArgumentsToMCPValues(argumentsJSON)
        let timeout = provider.toolCallTimeout

        // Run the network call off MainActor so it doesn't block the UI thread.
        let (content, isError): ([MCP.Tool.Content], Bool?)
        do {
            (content, isError) = try await Self.callMCPTool(
                client: client,
                toolName: toolName,
                arguments: arguments,
                timeout: timeout
            )
        } catch let error where Self.isRecoverableSessionError(error) {
            if var reconnectState = providerStates[providerId] {
                reconnectState.isAutoReconnecting = true
                providerStates[providerId] = reconnectState
                notifyStatusChanged()
            }
            defer {
                if var finished = providerStates[providerId] {
                    finished.isAutoReconnecting = false
                    providerStates[providerId] = finished
                }
            }
            // One reconnect + one retry; the rebuilt transport carries fresh
            // OAuth/bearer credentials and negotiates a new session. If the
            // reconnect fails we surface the reconnect error (it is the more
            // actionable one: auth required, server down, ...).
            try await connect(providerId: providerId)
            guard let freshClient = clients[providerId] else {
                throw MCPProviderError.notConnected
            }
            if var reconnected = providerStates[providerId] {
                reconnected.lastAutoReconnectAt = Date()
                providerStates[providerId] = reconnected
                notifyStatusChanged()
            }
            (content, isError) = try await Self.callMCPTool(
                client: freshClient,
                toolName: toolName,
                arguments: arguments,
                timeout: timeout
            )
        }

        // Check for error
        if let isError = isError, isError {
            let errorText = content.compactMap { item -> String? in
                if case .text(let text, _, _) = item { return text }
                return nil
            }.joined(separator: "\n")
            throw MCPProviderError.toolExecutionFailed(errorText.isEmpty ? "Tool returned error" : errorText)
        }

        // Convert content to string
        return MCPProviderTool.convertMCPContent(content)
    }

    /// True when a tool-call failure indicates the connection/session is
    /// stale (expired `Mcp-Session-Id`, expired auth token, closed
    /// transport) rather than a failure of the tool itself. These are the
    /// cases where the request was rejected before execution, so a single
    /// reconnect + retry is safe (no double-execution risk). Timeouts are
    /// deliberately excluded: the server may have executed the tool.
    ///
    /// The MCP SDK exposes these conditions only as `internalError`
    /// message strings, so we match the exact strings it produces
    /// (`HTTPClientTransport.processHTTPResponse` / `send`).
    nonisolated static func isRecoverableSessionError(_ error: Error) -> Bool {
        guard let mcpError = error as? MCPError else { return false }
        switch mcpError {
        case .connectionClosed:
            return true
        case .internalError(let message):
            guard let message else { return false }
            return message == "Session expired"
                || message == "Authentication required"
                || message == "Access forbidden"
                || message == "Transport not connected"
        default:
            return false
        }
    }

    /// Trampoline that runs the MCP network call outside MainActor isolation.
    /// Non-rejoining timeout (see `withTimeout`): a tool call the SDK cannot
    /// cancel is abandoned at the deadline instead of pinning the agent turn.
    private nonisolated static func callMCPTool(
        client: MCP.Client,
        toolName: String,
        arguments: [String: MCP.Value],
        timeout: TimeInterval
    ) async throws -> ([MCP.Tool.Content], Bool?) {
        do {
            return try await valueWithDeadline(
                seconds: timeout,
                operationName: "MCP tool \(toolName)"
            ) {
                try await client.callTool(name: toolName, arguments: arguments)
            }
        } catch is DeadlineExceededError {
            throw MCPProviderError.timeout
        }
    }

    // MARK: - Test Connection

    /// Spin up the same runner we'd use in production, complete an MCP
    /// handshake under a tight timeout, list the available tools, then
    /// tear everything down. Returns the tool count for the editor's
    /// success label. Stdio test runs are intentionally short-lived;
    /// the provider isn't persisted and no state is left behind.
    public func testStdioConnection(provider: MCPProvider) async throws -> Int {
        let result = await MCPProviderProbeService.probeStdio(provider: provider)
        guard result.succeeded else {
            throw MCPProviderError.connectionFailed(result.redactedMessage)
        }
        return result.toolCount
    }

    /// Tear down any live-connection stdio runners registered against
    /// `providerId`, including half-started runners in `connect`'s catch path.
    private func stopStdioRunners(
        for providerId: UUID,
        operation: MCPConnectionOperation? = nil
    ) {
        if let operation {
            guard let registered = stdioRunnerOperations[providerId], registered === operation else {
                return
            }
        }
        stdioRunnerOperations.removeValue(forKey: providerId)
        stdioRunnerTokens.removeValue(forKey: providerId)
        if let runner = hostStdioRunners.removeValue(forKey: providerId) {
            Task { await runner.stop() }
        }
        if let runner = sandboxStdioRunners.removeValue(forKey: providerId) {
            Task { await runner.stop() }
        }
    }

    /// Test connection to a provider without persisting
    public func testConnection(url: String, token: String?, headers: [String: String]) async throws -> Int {
        guard let endpoint = URL(string: url) else {
            throw MCPProviderError.invalidURL
        }

        // Create temporary transport
        var allHeaders: [String: String] = headers
        if let token = token, !token.isEmpty {
            allHeaders["Authorization"] = "Bearer \(token)"
        }

        let transport = MCPHTTPTransportBuilder.makeTransport(
            endpoint: endpoint,
            headers: allHeaders,
            streaming: false,
            discoveryTimeout: 10,
            toolCallTimeout: 10
        )

        let client = MCP.Client(
            name: "Osaurus",
            version: "1.0.0"
        )

        // Probe clients are short-lived: always tear the transport down so
        // the test URLSession doesn't outlive the sheet that triggered it.
        do {
            // Connect
            _ = try await client.connect(transport: transport)

            // List tools to verify connection
            let tools = try await client.listAllTools()

            await client.disconnect()
            return tools.count
        } catch {
            await client.disconnect()
            throw error
        }
    }

    // MARK: - OAuth

    /// Run the OAuth sign-in flow for an existing provider, persist tokens + cached
    /// `MCPOAuthConfig`, and (optionally) trigger a reconnect.
    ///
    /// On success the provider is auto-enabled (a successful sign-in is an unambiguous
    /// signal of intent — most imported providers ship disabled so the user wouldn't
    /// see anything connect otherwise) and `connect(...)` runs unconditionally.
    ///
    /// On failure the error is recorded in `MCPProviderState.lastError` so the
    /// `ProviderCard` UI can surface it next to the Sign In button, then re-thrown
    /// so callers can also toast it.
    @discardableResult
    public func oauthSignIn(providerId: UUID, reconnect: Bool = true) async throws -> MCPOAuthSignInResult {
        guard var provider = configuration.provider(id: providerId) else {
            throw MCPProviderError.providerNotFound
        }

        // Use any cached resource_metadata hint from the last 401 to skip well-known probing.
        let hint = providerStates[providerId]?.resourceMetadataURL
            .map { MCPBearerChallenge(resourceMetadataURL: $0) }

        // Make sure the provider record reflects the OAuth auth type *before* sign-in,
        // so any client_id we cache survives even if the user toggled the picker.
        if provider.authType != .oauth {
            provider.authType = .oauth
        }

        let result: MCPOAuthSignInResult
        do {
            result = try await MCPOAuthService.signIn(provider: provider, hint: hint, persist: true)
        } catch {
            // Surface the error to the UI so the orange "Sign in required" banner can
            // explain what went wrong, instead of looking like a no-op. We keep
            // `requiresAuth` set so the Sign In button stays available for retry.
            if var state = providerStates[providerId] {
                state.lastError = "Sign-in failed: \(error.localizedDescription)"
                providerStates[providerId] = state
            }
            notifyStatusChanged()
            throw error
        }

        // Persist refreshed config back into the provider record.
        provider.oauth = result.config
        // A successful Sign In is intent-to-use: enable the provider if it was
        // imported in the disabled state. Without this, every imported OAuth
        // provider would sit silently after sign-in and the user would have
        // to discover the toggle.
        let wasDisabled = !provider.enabled
        if wasDisabled {
            provider.enabled = true
        }
        configuration.update(provider)
        MCPProviderConfigurationStore.save(configuration)

        // Clear the "needs sign in" badge.
        if var state = providerStates[providerId] {
            state.requiresAuth = false
            state.resourceMetadataURL = nil
            state.lastError = nil
            providerStates[providerId] = state
        }
        notifyStatusChanged()

        // Reconnect unconditionally on success. The previous behaviour gated this on
        // `provider.enabled`, which never fired for imported providers (created
        // disabled) so the user thought Sign In did nothing.
        if reconnect {
            Task { try? await connect(providerId: providerId) }
        }
        return result
    }

    // MARK: - Private Helpers

    /// Branch on `provider.transport` and return the appropriate
    /// `MCP.Transport`. HTTP is the default path; stdio routes to either
    /// `MCPStdioHostRunner` or `SandboxStdioRunner` depending on the
    /// provider's `executionHost`. The runner is retained in the manager
    /// so `disconnect(...)` can stop the subprocess later.
    private func createTransport(
        for provider: MCPProvider,
        operation: MCPConnectionOperation? = nil
    ) async throws -> any MCP.Transport {
        switch provider.transport {
        case .http:
            return try await createHTTPTransport(for: provider, operation: operation)
        case .stdio:
            return try await createStdioTransport(for: provider, operation: operation)
        }
    }

    /// Build a stdio transport for `provider` and start the backing subprocess.
    /// Whichever runner we use, we keep the strong reference so the process
    /// stays alive — without that the actor would be deallocated, the
    /// `FileDescriptor`s would close, and the MCP client would see an EOF on
    /// its first read.
    private func createStdioTransport(
        for provider: MCPProvider,
        operation: MCPConnectionOperation? = nil
    ) async throws -> any MCP.Transport {
        switch provider.executionHost {
        case .host:
            let runner = try MCPStdioHostRunner(provider: provider)
            let providerId = provider.id
            let runnerToken = UUID()
            stopStdioRunners(for: providerId)
            hostStdioRunners[providerId] = runner
            stdioRunnerTokens[providerId] = runnerToken
            if let operation {
                stdioRunnerOperations[providerId] = operation
            }
            await runner.setProcessExitHandler { [weak self] exitCode in
                Task { @MainActor in
                    guard let self else { return }
                    let tail = await runner.lastStderrTail()
                    self.handleStdioProcessExit(
                        providerId: providerId,
                        runnerToken: runnerToken,
                        exitCode: exitCode,
                        stderrTail: tail
                    )
                }
            }
            do {
                try await runner.start(connectionOperation: operation)
                if let operation {
                    try requireCurrentConnectionOperation(operation)
                }
            } catch {
                if stdioRunnerTokens[providerId] == runnerToken {
                    stopStdioRunners(for: providerId)
                } else {
                    await runner.stop()
                }
                throw error
            }
            return runner.transport
        case .sandbox:
            #if os(macOS)
                let availability = await SandboxManager.shared.checkAvailability()
                if let operation {
                    try requireCurrentConnectionOperation(operation)
                }
                guard availability.isAvailable else {
                    // OS doesn't support the sandbox at all (macOS < 26).
                    // No amount of provisioning will fix this — surface
                    // it as the terminal error.
                    throw MCPStdioTransportError.sandboxUnavailable
                }
                // Auto-provision a stopped container. Users expect "enable
                // this stdio provider" to just work; making them open the
                // Sandbox tab first and click Start is friction we can
                // eliminate. `startContainer()` is a no-op when already
                // running, so the happy path stays free.
                if await SandboxManager.shared.status() != .running {
                    do {
                        try await SandboxManager.shared.startContainer()
                        if let operation {
                            try requireCurrentConnectionOperation(operation)
                        }
                    } catch {
                        throw MCPStdioTransportError.processSpawnFailed(
                            "Could not start the Osaurus sandbox: "
                                + error.localizedDescription
                        )
                    }
                }
                // Scope the MCP subprocess to the calling agent (execution
                // context when connect happens mid-turn, else the active
                // agent) — never the shared "default" namespace. Provision
                // first so the Linux user + bridge token exist; in
                // allowlist egress mode the token is also the subprocess's
                // proxy credential.
                let agentId = ChatExecutionContext.currentAgentId ?? AgentManager.shared.activeAgent.id
                let agentName = SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
                do {
                    try await SandboxAgentProvisioner.shared.ensureProvisioned(agentId: agentId)
                    if let operation {
                        try requireCurrentConnectionOperation(operation)
                    }
                } catch {
                    throw MCPStdioTransportError.processSpawnFailed(
                        "Could not provision the sandbox agent: " + error.localizedDescription
                    )
                }
                let runner = try SandboxStdioRunner(provider: provider, agentName: agentName)
                let providerId = provider.id
                let runnerToken = UUID()
                stopStdioRunners(for: providerId)
                sandboxStdioRunners[providerId] = runner
                stdioRunnerTokens[providerId] = runnerToken
                if let operation {
                    stdioRunnerOperations[providerId] = operation
                }
                await runner.setProcessExitHandler { [weak self] exitCode in
                    Task { @MainActor in
                        guard let self else { return }
                        let tail = await runner.lastStderrTail()
                        self.handleStdioProcessExit(
                            providerId: providerId,
                            runnerToken: runnerToken,
                            exitCode: exitCode,
                            stderrTail: tail
                        )
                    }
                }
                do {
                    try await runner.start(connectionOperation: operation)
                    if let operation {
                        try requireCurrentConnectionOperation(operation)
                    }
                } catch {
                    if stdioRunnerTokens[providerId] == runnerToken {
                        stopStdioRunners(for: providerId)
                    } else {
                        await runner.stop()
                    }
                    throw error
                }
                return runner.transport
            #else
                throw MCPStdioTransportError.sandboxUnavailable
            #endif
        }
    }

    /// Build the HTTP transport for a provider, including any cached auth
    /// headers. OAuth refresh-before-connect happens inside this method so
    /// every entrypoint (connect / testConnection) goes through the same gate.
    ///
    /// Headers are injected per-request via the transport's request modifier
    /// instead of `httpAdditionalHeaders` — Apple documents the latter as
    /// unsupported for `Authorization`, and per-request injection also covers
    /// the SDK's SSE reconnects. Timeout semantics live in
    /// `MCPHTTPTransportBuilder`.
    private func createHTTPTransport(
        for provider: MCPProvider,
        operation: MCPConnectionOperation? = nil
    ) async throws -> HTTPClientTransport {
        guard let endpoint = URL(string: provider.url) else {
            throw MCPProviderError.invalidURL
        }

        // Build headers
        var headers = provider.resolvedHeaders()
        switch provider.authType {
        case .oauth:
            let tokens = try await ensureFreshOAuthTokens(for: provider, operation: operation)
            headers["Authorization"] = "Bearer \(tokens.accessToken)"
        case .bearerToken:
            // Reading the token from the Keychain blocks on a securityd XPC round
            // trip plus decryption — done off the main actor so it can't hang the
            // UI (this method is `@MainActor`).
            let providerId = provider.id
            let token = await Task.detached(priority: .userInitiated) {
                MCPProviderKeychain.getToken(for: providerId)
            }.value
            if let operation {
                try requireCurrentConnectionOperation(operation)
            }
            if let token, !token.isEmpty {
                headers["Authorization"] = "Bearer \(token)"
            }
        case .none:
            break
        }

        return MCPHTTPTransportBuilder.makeTransport(
            endpoint: endpoint,
            headers: headers,
            streaming: provider.streamingEnabled,
            discoveryTimeout: provider.discoveryTimeout,
            toolCallTimeout: provider.toolCallTimeout
        )
    }

    /// Refresh OAuth tokens proactively if they are at-or-near expiry.
    private func ensureFreshOAuthTokens(
        for provider: MCPProvider,
        operation: MCPConnectionOperation? = nil
    ) async throws -> MCPOAuthTokens {
        // Off the main actor: the Keychain read blocks on securityd XPC + decrypt.
        let providerId = provider.id
        let stored = await Task.detached(priority: .userInitiated) {
            MCPProviderKeychain.getOAuthTokens(for: providerId)
        }.value
        if let operation {
            try requireCurrentConnectionOperation(operation)
        }
        guard let tokens = stored else {
            throw MCPProviderError.connectionFailed("Sign in required")
        }
        guard tokens.isExpired else { return tokens }

        // Skip refresh attempts when we know we have no refresh token to spend.
        guard let rt = tokens.refreshToken, !rt.isEmpty else {
            throw MCPProviderError.connectionFailed("Session expired — please sign in again")
        }
        do {
            let refreshed = try await MCPOAuthService.refresh(provider: provider, tokens: tokens)
            if let operation {
                try requireCurrentConnectionOperation(operation)
            }
            return refreshed
        } catch {
            let mayMutateAuthState = operation.map { connectionOperationIsCurrent($0) } ?? true
            if MCPOAuthService.isPermanentAuthFailure(error), mayMutateAuthState {
                handlePermanentOAuthFailure(providerId: provider.id)
            }
            throw MCPProviderError.connectionFailed(
                "Could not refresh OAuth tokens: \(error.localizedDescription)"
            )
        }
    }

    private func handlePermanentOAuthFailure(providerId: UUID) {
        MCPProviderKeychain.deleteOAuthTokens(for: providerId)
        if var state = providerStates[providerId] {
            state.requiresAuth = true
            state.isConnected = false
            state.isConnecting = false
            state.lastError = "Session expired — please sign in again."
            providerStates[providerId] = state
        }
        notifyStatusChanged()
    }

    private func handleStdioProcessExit(
        providerId: UUID,
        runnerToken: UUID,
        exitCode: Int32,
        stderrTail: String
    ) {
        guard stdioRunnerTokens[providerId] == runnerToken else { return }
        let runnerOperation = stdioRunnerOperations[providerId]
        let runnerGeneration = runnerOperation?.generation
        let isSuperseded = runnerGeneration.map {
            connectionGenerations[providerId] != $0
        } ?? false

        if let runnerOperation {
            runnerOperation.cancel()
            if activeConnectionOperations[providerId] === runnerOperation {
                activeConnectionOperations.removeValue(forKey: providerId)
            }
            if !isSuperseded {
                connectionGenerations[providerId] = (connectionGenerations[providerId] ?? 0) &+ 1
            }
        }

        var catalogChanged = false
        let ownsRegisteredTools = runnerGeneration.map {
            registeredToolGenerations[providerId] == $0
        } ?? true
        if ownsRegisteredTools {
            if let tools = registeredTools[providerId] {
                ToolRegistry.shared.unregister(names: tools.map { $0.name })
                catalogChanged = true
            }
            discoveredTools.removeValue(forKey: providerId)
            registeredTools.removeValue(forKey: providerId)
            registeredToolGenerations.removeValue(forKey: providerId)
        }

        let ownsClient = runnerGeneration.map {
            clientGenerations[providerId] == $0
        } ?? true
        if ownsClient {
            if let client = clients.removeValue(forKey: providerId) {
                Task.detached { await client.disconnect() }
            }
            clientGenerations.removeValue(forKey: providerId)
        }

        stopStdioRunners(for: providerId, operation: runnerOperation)

        // An old subprocess can exit while a replacement connection is still
        // resolving credentials or provisioning its runner. Its token may
        // still be installed, but it must not overwrite the replacement's
        // connecting/connected state.
        guard !isSuperseded else {
            if catalogChanged { scheduleToolCatalogChanged() }
            return
        }

        if var state = providerStates[providerId] {
            state.isConnected = false
            state.isConnecting = false
            state.discoveredToolCount = 0
            state.discoveredToolNames = []
            state.lastStderrTail = stderrTail.isEmpty ? nil : stderrTail
            let codeSuffix = exitCode >= 0 ? " (exit \(exitCode))" : ""
            if stderrTail.isEmpty {
                state.lastError = "Stdio MCP subprocess exited unexpectedly\(codeSuffix)."
            } else {
                state.lastError = "Stdio MCP subprocess exited\(codeSuffix): \(stderrTail)"
            }
            state.lastFailureWasTransient = false
            providerStates[providerId] = state
        }
        if catalogChanged { scheduleToolCatalogChanged() }
        notifyStatusChanged()
    }

    private func registerRemoteToolListChangedHandler(
        client: MCP.Client,
        providerId: UUID,
        generation: UInt64
    ) async {
        await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleRemoteToolListChanged(
                    providerId: providerId,
                    generation: generation
                )
            }
        }
    }

    private func handleRemoteToolListChanged(
        providerId: UUID,
        generation: UInt64
    ) async {
        guard let provider = configuration.provider(id: providerId),
            let client = clients[providerId],
            clientGenerations[providerId] == generation
        else { return }

        do {
            try await discoverTools(
                for: providerId,
                client: client,
                provider: provider,
                expectedGeneration: generation
            )
        } catch {
            if clients[providerId] === client,
                clientGenerations[providerId] == generation,
                var state = providerStates[providerId] {
                state.lastError = "Tool list refresh failed: \(error.localizedDescription)"
                providerStates[providerId] = state
                notifyStatusChanged()
            }
        }
    }

    /// Issue a low-cost POST against the server's MCP endpoint to classify an
    /// auth failure, if any. The Swift MCP SDK doesn't expose response status
    /// or headers on its error type, so this is the cheapest correct way to
    /// know whether the connect failed on a 401/403. Returns a result for any
    /// 401/403 — including a bare one with no `WWW-Authenticate` header, which
    /// token-only servers commonly send.
    private nonisolated func probeAuthFailure(for provider: MCPProvider) async -> MCPAuthFailureProbeResult? {
        guard let endpoint = URL(string: provider.url) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        // Use any saved auth so we can distinguish "wrong/expired token" 401 from
        // "no token at all" 401 (the WWW-Authenticate header is the same either way,
        // but sending the existing token avoids tripping rate-limits on the empty path).
        for (key, value) in provider.resolvedHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        switch provider.authType {
        case .oauth:
            if let tokens = MCPProviderKeychain.getOAuthTokens(for: provider.id) {
                request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            }
        case .bearerToken:
            if let token = MCPProviderKeychain.getToken(for: provider.id), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .none:
            break
        }
        // A spec-complete initialize payload: some servers validate the
        // request shape before auth, and a params-less shorthand would turn
        // an auth failure into a protocol error.
        request.httpBody = MCPAuthFailureProbe.handshakeBody()
        request.timeoutInterval = 10

        do {
            let (data, response) = try await GlobalProxySettings.sharedSession().data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return MCPAuthFailureProbe.evaluate(
                response: http,
                body: data,
                sentAuthorization: request.value(forHTTPHeaderField: "Authorization") != nil
            )
        } catch {
            return nil
        }
    }

    private func discoverTools(
        for providerId: UUID,
        client: MCP.Client,
        provider: MCPProvider,
        operation: MCPConnectionOperation? = nil,
        expectedGeneration: UInt64? = nil
    ) async throws {
        try await refreshDiscoveredTools(
            for: providerId,
            provider: provider,
            operation: operation,
            expectedGeneration: operation?.generation ?? expectedGeneration
        ) {
            // List tools with timeout, following pagination cursors so servers
            // that split tools/list across pages (e.g. Baserow, #1999) aren't
            // truncated to their first page.
            try await self.withTimeout(seconds: provider.discoveryTimeout) {
                try await client.listAllTools()
            }
        }
    }

    /// Fetch and install a complete provider catalog. Keeping the fetch
    /// outside the replacement operation makes refresh failure atomic from
    /// the registry's perspective and provides a deterministic test seam.
    internal func refreshDiscoveredTools(
        for providerId: UUID,
        provider: MCPProvider,
        operation: MCPConnectionOperation? = nil,
        expectedGeneration: UInt64? = nil,
        fetch: () async throws -> [MCP.Tool]
    ) async throws {
        let mcpTools = try await fetch()
        if let operation {
            try requireCurrentConnectionOperation(operation)
        }
        if let expectedGeneration {
            guard clientGenerations[providerId] == expectedGeneration else {
                throw CancellationError()
            }
        }
        // Only replace the live catalog after the complete paginated fetch
        // succeeds. A failed tools/list refresh therefore leaves the last
        // executable catalog intact instead of erasing it first.
        replaceDiscoveredTools(
            mcpTools,
            for: providerId,
            provider: provider,
            generation: expectedGeneration
        )
        await publishToolCatalogChanged()
    }

    /// Replace one provider's complete registered catalog. Removing all prior
    /// wrappers first is required even when names are unchanged: schemas are
    /// immutable on `MCPProviderTool`, and a reconnect may return a new JSON
    /// contract or omit tools that existed in the previous session.
    @discardableResult
    internal func replaceDiscoveredTools(
        _ mcpTools: [MCP.Tool],
        for providerId: UUID,
        provider: MCPProvider,
        generation: UInt64? = nil
    ) -> [MCPProviderTool] {
        if let oldTools = registeredTools[providerId] {
            ToolRegistry.shared.unregister(names: oldTools.map(\.name))
        }

        discoveredTools[providerId] = mcpTools
        let tools = registerDiscoveredTools(mcpTools, for: providerId, provider: provider)
        registeredTools[providerId] = tools
        if let generation {
            registeredToolGenerations[providerId] = generation
        } else {
            registeredToolGenerations.removeValue(forKey: providerId)
        }

        if var state = providerStates[providerId] {
            state.discoveredToolCount = tools.count
            state.discoveredToolNames = tools.map(\.mcpToolName)
            providerStates[providerId] = state
        }
        return tools
    }

    /// Wrap each discovered MCP tool and register it with the shared
    /// `ToolRegistry`, returning the wrappers in discovery order.
    ///
    /// `registerMCPTool` auto-enables a tool only on its first registration
    /// and otherwise preserves the saved enabled state, so a per-tool disable
    /// survives re-discovery (launch / autoConnect). Do NOT force-enable here:
    /// that would overwrite the user's choice on every reconnect.
    @discardableResult
    internal func registerDiscoveredTools(
        _ mcpTools: [MCP.Tool],
        for providerId: UUID,
        provider: MCPProvider
    ) -> [MCPProviderTool] {
        var tools: [MCPProviderTool] = []
        var reservedNames = Set(ToolRegistry.shared.registeredToolNames())
        for mcpTool in mcpTools {
            let tool = MCPProviderTool(
                mcpTool: mcpTool,
                providerId: providerId,
                providerName: provider.name,
                reservedNames: reservedNames
            )
            tools.append(tool)
            reservedNames.insert(tool.name)
            ToolRegistry.shared.registerMCPTool(tool)
        }
        return tools
    }

    /// Non-rejoining timeout: `valueWithDeadline` abandons an MCP SDK call
    /// that ignores cancellation instead of blocking the caller until it
    /// returns (a `withThrowingTaskGroup` race re-joins the stuck child at
    /// scope exit, so "Connecting…" could still hang forever after the
    /// timeout had nominally fired).
    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T)
        async throws -> T
    {
        do {
            return try await valueWithDeadline(seconds: seconds, operationName: "MCP request", operation: operation)
        } catch is DeadlineExceededError {
            throw MCPProviderError.timeout
        }
    }

    private func notifyStatusChanged() {
        NotificationCenter.default.post(name: Foundation.Notification.Name.mcpProviderStatusChanged, object: nil)
    }

    /// Publish catalog changes only after frozen per-session tool snapshots
    /// have been cleared, so notification consumers cannot immediately
    /// recompose against the old names or schemas.
    private func publishToolCatalogChanged() async {
        await SessionToolStateStore.shared.invalidateToolCatalog()
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    /// Synchronous lifecycle entry points (disable, disconnect, process exit)
    /// cannot await the session-state actor. Preserve ordering inside the task:
    /// invalidate first, then notify observers.
    private func scheduleToolCatalogChanged() {
        Task { await publishToolCatalogChanged() }
    }
}

// MARK: - Errors

public enum MCPProviderError: LocalizedError {
    case providerNotFound
    case providerDisabled
    case notConnected
    case invalidURL
    case timeout
    case toolExecutionFailed(String)
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
        case .toolExecutionFailed(let message):
            return "Tool execution failed: \(message)"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        }
    }
}
