//
//  BonjourAdvertiser.swift
//  osaurus
//
//  Advertises Osaurus agents as Bonjour (mDNS/DNS-SD) services on the local network,
//  enabling other devices and apps to discover them without manual configuration.
//

import Combine
import Foundation
import os

/// Manages Bonjour advertisement of Osaurus agents.
/// Each agent is published as a `_osaurus._tcp` service carrying the agent's
/// id, description, and crypto address in its TXT record.
@MainActor
public final class BonjourAdvertiser: NSObject {
    public static let shared = BonjourAdvertiser()

    /// Bonjour service type for Osaurus agents.
    public static let serviceType = "_osaurus._tcp."

    /// DNS-SD instance names are limited to 63 bytes. The UUID suffix
    /// (`@<uuid>` = 37 bytes) must stay intact for identity, so the display
    /// name gets whatever budget remains. The full name and id always travel
    /// in the TXT record, so truncation is cosmetic.
    static let maxInstanceNameBytes = 63
    /// Cap the TXT `description` value. Individual TXT key=value strings max
    /// out at 255 bytes; keep well under so the record stays small on the wire.
    static let maxTXTDescriptionBytes = 200

    private var services: [UUID: NetService] = [:]
    /// The instance name we asked mDNS to publish per agent. mDNS may rename
    /// the live service on conflict ("Name (2)"); comparing against what we
    /// REQUESTED (instead of `service.name`) prevents an endless
    /// stop/republish loop after an auto-rename.
    private var requestedNames: [UUID: String] = [:]
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
        requestedNames.removeAll()
    }

    // MARK: - Private

    private func syncAdvertisements(agents: [Agent]) {
        guard isAdvertising else { return }

        let bonjourEnabledIds = Set(agents.filter(\.bonjourEnabled).map(\.id))

        // Remove services for agents that no longer exist or have Bonjour disabled.
        for id in services.keys where !bonjourEnabledIds.contains(id) {
            services[id]?.stop()
            services.removeValue(forKey: id)
            requestedNames.removeValue(forKey: id)
        }

        // Publish or re-publish services for current agents. Compare against
        // the name we last REQUESTED, not the live `service.name`: mDNS may
        // auto-rename on conflict, and reacting to that would stop/republish
        // the service forever.
        for agent in agents where agent.bonjourEnabled {
            let expectedName = Self.instanceName(for: agent)
            if services[agent.id] == nil || requestedNames[agent.id] != expectedName {
                services[agent.id]?.stop()
                publish(agent: agent, name: expectedName)
            }
        }
    }

    /// Build a DNS-SD instance name that fits the 63-byte limit while keeping
    /// the full UUID (needed by the browser to identify the agent). The
    /// display name is truncated on a character boundary to whatever budget
    /// the UUID suffix leaves.
    static func instanceName(for agent: Agent) -> String {
        let suffix = "@\(agent.id.uuidString)"
        let budget = maxInstanceNameBytes - suffix.utf8.count
        return truncateUTF8(agent.name, maxBytes: max(0, budget)) + suffix
    }

    /// Truncate a string to at most `maxBytes` of UTF-8 without splitting a
    /// character.
    static func truncateUTF8(_ string: String, maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        var result = ""
        var used = 0
        for char in string {
            let size = String(char).utf8.count
            if used + size > maxBytes { break }
            result.append(char)
            used += size
        }
        return result
    }

    private func publish(agent: Agent, name: String) {
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
        requestedNames[agent.id] = name
    }

    private func txtRecord(for agent: Agent) -> Data {
        var fields: [String: Data] = [:]
        fields["name"] = agent.name.data(using: .utf8)
        fields["id"] = agent.id.uuidString.data(using: .utf8)
        if !agent.description.isEmpty {
            let capped = Self.truncateUTF8(agent.description, maxBytes: Self.maxTXTDescriptionBytes)
            fields["description"] = capped.data(using: .utf8)
        }
        if let address = agent.agentAddress {
            fields["address"] = address.data(using: .utf8)
        }
        // Secure Channel capability (diagnostic): this peer accepts
        // `/secure/session` handshakes and requires E2E encryption on agent
        // run/dispatch. Browsers use it to explain "peer needs upgrade"
        // instead of a bare handshake 404.
        fields["osc"] = "1".data(using: .utf8)
        return NetService.data(fromTXTRecord: fields)
    }
}

// MARK: - NetServiceDelegate

extension BonjourAdvertiser: NetServiceDelegate {
    private nonisolated static var delegateLogger: Logger {
        Logger(subsystem: "com.osaurus", category: "bonjour")
    }

    public nonisolated func netServiceDidPublish(_ sender: NetService) {
        Self.delegateLogger.info(
            "Advertised agent '\(sender.name, privacy: .public)' on port \(sender.port)"
        )
    }

    public nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Self.delegateLogger.error(
            "Failed to advertise agent '\(sender.name, privacy: .public)': \(errorDict, privacy: .public)"
        )
    }
}
