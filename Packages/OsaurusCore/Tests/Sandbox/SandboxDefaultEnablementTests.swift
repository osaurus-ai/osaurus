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

            registry.unregisterAllSandboxTools()
            SandboxManager.State.shared.status = originalStatus
            SandboxConfigurationStore.save(originalSandboxConfig)
            manager.setActiveAgent(originalActiveAgentId)
            _ = await manager.delete(id: agent.id)
        }
    }
}
