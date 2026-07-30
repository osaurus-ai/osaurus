//
//  AgentChannelConnectionManager.swift
//  osaurus
//
//  Editable channel configuration support for the management UI.
//

import Foundation

enum AgentChannelConnectionManagerError: LocalizedError, Equatable, Sendable {
    case emptyConnectionId
    case reservedConnectionId(String)
    case emptyName
    case missingSupportedActions(String)
    case missingCustomHTTPConfiguration(String)
    case invalidCustomHTTPBaseURL(String)
    case invalidCustomHTTPMethod(action: String, method: String)
    case invalidCustomHTTPPath(action: String, path: String)
    case invalidCustomHTTPHeader(action: String, header: String)
    case invalidCustomHTTPResponseMapping(action: String, path: String)
    case unsupportedCustomHTTPAction(String)
    case invalidSecretReference(String)
    case duplicateConnectionId(String)
    case importFailed(String)
    case emptyBindingId
    case duplicateBindingId(String)
    case invalidBinding(String)

    var errorDescription: String? {
        switch self {
        case .emptyConnectionId:
            return "Agent channel connection id is required."
        case .reservedConnectionId(let id):
            return "`\(id)` is reserved for a native Agent Channel connection."
        case .emptyName:
            return "Agent channel connection name is required."
        case .missingSupportedActions(let id):
            return "Agent channel connection `\(id)` must support at least one standard action."
        case .missingCustomHTTPConfiguration(let id):
            return "Custom JSON channel `\(id)` requires a custom HTTP configuration."
        case .invalidCustomHTTPBaseURL(let url):
            return "`\(url)` is not a valid HTTP or HTTPS base URL."
        case .invalidCustomHTTPMethod(let action, let method):
            return "Custom action `\(action)` uses unsupported HTTP method `\(method)`."
        case .invalidCustomHTTPPath(let action, let path):
            return "Custom action `\(action)` path `\(path)` must start with `/` and must not contain line breaks."
        case .invalidCustomHTTPHeader(let action, let header):
            return "Custom action `\(action)` header `\(header)` must not contain line breaks."
        case .invalidCustomHTTPResponseMapping(let action, let path):
            return "Custom action `\(action)` response mapping path `\(path)` is not supported."
        case .unsupportedCustomHTTPAction(let action):
            return "Custom action `\(action)` must be one of the standard Agent Channel actions."
        case .invalidSecretReference(let name):
            return "Secret reference `\(name)` must include a non-empty name and Keychain id with no line breaks."
        case .duplicateConnectionId(let id):
            return "Agent channel connection id `\(id)` appears more than once."
        case .importFailed(let message):
            return "Agent channel configuration import failed: \(message)"
        case .emptyBindingId:
            return "Agent destination binding id is required."
        case .duplicateBindingId(let id):
            return "Agent destination binding id `\(id)` appears more than once."
        case .invalidBinding(let message):
            return "Agent destination binding is invalid: \(message)"
        }
    }
}

final class AgentChannelConnectionManager: @unchecked Sendable {
    static let shared = AgentChannelConnectionManager()

    private static let reservedConnectionIds = Set([
        AgentChannelConnection.nativeDiscordConnectionId,
        AgentChannelConnection.nativeSlackConnectionId,
        AgentChannelConnection.nativeTelegramConnectionId,
        AgentChannelConnection.nativeIMessageConnectionId,
    ])
    private static let supportedHTTPMethods = Set(["GET", "POST", "PUT", "PATCH", "DELETE"])

    /// Agent existence check for binding reference validation, injectable
    /// so tests don't need real agent files on disk. `AgentStore.exists` is
    /// nonisolated (pure filesystem), so validation never has to hop onto
    /// the main thread — the old `DispatchQueue.main.sync` bridge here was
    /// a deadlock vector whenever the main thread was itself waiting on
    /// background work.
    private let agentExists: @Sendable (UUID) -> Bool

    init(
        agentExists: @escaping @Sendable (UUID) -> Bool = { id in
            AgentStore.exists(id: id)
        }
    ) {
        self.agentExists = agentExists
    }

    func configurationFileURL() -> URL {
        AgentChannelConfigurationStore.configurationFileURL()
    }

    func loadConfiguration() -> AgentChannelConfiguration {
        AgentChannelConfigurationStore.load()
    }

