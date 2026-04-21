//
//  SandboxPluginRegistration.swift
//  osaurus
//
//  Shared service used by both the in-process `sandbox_plugin_register`
//  tool and the host-API `POST /api/plugin/create` endpoint to register
//  agent-created sandbox plugins. Centralises validation, restricted
//  defaults, library persistence, install, hot-registration, and the
//  user-facing toast so the two call sites can't drift apart.
//

import Foundation

/// Result of a successful registration. Surfaced by the in-process tool
/// (in its envelope payload) and by the HTTP bridge (in its JSON body).
public struct SandboxPluginRegistrationOutcome: Sendable {
    public struct RegisteredTool: Sendable, Equatable {
        public let name: String
        public let description: String
    }

    public let plugin: SandboxPlugin
    public let registeredTools: [RegisteredTool]
}

/// Where a registration request came from. Recorded in `metadata.created_via`
/// so the library UI can later distinguish the in-process tool path from
/// the host-API bridge path.
public enum SandboxPluginRegistrationSource: String, Sendable {
    case agentTool = "agent_tool"
    case hostBridge = "host_bridge"

    /// `metadata.created_by` value. Both paths attribute ownership to the
    /// agent — the call site is captured separately by `rawValue`.
    var metadataValue: String { "agent" }
}

/// Structured failure reason. Maps cleanly onto both
/// `ToolEnvelope.failure(kind: ...)` (for the in-process tool) and
/// HTTP status codes (for the bridge).
public enum SandboxPluginRegistrationError: Error, Sendable {
    case invalidArgs(String)
    case unavailable(String)
    case rateLimited(String)
    case executionError(String, retryable: Bool)

    public var message: String {
        switch self {
        case .invalidArgs(let msg),
            .unavailable(let msg),
            .rateLimited(let msg):
            return msg
        case .executionError(let msg, _):
            return msg
        }
    }

    public var retryable: Bool {
        switch self {
        case .invalidArgs: return false
        case .unavailable, .rateLimited: return true
        case .executionError(_, let retryable): return retryable
        }
    }

    public var httpStatusCode: Int {
        switch self {
        case .invalidArgs: return 400
        case .unavailable: return 503
        case .rateLimited: return 429
        case .executionError: return 500
        }
    }
}

@MainActor
public enum SandboxPluginRegistration {

    // MARK: - Entry Points

    /// Validate, persist, install, and hot-register an agent-created
    /// plugin. Throws `SandboxPluginRegistrationError` on any failure;
    /// returns the registered tools on success.
    ///
    /// Callers are expected to enforce their own gates (e.g. the
    /// `pluginCreate` autonomous-exec flag, request authentication)
    /// before invoking this method.
    public static func register(
        plugin: SandboxPlugin,
        agentId: String,
        source: SandboxPluginRegistrationSource,
        skipRateLimit: Bool = false
    ) async throws -> SandboxPluginRegistrationOutcome {
        var staged = plugin
        try validateAndStage(&staged, agentId: agentId)

        if !skipRateLimit {
            guard SandboxRateLimiter.shared.checkLimit(agent: agentId, service: "http") else {
                throw SandboxPluginRegistrationError.rateLimited(
                    "Plugin registration rate limit exceeded for this agent."
                )
            }
        }

        guard await SandboxManager.shared.status().isRunning else {
            throw SandboxPluginRegistrationError.unavailable(
                "Sandbox container is not running."
            )
        }

        // Stamp provenance + restricted defaults BEFORE persisting so the
        // library copy matches what gets installed.
        SandboxPluginDefaults.applyRestrictedDefaults(&staged)
        if staged.metadata == nil { staged.metadata = [:] }
        staged.metadata?["created_by"] = .string(source.metadataValue)
        staged.metadata?["created_via"] = .string(source.rawValue)

        SandboxPluginLibrary.shared.save(staged)

        do {
            try await SandboxPluginManager.shared.install(plugin: staged, for: agentId)
        } catch {
            throw SandboxPluginRegistrationError.executionError(
                "Plugin installation failed: \(error.localizedDescription)",
                retryable: true
            )
        }

        let registered = hotRegisterTools(plugin: staged)
        queueToast(plugin: staged, toolCount: registered.count, agentId: agentId)

        return SandboxPluginRegistrationOutcome(
            plugin: staged,
            registeredTools: registered
        )
    }

    // MARK: - Validation

