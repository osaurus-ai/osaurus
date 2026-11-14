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
            tint: theme.dataInk(seed: seed ?? name),
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
