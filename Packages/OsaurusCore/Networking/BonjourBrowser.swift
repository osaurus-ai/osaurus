//
//  BonjourBrowser.swift
//  osaurus
//
//  Discovers remote Osaurus agents advertised as Bonjour services on the local
//  network, enabling the agent selector to list peers from other devices.
//

import Darwin
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
    /// Mascot avatar id (e.g. "green") from the persisted `RemoteAgent` record
    /// (refreshed from the agent's live metadata on connect), so the picker can
    /// render the agent's own avatar instead of a generic glyph. nil = monogram
    /// fallback on the name (e.g. a paired agent that hasn't connected yet).
    public let avatar: String?

    public init(
        id: UUID,
        name: String,
        remoteAgentAddress: String,
        providerId: UUID,
        avatar: String? = nil
    ) {
        self.id = id
        self.name = name
        self.remoteAgentAddress = remoteAgentAddress
        self.providerId = providerId
        self.avatar = avatar
    }
}

// MARK: - DiscoveredAgent

/// A remote Osaurus agent discovered via Bonjour on the local network.
public struct DiscoveredAgent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let agentDescription: String
    public let address: String?
    public let host: String?
    /// A numeric IP (preferring IPv4) parsed from the service's resolved
    /// addresses. Used as a connection fallback when the mDNS `.local`
    /// `host` is missing or cannot be resolved on the current network (some
    /// enterprise/VPN setups block multicast `.local` resolution).
    public let resolvedIP: String?
    public let port: Int
    /// Whether the peer advertised Secure Channel support (`osc=1` in its
    /// TXT record). Peers without it predate end-to-end encryption and will
    /// reject nothing — but WE will refuse to send them agent traffic, so
    /// surface a "peer needs upgrade" message instead of a cryptic failure.
    public let supportsSecureChannel: Bool

    /// Internal key that matches the NetService name for lookup/removal.
    internal let serviceName: String

    /// Best connectable host: the stable `.local` name when present,
    /// otherwise the resolved numeric IP. `nil` only when neither resolved.
    public var connectHost: String? {
        if let host, !host.isEmpty { return host }
        if let resolvedIP, !resolvedIP.isEmpty { return resolvedIP }
        return nil
    }

    /// A short, human-verifiable rendering of the pinned crypto `address`
    /// (e.g. `0x742d35…bD18`), shown at the pairing decision point so the
    /// user verifies the cryptographic identity rather than only the
    /// attacker-controllable display name. `nil` when no address is advertised.
    public var addressFingerprint: String? {
        guard let address, !address.isEmpty else { return nil }
        let hex = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        guard hex.count > 12 else { return address }
        return "0x\(hex.prefix(6))…\(hex.suffix(4))"
    }

    /// True when the peer claims Secure Channel support (`osc=1`) but
    /// advertised no crypto address to pin. A genuine Osaurus peer always
    /// advertises its address alongside `osc=1`; the inconsistent combination
    /// is the signature of a spoofed advertisement (or a buggy peer), so the
    /// pairing flow refuses it rather than silently skipping the server
    /// identity check that the addressless branch would otherwise bypass.
    public var isUnverifiableSecureChannelPeer: Bool {
        supportsSecureChannel && (address ?? "").isEmpty
    }
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
    /// Whether the background browse thread has been started. Browsing begins
    /// lazily (see `startIfNeeded`) so the singleton can be constructed — e.g.
    /// to subscribe to `$discoveredAgents` — without probing the LAN.
    private var hasStarted = false

    /// Grace period before a `didRemove` actually drops an agent from the
    /// published list. mDNS TTL flaps (sleep/wake, Wi-Fi roam, cache expiry
    /// races) routinely emit remove+find pairs seconds apart; tearing down an
    /// ephemeral provider — and the active chat using it — on the first remove
    /// is needlessly destructive.
    private static let removalGracePeriod: Duration = .seconds(12)
    private var pendingRemovals: [String: Task<Void, Never>] = [:]

    private override init() {
        super.init()
        // The core is created but NOT started here. Merely constructing the
        // singleton (every chat window subscribes to `$discoveredAgents`) must
        // not begin an always-on mDNS browse or trigger the Local Network
        // permission prompt for users who never use peer discovery. The browse
        // starts the first time a discovery surface appears (`startIfNeeded`).
        self.core = BonjourBrowserCore(
            serviceType: BonjourAdvertiser.serviceType,
            onResolved: { agent in
                Task { @MainActor [weak self] in self?.upsert(agent) }
            },
            onRemoved: { serviceName in
                Task { @MainActor [weak self] in self?.remove(serviceName: serviceName) }
            }
        )
    }

    // MARK: - Lifecycle

    /// Begin browsing for peers if it hasn't started yet. Idempotent and cheap
    /// to call from `onAppear` / popover-open of any discovery surface (e.g.
    /// the agent picker). Once started, the browse runs for the process
    /// lifetime so an active discovered-agent chat keeps re-resolving across
    /// network changes.
    public func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        core?.start()
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
///
/// Module-internal (not `private`) so its pure static helpers
/// (`firstResolvedIP`, `searchRetryDelay`) can be unit-tested via
/// `@testable import`.
final class BonjourBrowserCore: NSObject, @unchecked Sendable {
    private let serviceType: String
    private let onResolved: @Sendable (DiscoveredAgent) -> Void
    private let onRemoved: @Sendable (String) -> Void

