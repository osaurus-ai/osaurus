//
//  SwarmLocalNetworkProbe.swift
//  osaurus
//
//  macOS Local Network privacy blocks mDNS and LAN dials for an app the user
//  has not approved, and the Swarm library only reports that as unreachable
//  hosts. A Bonjour browse for the Swarm service both asks for the approval
//  (first run) and tells us when it was denied, so Settings can say so
//  instead of showing an empty node list.
//

import Foundation
import Network

enum SwarmLocalNetworkAccess: Equatable, Sendable {
    /// Not probed (simulator, or not started).
    case unknown
    case allowed
    case denied
}

@MainActor
final class SwarmLocalNetworkProbe {
    static let serviceType = "_osaurus-swarm._udp"

    private var browser: NWBrowser?

    /// Browses for the Swarm service and reports access as the browser's
    /// state settles. `kDNSServiceErr_PolicyDenied` is the Local Network
    /// denial; any other state that gets to `ready` means access works.
    func start(onChange: @escaping @MainActor (SwarmLocalNetworkAccess) -> Void) {
        stop()
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .udp)
        browser.stateUpdateHandler = { state in
            let access: SwarmLocalNetworkAccess?
            switch state {
            case .ready:
                access = .allowed
            case .waiting(let error), .failed(let error):
                access = Self.isPolicyDenied(error) ? .denied : nil
            default:
                access = nil
            }
            guard let access else { return }
            Task { @MainActor in onChange(access) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }  // kDNSServiceErr_PolicyDenied
        return false
    }

    /// System Settings → Privacy & Security → Local Network.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    )!
}
