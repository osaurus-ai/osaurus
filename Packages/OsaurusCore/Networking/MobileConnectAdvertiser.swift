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

    func startAdvertising(port: Int) {
        stopAdvertising()
        self.port = port
        retries = 0
        publish()
    }

    func stopAdvertising() {
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
        try? await Task.sleep(nanoseconds: UInt64(retries) * 1_000_000_000)
        guard service != nil else { return }  // stopped meanwhile
        service?.stop()
        publish()
    }
}

// MARK: - NetServiceDelegate

extension MobileConnectAdvertiser: NetServiceDelegate {

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        MobileConnectLog.write("bonjour: advertised '\(sender.name)' on port \(sender.port)")
        Self.logger.info("Advertised pairing service '\(sender.name, privacy: .public)' on port \(sender.port)")
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        MobileConnectLog.write("bonjour: FAILED to advertise '\(sender.name)': \(errorDict)")
        Self.logger.error(
            "Failed to advertise pairing service '\(sender.name, privacy: .public)': \(errorDict, privacy: .public)"
        )
        Task { @MainActor [weak self] in await self?.retryPublish() }
    }
}
