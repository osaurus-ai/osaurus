//
//  MCPProviderManager.swift
//  osaurus
//
//  Manages remote MCP provider connections and tool execution.
//

import Foundation
import MCP

/// Notification posted when provider connection status changes
extension Foundation.Notification.Name {
    static let mcpProviderStatusChanged = Foundation.Notification.Name("MCPProviderStatusChanged")
}

/// Explicit edit intent for the legacy/static bearer token stored in Keychain.
public enum MCPProviderBearerTokenEdit: Sendable, Equatable {
    case preserve
    case replace(String)
    case clear

    public static func fromBearerField(
        _ value: String,
        authType: MCPProviderAuthType,
        clearRequested: Bool = false
    ) -> MCPProviderBearerTokenEdit {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clearRequested && trimmed.isEmpty { return .clear }
        guard authType == .bearerToken else { return .preserve }
        return trimmed.isEmpty ? .preserve : .replace(trimmed)
    }

    public var tokenForNewProvider: String? {
        guard case .replace(let token) = self, !token.isEmpty else { return nil }
        return token
    }

    @discardableResult
    func apply(
        save: (String) -> Bool,
        delete: () -> Bool
    ) -> Bool {
        switch self {
        case .preserve:
            return true
        case .replace(let token):
            guard !token.isEmpty else { return true }
            return save(token)
        case .clear:
            return delete()
        }
    }
}

enum MCPProviderCredentialPersistence {
    static func persist(
        providerId: UUID,
        tokenEdit: MCPProviderBearerTokenEdit,
        secretWrites: [MCPProviderSecretWrite]
    ) -> Bool {
        persist(
            providerId: providerId,
            tokenEdit: tokenEdit,
            secretWrites: secretWrites,
            readToken: MCPProviderKeychain.getToken,
            saveToken: MCPProviderKeychain.saveToken,
            deleteToken: MCPProviderKeychain.deleteToken,
            persistSecrets: MCPProviderSecretPersistence.persist
        )
    }

