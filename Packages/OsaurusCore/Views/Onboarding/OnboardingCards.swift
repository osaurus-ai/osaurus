//
//  OnboardingCards.swift
//  osaurus
//
//  Glass card chrome and the unified row-card used across every onboarding
//  list (model picker, provider picker, choose-path, complete options).
//

import SwiftUI

// MARK: - Glass Card

/// Glass card with gradient border and accent edge.
/// Used as the chrome under `OnboardingRowCard` and any custom-content card
/// (recovery code, provider help, custom-provider form).
struct OnboardingGlassCard<Content: View>: View {
    let isSelected: Bool
    let content: Content

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    init(isSelected: Bool = false, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: OnboardingMetrics.cardCornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .background(cardBackground)
            .clipShape(shape)
            .overlay(cardBorder)
            .shadow(
                color: theme.shadowColor.opacity(isHovered ? 0.15 : 0.08),
                radius: isHovered ? 16 : 8,
                y: isHovered ? 6 : 3
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .onHover { hovering in
                withAnimation(theme.animationQuick()) { isHovered = hovering }
            }
    }

    private var cardBackground: some View {
        ZStack {
            if theme.glassEnabled {
                Rectangle().fill(.ultraThinMaterial)
            }

            theme.cardBackground.opacity(
                theme.glassEnabled
                    ? (theme.isDark ? OnboardingStyle.glassOpacityDark : OnboardingStyle.glassOpacityLight)
                    : 1.0
            )

            LinearGradient(
                colors: [
                    theme.accentColor.opacity(
                        theme.isDark
                            ? OnboardingStyle.accentGradientOpacityDark
                            : OnboardingStyle.accentGradientOpacityLight
                    ),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var cardBorder: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        isSelected
                            ? theme.accentColor
                            : (isHovered
                                ? theme.accentColor.opacity(0.4)
                                : theme.glassEdgeLight.opacity(
                                    theme.isDark
                                        ? OnboardingStyle.edgeLightOpacityDark
                                        : OnboardingStyle.edgeLightOpacityLight
                                )),
                        isSelected
                            ? theme.accentColor.opacity(0.6)
                            : theme.primaryBorder.opacity(
                                theme.isDark
                                    ? OnboardingStyle.borderOpacityDark
                                    : OnboardingStyle.borderOpacityLight
                            ),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: isSelected ? 2 : 1
            )
            .overlay(accentEdge)
    }

    private var accentEdge: some View {
        shape
            .strokeBorder(
                theme.accentColor.opacity(
                    isHovered || isSelected
                        ? OnboardingStyle.accentEdgeHoverOpacity
                        : OnboardingStyle.accentEdgeNormalOpacity
                ),
                lineWidth: 1
            )
            .mask(
                LinearGradient(
                    colors: [Color.white, Color.white.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}

// MARK: - Row Card Supporting Types

/// Trailing accessory for `OnboardingRowCard`.
enum OnboardingRowAccessory {
    case none
    case radio(isSelected: Bool)
    case chevron
}

/// Optional small text badge shown next to the title (e.g. "VLM", size, "Downloaded").
struct OnboardingRowBadge {
    enum Style {
        case neutral
        case success
        /// Yellow chip — used for the "Tight fit" capability hint.
        case warning
        /// Red chip — used for "Too large for this Mac" on disabled rows.
        case error
        /// Category chip whose color, icon, and label all come from the
        /// `ModelUseCase`. The badge's `text` field is unused for this
        /// style — `OnboardingBadgeChip` reads from the enum directly.
        case useCase(ModelUseCase)
    }

    let text: String
    let style: Style

    init(_ text: String, style: Style = .neutral) {
        self.text = text
        self.style = style
    }

    /// Convenience constructor for a use-case category badge.
    static func useCase(_ useCase: ModelUseCase) -> OnboardingRowBadge {
        OnboardingRowBadge(useCase.rawValue, style: .useCase(useCase))
    }
}

/// The leading icon for an `OnboardingRowCard`.
enum OnboardingRowIcon {
    case symbol(String)
    case view(AnyView)

    static func custom<V: View>(@ViewBuilder _ builder: () -> V) -> OnboardingRowIcon {
        .view(AnyView(builder()))
    }
}

// MARK: - Row Card

/// Single row card used across all onboarding lists (model picker, provider
/// picker, choose-path, complete options). Replaces the four near-identical
/// legacy cards with one component.
struct OnboardingRowCard: View {
    let icon: OnboardingRowIcon
    let title: String
    let subtitle: String?
    /// Muted third line rendered beneath `subtitle` (e.g. "Released Apr 2026").
    let secondaryLine: String?
    let badges: [OnboardingRowBadge]
    let accessory: OnboardingRowAccessory
    let isSelected: Bool
    /// When `true` the row is dimmed, the accessory is hidden, and the
    /// underlying button is disabled — used by the onboarding picker to
    /// keep too-large curated models visible (so the badge can explain
    /// why) without letting the user select one that won't run.
    let isDisabled: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    init(
        icon: OnboardingRowIcon,
        title: String,
        subtitle: String? = nil,
        secondaryLine: String? = nil,
        badges: [OnboardingRowBadge] = [],
        accessory: OnboardingRowAccessory = .none,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.secondaryLine = secondaryLine
        self.badges = badges
        self.accessory = accessory
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            OnboardingGlassCard(isSelected: isSelected && !isDisabled) {
                HStack(spacing: 14) {
                    iconView

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(LocalizedStringKey(title), bundle: .module)
                                .font(theme.font(size: 14, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if !badges.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                                        OnboardingBadgeChip(badge: badge)
                                    }
                                }
                                .layoutPriority(1)
                            }
                        }

                        if let subtitle = subtitle, !subtitle.isEmpty {
                            Text(LocalizedStringKey(subtitle), bundle: .module)
                                .font(theme.font(size: 12))
                                .foregroundColor(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(2)
                        }

                        if let secondaryLine = secondaryLine, !secondaryLine.isEmpty {
                            Text(secondaryLine)
                                .font(theme.font(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    accessoryView
                }
                .padding(.horizontal, OnboardingMetrics.cardPaddingH)
                .padding(.vertical, OnboardingMetrics.cardPaddingV)
                .opacity(isDisabled ? 0.55 : 1.0)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var iconView: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(theme.accentColor)
                    .blur(radius: 8)
                    .frame(
                        width: OnboardingMetrics.cardIcon - 8,
                        height: OnboardingMetrics.cardIcon - 8
                    )
            }

            Circle()
                .fill(isSelected ? theme.accentColor : theme.cardBackground)
                .frame(width: OnboardingMetrics.cardIcon, height: OnboardingMetrics.cardIcon)

            switch icon {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isSelected ? .white : theme.secondaryText)
            case .view(let view):
                view
            }
        }
    }

    @ViewBuilder
    private var accessoryView: some View {
        // A radio circle on a grayed row would read as "selectable but
        // unselected", so disabled rows drop the accessory entirely.
        if isDisabled {
            EmptyView()
        } else {
            switch accessory {
            case .none:
                EmptyView()
            case .radio(let selected):
                ZStack {
                    Circle()
                        .strokeBorder(
                            selected ? theme.accentColor : theme.primaryBorder,
                            lineWidth: selected ? 6 : 1.5
                        )
                        .frame(width: 20, height: 20)
                    if selected {
                        Circle().fill(Color.white).frame(width: 7, height: 7)
                    }
                }
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }
}

// MARK: - Badge Chip

/// Small chip used for `OnboardingRowCard` badges.
private struct OnboardingBadgeChip: View {
    let badge: OnboardingRowBadge

    @Environment(\.theme) private var theme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
    }

    var body: some View {
        switch badge.style {
        case .neutral:
            Text(badge.text)
                .font(theme.font(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(shape.fill(theme.secondaryBackground))
        case .success:
            iconChip(
                text: badge.text,
                icon: "checkmark.circle.fill",
                color: .green
            )
        case .warning:
            iconChip(
                text: badge.text,
                icon: "exclamationmark.triangle.fill",
                color: theme.warningColor
            )
        case .error:
            iconChip(
                text: badge.text,
                icon: "xmark.octagon.fill",
                color: theme.errorColor
            )
        case .useCase(let useCase):
            HStack(spacing: 3) {
                Image(systemName: useCase.iconName)
                    .font(.system(size: 9, weight: .semibold))
                Text(useCase.displayName, bundle: .module)
                    .font(theme.font(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(useCase.tintColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(shape.fill(useCase.tintColor.opacity(0.15)))
        }
    }

    /// Shared layout for the icon-prefixed chip styles
    /// (success / warning / error).
    private func iconChip(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(theme.font(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(shape.fill(color.opacity(0.15)))
    }
}