    /// Reject anything the install pipeline would silently mishandle.
    /// Mutates `plugin` only if a future check needs to normalise fields;
    /// today everything is read-only.
    static func validateAndStage(
        _ plugin: inout SandboxPlugin,
        agentId: String
    ) throws {
        let pathErrors = plugin.validateFilePaths()
        if !pathErrors.isEmpty {
            throw SandboxPluginRegistrationError.invalidArgs(
                "Invalid file paths: \(pathErrors.joined(separator: "; "))"
            )
        }

        if let setup = plugin.setup {
            let violations = SandboxNetworkPolicy.validateSetupCommand(setup)
            if !violations.isEmpty {
                throw SandboxPluginRegistrationError.invalidArgs(
                    "Setup command rejected: \(violations.joined(separator: "; "))"
                )
            }
        }

        // Per-tool `run` commands ride the same network policy as `setup`.
        // Without this, an agent could put `curl https://evil.example` directly
        // into a tool's `run` and bypass the allowlist.
        for tool in plugin.tools ?? [] {
            let violations = SandboxNetworkPolicy.validateSetupCommand(tool.run)
            if !violations.isEmpty {
                throw SandboxPluginRegistrationError.invalidArgs(
                    "Tool `\(tool.id)` run command rejected: "
                        + violations.joined(separator: "; ")
                )
            }
        }

        if let agentUUID = UUID(uuidString: agentId) {
            let missing = missingSecrets(for: plugin, agentId: agentUUID)
            if !missing.isEmpty {
                throw SandboxPluginRegistrationError.invalidArgs(
                    "Missing secrets for plugin: \(missing.joined(separator: ", ")). "
                        + "Call `sandbox_secret_set` (or have the user provide values) "
                        + "for each before re-registering."
                )
            }
        }
    }

    // MARK: - Helpers

    /// Returns the names of declared `secrets` whose values are not present
    /// in the agent or plugin keychain.
    private static func missingSecrets(
        for plugin: SandboxPlugin,
        agentId: UUID
    ) -> [String] {
        guard let names = plugin.secrets, !names.isEmpty else { return [] }
        let env = AgentSecretsKeychain.mergedSecretsEnvironment(
            agentId: agentId,
            pluginId: plugin.id
        )
        return names.filter { (env[$0] ?? "").isEmpty }
    }

    private static func hotRegisterTools(
        plugin: SandboxPlugin
    ) -> [SandboxPluginRegistrationOutcome.RegisteredTool] {
        ToolRegistry.shared.registerSandboxPluginTools(plugin: plugin)

        let registered = (plugin.tools ?? []).map {
            SandboxPluginRegistrationOutcome.RegisteredTool(
                name: "\(plugin.id)_\($0.id)",
                description: $0.description
            )
        }

        // CapabilityLoadBuffer is an actor; fire-and-forget so this stays
        // synchronous-on-MainActor for the simpler call sites.
        let specs = ToolRegistry.shared.specs(forTools: registered.map(\.name))
        Task {
            for spec in specs {
                await CapabilityLoadBuffer.shared.add(spec)
            }
        }

        return registered
    }

    private static func queueToast(
        plugin: SandboxPlugin,
        toolCount: Int,
        agentId: String
    ) {
        let actionId = "removeAgentPlugin:\(plugin.id):\(agentId)"
        // Replace any prior handler so re-registering the same plugin doesn't
        // leak the old closure (which captured a stale agentId/pluginId).
        ToastManager.shared.unregisterActionHandler(for: actionId)
        ToastManager.shared.registerActionHandler(for: actionId) { _ in
            Task { @MainActor in
                try? await SandboxPluginManager.shared.uninstall(
                    pluginId: plugin.id,
                    from: agentId
                )
                SandboxPluginLibrary.shared.delete(id: plugin.id)
            }
        }
        ToastManager.shared.action(
            "Agent created plugin: \(plugin.name)",
            message: "\(toolCount) tool\(toolCount == 1 ? "" : "s") registered",
            actionTitle: "Remove",
            actionId: actionId,
            timeout: 0
        )
    }
}

// MARK: - Tool Envelope Mapping

extension SandboxPluginRegistrationError {
    /// Map the registration error onto a tool-envelope `kind` so the
    /// in-process tool can return a structured failure without restating
    /// the case-by-case mapping at every call site.
    var toolEnvelopeKind: ToolEnvelope.Kind {
        switch self {
        case .invalidArgs: return .invalidArgs
        case .unavailable: return .unavailable
        case .rateLimited: return .rejected
        case .executionError: return .executionError
        }
    }
}