    static func persist(
        providerId: UUID,
        tokenEdit: MCPProviderBearerTokenEdit,
        secretWrites: [MCPProviderSecretWrite],
        readToken: (UUID) -> String?,
        saveToken: (String, UUID) -> Bool,
        deleteToken: (UUID) -> Bool,
        persistSecrets: ([MCPProviderSecretWrite], UUID) -> Bool
    ) -> Bool {
        let previousToken = readToken(providerId)
        guard tokenEdit.apply(
            save: { saveToken($0, providerId) },
            delete: { deleteToken(providerId) }
        ) else { return false }

        guard persistSecrets(secretWrites, providerId) else {
            if let previousToken {
                _ = saveToken(previousToken, providerId)
            } else {
                _ = deleteToken(providerId)
            }
            return false
        }
        return true
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

    /// Discovered MCP tools keyed by provider ID
    private var discoveredTools: [UUID: [MCP.Tool]] = [:]

    /// Registered tool instances keyed by provider ID
    private var registeredTools: [UUID: [MCPProviderTool]] = [:]

    /// Host-resident stdio subprocess owners keyed by provider ID. Held so
    /// `disconnect(...)` can terminate them — the subprocess only stays
    /// alive while we hold the runner.
    private var hostStdioRunners: [UUID: MCPStdioHostRunner] = [:]

    /// Sandbox-resident stdio subprocess owners keyed by provider ID. Same
    /// lifecycle as `hostStdioRunners` but routed through the container.
    private var sandboxStdioRunners: [UUID: SandboxStdioRunner] = [:]

    private init() {
        self.configuration = MCPProviderConfigurationStore.load()
        self.providerStates = Self.initialProviderStates(for: configuration)
    }

    #if DEBUG
    init(configuration: MCPProviderConfiguration) {
        self.configuration = configuration
        self.providerStates = Self.initialProviderStates(for: configuration)
    }
    #endif

    private static func initialProviderStates(
        for configuration: MCPProviderConfiguration
    ) -> [UUID: MCPProviderState] {
        Dictionary(
            uniqueKeysWithValues: configuration.providers.map {
                ($0.id, MCPProviderState(providerId: $0.id))
            }
        )
    }

    // MARK: - Provider Management

    /// Add a new provider
    @discardableResult
    public func addProvider(_ provider: MCPProvider, token: String?) -> Bool {
        addProvider(provider, token: token, secretWrites: [])
    }

    @discardableResult
    func addProvider(
        _ provider: MCPProvider,
        token: String?,
        secretWrites: [MCPProviderSecretWrite]
    ) -> Bool {
        let provider = provider.scopedToActiveTransport()

        let tokenEdit: MCPProviderBearerTokenEdit =
            provider.transport == .http && provider.authType == .bearerToken
                ? token.map(MCPProviderBearerTokenEdit.replace) ?? .preserve
                : .preserve
        guard MCPProviderCredentialPersistence.persist(
            providerId: provider.id,
            tokenEdit: tokenEdit,
            secretWrites: secretWrites
        ) else { return false }

        configuration.add(provider)
        MCPProviderConfigurationStore.save(configuration)
        // KPI: a user-configured MCP tool provider. Only the transport kind
        // is captured — never the command, URL, or args.
        FeatureTelemetry.mcpProviderAdded(transport: provider.transport.rawValue)

        // Initialize state
        providerStates[provider.id] = MCPProviderState(providerId: provider.id)

        // Auto-connect if enabled
        if provider.enabled {
            Task {
                try? await connect(providerId: provider.id)
            }
        }

        notifyStatusChanged()
        return true
    }

    /// Update an existing provider
    @discardableResult
    public func updateProvider(
        _ provider: MCPProvider,
        tokenEdit: MCPProviderBearerTokenEdit = .preserve
    ) -> Bool {
        updateProvider(provider, tokenEdit: tokenEdit, secretWrites: [])
    }

    @discardableResult
    func updateProvider(
        _ provider: MCPProvider,
        tokenEdit: MCPProviderBearerTokenEdit,
        secretWrites: [MCPProviderSecretWrite]
    ) -> Bool {
        let provider = provider.scopedToActiveTransport()
        let wasConnected = providerStates[provider.id]?.isConnected ?? false
        let previous = configuration.provider(id: provider.id)

        var credentialWrites = secretWrites
        if let previous {
            credentialWrites += Set(previous.secretHeaderKeys)
                .subtracting(Set(provider.secretHeaderKeys))
                .map { MCPProviderSecretWrite(storage: .header, key: $0, mutation: .delete) }
            credentialWrites += Set(previous.secretEnvKeys)
                .subtracting(Set(provider.secretEnvKeys))
                .map { MCPProviderSecretWrite(storage: .environment, key: $0, mutation: .delete) }
        }
        let effectiveTokenEdit: MCPProviderBearerTokenEdit =
            previous?.authType == .bearerToken && provider.authType != .bearerToken
                ? .clear
                : tokenEdit
        guard MCPProviderCredentialPersistence.persist(
            providerId: provider.id,
            tokenEdit: effectiveTokenEdit,
            secretWrites: credentialWrites
        ) else { return false }

        // Disconnect if connected
        if wasConnected {
            disconnect(providerId: provider.id)
        }

        configuration.update(provider)
        MCPProviderConfigurationStore.save(configuration)

        // If the user switched away from OAuth, drop any cached tokens for this provider.
        if previous?.authType == .oauth && provider.authType != .oauth {
            MCPProviderKeychain.deleteOAuthTokens(for: provider.id)
            MCPProviderKeychain.deleteOAuthClientSecret(for: provider.id)
        }

        // Reconnect if was connected and still enabled
        if wasConnected && provider.enabled {
            Task {
                try? await connect(providerId: provider.id)
            }
        }

        notifyStatusChanged()
        return true
    }

    /// Remove a provider
    public func removeProvider(id: UUID) {
        // Disconnect first
        disconnect(providerId: id)

        // Remove from configuration (also cleans up Keychain)
        configuration.remove(id: id)
        MCPProviderConfigurationStore.save(configuration)
        MCPProviderCallHistoryStore.clear(providerId: id)
        MCPProviderHealthSnapshotStore.clear(providerId: id)

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

    /// Connect to a provider
    public func connect(providerId: UUID) async throws {
        guard let provider = configuration.provider(id: providerId) else {
            throw MCPProviderError.providerNotFound
        }
        try await performConnect(provider: provider, allowOAuthRetry: true)
    }

    private func performConnect(provider: MCPProvider, allowOAuthRetry: Bool) async throws {
        let providerId = provider.id

        guard provider.enabled else {
            throw MCPProviderError.providerDisabled
        }

        // Update state to connecting
        var state = providerStates[providerId] ?? MCPProviderState(providerId: providerId)
        state.isConnecting = true
        state.lastError = nil
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
            let transport = try await createTransport(for: provider)

            // Create MCP client
            let client = MCP.Client(
                name: "Osaurus",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            )
            attemptClient = client

            // Connect under a timeout. Without this, a stdio subprocess that
            // spawned successfully but never speaks MCP would leave the card
            // stuck on "Connecting…" indefinitely. `discoverTools` uses the
            // same cancellation-aware timeout for the second leg.
            try await MCPAsyncTimeout.run(seconds: provider.discoveryTimeout) {
                _ = try await client.connect(transport: transport)
            }

            // Store client, tearing down any client we're replacing (a
            // connect on an already-connected provider must not leak the
            // old transport's URLSession / SSE loop).
            if let replaced = clients[providerId], replaced !== client {
                Task.detached { await replaced.disconnect() }
            }
            clients[providerId] = client

            await registerRemoteToolListChangedHandler(client: client, providerId: providerId)

            // Discover tools
            try await discoverTools(for: providerId, client: client, provider: provider)

            // Update state to connected (re-read state since discoverTools modified it)
            if var updatedState = providerStates[providerId] {
                updatedState.isConnecting = false
                updatedState.isConnected = true
                updatedState.lastConnectedAt = Date()
                updatedState.lastError = nil
                updatedState.requiresAuth = false
                updatedState.resourceMetadataURL = nil
                providerStates[providerId] = updatedState
                print(
                    "[Osaurus] MCP Provider '\(provider.name)': Connected with \(updatedState.discoveredToolCount) tools"
                )
            }
            notifyStatusChanged()

        } catch {
            // Stdio transports talk to a local subprocess, not an HTTP server,
            // so there's no 401 to probe — the error is either a spawn
            // failure or a protocol mismatch.
            let authFailure: MCPAuthFailureProbeResult? =
                provider.transport == .http
                ? await probeAuthFailure(for: provider)
                : nil

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
                    do {
                        _ = try await MCPOAuthService.refresh(provider: provider, tokens: tokens)
                        // Re-enter without retry budget so we can't loop.
                        try await performConnect(provider: provider, allowOAuthRetry: false)
                        return
                    } catch {
                        if MCPOAuthService.isPermanentAuthFailure(error) {
                            handlePermanentOAuthFailure(providerId: providerId)
                        }
                        // Fall through and surface the original auth challenge.
                    }
                }

                state.requiresAuth = true
                state.resourceMetadataURL = authFailure.challenge?.resourceMetadataURL
                state.lastError = MCPAuthFailureProbe.failureDescription(
                    authType: provider.authType,
                    probe: authFailure
                )
            } else {
                state.lastError = error.localizedDescription
            }

            state.isConnecting = false
            state.isConnected = false
            state.discoveredToolCount = 0
            state.discoveredToolNames = []
            providerStates[providerId] = state

            // Unregister any tools that were registered before the failure
            if let tools = registeredTools[providerId] {
                ToolRegistry.shared.unregister(names: tools.map { $0.name })
            }

            // Clean up local state. The half-connected client from THIS
            // attempt must be disconnected explicitly so its transport
            // invalidates the URLSession and stops any SSE retry loop.
            let staleClient = clients.removeValue(forKey: providerId)
            var teardown: [MCP.Client] = []
            if let attemptClient { teardown.append(attemptClient) }
            if let staleClient, staleClient !== attemptClient { teardown.append(staleClient) }
            for client in teardown {
                Task.detached { await client.disconnect() }
            }
            discoveredTools.removeValue(forKey: providerId)
            registeredTools.removeValue(forKey: providerId)
            // Stdio subprocesses might have been spawned successfully even
            // though the MCP handshake failed — make sure we don't leak them.
            stopStdioRunners(for: providerId)

            print("[Osaurus] MCP Provider '\(provider.name)': Connection failed - \(error)")
            notifyStatusChanged()
            throw error
        }
    }

    /// Disconnect from a provider
    public func disconnect(providerId: UUID) {
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
        discoveredTools.removeValue(forKey: providerId)
        registeredTools.removeValue(forKey: providerId)

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

        notifyStatusChanged()
    }

    /// Reconnect to a provider
    public func reconnect(providerId: UUID) async throws {
        disconnect(providerId: providerId)
        try await connect(providerId: providerId)
    }

    /// Connect to all enabled providers on app launch
    public func connectEnabledProviders() async {
        for provider in configuration.enabledProviders {
            do {
                try await connect(providerId: provider.id)
            } catch {
                print("[Osaurus] Failed to auto-connect to '\(provider.name)': \(error)")
            }
        }
    }

    /// Disconnect from all providers
    public func disconnectAll() {
        for providerId in clients.keys {
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

        let startedAt = Date()
        var didRecordCall = false

        do {
            // A missing client on an enabled provider (transient connect failure
            // at launch, earlier session loss) is recoverable - reconnect instead
            // of failing the model's tool call outright.
            if clients[providerId] == nil, provider.enabled {
                try await performConnect(provider: provider, allowOAuthRetry: true)
            }
            guard let client = clients[providerId] else {
                throw MCPProviderError.notConnected
            }

            let arguments = try MCPProviderTool.convertArgumentsToMCPValues(argumentsJSON)
            let timeout = provider.toolCallTimeout

            // Run the network call off MainActor so it doesn't block the UI thread.
            let (content, isError): ([MCP.Tool.Content], Bool)
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
                try await performConnect(provider: provider, allowOAuthRetry: true)
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
            if isError {
                let errorText = content.compactMap { item -> String? in
                    if case .text(let text, _, _) = item { return text }
                    return nil
                }.joined(separator: "\n")
                let message = errorText.isEmpty ? "Tool returned error" : errorText
                recordProviderToolCall(
                    provider: provider,
                    toolName: toolName,
                    argumentsJSON: argumentsJSON,
                    startedAt: startedAt,
                    succeeded: false,
                    errorMessage: message
                )
                didRecordCall = true
                throw MCPProviderError.toolExecutionFailed(message)
            }

            // Convert content to string
            let result = MCPProviderTool.convertMCPContent(content)
            recordProviderToolCall(
                provider: provider,
                toolName: toolName,
                argumentsJSON: argumentsJSON,
                startedAt: startedAt,
                succeeded: true,
                result: result
            )
            didRecordCall = true
            return result
        } catch {
            if !didRecordCall {
                recordProviderToolCall(
                    provider: provider,
                    toolName: toolName,
                    argumentsJSON: argumentsJSON,
                    startedAt: startedAt,
                    succeeded: false,
                    errorMessage: error.localizedDescription
                )
            }
            throw error
        }
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

    private func recordProviderToolCall(
        provider: MCPProvider,
        toolName: String,
        argumentsJSON: String,
        startedAt: Date,
        succeeded: Bool,
        result: String? = nil,
        errorMessage: String? = nil
    ) {
        MCPProviderCallHistoryStore.record(
            MCPProviderCallRecord(
                providerId: provider.id,
                providerName: provider.name,
                toolName: toolName,
                startedAt: startedAt,
                finishedAt: Date(),
                succeeded: succeeded,
                argumentSummary: MCPProviderCallRecord.summarizeArguments(argumentsJSON),
                resultSummary: result.map(MCPProviderCallRecord.summarizeResult),
                errorMessage: errorMessage
            )
        )
    }

    #if DEBUG
    func installConnectedClientForTesting(_ client: MCP.Client, provider: MCPProvider) {
        if configuration.provider(id: provider.id) == nil {
            configuration.add(provider)
        } else {
            configuration.update(provider)
        }

        clients[provider.id] = client
        var state = providerStates[provider.id] ?? MCPProviderState(providerId: provider.id)
        state.isConnected = true
        state.isConnecting = false
        state.lastConnectedAt = Date()
        providerStates[provider.id] = state
    }
    #endif

    /// Trampoline that runs the MCP network call outside MainActor isolation.
    nonisolated private static func callMCPTool(
        client: MCP.Client,
        toolName: String,
        arguments: [String: MCP.Value],
        timeout: TimeInterval
    ) async throws -> ([MCP.Tool.Content], Bool) {
        try await MCPAsyncTimeout.run(seconds: timeout) {
            let (content, isError) = try await client.callTool(name: toolName, arguments: arguments)
            return (content, isError ?? false)
        }
    }

    // MARK: - Test Connection

    /// Spin up the same runner we'd use in production, complete an MCP
    /// handshake under a tight timeout, list the available tools, then
    /// tear everything down. Returns the tool count for the editor's
    /// success label. Stdio test runs are intentionally short-lived;
    /// the provider isn't persisted and no state is left behind.
    public func testStdioConnection(provider: MCPProvider) async throws -> Int {
        // Build the production transport; spawning a real subprocess is
        // the whole point — fake-test paths would miss PATH lookup, env
        // resolution, and protocol mismatches.
        let transport: any MCP.Transport
        do {
            transport = try await createStdioTransport(for: provider)
        } catch {
            // `createStdioTransport` retains the runner in
            // `hostStdioRunners` / `sandboxStdioRunners` on success but
            // we don't want a test attempt to register one — wipe both
            // before rethrowing.
            stopStdioRunners(for: provider.id)
            throw error
        }

        let client = MCP.Client(name: "Osaurus", version: "1.0.0")

        do {
            try await MCPAsyncTimeout.run(seconds: 10) {
                _ = try await client.connect(transport: transport)
            }
            let tools = try await MCPAsyncTimeout.run(seconds: 10) {
                try await client.listAllTools()
            }
            stopStdioRunners(for: provider.id)
            return tools.count
        } catch {
            stopStdioRunners(for: provider.id)
            throw error
        }
    }

    /// Tear down any stdio runners registered against `providerId`. Used
    /// by `testStdioConnection` so probe attempts don't leak subprocesses,
    /// and by `connect`'s catch path for the same reason.
    private func stopStdioRunners(for providerId: UUID) {
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
    private func createTransport(for provider: MCPProvider) async throws -> any MCP.Transport {
        switch provider.transport {
        case .http:
            return try await createHTTPTransport(for: provider)
        case .stdio:
            return try await createStdioTransport(for: provider)
        }
    }

    /// Build a stdio transport for `provider` and start the backing subprocess.
    /// Whichever runner we use, we keep the strong reference so the process
    /// stays alive — without that the actor would be deallocated, the
    /// `FileDescriptor`s would close, and the MCP client would see an EOF on
    /// its first read.
    private func createStdioTransport(for provider: MCPProvider) async throws -> any MCP.Transport {
        switch provider.executionHost {
        case .host:
            let runner = try MCPStdioHostRunner(provider: provider)
            let providerId = provider.id
            await runner.setProcessExitHandler { [weak self] exitCode in
                Task { @MainActor in
                    guard let self else { return }
                    let tail = await runner.lastStderrTail()
                    self.handleStdioProcessExit(
                        providerId: providerId,
                        exitCode: exitCode,
                        stderrTail: tail
                    )
                }
            }
            try await runner.start()
            hostStdioRunners[provider.id] = runner
            return runner.transport
        case .sandbox:
            #if os(macOS)
                let availability = await SandboxManager.shared.checkAvailability()
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
                } catch {
                    throw MCPStdioTransportError.processSpawnFailed(
                        "Could not provision the sandbox agent: " + error.localizedDescription
                    )
                }
                let runner = try SandboxStdioRunner(provider: provider, agentName: agentName)
                let providerId = provider.id
                await runner.setProcessExitHandler { [weak self] exitCode in
                    Task { @MainActor in
                        guard let self else { return }
                        let tail = await runner.lastStderrTail()
                        self.handleStdioProcessExit(
                            providerId: providerId,
                            exitCode: exitCode,
                            stderrTail: tail
                        )
                    }
                }
                try await runner.start()
                sandboxStdioRunners[provider.id] = runner
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
    private func createHTTPTransport(for provider: MCPProvider) async throws -> HTTPClientTransport {
        guard let endpoint = URL(string: provider.url) else {
            throw MCPProviderError.invalidURL
        }

        // Build headers
        var headers = provider.resolvedHeaders()
        switch provider.authType {
        case .oauth:
            let tokens = try await ensureFreshOAuthTokens(for: provider)
            headers["Authorization"] = "Bearer \(tokens.accessToken)"
        case .bearerToken:
            // Reading the token from the Keychain blocks on a securityd XPC round
            // trip plus decryption — done off the main actor so it can't hang the
            // UI (this method is `@MainActor`).
            let providerId = provider.id
            let token = await Task.detached(priority: .userInitiated) {
                MCPProviderKeychain.getToken(for: providerId)
            }.value
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
    private func ensureFreshOAuthTokens(for provider: MCPProvider) async throws -> MCPOAuthTokens {
        // Off the main actor: the Keychain read blocks on securityd XPC + decrypt.
        let providerId = provider.id
        let stored = await Task.detached(priority: .userInitiated) {
            MCPProviderKeychain.getOAuthTokens(for: providerId)
        }.value
        guard let tokens = stored else {
            throw MCPProviderError.connectionFailed("Sign in required")
        }
        guard tokens.isExpired else { return tokens }

        // Skip refresh attempts when we know we have no refresh token to spend.
        guard let rt = tokens.refreshToken, !rt.isEmpty else {
            throw MCPProviderError.connectionFailed("Session expired — please sign in again")
        }
        do {
            return try await MCPOAuthService.refresh(provider: provider, tokens: tokens)
        } catch {
            if MCPOAuthService.isPermanentAuthFailure(error) {
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

    private func handleStdioProcessExit(providerId: UUID, exitCode: Int32, stderrTail: String) {
        guard providerStates[providerId]?.isConnected == true else { return }

        if let tools = registeredTools[providerId] {
            ToolRegistry.shared.unregister(names: tools.map { $0.name })
        }
        if let client = clients.removeValue(forKey: providerId) {
            Task.detached { await client.disconnect() }
        }
        discoveredTools.removeValue(forKey: providerId)
        registeredTools.removeValue(forKey: providerId)
        stopStdioRunners(for: providerId)

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
            providerStates[providerId] = state
        }
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
        notifyStatusChanged()
    }

    private func registerRemoteToolListChangedHandler(client: MCP.Client, providerId: UUID) async {
        await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
            Task { @MainActor in
                await self?.handleRemoteToolListChanged(providerId: providerId)
            }
        }
    }

    private func handleRemoteToolListChanged(providerId: UUID) async {
        guard let provider = configuration.provider(id: providerId),
            let client = clients[providerId]
        else { return }

        do {
            if let oldTools = registeredTools[providerId] {
                ToolRegistry.shared.unregister(names: oldTools.map { $0.name })
            }
            try await discoverTools(for: providerId, client: client, provider: provider)
        } catch {
            if var state = providerStates[providerId] {
                state.lastError = "Tool list refresh failed: \(error.localizedDescription)"
                providerStates[providerId] = state
            }
            notifyStatusChanged()
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

    private func discoverTools(for providerId: UUID, client: MCP.Client, provider: MCPProvider) async throws {
        // List tools with timeout, following pagination cursors so servers
        // that split tools/list across pages (e.g. Baserow, #1999) aren't
        // truncated to their first page.
        let mcpTools = try await MCPAsyncTimeout.run(seconds: provider.discoveryTimeout) {
            try await client.listAllTools()
        }

        // Store discovered tools
        discoveredTools[providerId] = mcpTools

        let tools = registerDiscoveredTools(mcpTools, for: providerId, provider: provider)
        registeredTools[providerId] = tools

        // Update state
        if var state = providerStates[providerId] {
            state.discoveredToolCount = tools.count
            state.discoveredToolNames = tools.map { $0.mcpToolName }
            providerStates[providerId] = state
        }

        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    /// Wrap each discovered MCP tool and register it with the shared
    /// `ToolRegistry`, returning the wrappers in discovery order.
    ///
    /// `registerMCPTool` auto-enables a tool only on its first registration
    /// and otherwise preserves the saved enabled state, so a per-tool disable
    /// survives re-discovery (launch / autoConnect). Do not force-enable here:
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

    private func notifyStatusChanged() {
        NotificationCenter.default.post(name: Foundation.Notification.Name.mcpProviderStatusChanged, object: nil)
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
