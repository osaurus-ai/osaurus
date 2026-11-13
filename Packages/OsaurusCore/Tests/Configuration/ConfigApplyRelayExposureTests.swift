//
//  ConfigApplyRelayExposureTests.swift
//  OsaurusCoreTests
//
//  Issue #3386: `config apply` with an `agents:` section turned Remote
//  Access on for every custom agent, named or not, on a Mac with a legacy
//  phone pairing stored.
//

import Foundation
import Testing

@testable import OsaurusCore

extension PairedRelaySuites {
    @Suite(.serialized)
    @MainActor
    struct ConfigApplyRelayExposureTests {
        private func randomAddress() -> String {
            "0x\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())00000000"
        }

        private func addRemoteAgent(_ label: String) -> Agent {
            let agent = Agent(name: "\(label) \(UUID().uuidString.prefix(6))", agentAddress: randomAddress())
            AgentManager.shared.add(agent)
            return agent
        }

        private func pairedService() throws -> (MobilePairingService, UserDefaults) {
            let defaults = UserDefaults(suiteName: "ConfigApplyRelayExposureTests.\(UUID().uuidString)")!
            defaults.set(false, forKey: MobilePairingService.keepAwakeDefaultsKey)
            defaults.set(true, forKey: MobilePairingService.reachAnywhereDefaultsKey)
            let device = PairedMobileDevice(
                deviceId: "iphone",
                name: "iPhone",
                keyId: UUID(),
                pairedAt: Date(),
                keyExpiresAt: nil
            )
            defaults.set(try JSONEncoder().encode(device), forKey: "mobileConnectPairedDevice")
            return (MobilePairingService(defaults: defaults), defaults)
        }

        private func drainMainActor() async {
            for _ in 0 ..< 5 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(50))
        }

        private func relayDisabledEntry(_ name: String) -> AgentEntry {
            var caps = AgentCapabilitiesEntry()
            caps.relayEnabled = false
            var entry = AgentEntry(name: name)
            entry.capabilities = caps
            return entry
        }

        private func cleanUp(_ agents: [Agent]) async {
            for agent in agents {
                if RelayTunnelManager.shared.isTunnelEnabled(for: agent.id) {
                    RelayTunnelManager.shared.setTunnelEnabled(false, for: agent.id)
                }
                _ = await AgentManager.shared.delete(id: agent.id)
            }
        }

        @Test func applyWithRelayDisabledLeavesEveryAgentOff() async throws {
            let named = addRemoteAgent("Relay Apply Named")
            let unnamed = addRemoteAgent("Relay Apply Unnamed")
            let (pairing, _) = try pairedService()

            var document = OsaurusConfigDocument()
            document.agents = [relayDisabledEntry(named.name)]
            let results = await ConfigApplier.apply(document: document, prune: false)
            #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
            await drainMainActor()

            let stored = RelayConfigurationStore.load()
            for agent in [named, unnamed] {
                #expect(!RelayTunnelManager.shared.isTunnelEnabled(for: agent.id), "\(agent.name)")
                #expect(!stored.isEnabled(for: agent.id), "\(agent.name)")
            }

            withExtendedLifetime(pairing) {}
            await cleanUp([named, unnamed])
        }

        @Test func agentCreatedWithRelayDisabledStaysOffOnceAddressed() async throws {
            let (pairing, _) = try pairedService()
            let name = "Relay Apply Created \(UUID().uuidString.prefix(6))"

            var document = OsaurusConfigDocument()
            document.agents = [relayDisabledEntry(name)]
            let results = await ConfigApplier.apply(document: document, prune: false)
            #expect(results.allSatisfy { $0.status != .failed }, "\(results)")

            var created = try #require(AgentManager.shared.agents.first { $0.name == name })
            created.agentAddress = randomAddress()
            AgentManager.shared.update(created)
            await drainMainActor()

            #expect(!RelayTunnelManager.shared.isTunnelEnabled(for: created.id))
            #expect(!RelayConfigurationStore.load().isEnabled(for: created.id))
            #expect(RelayTunnelManager.shared.isTunnelKeptOff(for: created.id))

            withExtendedLifetime(pairing) {}
            await cleanUp([created])
        }
    }
}
