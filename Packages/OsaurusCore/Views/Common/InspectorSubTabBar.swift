//
//  InspectorSubTabBar.swift
//  osaurus
//
//  Small underlined tabs over a hairline, for switching views inside one
//  inspector lens: Design | Test in the Draft lens, Chats | Runs in
//  History. A tab can carry a count and a badge (something needs you, or
//  something is running).
//

import SwiftUI

struct InspectorSubTabBar<Value: Hashable>: View {
    enum Badge: Equatable {
        /// Something in the tab waits for the user.
        case attention
        /// Something in the tab is running.
        case activity
    }

    struct Tab: Identifiable {
        let value: Value
        let title: String
        var count: Int?
        var badge: Badge?
        var id: Value { value }

        init(_ value: Value, _ title: String, count: Int? = nil, badge: Badge? = nil) {
            self.value = value
            self.title = title
            self.count = count
            self.badge = badge
        }
    }

    @Binding var selection: Value
    let tabs: [Tab]
    var horizontalPadding: CGFloat = 14

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            ForEach(tabs) { tab in
                button(tab)
            }
            Spacer()
        }
        .padding(.horizontal, horizontalPadding)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border.default).frame(height: 1)
        }
    }

    private func button(_ tab: Tab) -> some View {
        let selected = selection == tab.value
        return Button {
            selection = tab.value
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: tab.title)
                    .font(
                        theme.font(
                            size: theme.pointSize(.bodySmall),
                            weight: selected ? .semibold : .medium
                        )
                    )
                    .foregroundColor(selected ? theme.text.primary : theme.text.secondary)
                if let count = tab.count {
                    Text(verbatim: "\(count)")
                        .textStyle(.footnote, weight: 500)
                        .monospacedDigit()
                        .foregroundColor(theme.text.tertiary)
                }
                switch tab.badge {
                case .attention:
                    Circle().fill(theme.status.warning.foreground).frame(width: 6, height: 6)
                case .activity:
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                case nil:
                    EmptyView()
                }
            }
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(selected ? theme.action.primary.default.background : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
