//
//  SandboxNetworkPolicyTests.swift
//  osaurusTests
//
//  Pins the combined-mode sandbox egress policy: outbound network is the
//  network leg of the agent-as-bridge exfiltration path, so it must be a
//  user-controlled, boot-time decision that defaults ON (current
//  behavior) and is honored when turned OFF. The control surface is the
//  per-agent `AutonomousExecConfig.sandboxNetworkEnabled`; each boot
//  composes the VM's network from the pod members' own policies.
//

#if os(macOS)

    import Foundation
    import Testing

    @testable import OsaurusCore

    @Suite
    struct SandboxNetworkPolicyTests {

        // MARK: - Pod network composition

        @Test func everyMemberOpenKeepsNAT() {
            #expect(SandboxEgressPolicy.podNetwork(for: [.open, .open]) == .nat)
            // Setup and diagnostics only: nothing to restrict.
            #expect(SandboxEgressPolicy.podNetwork(for: []) == .nat)
        }

        @Test func everyMemberOffCutsTheNetwork() {
            #expect(SandboxEgressPolicy.podNetwork(for: [.none, .none]) == .none)
        }

        /// The bug this replaces: the VM took the booting agent's policy, so
        /// an open agent's boot gave an agent with network off full egress.
        @Test func mixedMembersFilterPerAgent() {
            #expect(SandboxEgressPolicy.podNetwork(for: [.open, .none]) == .filtered)
            #expect(SandboxEgressPolicy.podNetwork(for: [.open, .allowlist(["a.com"])]) == .filtered)
            #expect(SandboxEgressPolicy.podNetwork(for: [.allowlist(["a.com"])]) == .filtered)
            #expect(SandboxEgressPolicy.podNetwork(for: [.none, .allowlist(["a.com"])]) == .filtered)
        }

        @Test @MainActor func agentlessMembersAreOpen() {
            #expect(SandboxManager.egressMode(forMember: "diag") == .open)
            #expect(SandboxManager.egressMode(forMember: "wf-template") == .open)
        }

        // MARK: - Per-agent config defaults + back-compat

        @Test func autonomousConfigDefaultsToNetworkOn() {
            let config = AutonomousExecConfig.default
            #expect(config.sandboxNetworkEnabled == true)
        }

        @Test func legacyConfigDecodesToSafeDefaults() throws {
            // An agent persisted before these fields existed must keep
            // loading: egress on. The removed combined-mode grants
            // (`allowHostSecretReads` / `allowHostFolderWrites`) may still
            // sit in older JSON and are ignored.
            let legacy = """
                {"enabled":true,"maxCommandsPerTurn":10,"commandTimeout":30,"pluginCreate":true,"allowHostSecretReads":true,"allowHostFolderWrites":true}
                """
            let decoded = try JSONDecoder().decode(
                AutonomousExecConfig.self,
                from: Data(legacy.utf8)
            )
            #expect(decoded.enabled == true)
            #expect(decoded.sandboxNetworkEnabled == true)
        }

        @Test func newFieldsRoundTripThroughCodable() throws {
            let original = AutonomousExecConfig(
                enabled: true,
                sandboxNetworkEnabled: false
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(AutonomousExecConfig.self, from: data)
            #expect(decoded.sandboxNetworkEnabled == false)
        }
    }

#endif
