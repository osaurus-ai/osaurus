//
//  OnboardingTeamViews.swift
//  osaurus
//
//  The setup card's pieces inside chat: its header with where setup
//  stands, and the list of teammates to start with. Each teammate wears
//  its sidebar avatar, so the row picked here is the one found there later.
//

import SwiftUI

// MARK: - Header

/// The setup card's header: where setup stands, Skip setup, and what this
/// step is.
struct OnboardingSetupHeader: View {
    let step: OnboardingPanel.Step?
    var teammate: OnboardingPanel.Teammate?
    let onSkip: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s8) {
                OnboardingSetupStepper(current: .of(step))
                Spacer(minLength: theme.space.s8)
                SettingsButton(.tertiary, L("Skip setup"), size: .small, verbatim: true, action: onSkip)
            }

            HStack(alignment: .center, spacing: theme.space.s12) {
                if step == .firstTask, let teammate {
                    OnboardingTeammateAvatar(
                        mascotId: teammate.mascotId, name: teammate.name, imageURL: teammate.imageURL, size: 36)
                }
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(title, bundle: .module)
                        .textStyle(.body, weight: 600)
                        .foregroundStyle(theme.text.primary)
                    Text(subtitle, bundle: .module)
                        .textStyle(.footnote)
                        .foregroundStyle(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var title: LocalizedStringKey {
        switch step {
        case .brain: return "Pick a model"
        case .team, nil: return "Meet your team"
        case .firstTask:
            guard let teammate else { return "Your first task" }
            return "Your first task with \(teammate.name)"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch step {
        case .brain: return "Choose where Osaurus runs to start chatting."
        case .team, nil: return "Pick who to start with. You can switch any time."
        case .firstTask: return "Try one of these, or ask me anything."
        }
    }
}

/// "Welcome — Model — Team": finished chapters checked, the current one lit.
struct OnboardingSetupStepper: View {
    let current: OnboardingChapter

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space.s6) {
            ForEach(OnboardingChapter.allCases, id: \.rawValue) { chapter in
                if chapter.rawValue > 0 {
                    Capsule()
                        .fill(chapter.rawValue <= current.rawValue ? theme.border.strong : theme.border.subtle)
                        .frame(width: 14, height: 1)
                }
                segment(chapter)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                "Setup chapter \(current.rawValue + 1) of \(OnboardingChapter.allCases.count): \(Text(current.title, bundle: .module))",
                bundle: .module
            )
        )
    }

    private func segment(_ chapter: OnboardingChapter) -> some View {
        let isCurrent = chapter == current
        let isDone = chapter.rawValue < current.rawValue
        return HStack(spacing: theme.space.s4) {
            Image(systemName: isDone ? "checkmark.circle.fill" : isCurrent ? "circle.inset.filled" : "circle")
                .glyphSize(.micro, weight: .semibold)
                .foregroundStyle(
                    isDone ? theme.status.success.foreground : isCurrent ? theme.text.primary : theme.text.tertiary
                )
            Text(chapter.title, bundle: .module)
                .textStyle(.caption, weight: isCurrent ? 600 : 400)
                .foregroundStyle(isCurrent ? theme.text.primary : theme.text.secondary)
        }
    }
}

// MARK: - Teammates

/// The teammate's avatar exactly as the sidebar draws it: a still image,
/// never the animated dino.
struct OnboardingTeammateAvatar: View {
    @Environment(\.theme) private var theme
    let mascotId: String?
    let name: String
    var imageURL: URL? = nil
    var size: CGFloat = 32

    var body: some View {
        AgentAvatarView(
            mascotId: mascotId,
            name: name,
            tint: theme.dataInk(seed: name),
            diameter: size,
            customImageURL: imageURL,
            monogramFontSize: size * 0.45,
            borderWidth: 0
        )
        .accessibilityHidden(true)
    }
}

/// "Meet your team": one row per teammate, divided like the asks below it.
struct OnboardingTeamList: View {
    let cards: [OnboardingPanel.Card]
    let onPick: (OnboardingPanel.Card) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                if index > 0 { ThemeHairlineDivider() }
                OnboardingPanelRow(action: { onPick(card) }) {
                    HStack(spacing: theme.space.s12) {
                        OnboardingTeammateAvatar(mascotId: card.mascotId, name: card.name, imageURL: card.imageURL)
                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            Text(card.name)
                                .textStyle(.label, weight: 600)
                                .foregroundStyle(theme.text.primary)
                            Text(card.pitch)
                                .textStyle(.footnote)
                                .foregroundStyle(theme.text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: theme.space.s8)
                        if let access = card.access {
                            StatusChip(access, help: card.note)
                        }
                    }
                }
                .accessibilityLabel(
                    Text(verbatim: [card.name, card.pitch, card.access].compactMap { $0 }.joined(separator: ", "))
                )
                .onboardingRowReveal(index)
            }
        }
    }
}

/// A full-width row of the setup card: hover wash, trailing chevron.
struct OnboardingPanelRow<Label: View>: View {
    var trailingSymbol = "chevron.right"
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        SwiftUI.Button(action: action) {
            HStack(spacing: theme.space.s12) {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: trailingSymbol)
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundStyle(isHovered ? theme.text.secondary : theme.text.tertiary)
                    .offset(x: isHovered ? 2 : 0)
            }
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s12)
            .background(isHovered ? theme.surface.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.motion.quick) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