    private var browser: NetServiceBrowser?
    /// Retains services while they resolve (a dropped reference cancels the
    /// resolve), keyed by NetService name.
    private var resolvingServices: [String: NetService] = [:]
    /// Service names whose first resolve failed and have one retry in flight.
    private var retriedResolves: Set<String> = []
    /// Consecutive failed/aborted browse starts, reset by a successful
    /// `willSearch`. Bounds the re-`searchForServices` backoff. Touched only on
    /// the browser run-loop thread.
    private var searchRetryCount = 0
    static let maxSearchRetries = 5

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
            resolvedIP: Self.firstResolvedIP(from: service.addresses),
            port: Int(service.port),
            supportsSecureChannel: osc,
            serviceName: service.name
        )
        onResolved(agent)
    }

    // MARK: - Address Parsing

    /// Extract a numeric IP (preferring IPv4) from a service's resolved
    /// `addresses`, used as a connection fallback when the `.local` hostname is
    /// missing or unresolvable. Pure/static so it's unit-testable.
    static func firstResolvedIP(from addresses: [Data]?) -> String? {
        guard let addresses, !addresses.isEmpty else { return nil }
        var ipv6Fallback: String?
        for data in addresses {
            let parsed: String? = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr>.size else {
                    return nil
                }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(
                    sa,
                    socklen_t(data.count),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                guard status == 0 else { return nil }
                return String(cString: host)
            }
            guard let ip = parsed, !ip.isEmpty else { continue }
            // Prefer IPv4 (routable on the LAN we discovered the peer on); keep
            // the first IPv6 only as a fallback.
            if ip.contains(".") { return ip }
            if ipv6Fallback == nil { ipv6Fallback = ip }
        }
        return ipv6Fallback
    }

    // MARK: - Browse Restart

    /// Backoff before the `attempt`-th browse restart (0-based): 1s, 2s, 4s, …
    /// capped at 30s. Returns nil once the retry budget is exhausted.
    static func searchRetryDelay(attempt: Int) -> TimeInterval? {
        guard attempt < maxSearchRetries else { return nil }
        return min(pow(2.0, Double(max(0, attempt))), 30.0)
    }

    /// Schedule a bounded re-`searchForServices` on the browser's run loop.
    /// Called from the browse-failure delegate callbacks (same thread).
    func scheduleSearchRetry() {
        guard let delay = Self.searchRetryDelay(attempt: searchRetryCount) else {
            Self.logger.error(
                "Giving up Bonjour browse after \(Self.maxSearchRetries, privacy: .public) attempts"
            )
            return
        }
        searchRetryCount += 1
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, let browser = self.browser else { return }
            browser.searchForServices(ofType: self.serviceType, inDomain: "")
        }
        RunLoop.current.add(timer, forMode: .default)
    }
}

// MARK: - NetServiceBrowserDelegate / NetServiceDelegate

// Callbacks arrive on the background browser thread's run loop. `BonjourBrowserCore`
// is not actor-isolated, so the delegate methods run there directly and mutate
// `resolvingServices` only on that thread.

extension BonjourBrowserCore: NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        // A successful (re)start re-arms the retry budget.
        searchRetryCount = 0
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        // The browse never started — most often a denied Local Network
        // permission or mDNSResponder not yet ready. Surface it (silent
        // zero-discovery is the worst outcome) and retry with bounded backoff.
        Self.logger.error(
            "Bonjour browse failed to start: \(errorDict, privacy: .public)"
        )
        scheduleSearchRetry()
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        // We never call `stop()` ourselves, so an unsolicited stop means the
        // browse ended unexpectedly (e.g. mDNSResponder churn). Restart it
        // under the same bounded backoff.
        Self.logger.error("Bonjour browse stopped unexpectedly; restarting")
        scheduleSearchRetry()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        // Finding a service proves the browse is healthy; re-arm the budget.
        searchRetryCount = 0
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
