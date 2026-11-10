//
//  MobileConnectAdvertiser.swift
//  osaurus
//
//  Advertises this Mac itself (not an agent) as `_osaurus-mobile._tcp` so the
//  Osaurus iPhone app can find it for 6-digit pairing. The TXT record carries
//  only a display name and the protocol version; identity and keys are
//  exchanged by `POST /pair/code`.
//
//  Publishing is logged and retried: a publish that fails (mDNSResponder not ready at launch, a name collision beyond
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
    /// An mDNS instance name is at most 63 bytes; a longer one is refused.
    static let maxInstanceNameBytes = 63
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

    func stopAdvertising() {
        generation += 1
        if service != nil { MobileConnectLog.write("bonjour: stopped advertising") }
        service?.stop()
        service = nil
    }

    private func publish() {
        let name = Self.truncateUTF8(Host.current().localizedName ?? "Osaurus", maxBytes: Self.maxInstanceNameBytes)
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

    /// Truncate a string to at most `maxBytes` of UTF-8 without splitting a
    /// character.
    nonisolated static func truncateUTF8(_ string: String, maxBytes: Int) -> String {
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
        Self.logger.info("Advertised pairing service '\(sender.name, privacy: .public)' on port \(sender.port)")
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        MobileConnectLog.write("bonjour: FAILED to advertise '\(sender.name)' (\(sender.type)): \(errorDict)")
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