    func editableConnections() -> [AgentChannelConnection] {
        loadConfiguration().connections
            .filter { !Self.reservedConnectionIds.contains($0.id.lowercased()) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func connection(id: String) -> AgentChannelConnection? {
        let normalizedId = AgentChannelConnection.normalizedId(id)
        return editableConnections().first { $0.id == normalizedId }
    }

    func upsertConnection(
        _ connection: AgentChannelConnection,
        replacingOriginalId originalId: String? = nil
    ) throws {
        let validated = try validatedConnection(connection)
        let normalizedOriginalId =
            originalId
            .map(AgentChannelConnection.normalizedId)
            .flatMap { $0.isEmpty ? nil : $0 }
        if let normalizedOriginalId,
            Self.reservedConnectionIds.contains(normalizedOriginalId.lowercased()) {
            throw AgentChannelConnectionManagerError.reservedConnectionId(normalizedOriginalId)
        }
        var configuration = loadConfiguration()
        if let normalizedOriginalId,
            normalizedOriginalId != validated.id,
            configuration.connections.contains(where: { $0.id == validated.id }) {
            throw AgentChannelConnectionManagerError.duplicateConnectionId(validated.id)
        }
        if normalizedOriginalId == nil,
            configuration.connections.contains(where: { $0.id == validated.id }) {
            throw AgentChannelConnectionManagerError.duplicateConnectionId(validated.id)
        }
        configuration.connections.removeAll { existing in
            if let normalizedOriginalId {
                return existing.id == validated.id || existing.id == normalizedOriginalId
            }
            return existing.id == validated.id
        }
        configuration.connections.append(validated)
        try AgentChannelConfigurationStore.save(configuration)
    }

    func deleteConnection(id: String) throws {
        let normalizedId = AgentChannelConnection.normalizedId(id)
        guard !Self.reservedConnectionIds.contains(normalizedId.lowercased()) else {
            throw AgentChannelConnectionManagerError.reservedConnectionId(normalizedId)
        }
        var configuration = loadConfiguration()
        configuration.connections.removeAll { $0.id == normalizedId }
        // Cascade-disable bindings that pointed at the deleted connection.
        // Disabled (not deleted) so the operator sees what broke — and so a
        // LATER connection recreated under the same id can never silently
        // reactivate an old autonomous route without an explicit re-enable.
        configuration.bindings = configuration.bindings.map { binding in
            guard binding.connectionId == normalizedId else { return binding }
            var disabled = binding
            disabled.enabled = false
            return disabled
        }
        try AgentChannelConfigurationStore.save(configuration)
    }

    // MARK: - Proactive outbound bindings

    func bindings() -> [AgentChannelBinding] {
        loadConfiguration().bindings
            .sorted { lhs, rhs in
                lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel)
                    == .orderedAscending
            }
    }

    func binding(id: String) -> AgentChannelBinding? {
        loadConfiguration().binding(id: id)
    }

    func upsertBinding(
        _ binding: AgentChannelBinding,
        replacingOriginalId originalId: String? = nil
    ) throws {
        let validated = try validatedBinding(binding)
        // Referential integrity at save time: the agent must exist and the
        // connection must be native or currently configured. Import takes a
        // softer path (disable instead of reject) in `validatedConfiguration`.
        guard agentExists(validated.agentId) else {
            throw AgentChannelConnectionManagerError.invalidBinding(
                "agent `\(validated.agentId.uuidString)` does not exist"
            )
        }
        guard Self.isKnownConnectionId(validated.connectionId, in: loadConfiguration()) else {
            throw AgentChannelConnectionManagerError.invalidBinding(
                "connection `\(validated.connectionId)` does not exist"
            )
        }
        let normalizedOriginalId =
            originalId
            .map(AgentChannelBinding.normalizedBindingId)
            .flatMap { $0.isEmpty ? nil : $0 }
        var configuration = loadConfiguration()
        if normalizedOriginalId != validated.id,
            configuration.bindings.contains(where: { $0.id == validated.id }) {
            throw AgentChannelConnectionManagerError.duplicateBindingId(validated.id)
        }
        configuration.bindings.removeAll { existing in
            if let normalizedOriginalId {
                return existing.id == validated.id || existing.id == normalizedOriginalId
            }
            return existing.id == validated.id
        }
        configuration.bindings.append(validated)
        try AgentChannelConfigurationStore.save(configuration)
    }

    func deleteBinding(id: String) throws {
        let normalizedId = AgentChannelBinding.normalizedBindingId(id)
        var configuration = loadConfiguration()
        configuration.bindings.removeAll { $0.id == normalizedId }
        try AgentChannelConfigurationStore.save(configuration)
    }

    /// Remove every binding owned by a deleted agent. Agent UUIDs are never
    /// reused, so deletion (not disablement) is safe and keeps the
    /// configuration free of permanent orphans. Called by
    /// `AgentManager.delete`.
    func deleteBindings(agentId: UUID) throws {
        var configuration = loadConfiguration()
        let before = configuration.bindings.count
        configuration.bindings.removeAll { $0.agentId == agentId }
        guard configuration.bindings.count != before else { return }
        try AgentChannelConfigurationStore.save(configuration)
    }

    /// Whether `connectionId` resolves to a native provider connection or a
    /// custom connection present in `configuration`.
    static func isKnownConnectionId(
        _ connectionId: String,
        in configuration: AgentChannelConfiguration
    ) -> Bool {
        let normalized = AgentChannelConnection.normalizedId(connectionId)
        if reservedConnectionIds.contains(normalized.lowercased()) { return true }
        return configuration.connection(id: normalized) != nil
    }

    private func validatedBinding(_ binding: AgentChannelBinding) throws -> AgentChannelBinding {
        let normalized = binding.normalized
        guard !normalized.id.isEmpty else {
            throw AgentChannelConnectionManagerError.emptyBindingId
        }
        guard !normalized.id.containsLineBreak else {
            throw AgentChannelConnectionManagerError.invalidBinding(
                "binding id must not contain line breaks"
            )
        }
        guard !normalized.connectionId.isEmpty else {
            throw AgentChannelConnectionManagerError.invalidBinding("connection id is required")
        }
        guard !normalized.roomId.isEmpty else {
            throw AgentChannelConnectionManagerError.invalidBinding("room id is required")
        }
        guard !normalized.allowedSources.isEmpty else {
            throw AgentChannelConnectionManagerError.invalidBinding(
                "at least one allowed run source is required"
            )
        }
        return normalized
    }

    func exportConfigurationData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(loadConfiguration().normalized)
    }

