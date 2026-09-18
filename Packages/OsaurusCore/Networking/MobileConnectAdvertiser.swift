//
//  MobileConnectAdvertiser.swift
//  osaurus
//
//  Advertises this Mac itself (not an agent) as `_osaurus-mobile._tcp` so the
//  iOSaurus app can find it for 6-digit pairing even when no agent has
//  Bonjour enabled. The TXT record carries only a display name and the
//  protocol version; identity and keys are exchanged by `POST /pair/code`.
//

import Foundation

@MainActor
final class MobileConnectAdvertiser: NSObject {
    static let shared = MobileConnectAdvertiser()
    static let serviceType = "_osaurus-mobile._tcp."

    private var service: NetService?

    func startAdvertising(port: Int) {
        stopAdvertising()
        let name = Host.current().localizedName ?? "Osaurus"
        let service = NetService(domain: "", type: Self.serviceType, name: name, port: Int32(port))
        service.setTXTRecord(
            NetService.data(fromTXTRecord: [
                "name": Data(name.utf8),
                "v": Data("\(MobilePairingService.wireVersion)".utf8),
            ])
        )
        service.publish()
        self.service = service
    }

    func stopAdvertising() {
        service?.stop()
        service = nil
    }
}
