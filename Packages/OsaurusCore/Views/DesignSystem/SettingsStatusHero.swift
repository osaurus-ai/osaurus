//
//  SettingsStatusHero.swift
//  osaurus
//
//  The one live value a page is about (a server URL, a pairing code) with
//  its state beside it and the next action under it.
//

import AppKit
import SwiftUI

struct SettingsStatusHero<Status: View, Actions: View>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(12, enabled: baseComponentEnabled) }

    /// Catalog key; nil when the enclosing section already titles it.
    var title: String?
    var icon: String?
    /// Catalog key for the caption above the value.
    let valueLabel: String
    /// Rendered verbatim.
    let value: String
    /// Already-localized VoiceOver reading of `value` (codes read digit by digit).
    var valueAccessibilityLabel: String?
    var copyable: Bool
    /// Catalog key for the caption above `status`; nil for none.
    var statusLabel: String?
    @ViewBuilder let status: Status
    /// `SettingsButton` / `SettingsMenuButton` only; counts go in a
    /// `SettingsStatStrip` below the hero, not here.
    @ViewBuilder let actions: Actions

    init(
        title: String? = nil,
        icon: String? = nil,
        valueLabel: String,
        value: String,
        valueAccessibilityLabel: String? = nil,
        copyable: Bool = true,
        statusLabel: String? = "Status",
        @ViewBuilder status: () -> Status,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.icon = icon
        self.valueLabel = valueLabel
        self.value = value
        self.valueAccessibilityLabel = valueAccessibilityLabel
        self.copyable = copyable
        self.statusLabel = statusLabel
        self.status = status()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatusHero.body.verticalGap", inheriting: theme.space.s16)) {
            if let title {
                Label {
                    Text(LocalizedStringKey(title), bundle: .module)
                } icon: {
                    if let icon { Image(systemName: icon) }
                }
                .assignedTypography("component.library.12.heading", fallback: SettingsFont.sectionTitle)
                .foregroundColor(theme.text.primary)
            }

            HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatusHero.body.horizontalGap", inheriting: theme.space.s16)) {
                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatusHero.body.verticalGap2", inheriting: theme.space.s8)) {
                    caption(valueLabel)
                    HStack(spacing: theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatusHero.body.horizontalGap2", inheriting: theme.space.s8)) {
                        Text(verbatim: value)
                            .assignedTypography("component.library.12.text", fallback: SettingsFont.mono)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 0, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.horizontal, theme.space.s12)
                            .padding(.vertical, theme.space.s8)
                            .settingsChrome(.control)
                            .accessibilityLabel(Text(verbatim: valueAccessibilityLabel ?? value))
                        if copyable {
                            SettingsIconButton("doc.on.doc", help: "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(value, forType: .string)
                            }
                        }
                    }.catalogLayoutTarget("component.library.12.elements.layout.settingsStatusHero.body.horizontalGap2")
                }.catalogLayoutTarget("component.library.12.elements.layout.settingsStatusHero.body.verticalGap2")
                .frame(minWidth: 0, alignment: .leading)

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatusHero.body.verticalGap3", inheriting: theme.space.s8)) {
                    if let statusLabel { caption(statusLabel) }
                    status.environment(\.theme, theme)
                }.catalogLayoutTarget("component.library.12.elements.layout.settingsStatusHero.body.verticalGap3")
                .fixedSize()
                .layoutPriority(1)
            }.catalogLayoutTarget("component.library.12.elements.layout.settingsStatusHero.body.horizontalGap")

            if Actions.self != EmptyView.self {
                HStack(spacing: theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatusHero.body.horizontalGap3", inheriting: theme.space.s8)) { actions }.catalogLayoutTarget("component.library.12.elements.layout.settingsStatusHero.body.horizontalGap3")
            }
        }.catalogLayoutTarget("component.library.12.elements.layout.settingsStatusHero.body.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatusHero.body.padding.horizontal", inheriting: theme.space.s16)).padding(.vertical, theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatusHero.body.padding.vertical", inheriting: theme.space.s16)).catalogLayoutTarget("component.library.12.elements.layout.settingsStatusHero.body.padding.horizontal").catalogLayoutTarget("component.library.12.elements.layout.settingsStatusHero.body.padding.vertical")
        .frame(maxWidth: .infinity, alignment: .leading)
        .assignedBaseChrome(12, fallback: .inset)
    }

    private func caption(_ key: String) -> some View {
        Text(LocalizedStringKey(key), bundle: .module)
            .assignedTypography("component.library.12.caption", fallback: SettingsFont.compactLabel)
            .foregroundColor(theme.text.secondary)
    }
}
