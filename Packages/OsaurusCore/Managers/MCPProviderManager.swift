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

        // Initialize states for all providers
        for provider in configuration.providers {
            providerStates[provider.id] = MCPProviderState(providerId: provider.id)
        }
    }

    // MARK: - Provider Management

    /// Add a new provider
    public func addProvider(_ provider: MCPProvider, token: String?) {
        configuration.add(provider)
        MCPProviderConfigurationStore.save(configuration)
        // KPI: a user-configured MCP tool provider. Only the transport kind
        // is captured — never the command, URL, or args.
        FeatureTelemetry.mcpProviderAdded(transport: provider.transport.rawValue)

        // Save token to Keychain if provided
        if let token = token, !token.isEmpty {
            MCPProviderKeychain.saveToken(token, for: provider.id)
        }

        // Initialize state
        providerStates[provider.id] = MCPProviderState(providerId: provider.id)

        // Auto-connect if enabled
        if provider.enabled {
            Task {
                try? await connect(providerId: provider.id)
            }
        }

        notifyStatusChanged()
    }

    /// Update an existing provider
    public func updateProvider(_ provider: MCPProvider, token: String?) {
        let wasConnected = providerStates[provider.id]?.isConnected ?? false

        // Disconnect if connected
        if wasConnected {
            disconnect(providerId: provider.id)
        }

        let previous = configuration.provider(id: provider.id)
        configuration.update(provider)
        MCPProviderConfigurationStore.save(configuration)

        // Update token if provided (empty string means clear token)
        if let token = token {
            if token.isEmpty {
                MCPProviderKeychain.deleteToken(for: provider.id)
            } else {
                MCPProviderKeychain.saveToken(token, for: provider.id)
            }
        }

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

        do {
            // Create authenticated transport
            let transport = try await createTransport(for: provider)

            // Create MCP client
            let client = MCP.Client(
                name: "Osaurus",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            )

            // Connect under a timeout. Without this, a stdio subprocess that
            // spawned successfully but never speaks MCP would leave the card
            // stuck on "Connecting…" indefinitely. `discoverTools` already
            // uses `withTimeout` for the second leg of the handshake — we
            // mirror that for the first.
            try await withTimeout(seconds: provider.discoveryTimeout) {
                _ = try await client.connect(transport: transport)
            }

            // Store client
            clients[providerId] = client

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
            // so there's no `WWW-Authenticate` 401 to probe — the error is
            // either a spawn failure or a protocol mismatch.
            let challenge: MCPBearerChallenge? =
                provider.transport == .http
                ? await probeAuthChallenge(for: provider)
                : nil

            if let challenge {
                // Try one refresh+retry for OAuth providers when we already have tokens.
                // Off the main actor: the Keychain read blocks on securityd XPC + decrypt.
                if allowOAuthRetry,
                    provider.authType == .oauth,
                    let tokens = await Task.detached(
                        priority: .userInitiated,
                        operation: { MCPProviderKeychain.getOAuthTokens(for: providerId) }
                    ).value,
                    tokens.refreshToken?.isEmpty == false
                {
                    do {
                        _ = try await MCPOAuthService.refresh(provider: provider, tokens: tokens)
                        // Re-enter without retry budget so we can't loop.
                        try await performConnect(provider: provider, allowOAuthRetry: false)
                        return
                    } catch {
                        // Fall through and surface the original auth challenge.
                    }
                }

                state.requiresAuth = true
                state.resourceMetadataURL = challenge.resourceMetadataURL
                state.lastError =
                    challenge.errorDescription ?? challenge.error ?? "Server requires sign in"
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

            // Clean up local state
            clients.removeValue(forKey: providerId)
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

        // Clean up
        clients.removeValue(forKey: providerId)
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

    /// Execute a tool on a provider
    public func executeTool(providerId: UUID, toolName: String, argumentsJSON: String) async throws -> String {
        guard let client = clients[providerId] else {
            throw MCPProviderError.notConnected
        }

        guard let provider = configuration.provider(id: providerId) else {
            throw MCPProviderError.providerNotFound
        }

        let arguments = try MCPProviderTool.convertArgumentsToMCPValues(argumentsJSON)
        let timeout = provider.toolCallTimeout

        // Run the network call off MainActor so it doesn't block the UI thread.
        let (content, isError) = try await Self.callMCPTool(
            client: client,
            toolName: toolName,
            arguments: arguments,
            timeout: timeout
        )

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

    /// Trampoline that runs the MCP network call outside MainActor isolation.
    private nonisolated static func callMCPTool(
        client: MCP.Client,
        toolName: String,
        arguments: [String: MCP.Value],
        timeout: TimeInterval
    ) async throws -> ([MCP.Tool.Content], Bool?) {
        try await withThrowingTaskGroup(of: ([MCP.Tool.Content], Bool?).self) { group in
            group.addTask {
                try await client.callTool(name: toolName, arguments: arguments)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MCPProviderError.timeout
            }
            guard let result = try await group.next() else {
                throw MCPProviderError.timeout
            }
            group.cancelAll()
            return result
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
            try await withTimeout(seconds: 10) {
                _ = try await client.connect(transport: transport)
            }
            let (tools, _) = try await withTimeout(seconds: 10) {
                try await client.listTools()
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
        let configuration = GlobalProxySettings.makeConfiguration(base: .default)
        var allHeaders: [String: String] = headers
        if let token = token, !token.isEmpty {
            allHeaders["Authorization"] = "Bearer \(token)"
        }
        if !allHeaders.isEmpty {
            configuration.httpAdditionalHeaders = allHeaders
        }
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20

        let transport = HTTPClientTransport(
            endpoint: endpoint,
            configuration: configuration,
            streaming: false
        )

        let client = MCP.Client(
            name: "Osaurus",
            version: "1.0.0"
        )

        // Connect
        _ = try await client.connect(transport: transport)

        // List tools to verify connection
        let (tools, _) = try await client.listTools()

        return tools.count
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
                let runner = try SandboxStdioRunner(provider: provider)
                try await runner.start()
                sandboxStdioRunners[provider.id] = runner
                return runner.transport
            #else
                throw MCPStdioTransportError.sandboxUnavailable
            #endif
        }
    }

    /// Build the `URLSessionConfiguration` for a provider, including any cached
    /// auth headers. OAuth refresh-before-connect happens inside this method so
    /// every entrypoint (connect / testConnection) goes through the same gate.
    private func createHTTPTransport(for provider: MCPProvider) async throws -> HTTPClientTransport {
        guard let endpoint = URL(string: provider.url) else {
            throw MCPProviderError.invalidURL
        }

        let urlConfig = GlobalProxySettings.makeConfiguration(base: .default)

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

        if !headers.isEmpty {
            urlConfig.httpAdditionalHeaders = headers
        }

        urlConfig.timeoutIntervalForRequest = provider.discoveryTimeout
        urlConfig.timeoutIntervalForResource = max(provider.discoveryTimeout, provider.toolCallTimeout)

        return HTTPClientTransport(
            endpoint: endpoint,
            configuration: urlConfig,
            streaming: provider.streamingEnabled
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
            throw MCPProviderError.connectionFailed(
                "Could not refresh OAuth tokens: \(error.localizedDescription)"
            )
        }
    }

    /// Issue a low-cost POST against the server's MCP endpoint to capture an auth
    /// challenge, if any. The Swift MCP SDK doesn't expose response headers on its
    /// error type, so this is the cheapest correct way to know whether a 401 came
    /// from an OAuth-protected server.
    private nonisolated func probeAuthChallenge(for provider: MCPProvider) async -> MCPBearerChallenge? {
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
        // A minimal JSON-RPC initialize payload — most MCP servers will hit auth
        // before they even attempt to parse it, so the body is mostly cosmetic.
        request.httpBody = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}".utf8)
        request.timeoutInterval = 10

        do {
            let (_, response) = try await GlobalProxySettings.sharedSession().data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 401 || http.statusCode == 403 else { return nil }
            let header =
                http.value(forHTTPHeaderField: "WWW-Authenticate")
                ?? http.value(forHTTPHeaderField: "www-authenticate")
            return MCPWWWAuthenticate.parseBearer(header)
        } catch {
            return nil
        }
    }

    private func discoverTools(for providerId: UUID, client: MCP.Client, provider: MCPProvider) async throws {
        // List tools with timeout
        let (mcpTools, _) = try await withTimeout(seconds: provider.discoveryTimeout) {
            try await client.listTools()
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
    /// survives re-discovery (launch / autoConnect). Do NOT force-enable here:
    /// that would overwrite the user's choice on every reconnect.
    @discardableResult
    internal func registerDiscoveredTools(
        _ mcpTools: [MCP.Tool],
        for providerId: UUID,
        provider: MCPProvider
    ) -> [MCPProviderTool] {
        var tools: [MCPProviderTool] = []
        for mcpTool in mcpTools {
            let tool = MCPProviderTool(
                mcpTool: mcpTool,
                providerId: providerId,
                providerName: provider.name
            )
            tools.append(tool)
            ToolRegistry.shared.registerMCPTool(tool)
        }
        return tools
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T)
        async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MCPProviderError.timeout
            }

            guard let result = try await group.next() else {
                throw MCPProviderError.timeout
            }
            group.cancelAll()
            return result
        }
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
