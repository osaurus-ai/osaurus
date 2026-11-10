//
//  ConversationEventRow.swift
//  osaurus
//
//  A participant event in the transcript, drawn like the compaction
//  marker (line · pill · line): "You allowed web_fetch for @alice ·
//  Paired phone". Links to the item's Insights row when it has one.
//

import SwiftUI

struct ConversationEventRow: View {
    let text: String
    let icon: String
    let attentionId: UUID?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space.s8) {
            line
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .glyphSize(8, weight: .semibold)
                    .accessibilityHidden(true)
                Text(text)
                    .textStyle(.footnote, weight: 500)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .foregroundColor(theme.text.tertiary)
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(theme.surface.hover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default)
            )
            .layoutPriority(1)
            if let attentionId {
                PickerCardTextLink(title: L("View in Insights"), icon: "arrow.up.right", fillsWidth: false) {
                    InsightsService.shared.showInteraction(attentionId: attentionId)
                    AppDelegate.shared?.showManagementWindow(initialTab: .insights)
                }
                .fixedSize()
                .accessibilityIdentifier("conversation-event-insights")
            }
            line
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private var line: some View {
        Rectangle()
            .fill(theme.border.subtle)
            .frame(height: 1)
            .frame(minWidth: 12, maxWidth: .infinity)
    }
}
