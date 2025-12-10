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

        guard provider.enabled else {
            throw MCPProviderError.providerDisabled
        }

        // Update state to connecting
        var state = providerStates[providerId] ?? MCPProviderState(providerId: providerId)
        state.isConnecting = true
        state.lastError = nil
        providerStates[providerId] = state

        do {
            // Create authenticated transport
            let transport = try createTransport(for: provider)

            // Create MCP client
            let client = MCP.Client(
                name: "Osaurus",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            )

            // Connect
            _ = try await client.connect(transport: transport)

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
                providerStates[providerId] = updatedState
                print(
                    "[Osaurus] MCP Provider '\(provider.name)': Connected with \(updatedState.discoveredToolCount) tools"
                )
            }
            notifyStatusChanged()

        } catch {
            // Update state with error - reset tool discovery state to match disconnect behavior
            state.isConnecting = false
            state.isConnected = false
            state.lastError = error.localizedDescription
            state.discoveredToolCount = 0
            state.discoveredToolNames = []
            providerStates[providerId] = state

            // Clean up (same as disconnect)
            clients.removeValue(forKey: providerId)
            discoveredTools.removeValue(forKey: providerId)
            registeredTools.removeValue(forKey: providerId)

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

        // Update state
        if var state = providerStates[providerId] {
            state.isConnected = false
            state.isConnecting = false
            state.discoveredToolCount = 0
            state.discoveredToolNames = []
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

    // MARK: - Tool Execution

    /// Execute a tool on a provider
    public func executeTool(providerId: UUID, toolName: String, argumentsJSON: String) async throws -> String {
        guard let client = clients[providerId] else {
            throw MCPProviderError.notConnected
        }

        guard let provider = configuration.provider(id: providerId) else {
            throw MCPProviderError.providerNotFound
        }

        // Convert arguments
        let arguments = try MCPProviderTool.convertArgumentsToMCPValues(argumentsJSON)

        // Execute with timeout
        let (content, isError) = try await withTimeout(seconds: provider.toolCallTimeout) {
            try await client.callTool(name: toolName, arguments: arguments)
        }

        // Check for error
        if let isError = isError, isError {
            let errorText = content.compactMap { item -> String? in
                if case .text(let text) = item { return text }
                return nil
            }.joined(separator: "\n")
            throw MCPProviderError.toolExecutionFailed(errorText.isEmpty ? "Tool returned error" : errorText)
        }

        // Convert content to string
        return MCPProviderTool.convertMCPContent(content)
    }

    // MARK: - Test Connection

    /// Test connection to a provider without persisting
    public func testConnection(url: String, token: String?, headers: [String: String]) async throws -> Int {
        guard let endpoint = URL(string: url) else {
            throw MCPProviderError.invalidURL
        }

        // Create temporary transport
        let configuration = URLSessionConfiguration.default
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

    // MARK: - Private Helpers

    private func createTransport(for provider: MCPProvider) throws -> HTTPClientTransport {
        guard let endpoint = URL(string: provider.url) else {
            throw MCPProviderError.invalidURL
        }

        let urlConfig = URLSessionConfiguration.default

        // Build headers
        var headers = provider.resolvedHeaders()
        if let token = provider.getToken(), !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
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

    private func discoverTools(for providerId: UUID, client: MCP.Client, provider: MCPProvider) async throws {
        // List tools with timeout
        let (mcpTools, _) = try await withTimeout(seconds: provider.discoveryTimeout) {
            try await client.listTools()
        }

        // Store discovered tools
        discoveredTools[providerId] = mcpTools

        // Create and register tool wrappers
        var tools: [MCPProviderTool] = []
        for mcpTool in mcpTools {
            let tool = MCPProviderTool(
                mcpTool: mcpTool,
                providerId: providerId,
                providerName: provider.name
            )
            tools.append(tool)
            ToolRegistry.shared.register(tool)
        }
        registeredTools[providerId] = tools

        // Update state
        if var state = providerStates[providerId] {
            state.discoveredToolCount = tools.count
            state.discoveredToolNames = tools.map { $0.mcpToolName }
            providerStates[providerId] = state
        }

        // Notify tools list changed
        await MCPServerManager.shared.notifyToolsListChanged()
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
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
