//
//  OnboardingPanelView.swift
//  osaurus
//
//  The first run's setup card under its latest authored line, a
//  discovery's buttons, and the run-location label under each reply. A tap
//  goes straight to `OnboardingFirstRun` or `DiscoveryCenter`; nothing here
//  generates.
//

import AppKit
import SwiftUI

struct OnboardingPanelView: View {
    let panel: OnboardingPanel

    @Environment(\.theme) private var theme
    @State private var topic = ""

    var body: some View {
        Group {
            if panel.isDiscovery { discovery } else { setupCard }
        }
        .padding(.vertical, theme.space.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var asks: [OnboardingPanel.Button] { panel.buttons.filter { $0.style == .ask } }
    private var controls: [OnboardingPanel.Button] { panel.buttons.filter { $0.style != .ask } }

    private func perform(_ action: OnboardingAction) {
        if panel.isDiscovery {
            DiscoveryCenter.shared.perform(action, sessionId: panel.sessionId)
        } else {
            OnboardingFirstRun.shared.perform(action, sessionId: panel.sessionId)
        }
    }

    private func button(_ button: OnboardingPanel.Button) -> some View {
        SettingsButton(
            button.style == .primary ? .primary : .tertiary,
            button.title,
            icon: button.icon,
            size: .small,
            verbatim: true
        ) { perform(button.action) }
    }

    private var divider: some View { ThemeHairlineDivider() }

    // MARK: - Setup card

    /// Header, then the step's teammates or asks, then Back and the step's
    /// action, all on one card.
    private var setupCard: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
        let hasDetail = panel.note != nil || panel.topicField
        return VStack(alignment: .leading, spacing: theme.space.s0) {
            OnboardingSetupHeader(step: panel.step, teammate: panel.teammate) { perform(.dismissSetup) }
                .padding(theme.space.s16)

            if !panel.cards.isEmpty {
                divider
                OnboardingTeamList(cards: panel.cards) { perform(.selectPath($0.id)) }
            }
            if hasDetail {
                divider
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    if let note = panel.note { noteRow(note) }
                    if panel.topicField { topicRow }
                }
                .padding(theme.space.s16)
                .onboardingEntrance(1)
            }
            if !asks.isEmpty {
                divider
                VStack(alignment: .leading, spacing: theme.space.s0) {
                    ForEach(Array(asks.enumerated()), id: \.element.id) { index, ask in
                        if index > 0 { divider }
                        OnboardingPanelRow(trailingSymbol: "arrow.right", action: { perform(ask.action) }) {
                            Text(ask.title)
                                .textStyle(.bodySmall)
                                .foregroundStyle(theme.text.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .onboardingRowReveal(index)
                    }
                }
            }
            if !controls.isEmpty {
                divider
                footer.padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s12)
            }
        }
        .background(theme.surface.subtle)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default))
        .onboardingEntrance(0)
    }

    /// Back and other quiet controls lead; the step's action trails.
    private var footer: some View {
        HStack(spacing: theme.space.s8) {
            ForEach(controls.filter { $0.style != .primary }) { button($0) }
            Spacer(minLength: theme.space.s8)
            ForEach(controls.filter { $0.style == .primary }) { button($0) }
        }
    }

    private func noteRow(_ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Image(systemName: "info.circle")
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(theme.text.tertiary)
            Text(note)
                .textStyle(.footnote)
                .foregroundStyle(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var topicRow: some View {
        HStack(spacing: theme.space.s8) {
            SettingsTextField(
                placeholder: L("A topic to look into"),
                text: $topic,
                icon: "magnifyingglass",
                onSubmit: { perform(.topic(topic)) }
            )
            SettingsButton(.primary, L("Research"), size: .small, verbatim: true) { perform(.topic(topic)) }
                .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Discovery

    private var discovery: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            if let note = panel.note {
                Text(note)
                    .textStyle(.footnote)
                    .foregroundStyle(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .onboardingEntrance(1)
            }
            if !asks.isEmpty { askList(asks).onboardingEntrance(1) }
            if !controls.isEmpty {
                HStack(spacing: theme.space.s8) {
                    ForEach(controls) { button($0) }
                    Spacer(minLength: 0)
                }
                .onboardingEntrance(2)
            }
        }
    }

    private func askList(_ asks: [OnboardingPanel.Button]) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
        return VStack(alignment: .leading, spacing: theme.space.s0) {
            ForEach(asks.indices, id: \.self) { index in
                let ask = asks[index]
                if index > 0 { divider }
                SwiftUI.Button {
                    perform(ask.action)
                } label: {
                    HStack(spacing: theme.space.s8) {
                        Text(ask.title)
                            .textStyle(.bodySmall)
                            .foregroundStyle(theme.text.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .glyphSize(.footnote, weight: .semibold)
                            .foregroundStyle(theme.text.tertiary)
                    }
                    .padding(.horizontal, theme.space.s12)
                    .padding(.vertical, theme.space.s12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default))
    }
}

/// "On this Mac · 42 tok/s" under a first-run reply.
struct RunLocationLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .textStyle(.caption)
            .foregroundStyle(theme.text.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text(verbatim: text))
    }
}
