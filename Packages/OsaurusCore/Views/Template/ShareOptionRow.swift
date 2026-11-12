//
//  ShareOptionRow.swift
//  osaurus
//
//  One choice in a short list: an icon, a title, one line of detail, and
//  either a check (a setting with a current value) or a chevron (a step
//  to take). Used for Save as File / Publish and for Public / Unlisted /
//  Password, so the two decisions in sharing read the same way.
//

import SwiftUI

struct ShareOptionRow<Trailing: View>: View {
    @Environment(\.theme) private var theme

    let icon: String
    let title: String
    let detail: String
    /// nil: a step (chevron). true/false: a setting (check when selected).
    var isSelected: Bool? = nil
    var isEnabled = true
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    @State private var isHovered = false

    init(
        icon: String, title: String, detail: String, isSelected: Bool? = nil, isEnabled: Bool = true,
        action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
        self.trailing = trailing()
    }

    private var selected: Bool { isSelected == true }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: theme.space.s12) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(selected ? theme.surface.selected : theme.surface.hover)
                    Image(systemName: icon)
                        .glyphSize(.body, weight: .medium)
                        .foregroundColor(selected ? theme.text.link : theme.text.secondary)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(verbatim: title)
                        .font(SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                    Text(verbatim: detail)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailing

                if let isSelected {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .glyphSize(.medium, weight: .medium)
                        .foregroundColor(isSelected ? theme.text.link : theme.border.strong)
                } else {
                    Image(systemName: "chevron.right")
                        .glyphSize(.footnote, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s12)
            .settingsChrome(isHovered && isEnabled ? .cardHover : .card)
            .contentShape(RoundedRectangle(cornerRadius: theme.radius.large))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
    }
}

extension ShareOptionRow where Trailing == EmptyView {
    init(
        icon: String, title: String, detail: String, isSelected: Bool? = nil, isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.init(
            icon: icon, title: title, detail: detail, isSelected: isSelected, isEnabled: isEnabled, action: action
        ) { EmptyView() }
    }
}