    func importConfigurationData(_ data: Data) throws {
        do {
            let decoded = try JSONDecoder().decode(AgentChannelConfiguration.self, from: data)
            let validated = try validatedConfiguration(decoded)
            try AgentChannelConfigurationStore.save(validated)
        } catch let error as AgentChannelConnectionManagerError {
            throw error
        } catch {
            throw AgentChannelConnectionManagerError.importFailed(error.localizedDescription)
        }
    }

    private func validatedConfiguration(
        _ configuration: AgentChannelConfiguration
    ) throws -> AgentChannelConfiguration {
        var seen = Set<String>()
        let validatedConnections = try configuration.connections.map { connection in
            let normalized = AgentChannelConnection.normalizedId(connection.id)
            guard seen.insert(normalized).inserted else {
                throw AgentChannelConnectionManagerError.duplicateConnectionId(normalized)
            }
            return try validatedConnection(connection)
        }
        var seenBindings = Set<String>()
        let knownConnectionIds = AgentChannelConfiguration(connections: validatedConnections)
        let validatedBindings = try configuration.bindings.map { binding -> AgentChannelBinding in
            let normalizedId = AgentChannelBinding.normalizedBindingId(binding.id)
            guard seenBindings.insert(normalizedId).inserted else {
                throw AgentChannelConnectionManagerError.duplicateBindingId(normalizedId)
            }
            var validated = try validatedBinding(binding)
            // Import safety: an imported file is a claim, not an approval.
            // Autonomous bindings arrive DISABLED so this machine's operator
            // must explicitly re-acknowledge unprompted sending, and any
            // binding whose references don't resolve here (unknown agent or
            // connection) is disabled instead of rejected wholesale.
            if validated.outboundMode == .autonomous
                || !agentExists(validated.agentId)
                || !Self.isKnownConnectionId(validated.connectionId, in: knownConnectionIds)
            {
                validated.enabled = false
            }
            return validated
        }
        return AgentChannelConfiguration(
            schemaVersion: max(
                configuration.schemaVersion,
                AgentChannelConfiguration.currentSchemaVersion
            ),
            connections: validatedConnections,
            bindings: validatedBindings
        )
    }

