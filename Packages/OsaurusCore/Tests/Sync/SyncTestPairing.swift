//
//  SyncTestPairing.swift
//  OsaurusCoreTests
//
//  Confirms the pairing number on both cores, as the user does on both screens.
//

import Foundation
import OsaurusSync

enum SyncTestPairing {
    /// Confirms on `host` and `joiner` once each is waiting for its user. Call
    /// after `joiner.pairWithOffer`; `confirmPairing` throws until the number is up.
    static func confirm(host: SyncCore, joiner: SyncCore, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var hostDone = false
        var joinerDone = false
        while !(hostDone && joinerDone) {
            if !hostDone { hostDone = (try? host.confirmPairing(device: joiner.deviceKey())) != nil }
            if !joinerDone { joinerDone = (try? joiner.confirmPairing(device: host.deviceKey())) != nil }
            guard Date() < deadline else {
                throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "pairing number never came up"])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
