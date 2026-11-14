//
//  PresenceStatusChip.swift
//  osaurus
//
//  One status vocabulary for anything that can be reachable or not: an
//  agent someone shared with you, one of your own devices, and an agent's
//  remote access. Encryption is not a status; `EncryptionBadge` says it
//  separately where it matters.
//

import SwiftUI

struct PresenceStatusChip: View {
    enum Presence: Equatable {
        case online
        case connecting
        case attention
        case failed
        case offline
    }

    let label: String
    let presence: Presence
    var help: String?

    var body: some View {
        StatusChip(label, tone: tone, showsDot: true, help: help)
    }

    private var tone: StatusChip.Tone {
        switch presence {
        case .online: .success
        case .connecting: .info
        case .attention: .warning
        case .failed: .error
        case .offline: .neutral
        }
    }
}

extension PresenceStatusChip {
    /// An agent shared with you, from a workspace or a guest link.
    init(_ status: SharedAgentStatus) {
        let presence: Presence =
            switch status {
            case .ready: .online
            case .checking, .connecting: .connecting
            case .notConnected(let reason, _): reason == nil ? .offline : .attention
            case .accessRevoked: .failed
            case .offline, .unavailable, .readOnlyTeammate: .offline
            }
        self.init(label: Self.label(for: status), presence: presence)
    }

    /// An agent's remote access: On, Connecting, Off, Couldn't connect, or
    /// On another Mac.
    init(remoteAccess status: AgentRelayStatus) {
        switch status {
        case .connected:
            self.init(label: L("On"), presence: .online)
        case .connecting:
            self.init(label: L("Connecting"), presence: .connecting)
        case .disconnected:
            self.init(label: L("Off"), presence: .offline)
        case .error(let message):
            self.init(label: L("Couldn't connect"), presence: .failed, help: message)
        case .servedElsewhere:
            self.init(label: L("On another Mac"), presence: .attention)
        }
    }

    /// One of your own devices in the sync account.
    init(deviceConnected: Bool, revoked: Bool) {
        if revoked {
            self.init(label: L("Removed"), presence: .offline)
        } else if deviceConnected {
            self.init(label: L("Online"), presence: .online)
        } else {
            self.init(label: L("Offline"), presence: .offline)
        }
    }

    static func label(for status: SharedAgentStatus) -> String {
        status.shortLabel
    }
}

/// "End-to-end encrypted", shown next to a status rather than as one.
struct EncryptionBadge: View {
    var body: some View {
        StatusChip(L("End-to-end encrypted"), tone: .neutral, icon: "lock.fill")
    }
}
