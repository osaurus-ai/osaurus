//
//  ParticipantAvatar.swift
//  osaurus
//
//  A monogram for a person: a teammate, a guest, a channel sender, or one
//  of your devices. The color comes from a stable hash of who they are
//  (wallet, handle, channel id), so the same person keeps the same color in
//  the Inbox, the Guests list, Insights and every launch.
//

import SwiftUI

struct ParticipantAvatar: View {
    @Environment(\.theme) private var theme

    let name: String
    /// Identity the color is derived from; `name` when nil.
    var seed: String? = nil
    var diameter: CGFloat = 28

    var body: some View {
        AgentAvatarView(
            mascotId: nil,
            name: Self.monogramSource(name),
            tint: Self.color(for: seed ?? name),
            diameter: diameter,
            monogramFontSize: diameter * 0.43,
            borderWidth: theme.stroke.default
        )
        .accessibilityHidden(true)
    }

    /// Drops the leading `@` or `0x` so "@alice" reads as "A".
    static func monogramSource(_ name: String) -> String {
        var trimmed = Substring(name.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("@") { trimmed = trimmed.dropFirst() }
        if trimmed.lowercased().hasPrefix("0x") { trimmed = trimmed.dropFirst(2) }
        return String(trimmed)
    }

    /// FNV-1a over the lowercased seed: stable across launches, unlike
    /// `String.hashValue`.
    static func hue(for seed: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Double(hash % 360) / 360.0
    }

    static func color(for seed: String) -> Color {
        Color(hue: hue(for: seed), saturation: 0.55, brightness: 0.8)
    }
}

extension ParticipantAvatar {
    init(_ participant: Participant, diameter: CGFloat = 28) {
        self.init(
            name: ParticipantFormatter.compact(participant),
            seed: participant.wallet ?? participant.handle ?? participant.channelSenderId
                ?? participant.agentAddress ?? participant.displayName,
            diameter: diameter
        )
    }

    /// People get a monogram; the owner and agents keep their own icons.
    static func isPerson(_ participant: Participant) -> Bool {
        switch participant.kind {
        case .teammate, .invitePeer, .channelSender, .agentOwner: true
        case .owner, .ownerDevice, .remoteAgent, .agent: false
        }
    }
}
