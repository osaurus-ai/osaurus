//
//  BonjourBrowser.swift
//  osaurus
//
//  Discovers remote Osaurus agents advertised as Bonjour services on the local
//  network, enabling the agent selector to list peers from other devices.
//

import Foundation
import os

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
    /// Whether the peer advertised Secure Channel support (`osc=1` in its
    /// TXT record). Peers without it predate end-to-end encryption and will
    /// reject nothing — but WE will refuse to send them agent traffic, so
    /// surface a "peer needs upgrade" message instead of a cryptic failure.
    public let supportsSecureChannel: Bool

    /// Internal key that matches the NetService name for lookup/removal.
    internal let serviceName: String
}

// MARK: - BonjourBrowser

/// Browses the local network for `_osaurus._tcp.` services and surfaces them
/// as `DiscoveredAgent` values.  Agents that belong to this device are
/// automatically filtered out by comparing UUIDs against `AgentManager`.
///
/// The actual `NetServiceBrowser`/`NetService` work runs on a dedicated
/// background run-loop thread (`BonjourBrowserCore`). `searchForServices` and
/// `resolve` make synchronous connections to mDNSResponder that can block for
/// seconds on a busy or cold launch; keeping them off the main run loop means
/// they never hang the UI. Resolved results are marshalled back here onto the
/// main actor to update the published list.
@MainActor
public final class BonjourBrowser: NSObject, ObservableObject {
    public static let shared = BonjourBrowser()

    @Published public private(set) var discoveredAgents: [DiscoveredAgent] = []

    private var core: BonjourBrowserCore?

    /// Grace period before a `didRemove` actually drops an agent from the
    /// published list. mDNS TTL flaps (sleep/wake, Wi-Fi roam, cache expiry
    /// races) routinely emit remove+find pairs seconds apart; tearing down an
    /// ephemeral provider — and the active chat using it — on the first remove
    /// is needlessly destructive.
    private static let removalGracePeriod: Duration = .seconds(12)
    private var pendingRemovals: [String: Task<Void, Never>] = [:]

    private override init() {
        super.init()
        let core = BonjourBrowserCore(
            serviceType: BonjourAdvertiser.serviceType,
            onResolved: { agent in
                Task { @MainActor [weak self] in self?.upsert(agent) }
            },
            onRemoved: { serviceName in
                Task { @MainActor [weak self] in self?.remove(serviceName: serviceName) }
            }
        )
        self.core = core
        core.start()
    }

    // MARK: - Private

    private func upsert(_ agent: DiscoveredAgent) {
        // A re-discovered service cancels any in-flight debounced removal.
        pendingRemovals[agent.serviceName]?.cancel()
        pendingRemovals[agent.serviceName] = nil

        // Skip agents that belong to this device.
        let localIds = Set(AgentManager.shared.agents.map(\.id))
        guard !localIds.contains(agent.id) else { return }

        if let idx = discoveredAgents.firstIndex(where: { $0.serviceName == agent.serviceName }) {
            discoveredAgents[idx] = agent
        } else {
            discoveredAgents.append(agent)
        }
    }

    private func remove(serviceName: String) {
        pendingRemovals[serviceName]?.cancel()
        pendingRemovals[serviceName] = Task { [weak self] in
            try? await Task.sleep(for: Self.removalGracePeriod)
            guard !Task.isCancelled, let self else { return }
            self.pendingRemovals[serviceName] = nil
            self.discoveredAgents.removeAll { $0.serviceName == serviceName }
        }
    }
}

// MARK: - BonjourBrowserCore

/// Owns the `NetServiceBrowser` and runs it, plus all `NetService` resolves, on
/// a private background thread with its own run loop. All mutable state is
/// touched only on that thread; resolved agents are delivered through the
/// `@Sendable` callbacks. The browser lives for the process lifetime, so the
/// thread and its run loop are never torn down.
private final class BonjourBrowserCore: NSObject, @unchecked Sendable {
    private let serviceType: String
    private let onResolved: @Sendable (DiscoveredAgent) -> Void
    private let onRemoved: @Sendable (String) -> Void

    private var browser: NetServiceBrowser?
    /// Retains services while they resolve (a dropped reference cancels the
    /// resolve), keyed by NetService name.
    private var resolvingServices: [String: NetService] = [:]
    /// Service names whose first resolve failed and have one retry in flight.
    private var retriedResolves: Set<String> = []

    static let logger = Logger(subsystem: "com.osaurus", category: "bonjour")

    init(
        serviceType: String,
        onResolved: @escaping @Sendable (DiscoveredAgent) -> Void,
        onRemoved: @escaping @Sendable (String) -> Void
    ) {
        self.serviceType = serviceType
        self.onResolved = onResolved
        self.onRemoved = onRemoved
        super.init()
    }

    func start() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = RunLoop.current
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.schedule(in: runLoop, forMode: .default)
            browser.searchForServices(ofType: self.serviceType, inDomain: "")
            self.browser = browser
            // The scheduled browser installs a run-loop source, so `run()`
            // blocks here for the process lifetime instead of returning.
            runLoop.run()
        }
        thread.name = "com.osaurus.bonjour-browser"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func handleResolved(service: NetService) {
        defer {
            resolvingServices.removeValue(forKey: service.name)
            retriedResolves.remove(service.name)
        }

        guard let txtData = service.txtRecordData() else { return }
        let fields = NetService.dictionary(fromTXTRecord: txtData)

        guard
            let idData = fields["id"],
            let idString = String(data: idData, encoding: .utf8),
            let agentId = UUID(uuidString: idString),
            let name = fields["name"].flatMap({ String(data: $0, encoding: .utf8) })
        else { return }

        let desc = fields["description"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let addr = fields["address"].flatMap { String(data: $0, encoding: .utf8) }
        let osc = fields["osc"].flatMap { String(data: $0, encoding: .utf8) } == "1"

        let agent = DiscoveredAgent(
            id: agentId,
            name: name,
            agentDescription: desc,
            address: addr,
            host: service.hostName,
            port: Int(service.port),
            supportsSecureChannel: osc,
            serviceName: service.name
        )
        onResolved(agent)
    }
}

// MARK: - NetServiceBrowserDelegate / NetServiceDelegate

// Callbacks arrive on the background browser thread's run loop. `BonjourBrowserCore`
// is not actor-isolated, so the delegate methods run there directly and mutate
// `resolvingServices` only on that thread.

extension BonjourBrowserCore: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        service.delegate = self
        resolvingServices[service.name] = service
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        resolvingServices.removeValue(forKey: service.name)
        onRemoved(service.name)
    }
}

extension BonjourBrowserCore: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        handleResolved(service: sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // mDNS resolves regularly fail transiently right after wake / network
        // change; one retry recovers most of them without UI impact.
        if !retriedResolves.contains(sender.name) {
            retriedResolves.insert(sender.name)
            Self.logger.debug(
                "Retrying resolve for '\(sender.name, privacy: .public)' after failure: \(errorDict, privacy: .public)"
            )
            sender.resolve(withTimeout: 5.0)
            return
        }
        retriedResolves.remove(sender.name)
        resolvingServices.removeValue(forKey: sender.name)
        Self.logger.error(
            "Failed to resolve '\(sender.name, privacy: .public)': \(errorDict, privacy: .public)"
        )
    }
}
