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
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ServerSettingsSectionGroup.allCases, id: \.self) { group in
                    groupBlock(group)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .scrollIndicators(.hidden)
    }

    private func groupBlock(_ group: ServerSettingsSectionGroup) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(LocalizedStringKey(group.title), bundle: .module)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText.opacity(0.7))
                .padding(.leading, 10)
                .padding(.bottom, 4)

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
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isSelected ? theme.accentColor : .clear)
                    .frame(width: 2)
                    .padding(.vertical, 2)

                Text(LocalizedStringKey(section.title), bundle: .module)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                    .padding(.leading, 10)
                    .padding(.vertical, 5)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
