//
//  SettingsCallout.swift
//  osaurus
//
//  A page-level notice: tinted glyph, title, message, optional actions.
//  For a state the user must act on before the page is useful ("Set up
//  your Osaurus Identity", "Osaurus Router is off"), not for row help.
//

import SwiftUI

struct SettingsCallout<Actions: View>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(18, enabled: baseComponentEnabled) }

    let icon: String
    /// Catalog keys.
    let title: String
    let message: String
    /// Status tone for the glyph and surface; nil draws a neutral surface.
    var tone: ThemeStatusKind?
    /// Someone's own words (a reviewer's note), shown verbatim and set off
    /// below the message.
    var quote: String?
    @ViewBuilder let actions: Actions

    init(
        icon: String,
        title: String,
        message: String,
        tone: ThemeStatusKind? = nil,
        quote: String? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.tone = tone
        self.quote = quote
        self.actions = actions()
    }

    private var tint: Color? {
        tone.map { theme.status[$0].foreground }
    }

    var body: some View {
        HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.18.elements.layout.settingsCallout.body.horizontalGap", inheriting: theme.space.s12)) {
            Image(systemName: icon)
                .glyphSize(.large, weight: .semibold)
                .foregroundColor(tint ?? theme.text.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.18.elements.layout.settingsCallout.body.verticalGap", inheriting: theme.space.s6)) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .assignedTypography("component.library.18.label", fallback: SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                if !message.isEmpty {
                    Text(LocalizedStringKey(message), bundle: .module)
                        .assignedTypography("component.library.18.caption", fallback: SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let quote {
                    let quoteFill = "component.library.18.elements.quote.background"
                    Text(verbatim: quote)
                        .font(SettingsFont.body)
                        .foregroundColor(theme.text.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(theme.space.s12)
                        .background(
                            theme.assignedColor(quoteFill, fallback: theme.surface.subtle),
                            in: RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        )
                        .nativeCatalogTarget([quoteFill], "Callout quote")
                }
                if Actions.self != EmptyView.self {
                    HStack(spacing: theme.catalogLayoutMetric("component.library.18.elements.layout.settingsCallout.body.horizontalGap2", inheriting: theme.space.s8)) { actions }.catalogLayoutTarget("component.library.18.elements.layout.settingsCallout.body.horizontalGap2")
                        .padding(.top, theme.space.s6)
                }
            }.catalogLayoutTarget("component.library.18.elements.layout.settingsCallout.body.verticalGap")
            .frame(maxWidth: .infinity, alignment: .leading)
        }.catalogLayoutTarget("component.library.18.elements.layout.settingsCallout.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.18.elements.layout.settingsCallout.body.padding.horizontal", inheriting: theme.space.s16)).padding(.vertical, theme.catalogLayoutMetric("component.library.18.elements.layout.settingsCallout.body.padding.vertical", inheriting: theme.space.s16)).catalogLayoutTarget("component.library.18.elements.layout.settingsCallout.body.padding.horizontal").catalogLayoutTarget("component.library.18.elements.layout.settingsCallout.body.padding.vertical")
        .assignedBaseChrome(18, fallback: tone.map { .status($0) } ?? .surface)
    }
}