    private func validatedConnection(
        _ connection: AgentChannelConnection
    ) throws -> AgentChannelConnection {
        let normalized = connection.normalized
        guard !normalized.id.isEmpty else {
            throw AgentChannelConnectionManagerError.emptyConnectionId
        }
        guard !Self.reservedConnectionIds.contains(normalized.id.lowercased()) else {
            throw AgentChannelConnectionManagerError.reservedConnectionId(normalized.id)
        }
        guard !normalized.name.isEmpty else {
            throw AgentChannelConnectionManagerError.emptyName
        }
        guard !normalized.supportedActions.isEmpty else {
            throw AgentChannelConnectionManagerError.missingSupportedActions(normalized.id)
        }
        try validateSecretReferences(normalized.secrets)
        if normalized.kind == .customHTTP {
            try validateCustomHTTPConfiguration(for: normalized)
        }
        return normalized
    }

    private func validateSecretReferences(
        _ secrets: [AgentChannelSecretReference]
    ) throws {
        var seen = Set<String>()
        for secret in secrets {
            let name = secret.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let keychainId = secret.keychainId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                !keychainId.isEmpty,
                !name.containsLineBreak,
                !keychainId.containsLineBreak,
                seen.insert(name).inserted
            else {
                throw AgentChannelConnectionManagerError.invalidSecretReference(name)
            }
        }
    }

    private func validateCustomHTTPConfiguration(
        for connection: AgentChannelConnection
    ) throws {
        guard let customHTTP = connection.customHTTP else {
            throw AgentChannelConnectionManagerError.missingCustomHTTPConfiguration(connection.id)
        }
        guard let components = URLComponents(string: customHTTP.baseURL),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.isEmpty == false
        else {
            throw AgentChannelConnectionManagerError.invalidCustomHTTPBaseURL(customHTTP.baseURL)
        }
        do {
            try AgentChannelCustomJSONRunner.validateConfigurationURL(customHTTP)
        } catch {
            throw AgentChannelConnectionManagerError.invalidCustomHTTPBaseURL(customHTTP.baseURL)
        }

        let supportedActionNames = Set(connection.supportedActions.map(\.rawValue))
        for (actionName, action) in customHTTP.actions {
            guard AgentChannelAction(rawValue: actionName) != nil,
                supportedActionNames.contains(actionName)
            else {
                throw AgentChannelConnectionManagerError.unsupportedCustomHTTPAction(actionName)
            }
            guard Self.supportedHTTPMethods.contains(action.method) else {
                throw AgentChannelConnectionManagerError.invalidCustomHTTPMethod(
                    action: actionName,
                    method: action.method
                )
            }
            guard action.path.hasPrefix("/"),
                !action.path.containsLineBreak
            else {
                throw AgentChannelConnectionManagerError.invalidCustomHTTPPath(
                    action: actionName,
                    path: action.path
                )
            }
            try validateHeaderLikeFields(action: actionName, values: action.query)
            try validateHeaderLikeFields(action: actionName, values: action.headers)
            try validateResponseMapping(action: actionName, mapping: action.responseMapping)
            try validateIdempotency(action: actionName, idempotency: action.idempotency)
        }
    }

    private func validateResponseMapping(
        action: String,
        mapping: AgentChannelCustomHTTPResponseMapping
    ) throws {
        for path in mapping.allConfiguredPaths {
            do {
                try AgentChannelCustomHTTPResponseMapping.validatePath(path)
            } catch {
                throw AgentChannelConnectionManagerError.invalidCustomHTTPResponseMapping(
                    action: action,
                    path: path
                )
            }
        }
    }

    private func validateIdempotency(
        action: String,
        idempotency: AgentChannelCustomHTTPIdempotency?
    ) throws {
        guard let idempotency else { return }
        for path in idempotency.configuredResponsePaths {
            do {
                try AgentChannelCustomHTTPResponseMapping.validatePath(path)
            } catch {
                throw AgentChannelConnectionManagerError.invalidCustomHTTPResponseMapping(
                    action: action,
                    path: path
                )
            }
        }
    }

    private func validateHeaderLikeFields(
        action: String,
        values: [String: String]
    ) throws {
        for (key, value) in values where key.containsLineBreak || value.containsLineBreak {
            throw AgentChannelConnectionManagerError.invalidCustomHTTPHeader(
                action: action,
                header: key
            )
        }
    }
}

private extension String {
    var containsLineBreak: Bool {
        rangeOfCharacter(from: .newlines) != nil
    }
}
