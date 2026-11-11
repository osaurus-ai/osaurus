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

@Suite(.serialized)
@MainActor
struct ConfigApplyRelayExposureTests {
    private func addRemoteAgent(_ label: String) -> Agent {
        let agent = Agent(
            name: "\(label) \(UUID().uuidString.prefix(6))",
            agentAddress: "0x\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())00000000"
        )
        AgentManager.shared.add(agent)
        return agent
    }

    @Test func applyWithRelayDisabledLeavesEveryAgentOff() async throws {
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
        let pairing = MobilePairingService(defaults: defaults)

        let named = addRemoteAgent("Relay Apply Named")
        let unnamed = addRemoteAgent("Relay Apply Unnamed")

        var caps = AgentCapabilitiesEntry()
        caps.relayEnabled = false
        var entry = AgentEntry(name: named.name)
        entry.capabilities = caps
        var document = OsaurusConfigDocument()
        document.agents = [entry]
        let results = await ConfigApplier.apply(document: document, prune: false)
        #expect(results.allSatisfy { $0.status != .failed }, "\(results)")

        for _ in 0 ..< 5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))

        let stored = RelayConfigurationStore.load()
        for agent in [named, unnamed] {
            #expect(!RelayTunnelManager.shared.isTunnelEnabled(for: agent.id), "\(agent.name)")
            #expect(!stored.isEnabled(for: agent.id), "\(agent.name)")
        }

        withExtendedLifetime(pairing) {}
        for agent in [named, unnamed] {
            if RelayTunnelManager.shared.isTunnelEnabled(for: agent.id) {
                RelayTunnelManager.shared.setTunnelEnabled(false, for: agent.id)
            }
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }
}
