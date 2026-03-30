//
//  BonjourAdvertiser.swift
//  osaurus
//
//  Advertises Osaurus agents as Bonjour (mDNS/DNS-SD) services on the local network,
//  enabling other devices and apps to discover them without manual configuration.
//

import Combine
import Foundation

/// Manages Bonjour advertisement of Osaurus agents.
/// Each agent is published as a `_osaurus._tcp` service carrying the agent's
/// id, description, and crypto address in its TXT record.
@MainActor
public final class BonjourAdvertiser: NSObject {
    public static let shared = BonjourAdvertiser()

    /// Bonjour service type for Osaurus agents.
    public static let serviceType = "_osaurus._tcp."

    private var services: [UUID: NetService] = [:]
    private var currentPort: Int = 0
    private var isAdvertising = false
    private var cancellables: Set<AnyCancellable> = []

    private override init() {
        super.init()
        // Keep advertisements in sync whenever the agent list changes.
        AgentManager.shared.$agents
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                self?.syncAdvertisements(agents: agents)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Publish all current agents as Bonjour services on the given port.
    func startAdvertising(port: Int) {
        currentPort = port
        isAdvertising = true
        syncAdvertisements(agents: AgentManager.shared.agents)
    }

    /// Unpublish all active Bonjour services.
    func stopAdvertising() {
        isAdvertising = false
        for service in services.values { service.stop() }
        services.removeAll()
    }

    // MARK: - Private

    private func syncAdvertisements(agents: [Agent]) {
        guard isAdvertising else { return }

        let bonjourEnabledIds = Set(agents.filter(\.bonjourEnabled).map(\.id))

        // Remove services for agents that no longer exist or have Bonjour disabled.
        for id in services.keys where !bonjourEnabledIds.contains(id) {
            services[id]?.stop()
            services.removeValue(forKey: id)
        }

        // Publish or re-publish services for current agents.
        for agent in agents where agent.bonjourEnabled {
            let existing = services[agent.id]
            let expectedName = "\(agent.name)@\(agent.id.uuidString)"
            // Re-publish when there is no service yet or the display name changed.
            if existing == nil || existing?.name != expectedName {
                existing?.stop()
                publish(agent: agent)
            }
        }
    }

    private func publish(agent: Agent) {
        let name = "\(agent.name)@\(agent.id.uuidString)"
        let service = NetService(
            domain: "",  // empty = local. domain
            type: Self.serviceType,
            name: name,
            port: Int32(currentPort)
        )
        service.setTXTRecord(txtRecord(for: agent))
        service.delegate = self
        service.publish()
        services[agent.id] = service
    }

    private func txtRecord(for agent: Agent) -> Data {
        var fields: [String: Data] = [:]
        fields["name"] = agent.name.data(using: .utf8)
        fields["id"] = agent.id.uuidString.data(using: .utf8)
        if !agent.description.isEmpty {
            fields["description"] = agent.description.data(using: .utf8)
        }
        if let address = agent.agentAddress {
            fields["address"] = address.data(using: .utf8)
        }
        return NetService.data(fromTXTRecord: fields)
    }
}

// MARK: - NetServiceDelegate

extension BonjourAdvertiser: NetServiceDelegate {
    public nonisolated func netServiceDidPublish(_ sender: NetService) {
        print("[Bonjour] Advertised agent '\(sender.name)' on port \(sender.port)")
    }

    public nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("[Bonjour] Failed to advertise agent '\(sender.name)': \(errorDict)")
    }
}
