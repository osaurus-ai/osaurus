//
//  SandboxDefaultEnablementTests.swift
//  OsaurusCoreTests
//
//  Covers the "sandbox enabled by default" behavior:
//
//   * The built-in Default agent is configuration-only and resolves to
//     sandbox-OFF regardless of stored config or sandbox availability — it
//     never runs autonomous code execution.
//   * Newly created custom agents are seeded ON (where supported).
//   * Lazy provisioning: with the toggle on but the sandbox never set up,
//     `registerTools` drops the `sandbox_init_pending` placeholder into the
//     schema and does NOT kick a (cold-download) container start.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SandboxDefaultEnablementTests {

    // MARK: - Helpers

    /// Force `SandboxManager` availability for the duration of `body`, then
    /// restore it. The published value is the seam the production code reads
    /// to gate the default-on behavior.
    private func withAvailability<T>(
        _ availability: SandboxAvailability,
        _ body: () throws -> T
    ) rethrows -> T {
        let previous = SandboxManager.State.shared.availability
        SandboxManager.State.shared.availability = availability
        defer { SandboxManager.State.shared.availability = previous }
        return try body()
    }

    /// Point the Default-agent config store at a throwaway directory seeded
    /// with the given `autonomousExec`, so `effectiveAutonomousExec` reads a
    /// known stored value (or `nil`) without touching the user's real config.
    private func withDefaultAgentConfig<T>(
        autonomousExec: AutonomousExecConfig?,
        _ body: () throws -> T
    ) rethrows -> T {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-sandbox-default-enable-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let previous = DefaultAgentConfigurationStore.overrideDirectory
        DefaultAgentConfigurationStore.overrideDirectory = tmp
        DefaultAgentConfigurationStore.resetCacheForTests()
        if let autonomousExec {
            var cfg = DefaultAgentConfiguration.default
            cfg.autonomousExec = autonomousExec
            DefaultAgentConfigurationStore.save(cfg)
        }
        defer {
            DefaultAgentConfigurationStore.overrideDirectory = previous
            DefaultAgentConfigurationStore.resetCacheForTests()
            try? FileManager.default.removeItem(at: tmp)
        }
        return try body()
    }

    // MARK: - Default agent

    @Test
    func effectiveAutonomousExec_defaultAgent_offConfigOnlyEvenWhenAvailable() async {
        await SandboxTestLock.runWithStoragePaths {
            self.withDefaultAgentConfig(autonomousExec: nil) {
                self.withAvailability(.available) {
                    // The Default agent is configuration-only: it never runs
                    // autonomous exec, so the sandbox is off even on a
                    // supported machine with no stored override.
                    let config = AgentManager.shared.effectiveAutonomousExec(for: Agent.defaultId)
                    #expect(config == nil)
                }
            }
        }
    }

    @Test
    func effectiveAutonomousExec_defaultAgent_offWhenSandboxUnavailable() async {
        await SandboxTestLock.runWithStoragePaths {
            self.withDefaultAgentConfig(autonomousExec: nil) {
                self.withAvailability(.unavailable(reason: "test")) {
                    let config = AgentManager.shared.effectiveAutonomousExec(for: Agent.defaultId)
                    // Off regardless: config-only short-circuits before the
                    // availability check, and the VM can't run here anyway.
                    #expect(config == nil)
                }
            }
        }
    }

    @Test
    func effectiveAutonomousExec_defaultAgent_ignoresStoredEnabled() async {
        await SandboxTestLock.runWithStoragePaths {
            // Even a stored enabled:true is ignored for the configuration-only
            // Default agent — it always resolves to off (no sandbox chip is
            // shown for it, so there's no way to opt back in either).
            self.withDefaultAgentConfig(autonomousExec: AutonomousExecConfig(enabled: true)) {
                self.withAvailability(.available) {
                    let config = AgentManager.shared.effectiveAutonomousExec(for: Agent.defaultId)
                    #expect(config == nil)
                }
            }
        }
    }

    // MARK: - Seed for new agents

    @Test
    func sandboxDefaultAutonomousExec_mirrorsAvailability() async {
        await SandboxTestLock.runWithStoragePaths {
            self.withAvailability(.available) {
                #expect(AgentManager.sandboxDefaultAutonomousExec?.enabled == true)
            }
            self.withAvailability(.unavailable(reason: "test")) {
                #expect(AgentManager.sandboxDefaultAutonomousExec == nil)
            }
        }
    }

    @Test
    func create_seedsSandboxOnWhenAvailable_offWhenUnavailable() async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared

            let onAgent = self.withAvailability(.available) {
                manager.create(name: "Seed On \(UUID().uuidString)")
            }
            #expect(onAgent.autonomousExec?.enabled == true)
            _ = await manager.delete(id: onAgent.id)

            let offAgent = self.withAvailability(.unavailable(reason: "test")) {
                manager.create(name: "Seed Off \(UUID().uuidString)")
            }
            #expect(offAgent.autonomousExec == nil)
            _ = await manager.delete(id: offAgent.id)
        }
    }

    @Test
    func sharedCustomAgentSeed_keepsOnboardingDefaultOn() {
        withAvailability(.available) {
            let onboardingRecord = AgentManager.newCustomAgentRecord(
                name: "Onboarding",
                description: "Template",
                systemPrompt: "Help."
            )
            #expect(onboardingRecord.autonomousExec?.enabled == true)
            #expect(!onboardingRecord.isBuiltIn)
        }
    }

    @Test
    func legacyUnconfiguredCustomAgent_tracksBackendAvailability() {
        let legacy = Agent(name: "Legacy", autonomousExec: nil)

        let supported = AgentManager.resolvedAutonomousExec(
            for: legacy,
            availability: .available
        )
        let unsupported = AgentManager.resolvedAutonomousExec(
            for: legacy,
            availability: .unavailable(reason: "test")
        )

        #expect(supported?.enabled == true)
        #expect(unsupported == nil)
        #expect(legacy.autonomousExec == nil)
    }

    @Test
    func explicitOptOut_survivesReloadAndBackendTransitions() throws {
        let optedOut = Agent(
            name: "Opted Out",
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
        let reloaded = try JSONDecoder().decode(
            Agent.self,
            from: JSONEncoder().encode(optedOut)
        )

        #expect(reloaded.autonomousExec?.enabled == false)
        #expect(
            AgentManager.resolvedAutonomousExec(
                for: reloaded,
                availability: .available
            )?.enabled == false
        )
        #expect(
            AgentManager.resolvedAutonomousExec(
                for: reloaded,
                availability: .unavailable(reason: "test")
            )?.enabled == false
        )
    }

    @Test
    func duplicate_preservesExplicitOptOutAndUnconfiguredState() {
        let optedOut = Agent(
            name: "Opted Out",
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
        let optedOutCopy = AgentManager.duplicateRecord(
            from: optedOut,
            name: "Opted Out Copy"
        )
        #expect(optedOutCopy.id != optedOut.id)
        #expect(optedOutCopy.autonomousExec?.enabled == false)

        let unconfigured = Agent(name: "Legacy", autonomousExec: nil)
        let unconfiguredCopy = AgentManager.duplicateRecord(
            from: unconfigured,
            name: "Legacy Copy"
        )
        #expect(unconfiguredCopy.autonomousExec == nil)
        #expect(
            AgentManager.resolvedAutonomousExec(
                for: unconfiguredCopy,
                availability: .available
            )?.enabled == true
        )
    }

    @Test
    func defaultAgent_staysHardOffInPurePolicySeam() {
        var configuredDefault = Agent.default
        configuredDefault.autonomousExec = AutonomousExecConfig(enabled: true)

        #expect(
            AgentManager.resolvedAutonomousExec(
                for: configuredDefault,
                availability: .available
            ) == nil
        )
    }

    // MARK: - Lazy provisioning gate

    @Test
    func registerTools_defaultOnButNeverSetUp_registersPlaceholderWithoutStarting() async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let registry = ToolRegistry.shared
            let originalActiveAgentId = manager.activeAgentId
            let originalStatus = SandboxManager.State.shared.status
            let originalSandboxConfig = SandboxConfigurationStore.load()

            // A sandbox that the user never set up: setupComplete == false and
            // the container is not provisioned.
            var freshConfig = SandboxConfiguration.default
            freshConfig.setupComplete = false
            SandboxConfigurationStore.save(freshConfig)
            SandboxManager.State.shared.status = .notProvisioned

            let agent = Agent(
                name: "Lazy Sandbox \(UUID().uuidString)",
                agentAddress: "test-lazy-sandbox-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            manager.add(agent)
            manager.setActiveAgent(agent.id)

            registry.unregisterAllBuiltinSandboxTools()
            await SandboxToolRegistrar.shared.registerTools(for: agent.id)

            let names = registry.builtInSandboxToolNamesSnapshot
            // Lazy: the placeholder is offered so the model has something to
            // call (which triggers the on-demand boot), but the real exec
            // tools are NOT registered and no cold container start happened.
            #expect(names.contains(BuiltinSandboxTools.initPendingToolName))
            #expect(names.contains("sandbox_exec") == false)
            #expect(SandboxManager.State.shared.status == .notProvisioned)

            let firstUse = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .none,
                model: "gpt-5"
            )
            let firstUseSnapshot = AgentConfigSnapshot.capture(
                agentId: agent.id,
                modelOverride: "gpt-5"
            )
            let firstUseNames = Set(firstUse.tools.map(\.function.name))
            #expect(firstUseSnapshot.autonomousEnabled)
            #expect(firstUseSnapshot.canCreatePlugins)
            #expect(firstUseNames.contains(BuiltinSandboxTools.initPendingToolName))
            #expect(
                !firstUse.alwaysLoadedNames.contains(
                    BuiltinSandboxTools.initPendingToolName
                )
            )
            #expect(firstUse.manifest.sections.map(\.id).contains("pluginCreator"))

            let globallyDisabled = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .none,
                model: "gpt-5",
                toolsDisabled: true
            )
            #expect(
                !globallyDisabled.tools.contains {
                    $0.function.name == BuiltinSandboxTools.initPendingToolName
                }
            )

            // Simulate the successful end of the awaited handshake. Real
            // sandbox/control schemas must join immediately despite the
            // session's frozen first-use baseline, while the placeholder
            // disappears and remains absent from the frozen snapshot.
            registry.unregisterAllBuiltinSandboxTools()
            BuiltinSandboxTools.register(
                agentId: agent.id.uuidString,
                agentName: SandboxAgentProvisioner.linuxName(for: agent.id.uuidString),
                config: AutonomousExecConfig(enabled: true, pluginCreate: true)
            )
            let afterProvisioning = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .sandbox,
                model: "gpt-5",
                frozenAlwaysLoadedNames: firstUse.alwaysLoadedNames,
                frozenToolSpecs: firstUse.initialToolSpecs
            )
            let afterNames = Set(afterProvisioning.tools.map(\.function.name))
            #expect(!afterNames.contains(BuiltinSandboxTools.initPendingToolName))
            #expect(afterNames.isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
            #expect(afterNames.contains("sandbox_plugin_register"))

            registry.unregisterAllSandboxTools()
            SandboxManager.State.shared.status = originalStatus
            SandboxConfigurationStore.save(originalSandboxConfig)
            manager.setActiveAgent(originalActiveAgentId)
            _ = await manager.delete(id: agent.id)
        }
    }

    @Test
    func provisionOnDemand_coalescesAndAwaitsRealToolRegistration() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let registrar = SandboxToolRegistrar.shared
            let registry = ToolRegistry.shared
            let originalStatus = SandboxManager.State.shared.status
            let originalProvisionOverride = registrar.provisionAgentOverride

            let agent = Agent(
                name: "Awaited Sandbox \(UUID().uuidString)",
                agentAddress: "test-awaited-sandbox-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            manager.add(agent)
            SandboxManager.State.shared.status = .running

            final class Counter: @unchecked Sendable {
                var calls = 0
            }
            let counter = Counter()
            registrar.provisionAgentOverride = { @MainActor _ in
                counter.calls += 1
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            registry.unregisterAllBuiltinSandboxTools()

            async let first: Void = registrar.provisionOnDemand(for: agent.id)
            async let second: Void = registrar.provisionOnDemand(for: agent.id)
            try await first
            try await second

            #expect(counter.calls == 1)
            #expect(
                registry.builtInSandboxToolNamesSnapshot.contains("sandbox_exec")
            )
            #expect(
                !registry.builtInSandboxToolNamesSnapshot.contains(
                    BuiltinSandboxTools.initPendingToolName
                )
            )

            registry.unregisterAllSandboxTools()
            registrar.provisionAgentOverride = originalProvisionOverride
            SandboxManager.State.shared.status = originalStatus
            _ = await manager.delete(id: agent.id)
        }
    }

    @Test
    func provisionOnDemand_failureClearsTaskAndAllowsRetry() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            struct ExpectedFailure: Error {}

            let manager = AgentManager.shared
            let registrar = SandboxToolRegistrar.shared
            let registry = ToolRegistry.shared
            let originalStatus = SandboxManager.State.shared.status
            let originalProvisionOverride = registrar.provisionAgentOverride

            let agent = Agent(
                name: "Retry Sandbox \(UUID().uuidString)",
                agentAddress: "test-retry-sandbox-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            manager.add(agent)
            SandboxManager.State.shared.status = .running

            final class Counter: @unchecked Sendable {
                var calls = 0
            }
            let counter = Counter()
            registrar.provisionAgentOverride = { @MainActor _ in
                counter.calls += 1
                if counter.calls == 1 { throw ExpectedFailure() }
            }
            registry.unregisterAllBuiltinSandboxTools()

            var firstFailed = false
            do {
                try await registrar.provisionOnDemand(for: agent.id)
            } catch {
                firstFailed = true
            }
            #expect(firstFailed)

            try await registrar.provisionOnDemand(for: agent.id)
            #expect(counter.calls == 2)
            #expect(registry.builtInSandboxToolNamesSnapshot.contains("sandbox_exec"))

            registry.unregisterAllSandboxTools()
            registrar.provisionAgentOverride = originalProvisionOverride
            SandboxManager.State.shared.status = originalStatus
            _ = await manager.delete(id: agent.id)
        }
    }

    @Test
    func provisionOnDemand_cancellationClearsTaskAndAllowsRetry() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let registrar = SandboxToolRegistrar.shared
            let registry = ToolRegistry.shared
            let originalStatus = SandboxManager.State.shared.status
            let originalProvisionOverride = registrar.provisionAgentOverride

            let agent = Agent(
                name: "Cancel Sandbox \(UUID().uuidString)",
                agentAddress: "test-cancel-sandbox-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            manager.add(agent)
            SandboxManager.State.shared.status = .running

            registrar.provisionAgentOverride = { @MainActor _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            registry.unregisterAllBuiltinSandboxTools()

            let cancelled = Task {
                try await registrar.provisionOnDemand(for: agent.id)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            cancelled.cancel()

            var observedCancellation = false
            do {
                try await cancelled.value
            } catch is CancellationError {
                observedCancellation = true
            } catch {
                observedCancellation = error is SandboxToolRegistrar.OnDemandProvisionError
            }
            #expect(observedCancellation)

            registrar.provisionAgentOverride = { @MainActor _ in }
            try await registrar.provisionOnDemand(for: agent.id)
            #expect(registry.builtInSandboxToolNamesSnapshot.contains("sandbox_exec"))

            registry.unregisterAllSandboxTools()
            registrar.provisionAgentOverride = originalProvisionOverride
            SandboxManager.State.shared.status = originalStatus
            _ = await manager.delete(id: agent.id)
        }
    }

    // MARK: - Idempotent fast path

    /// `registerTools` is called on every warm-up and every send
    /// (`prepareChatExecutionMode`). The slow path unregisters the builtin
    /// sandbox tools FIRST and only re-registers them after async container
    /// work, so any compose landing in that window resolves a schema without
    /// the sandbox tools — flapping the composed shape and thrashing the
    /// warm-up KV fingerprint. Pin the fast path: a repeat call with the
    /// same agent/config and a running container must neither re-provision
    /// nor transition the registry through the empty state.
    @Test
    func registerTools_repeatCallSameAgentAndConfig_skipsReprovision() async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let registrar = SandboxToolRegistrar.shared
            let registry = ToolRegistry.shared
            let originalStatus = SandboxManager.State.shared.status
            let originalProvisionOverride = registrar.provisionAgentOverride

            let agent = Agent(
                name: "FastPath Sandbox \(UUID().uuidString)",
                agentAddress: "test-fastpath-sandbox-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            manager.add(agent)
            SandboxManager.State.shared.status = .running

            final class Counter: @unchecked Sendable {
                var provisionCalls = 0
            }
            let counter = Counter()
            registrar.provisionAgentOverride = { @MainActor _ in
                counter.provisionCalls += 1
            }

            registry.unregisterAllBuiltinSandboxTools()
            await registrar.registerTools(for: agent.id)
            #expect(registry.builtInSandboxToolNamesSnapshot.contains("sandbox_exec"))
            #expect(counter.provisionCalls == 1)

            // Repeat call: same agent, same config, container running —
            // must be a no-op (no re-provision, tools stay registered).
            await registrar.registerTools(for: agent.id)
            #expect(counter.provisionCalls == 1)
            #expect(registry.builtInSandboxToolNamesSnapshot.contains("sandbox_exec"))

            // Out-of-band teardown (eval runner) invalidates the fast path:
            // the next call must take the slow path and re-register.
            registry.unregisterAllBuiltinSandboxTools()
            await registrar.registerTools(for: agent.id)
            #expect(counter.provisionCalls == 2)
            #expect(registry.builtInSandboxToolNamesSnapshot.contains("sandbox_exec"))

            registry.unregisterAllSandboxTools()
            SandboxManager.State.shared.status = originalStatus
            registrar.provisionAgentOverride = originalProvisionOverride
            _ = await manager.delete(id: agent.id)
        }
    }
}
