//
//  SettingsFeatureCards.swift
//  osaurus
//
//  A row of equal explainer cards: what a page does, at a glance. `.leading`
//  orients a populated page (Orchestrator); `.centered` is the example trio
//  inside a hero `SettingsEmptyState`.
//

import SwiftUI

struct SettingsFeature {
    let icon: String
    /// Catalog key.
    let title: String
    /// Catalog key.
    let caption: String
    /// Makes a `.centered` card a shortcut. Without one it reads as an
    /// explanation: no card surface, so it doesn't look clickable.
    var action: (() -> Void)? = nil
}

struct SettingsFeatureCards: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var enabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(13, enabled: enabled) }

    enum Style {
        case leading
        case centered
    }

    let features: [SettingsFeature]
    var style: Style = .leading

    var body: some View {
        HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.13.elements.layout.settingsFeatureCards.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s12))) {
            ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                switch style {
                case .leading: leadingCard(feature)
                case .centered: CenteredFeatureCard(feature: feature)
                }
            }
        }.catalogLayoutTarget("component.library.13.elements.layout.settingsFeatureCards.body.horizontalGap")
        // Equal heights: a card whose caption wraps doesn't stand taller.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func leadingCard(_ feature: SettingsFeature) -> some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.13.elements.layout.settingsFeatureCards.leadingCard.verticalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s8))) {
            HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.13.elements.layout.settingsFeatureCards.leadingCard.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s8))) {
                Image(systemName: feature.icon)
                    .glyphSize(.micro, weight: .semibold)
                    .foregroundColor(theme.text.primary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(theme.surface.selected))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .accessibilityHidden(true)
                // Wraps rather than truncates when three cards share a narrow page.
                title(feature)
                    .assignedTypography("component.library.13.heading", fallback: SettingsFont.compactLabel)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }.catalogLayoutTarget("component.library.13.elements.layout.settingsFeatureCards.leadingCard.horizontalGap")
            caption(feature)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.catalogLayoutTarget("component.library.13.elements.layout.settingsFeatureCards.leadingCard.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.13.elements.layout.settingsFeatureCards.leadingCard.padding.horizontal", inheriting: theme.catalogMetric("padding", fallback: theme.space.s16))).padding(.vertical, theme.catalogLayoutMetric("component.library.13.elements.layout.settingsFeatureCards.leadingCard.padding.vertical", inheriting: theme.catalogMetric("padding", fallback: theme.space.s16))).catalogLayoutTarget("component.library.13.elements.layout.settingsFeatureCards.leadingCard.padding.horizontal").catalogLayoutTarget("component.library.13.elements.layout.settingsFeatureCards.leadingCard.padding.vertical")
        .frame(minHeight: theme.catalogMetric("height", fallback: 0))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .assignedBaseChrome(13, fallback: .card)
        .accessibilityElement(children: .combine)
    }

    private func title(_ feature: SettingsFeature) -> some View {
        featureTitle(feature, theme: theme)
    }

    private func caption(_ feature: SettingsFeature) -> some View {
        featureCaption(feature, theme: theme)
    }
}

private struct CenteredFeatureCard: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var enabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(13, enabled: enabled) }

    let feature: SettingsFeature
    @State private var isHovered = false

    var body: some View {
        if let action = feature.action {
            content
                .assignedBaseChrome(13, fallback: isHovered ? .cardHover : .card)
                .contentShape(RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous))
                .onTapGesture { if enabled { action() } }
                .assignedBaseKeyboardButton(13, action: action)
                .pointingHandCursor()
                .onHover { hovering in
                    withAnimation(theme.motion.quick) { isHovered = hovering }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default) { if enabled { action() } }
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        VStack(spacing: theme.catalogLayoutMetric("component.library.13.elements.layout.settingsFeatureCards.centeredCard.verticalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s10))) {
            SettingsIconTile(icon: feature.icon, size: 32)
                .accessibilityHidden(true)
            VStack(spacing: theme.catalogLayoutMetric("component.library.13.elements.layout.settingsFeatureCards.centeredCard.verticalGap2", inheriting: theme.catalogMetric("gap", fallback: theme.space.s4))) {
                title(feature)
                    .assignedTypography("component.library.13.heading", fallback: SettingsFont.rowTitle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                caption(feature)
                    .multilineTextAlignment(.center)
            }.catalogLayoutTarget("component.library.13.elements.layout.settingsFeatureCards.centeredCard.verticalGap2")
        }.catalogLayoutTarget("component.library.13.elements.layout.settingsFeatureCards.centeredCard.verticalGap")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.13.elements.layout.settingsFeatureCards.centeredCard.paddingX", inheriting: theme.catalogMetric("padding", fallback: theme.space.s12))).catalogLayoutTarget("component.library.13.elements.layout.settingsFeatureCards.centeredCard.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.13.elements.layout.settingsFeatureCards.centeredCard.paddingY", inheriting: theme.catalogMetric("padding", fallback: theme.space.s16))).catalogLayoutTarget("component.library.13.elements.layout.settingsFeatureCards.centeredCard.paddingY")
        .frame(minHeight: theme.catalogMetric("height", fallback: 0))
    }

    private func title(_ feature: SettingsFeature) -> some View {
        featureTitle(feature, theme: theme)
    }

    private func caption(_ feature: SettingsFeature) -> some View {
        featureCaption(feature, theme: theme)
    }
}

@MainActor
private func featureTitle(_ feature: SettingsFeature, theme: any ThemeProtocol) -> some View {
    Text(LocalizedStringKey(feature.title), bundle: .module)
        .foregroundColor(theme.text.primary)
}

@MainActor
private func featureCaption(_ feature: SettingsFeature, theme: any ThemeProtocol) -> some View {
    Text(LocalizedStringKey(feature.caption), bundle: .module)
        .assignedTypography("component.library.13.text", fallback: SettingsFont.rowDescription)
        .foregroundColor(theme.text.secondary)
        .fixedSize(horizontal: false, vertical: true)
}
