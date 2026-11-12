//
//  ServerSettingsSidebarNav.swift
//  osaurus
//
//  Left-rail "minimap" for the Server → Settings tab. Pure
//  navigation: renders the `ServerSettingsSection` anchors grouped by
//  `ServerSettingsSectionGroup` and reports the user's selection to
//  the parent, which drives the `ScrollViewReader` scroll.
//
//  Visual treatment is deliberately lightweight — no background fill,
//  no trailing divider, no selection pill. The active row is marked
//  by a thin accent bar pinned to the left edge, the way an outline /
//  minimap usually highlights "you are here". This keeps the content
//  pane visually dominant while giving users a quick reference index.
//

import SwiftUI

struct ServerSettingsSidebarNav: View {
    @Binding var selection: ServerSettingsSection

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s14) {
                ForEach(ServerSettingsSectionGroup.allCases, id: \.self) { group in
                    groupBlock(group)
                }
            }
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .scrollIndicators(.hidden)
    }

    private func groupBlock(_ group: ServerSettingsSectionGroup) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(LocalizedStringKey(group.title), bundle: .module)
                .font(SettingsFont.chip)
                .foregroundColor(theme.text.tertiary)
                .padding(.leading, theme.space.s8)
                .padding(.bottom, theme.space.s4)

            ForEach(group.sections) { section in
                row(section)
            }
        }
    }

    @ViewBuilder
    private func row(_ section: ServerSettingsSection) -> some View {
        let isSelected = selection == section
        Button {
            selection = section
        } label: {
            HStack(spacing: theme.space.s0) {
                Rectangle()
                    .fill(isSelected ? theme.action.primary.default.background : .clear)
                    .frame(width: 2)
                    .padding(.vertical, theme.space.s2)

                Text(LocalizedStringKey(section.title), bundle: .module)
                    .textStyle(.caption, weight: isSelected ? 600 : 400)
                    .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)
                    .padding(.leading, theme.space.s8)
                    .padding(.vertical, theme.space.s6)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
