//
//  SettingsStatStrip.swift
//  osaurus
//
//  Labeled read-only metrics ("Total Calls 42", "Uptime 3h 2m"). `.divided`
//  is one row of equal columns for a section's headline numbers; `.tiles`
//  is a grid of small wells for live resource readings.
//

import SwiftUI

struct SettingsStat: Identifiable {
    /// Catalog key.
    let label: String
    /// Rendered verbatim.
    let value: String
    var icon: String? = nil
    /// A status color for the value (a nonzero failure count).
    var valueTint: Color? = nil

    var id: String { label }
}

struct SettingsStatStrip: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var enabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(12, enabled: enabled) }

    enum Style {
        case divided
        case tiles(columns: Int)
    }

    let stats: [SettingsStat]
    var style: Style = .divided
    /// `.tiles` only: makes each tile a toggle that selects its stat's
    /// `id`; tapping the selected tile clears it.
    var selection: Binding<String?>? = nil

    var body: some View {
        switch style {
        case .divided: divided
        case .tiles(let columns): tiles(columns: columns)
        }
    }

    private var divided: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatStrip.divided.horizontalGap", inheriting: theme.space.s0)) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0 {
                    ThemeHairlineDivider(axis: .vertical).frame(height: 36)
                }
                VStack(spacing: theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatStrip.divided.verticalGap", inheriting: theme.space.s2)) {
                    Text(verbatim: stat.value)
                        .assignedTypography("component.library.12.text", fallback: SettingsFont.cardTitle)
                        .foregroundColor(stat.valueTint ?? theme.text.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    label(stat)
                }.catalogLayoutTarget("component.library.12.elements.layout.settingsStatStrip.divided.verticalGap")
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }.catalogLayoutTarget("component.library.12.elements.layout.settingsStatStrip.divided.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatStrip.divided.padding.horizontal", inheriting: theme.space.s0)).padding(.vertical, theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatStrip.divided.padding.vertical", inheriting: theme.space.s0)).catalogLayoutTarget("component.library.12.elements.layout.settingsStatStrip.divided.padding.horizontal").catalogLayoutTarget("component.library.12.elements.layout.settingsStatStrip.divided.padding.vertical")
        .frame(minHeight: theme.catalogMetric("height", fallback: 0))
        .assignedBaseChrome(12, fallback: nil)
    }

    private func tiles(columns: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: theme.space.s8),
                count: max(1, columns)
            ),
            spacing: theme.space.s8
        ) {
            ForEach(stats) { stat in
                if let selection {
                    let isSelected = selection.wrappedValue == stat.id
                    Button {
                        selection.wrappedValue = isSelected ? nil : stat.id
                    } label: {
                        tile(stat, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                } else {
                    tile(stat, isSelected: false)
                }
            }
        }
    }

    private func tile(_ stat: SettingsStat, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatStrip.tiles.verticalGap", inheriting: theme.space.s6)) {
            label(stat)
            Text(verbatim: stat.value)
                .assignedTypography("component.library.12.text", fallback: SettingsFont.mono)
                .foregroundColor(stat.valueTint ?? theme.text.primary)
                .lineLimit(1)
        }.catalogLayoutTarget("component.library.12.elements.layout.settingsStatStrip.tiles.verticalGap")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatStrip.tiles.padding.horizontal", inheriting: theme.space.s8)).padding(.vertical, theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatStrip.tiles.padding.vertical", inheriting: theme.space.s8)).catalogLayoutTarget("component.library.12.elements.layout.settingsStatStrip.tiles.padding.horizontal").catalogLayoutTarget("component.library.12.elements.layout.settingsStatStrip.tiles.padding.vertical")
        .frame(minHeight: theme.catalogMetric("height", fallback: 0))
        .assignedBaseChrome(12, fallback: isSelected ? .selected : .control, selected: isSelected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func label(_ stat: SettingsStat) -> some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.12.elements.layout.settingsStatStrip.label.horizontalGap", inheriting: theme.space.s4)) {
            if let icon = stat.icon {
                Image(systemName: icon)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.secondary)
                    .accessibilityHidden(true)
            }
            Text(LocalizedStringKey(stat.label), bundle: .module)
                .assignedTypography("component.library.12.caption", fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(1)
        }.catalogLayoutTarget("component.library.12.elements.layout.settingsStatStrip.label.horizontalGap")
    }
}
