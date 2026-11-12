//
//  AgentRoleBadge.swift
//  osaurus
//
//  The small round symbol on a teammate's avatar that says what it works
//  with: a calendar on Planner, an envelope on Courier.
//

import SwiftUI

struct AgentRoleBadge: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let diameter: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .glyphSize(points: diameter * 0.55, weight: .semibold)
            .foregroundStyle(theme.text.primary)
            .frame(width: diameter, height: diameter)
            .background(theme.surface.raised, in: Circle())
            .hairlineBorder(theme.border.default, in: Circle())
            .accessibilityHidden(true)
    }
}
