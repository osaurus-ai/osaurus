//
//  RemoteProviderManager.swift
//  osaurus
//
//  Manages remote OpenAI-compatible API provider connections.
//

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

    /// Current configuration
    @Published public private(set) var configuration: RemoteProviderConfiguration

    /// Runtime state for each provider
    @Published public private(set) var providerStates: [UUID: RemoteProviderState] = [:]

    /// Active service instances keyed by provider ID
    private var services: [UUID: RemoteProviderService] = [:]

    private init() {
        self.configuration = RemoteProviderConfigurationStore.load()

        // Initialize states for all providers
        for provider in configuration.providers {
            providerStates[provider.id] = RemoteProviderState(providerId: provider.id)
        }
    }

    // MARK: - Provider Management

    /// Add a new provider
    public func addProvider(_ provider: RemoteProvider, apiKey: String?) {
        configuration.add(provider)
        RemoteProviderConfigurationStore.save(configuration)

        // Save API key to Keychain if provided
        if let apiKey = apiKey, !apiKey.isEmpty {
            RemoteProviderKeychain.saveAPIKey(apiKey, for: provider.id)
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
    public func updateProvider(_ provider: RemoteProvider, apiKey: String?) {
        let wasConnected = providerStates[provider.id]?.isConnected ?? false

        // Disconnect if connected
        if wasConnected {
            disconnect(providerId: provider.id)
        }

        configuration.update(provider)
        RemoteProviderConfigurationStore.save(configuration)

        // Update API key if provided (nil means no change, empty string means clear)
        if let apiKey = apiKey {
            if apiKey.isEmpty {
                RemoteProviderKeychain.deleteAPIKey(for: provider.id)
            } else {
                RemoteProviderKeychain.saveAPIKey(apiKey, for: provider.id)
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
        RemoteProviderConfigurationStore.save(configuration)

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
        RemoteProviderConfigurationStore.save(configuration)

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
        providerStates[providerId] = state

        do {
            // Fetch models from the provider
            let models = try await RemoteProviderService.fetchModels(from: provider)

            // Create service instance
            let service = RemoteProviderService(provider: provider, models: models)
            services[providerId] = service

            // Update state to connected
            state.isConnecting = false
            state.isConnected = true
            state.discoveredModels = models
            state.lastConnectedAt = Date()
            state.lastError = nil
            providerStates[providerId] = state

            print("[Osaurus] Remote Provider '\(provider.name)': Connected with \(models.count) models")

            notifyStatusChanged()
            notifyModelsChanged()

        } catch {
            // Update state with error
            state.isConnecting = false
            state.isConnected = false
            state.lastError = error.localizedDescription
            state.discoveredModels = []
            providerStates[providerId] = state

            // Clean up
            services.removeValue(forKey: providerId)

            print("[Osaurus] Remote Provider '\(provider.name)': Connection failed - \(error)")

            notifyStatusChanged()
            throw error
        }
    }

    /// Disconnect from a provider
    public func disconnect(providerId: UUID) {
        // Clean up service
        services.removeValue(forKey: providerId)

        // Update state
        if var state = providerStates[providerId] {
            state.isConnected = false
            state.isConnecting = false
            state.discoveredModels = []
            providerStates[providerId] = state
        }

        if let provider = configuration.provider(id: providerId) {
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

    /// Find the service that handles a given model
    public func findService(forModel model: String) -> RemoteProviderService? {
        for service in services.values {
            if service.handles(requestedModel: model) {
                return service
            }
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
        apiKey: String?,
        headers: [String: String]
    ) async throws -> [String] {
        // Build temporary provider for testing
        let tempProvider = RemoteProvider(
            name: "Test",
            host: host,
            providerProtocol: providerProtocol,
            port: port,
            basePath: basePath,
            customHeaders: headers,
            authType: authType,
            enabled: true,
            autoConnect: false,
            timeout: 30
        )

        // Manually add API key to headers for test (since it's not in Keychain)
        var testHeaders = headers
        if authType == .apiKey, let apiKey = apiKey, !apiKey.isEmpty {
            testHeaders["Authorization"] = "Bearer \(apiKey)"
        }

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
            // Don't log the full auth header for security
            if key.lowercased() == "authorization" {
                print("[Osaurus] Test Connection: Adding header \(key)=Bearer ***")
            } else {
                print("[Osaurus] Test Connection: Adding header \(key)=\(value)")
            }
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[Osaurus] Test Connection: Invalid response type")
                throw RemoteProviderError.connectionFailed("Invalid response")
            }

            print("[Osaurus] Test Connection: HTTP \(httpResponse.statusCode)")

            if httpResponse.statusCode >= 400 {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("[Osaurus] Test Connection: Error response: \(errorMessage)")
                throw RemoteProviderError.connectionFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
            }

            // Parse models response
            let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
            print("[Osaurus] Test Connection: Success - found \(modelsResponse.data.count) models")
            return modelsResponse.data.map { $0.id }
        } catch let error as RemoteProviderError {
            throw error
        } catch {
            print("[Osaurus] Test Connection: Network error: \(error)")
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
