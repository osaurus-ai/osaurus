#if OSAURUS_DESIGN_INSPECTOR
import Foundation

@MainActor enum DesignModelConnectionChecks {
    static func run() {
        var checks: [String] = []
        func require(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { print("MODEL_CONNECTION_CHECK_FAILED: " + name); exit(1) }
            checks.append(name)
        }
        // This entry point runs only in a separate, offline verification profile.
        require(ProcessInfo.processInfo.environment["OSAURUS_DESIGN_INSPECTOR_CONNECTED_MODELS"] != "1", "offlineCheckProfile")
        require(KeychainQueryHelpers.disablesKeychainForProcess, "identityKeychainStillDisabled")
        require(KeychainQueryHelpers.providerServiceIsDisabled(KeychainQueryHelpers.designProviderService,
            processDisabled: true, connectedDesignProviders: false), "offlineProviderBlocked")
        require(!KeychainQueryHelpers.providerServiceIsDisabled(KeychainQueryHelpers.designProviderService,
            processDisabled: true, connectedDesignProviders: true), "connectedOwnProviderAllowed")
        for service in ["ai.osaurus.remote", "com.osaurus.storage", "com.osaurus.masterkey", "Claude Code-credentials"] {
            require(KeychainQueryHelpers.providerServiceIsDisabled(service,
                processDisabled: true, connectedDesignProviders: true), "otherServiceBlocked:" + service)
        }
        do {
            let old = try JSONDecoder().decode(ArchitectConfiguration.self, from: Data(#"{"model":"old-model"}"#.utf8))
            require(old.model == "old-model" && old.runtime == nil && old.claudeCode == nil, "oldArchitectFileCompatible")
            let root = OsaurusPaths.config().appendingPathComponent("connection-check", isDirectory: true)
            ArchitectConfigurationStore.overrideDirectory = root
            ArchitectConfigurationStore.resetCacheForTests()
            ArchitectConfigurationStore.save(ArchitectConfiguration(displayName: "Blueprint", systemPrompt: "Keep instructions"))
            let manager = AgentManager.shared
            let runtime = AgentRuntime.harness(UUID())
            var claude = ClaudeCodeAgentConfig.default
            claude.model = "opus"
            manager.updateDefaultModel(for: Agent.architectId, model: "check-model")
            manager.updateClaudeCodeConfig(claude, for: Agent.architectId)
            manager.updateRuntime(runtime, for: Agent.architectId)
            ArchitectConfigurationStore.resetCacheForTests()
            let saved = ArchitectConfigurationStore.load()
            require(saved.model == "check-model", "architectModelPersisted")
            require(saved.runtime == runtime && manager.effectiveRuntime(for: Agent.architectId) == runtime, "architectRuntimePersisted")
            require(saved.claudeCode == claude && manager.effectiveClaudeCodeConfig(for: Agent.architectId) == claude, "architectClaudeModelPersisted")
            require(saved.displayName == "Blueprint" && saved.systemPrompt == "Keep instructions", "architectOtherSettingsPreserved")
            manager.updateRuntime(.builtIn, for: Agent.architectId)
            ArchitectConfigurationStore.resetCacheForTests()
            require(ArchitectConfigurationStore.load().runtime == nil && manager.effectiveRuntime(for: Agent.architectId) == .builtIn, "architectReturnsToBuiltIn")
            print("MODEL_CONNECTION_CHECKS_PASSED: " + checks.joined(separator: ", "))
            exit(0)
        } catch {
            print("MODEL_CONNECTION_CHECK_FAILED: " + String(describing: error))
            exit(1)
        }
    }
}
#endif
