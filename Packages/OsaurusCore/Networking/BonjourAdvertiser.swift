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
    /// The TXT payload we last pushed to the live service per agent. Diffing
    /// against this lets a `description`/`address`/`osc` edit reach the wire
    /// via `setTXTRecord` even when the instance name is unchanged (otherwise
    /// the name-only guard would silently drop the update).
    private var publishedTXT: [UUID: Data] = [:]
    /// Consecutive `didNotPublish` failures per agent, for the bounded retry.
    /// Reset to 0 on a successful `didPublish`.
    private var publishRetryCounts: [UUID: Int] = [:]
    private var currentPort: Int = 0
    private var isAdvertising = false
    private var cancellables: Set<AnyCancellable> = []

    /// Max automatic re-publish attempts after `didNotPublish` before giving
    /// up (each failure is logged regardless).
    static let maxPublishRetries = 3

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
        publishedTXT.removeAll()
        publishRetryCounts.removeAll()
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
            publishedTXT.removeValue(forKey: id)
            publishRetryCounts.removeValue(forKey: id)
        }

        // Publish, update-in-place, or leave each current agent's service.
        // We compare against the name we last REQUESTED (mDNS may auto-rename
        // on conflict, and reacting to the live `service.name` would
        // stop/republish forever) AND the TXT we last published — so a
        // `description`/`address`/`osc` edit reaches the wire via
        // `setTXTRecord` without a disruptive stop/republish.
        for agent in agents where agent.bonjourEnabled {
            let expectedName = Self.instanceName(for: agent)
            let txt = Self.txtRecord(for: agent)
            switch Self.advertisementAction(
                hasService: services[agent.id] != nil,
                requestedName: requestedNames[agent.id],
                publishedTXT: publishedTXT[agent.id],
                newName: expectedName,
                newTXT: txt
            ) {
            case .publish:
                services[agent.id]?.stop()
                publish(agent: agent, name: expectedName, txt: txt)
            case .updateTXT:
                services[agent.id]?.setTXTRecord(txt)
                publishedTXT[agent.id] = txt
            case .none:
                break
            }
        }
    }

    /// Whether `syncAdvertisements` should (re)publish a service, update its
    /// live TXT record in place, or do nothing. A pure function of the cached
    /// state so the republish-vs-update logic is unit-testable without a live
    /// `NetService`/mDNS.
    enum AdvertisementAction: Equatable {
        /// (Re)publish: the service doesn't exist yet, or the DNS-SD instance
        /// name changed (mDNS keys a registration by name).
        case publish
        /// Name unchanged but the TXT payload changed — update in place.
        case updateTXT
        /// Nothing changed.
        case none
    }

    static func advertisementAction(
        hasService: Bool,
        requestedName: String?,
        publishedTXT: Data?,
        newName: String,
        newTXT: Data
    ) -> AdvertisementAction {
        guard hasService, requestedName == newName else { return .publish }
        return publishedTXT == newTXT ? .none : .updateTXT
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

    private func publish(agent: Agent, name: String, txt: Data) {
        let service = NetService(
            domain: "",  // empty = local. domain
            type: Self.serviceType,
            name: name,
            port: Int32(currentPort)
        )
        service.setTXTRecord(txt)
        service.delegate = self
        service.publish()
        services[agent.id] = service
        requestedNames[agent.id] = name
        publishedTXT[agent.id] = txt
    }

    /// Build the TXT record advertised for an agent. `static` (a pure function
    /// of the agent) so the payload can be unit-tested without a live
    /// `NetService`.
    static func txtRecord(for agent: Agent) -> Data {
        var fields: [String: Data] = [:]
        fields["name"] = agent.name.data(using: .utf8)
        fields["id"] = agent.id.uuidString.data(using: .utf8)
        if !agent.description.isEmpty {
            let capped = truncateUTF8(agent.description, maxBytes: maxTXTDescriptionBytes)
            fields["description"] = capped.data(using: .utf8)
        }
        // Advertise the address and the Secure Channel flag (`osc=1`) together,
        // and only when the agent has a derived address: the address is what a
        // peer pins and signs the handshake with, so claiming `osc=1` without
        // one would be a false promise (the agent fails closed at run time).
        // This also keeps an addressless advert unambiguously "legacy plaintext"
        // rather than a spoof claiming encryption.
        if let address = agent.agentAddress, !address.isEmpty {
            fields["address"] = address.data(using: .utf8)
            fields["osc"] = "1".data(using: .utf8)
        }
        return NetService.data(fromTXTRecord: fields)
    }

    // MARK: - Publish Retry

    /// Backoff before the `attempt`-th re-publish (0-based): 1s, 2s, 4s, …
    /// capped at 30s.
    static func publishRetryDelay(attempt: Int) -> Double {
        min(pow(2.0, Double(max(0, attempt))), 30.0)
    }

    /// The agent id whose service we REQUESTED under `serviceName` (the name we
    /// asked mDNS to publish, before any collision auto-rename).
    private func agentId(forServiceName serviceName: String) -> UUID? {
        requestedNames.first(where: { $0.value == serviceName })?.key
    }

    /// Re-publish an agent's service after a `didNotPublish` failure, bounded
    /// by `maxPublishRetries`. The retry counter persists across attempts and
    /// is cleared only by a successful `didPublish`.
    private func retryPublish(serviceName: String) async {
        guard isAdvertising, let id = agentId(forServiceName: serviceName) else { return }
        let attempt = publishRetryCounts[id, default: 0]
        guard attempt < Self.maxPublishRetries else {
            Self.delegateLogger.error(
                "Giving up advertising '\(serviceName, privacy: .public)' after \(Self.maxPublishRetries) failed attempts"
            )
            return
        }
        publishRetryCounts[id] = attempt + 1
        try? await Task.sleep(for: .seconds(Self.publishRetryDelay(attempt: attempt)))
        // Re-validate: the agent may have been removed/renamed/disabled while
        // we waited.
        guard isAdvertising,
            let agent = AgentManager.shared.agents.first(where: { $0.id == id }),
            agent.bonjourEnabled
        else { return }
        services[id]?.stop()
        publish(agent: agent, name: Self.instanceName(for: agent), txt: Self.txtRecord(for: agent))
    }

    /// Clear the retry counter for a successfully published service.
    private func clearPublishRetry(serviceName: String) {
        if let id = agentId(forServiceName: serviceName) {
            publishRetryCounts[id] = 0
        }
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
        let serviceName = sender.name
        Task { @MainActor [weak self] in
            self?.clearPublishRetry(serviceName: serviceName)
        }
    }

    public nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Self.delegateLogger.error(
            "Failed to advertise agent '\(sender.name, privacy: .public)': \(errorDict, privacy: .public)"
        )
        // Bounded re-publish: mDNS publish can fail transiently (mDNSResponder
        // not ready at cold launch, momentary collision beyond auto-rename).
        let serviceName = sender.name
        Task { @MainActor [weak self] in
            await self?.retryPublish(serviceName: serviceName)
        }
    }
}
