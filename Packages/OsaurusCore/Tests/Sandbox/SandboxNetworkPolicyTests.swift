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
    }

#endif
