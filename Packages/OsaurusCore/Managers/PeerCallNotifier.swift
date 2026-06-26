//
//  PeerCallNotifier.swift
//  osaurus
//
//  Debounced host-side notification when a connected peer drives this host
//  over the Secure Channel (remote agent run / remote chat completion).
//

import Foundation

/// Shows an in-app toast (via `ToastManager`, consistent with the rest of the
/// app) when an authenticated remote peer calls the host, debounced per peer
/// so a multi-turn burst collapses into a single toast instead of a flood.
@MainActor
final class PeerCallNotifier {
    static let shared = PeerCallNotifier()

    /// Per-peer cooldown. Chosen default: long enough to collapse a burst of
    /// back-to-back calls from one peer into a single toast, short enough that
    /// a later, separate session still surfaces. Easy to tweak.
    private let cooldown: TimeInterval = 60

    /// Last toast time keyed by a stable peer identifier.
    private var lastNotified: [String: Date] = [:]

    private init() {}

    /// Toast that a connected peer is running one of the host's agents.
    /// - Parameters:
    ///   - peerKey: Stable peer identifier (access-key id, else scoped audience).
    ///   - agentName: Display name of the agent being driven.
    func notifyAgentRun(peerKey: String, agentName: String) {
        guard shouldNotify(peerKey) else { return }
        ToastManager.shared.info(
            L("Agent in use"),
            message: String(
                format: L("A connected peer is running “%@”."),
                agentName
            )
        )
    }

    /// True at most once per `cooldown` per peer; records the time when it
    /// returns true.
    private func shouldNotify(_ peerKey: String) -> Bool {
        let now = Date()
        if let last = lastNotified[peerKey], now.timeIntervalSince(last) < cooldown {
            return false
        }
        lastNotified[peerKey] = now
        // Bound the dict across long uptimes that see many distinct peers.
        if lastNotified.count > 256 {
            let cutoff = now.addingTimeInterval(-cooldown)
            lastNotified = lastNotified.filter { $0.value >= cutoff }
        }
        return true
    }
}
