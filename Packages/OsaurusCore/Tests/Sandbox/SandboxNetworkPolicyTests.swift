//
//  SandboxNetworkPolicyTests.swift
//  osaurusTests
//
//  Pins the combined-mode sandbox egress policy: outbound network is the
//  network leg of the agent-as-bridge exfiltration path, so it must be a
//  user-controlled, boot-time decision that defaults ON (current
//  behavior) and is honored when turned OFF. The control surface is the
//  per-agent `AutonomousExecConfig.sandboxNetworkEnabled`, mirrored onto
//  the shared `SandboxConfiguration.network` and resolved at boot by
//  `SandboxManager.networkEnabled(from:)`.
//

#if os(macOS)

    import Foundation
    import Testing

    @testable import OsaurusCore

    @Suite
    struct SandboxNetworkPolicyTests {

        // MARK: - Boot-time resolver

        @Test func defaultConfigKeepsEgressOn() {
            #expect(SandboxManager.networkEnabled(from: .default))
        }

        @Test func outboundKeepsEgressOn() {
            let config = SandboxConfiguration(network: "outbound")
            #expect(SandboxManager.networkEnabled(from: config))
        }

        @Test func noneCutsEgress() {
            let config = SandboxConfiguration(network: "none")
            #expect(!SandboxManager.networkEnabled(from: config))
        }

        // MARK: - Per-agent config defaults + back-compat

        @Test func autonomousConfigDefaultsToNetworkOnSecretsOff() {
            let config = AutonomousExecConfig.default
            #expect(config.sandboxNetworkEnabled == true)
            #expect(config.allowHostSecretReads == false)
        }

        @Test func legacyConfigDecodesToSafeDefaults() throws {
            // An agent persisted before these fields existed must keep
            // loading: egress on, secrets refused.
            let legacy = """
                {"enabled":true,"maxCommandsPerTurn":10,"commandTimeout":30,"pluginCreate":true}
                """
            let decoded = try JSONDecoder().decode(
                AutonomousExecConfig.self,
                from: Data(legacy.utf8)
            )
            #expect(decoded.enabled == true)
            #expect(decoded.sandboxNetworkEnabled == true)
            #expect(decoded.allowHostSecretReads == false)
        }

        @Test func newFieldsRoundTripThroughCodable() throws {
            let original = AutonomousExecConfig(
                enabled: true,
                allowHostSecretReads: true,
                sandboxNetworkEnabled: false
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(AutonomousExecConfig.self, from: data)
            #expect(decoded.allowHostSecretReads == true)
            #expect(decoded.sandboxNetworkEnabled == false)
        }

        // MARK: - Boot-time reconcile (self-heal desynced installs)

        @Test func agentNetworkOnMapsToOutbound() {
            #expect(SandboxManager.reconciledNetwork(agentNetworkEnabled: true) == "outbound")
        }

        @Test func agentNetworkOffMapsToNone() {
            #expect(SandboxManager.reconciledNetwork(agentNetworkEnabled: false) == "none")
        }

        /// The regression that motivated the reconcile: the per-agent toggle
        /// says egress-on, but `sandbox.json` was left at "none" (early-build
        /// provisioning, the container-level toggle, or another agent's flip).
        /// Reconciling the active agent's preference at boot must override the
        /// stale value so the VM comes up with network.
        @Test func agentNetworkOnHealsStaleNoneConfig() {
            var stale = SandboxConfiguration(network: "none")
            #expect(!SandboxManager.networkEnabled(from: stale))  // pre-heal: egress cut

            stale.network = SandboxManager.reconciledNetwork(agentNetworkEnabled: true)
            #expect(SandboxManager.networkEnabled(from: stale))  // post-heal: egress on
        }

        /// Symmetric guarantee: a user who turned the agent toggle OFF still
        /// gets egress cut even if `sandbox.json` is stale at "outbound".
        @Test func agentNetworkOffHealsStaleOutboundConfig() {
            var stale = SandboxConfiguration(network: "outbound")
            #expect(SandboxManager.networkEnabled(from: stale))

            stale.network = SandboxManager.reconciledNetwork(agentNetworkEnabled: false)
            #expect(!SandboxManager.networkEnabled(from: stale))
        }
    }

#endif
