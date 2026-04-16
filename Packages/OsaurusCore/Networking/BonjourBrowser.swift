//
//  BonjourBrowser.swift
//  osaurus
//
//  Discovers remote Osaurus agents advertised as Bonjour services on the local
//  network, enabling the agent selector to list peers from other devices.
//

import Foundation

// MARK: - PairedRelayAgent

/// A remote Osaurus agent that is persistently paired and reachable via the relay tunnel,
/// but is not currently discoverable on the local network via Bonjour.
public struct PairedRelayAgent: Identifiable, Equatable, Sendable {
    /// The UUID of the agent on the remote Osaurus server.
    public let id: UUID
    /// Display name of the remote agent.
    public let name: String
    /// The crypto address (e.g. "0x...") used to construct the relay tunnel URL.
    public let remoteAgentAddress: String
    /// The local provider ID used to connect to this agent.
    public let providerId: UUID
}

// MARK: - DiscoveredAgent

/// A remote Osaurus agent discovered via Bonjour on the local network.
public struct DiscoveredAgent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let agentDescription: String
    public let address: String?
    public let host: String?
    public let port: Int

    /// Internal key that matches the NetService name for lookup/removal.
    internal let serviceName: String
}

// MARK: - BonjourBrowser

/// Browses the local network for `_osaurus._tcp.` services and surfaces them
/// as `DiscoveredAgent` values.  Agents that belong to this device are
/// automatically filtered out by comparing UUIDs against `AgentManager`.
@MainActor
public final class BonjourBrowser: NSObject, ObservableObject {
    public static let shared = BonjourBrowser()

    @Published public private(set) var discoveredAgents: [DiscoveredAgent] = []

    private var browser: NetServiceBrowser?
    /// Services currently being resolved, keyed by NetService name.
    private var resolvingServices: [String: NetService] = [:]

    private override init() {
        super.init()
        startBrowsing()
    }

    // MARK: - Private

    private func startBrowsing() {
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: BonjourAdvertiser.serviceType, inDomain: "")
        browser = b
    }

    private func handleResolved(service: NetService) {
        defer { resolvingServices.removeValue(forKey: service.name) }

        guard let txtData = service.txtRecordData() else { return }
        let fields = NetService.dictionary(fromTXTRecord: txtData)

        guard
            let idData = fields["id"],
            let idString = String(data: idData, encoding: .utf8),
            let agentId = UUID(uuidString: idString)
        else { return }

        // Skip agents that belong to this device.
        let localIds = Set(AgentManager.shared.agents.map(\.id))
        guard !localIds.contains(agentId) else { return }

        guard
            let name = fields["name"].flatMap({ String(data: $0, encoding: .utf8) })
        else { return }

        let desc = fields["description"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let addr = fields["address"].flatMap { String(data: $0, encoding: .utf8) }

        let agent = DiscoveredAgent(
            id: agentId,
            name: name,
            agentDescription: desc,
            address: addr,
            host: service.hostName,
            port: Int(service.port),
            serviceName: service.name
        )

        if let idx = discoveredAgents.firstIndex(where: { $0.serviceName == service.name }) {
            discoveredAgents[idx] = agent
        } else {
            discoveredAgents.append(agent)
        }
    }
}

// MARK: - NetServiceBrowserDelegate

// @preconcurrency tells Swift that these ObjC protocols predate Swift concurrency.
// The callbacks are guaranteed to arrive on the main run loop (the browser is
// started from @MainActor init()), so the @MainActor isolation on the methods
// below is correct and no actor-boundary crossing occurs.

extension BonjourBrowser: @preconcurrency NetServiceBrowserDelegate {
    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        service.delegate = self
        resolvingServices[service.name] = service
        service.resolve(withTimeout: 5.0)
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        resolvingServices.removeValue(forKey: service.name)
        discoveredAgents.removeAll { $0.serviceName == service.name }
    }
}

// MARK: - NetServiceDelegate

extension BonjourBrowser: @preconcurrency NetServiceDelegate {
    public func netServiceDidResolveAddress(_ sender: NetService) {
        handleResolved(service: sender)
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolvingServices.removeValue(forKey: sender.name)
        print("[Bonjour] Failed to resolve '\(sender.name)': \(errorDict)")
    }
}
