//
//  MobileConnectAdvertiser.swift
//  osaurus
//
//  Advertises this Mac itself (not an agent) as `_osaurus-mobile._tcp` so the
//  Osaurus iPhone app can find it for 6-digit pairing even when no agent has
//  Bonjour enabled. The TXT record carries only a display name and the
//  protocol version; identity and keys are exchanged by `POST /pair/code`.
//
//  Publishing is logged and retried like the agent advertiser's: a publish
//  that fails (mDNSResponder not ready at launch, a name collision beyond
//  auto-rename, local-network access denied) used to fail silently, and a
//  phone that could not find the Mac was indistinguishable from a Mac that
//  never said it was there.
//

import Foundation
import os

@MainActor
final class MobileConnectAdvertiser: NSObject {
    static let shared = MobileConnectAdvertiser()
    static let serviceType = "_osaurus-mobile._tcp."
    private static let maxPublishRetries = 3
    private nonisolated static let logger = Logger(subsystem: "com.osaurus", category: "bonjour")

    private var service: NetService?
    private var port: Int = 0
    private var retries = 0
    /// Bumped on every start and stop, so a retry still asleep from an
    /// earlier run can tell it is stale and leave the new service alone.
    private var generation = 0

    func startAdvertising(port: Int) {
        stopAdvertising()
        self.port = port
        retries = 0
        // What the running binary actually declares: a publish refused with
        // -72008 (policy denied) is either a type missing from this list or
        // the app being denied local-network access altogether.
        let declared = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
        let usage = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        MobileConnectLog.write(
            "bonjour: bundle declares NSBonjourServices=\(declared) usageDescription=\(usage == nil ? "missing" : "present") macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
        publish()
    }

    /// Publishes a throwaway service of the AGENT type for a moment. If it
    /// goes through while the pairing type is refused, the pairing type is
    /// missing from the bundle's declared list; if both are refused, the
    /// app itself is denied local-network access.
    private var probe: NetService?
    private var hasProbed = false

    private func probeAgentType() {
        guard !hasProbed else { return }
        hasProbed = true
        let service = NetService(domain: "", type: BonjourAdvertiser.serviceType, name: "osaurus-probe", port: Int32(port))
        service.delegate = self
        service.publish()
        probe = service
        MobileConnectLog.write("bonjour: probing \(BonjourAdvertiser.serviceType) as 'osaurus-probe'")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.probe?.stop()
            self?.probe = nil
        }
    }

    func stopAdvertising() {
        generation += 1
        if service != nil { MobileConnectLog.write("bonjour: stopped advertising") }
        service?.stop()
        service = nil
    }

    private func publish() {
        // An mDNS instance name is at most 63 bytes; a long Mac name would be
        // refused outright.
        let name = BonjourAdvertiser.truncateUTF8(
            Host.current().localizedName ?? "Osaurus", maxBytes: BonjourAdvertiser.maxInstanceNameBytes
        )
        let service = NetService(domain: "", type: Self.serviceType, name: name, port: Int32(port))
        service.setTXTRecord(
            NetService.data(fromTXTRecord: [
                "name": Data(name.utf8),
                "v": Data("\(MobilePairingService.wireVersion)".utf8),
            ])
        )
        service.delegate = self
        service.publish()
        self.service = service
        MobileConnectLog.write("bonjour: publishing \(Self.serviceType) as '\(name)' on port \(port)")
        Self.logger.info("Publishing pairing service '\(name, privacy: .public)' on port \(self.port)")
    }

    private func retryPublish() async {
        guard retries < Self.maxPublishRetries else {
            MobileConnectLog.write("bonjour: giving up after \(Self.maxPublishRetries) failed publishes")
            Self.logger.error("Giving up advertising the pairing service after \(Self.maxPublishRetries) attempts")
            return
        }
        retries += 1
        let started = generation
        try? await Task.sleep(nanoseconds: UInt64(retries) * 1_000_000_000)
        // Stopped meanwhile, or stopped and started again (a server
        // restart): that run has its own service and its own retries.
        guard generation == started, service != nil else { return }
        service?.stop()
        publish()
    }
}

// MARK: - NetServiceDelegate

extension MobileConnectAdvertiser: NetServiceDelegate {

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        MobileConnectLog.write("bonjour: advertised '\(sender.name)' (\(sender.type)) on port \(sender.port)")
        if sender.name == "osaurus-probe" { return }
        Self.logger.info("Advertised pairing service '\(sender.name, privacy: .public)' on port \(sender.port)")
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        MobileConnectLog.write("bonjour: FAILED to advertise '\(sender.name)' (\(sender.type)): \(errorDict)")
        if sender.name == "osaurus-probe" { return }
        Task { @MainActor [weak self] in self?.probeAgentType() }
        Self.logger.error(
            "Failed to advertise pairing service '\(sender.name, privacy: .public)': \(errorDict, privacy: .public)"
        )
        // Only for the service currently advertised: a late failure from one
        // a restart already replaced must not tear the new one down.
        let failed = ObjectIdentifier(sender)
        Task { @MainActor [weak self] in
            guard let self, self.service.map({ ObjectIdentifier($0) }) == failed else { return }
            await self.retryPublish()
        }
    }
}
