//
//  AnimatedTabSelector.swift
//  osaurus
//
//  Modern animated tab selector with sliding indicator using matchedGeometryEffect.
//  Used for sub-navigation within Models and Tools views.
//

import SwiftUI

// MARK: - Tab Item Protocol

protocol AnimatedTabItem: Hashable, CaseIterable {
    var title: String { get }
}

// MARK: - Animated Tab Selector

struct AnimatedTabSelector<Tab: AnimatedTabItem>: View where Tab.AllCases: RandomAccessCollection {
    @Environment(\.theme) private var theme
    @Binding var selection: Tab
    let counts: [Tab: Int]?
    let badges: [Tab: Int]?

    @Namespace private var tabNamespace

    init(
        selection: Binding<Tab>,
        counts: [Tab: Int]? = nil,
        badges: [Tab: Int]? = nil
    ) {
        self._selection = selection
        self.counts = counts
        self.badges = badges
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Tab.allCases), id: \.self) { tab in
                AnimatedTabButton(
                    tab: tab,
                    isSelected: selection == tab,
                    count: counts?[tab],
                    badge: badges?[tab],
                    namespace: tabNamespace
                ) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        selection = tab
                    }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.tertiaryBackground.opacity(0.6))
        )
    }
}

// MARK: - Animated Tab Button

private struct AnimatedTabButton<Tab: AnimatedTabItem>: View {
    @Environment(\.theme) private var theme

    let tab: Tab
    let isSelected: Bool
    let count: Int?
    let badge: Int?
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)

                if let count = count {
                    Text("(\(count))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(isSelected ? theme.secondaryText : theme.tertiaryText)
                }

                if let badge = badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange)
                        )
                }
            }
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.cardBackground)
                            .shadow(
                                color: theme.shadowColor.opacity(theme.shadowOpacity),
                                radius: 4,
                                x: 0,
                                y: 2
                            )
                            .matchedGeometryEffect(id: "tab_indicator", in: namespace)
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.secondaryBackground.opacity(0.5))
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Tools Tab (for ToolsManagerView)

enum ToolsTab: String, CaseIterable, AnimatedTabItem {
    case available = "Available"
    case plugins = "Plugins"
    case remote = "Remote"

    var title: String { rawValue }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var modelTab: ModelListTab = .all
        @State private var toolsTab: ToolsTab = .available

        var body: some View {
            VStack(spacing: 40) {
                AnimatedTabSelector(
                    selection: $modelTab,
                    counts: [.all: 150, .suggested: 12, .downloaded: 3]
                )

                AnimatedTabSelector(
                    selection: $toolsTab,
                    counts: [.available: 8, .plugins: 24, .remote: 2],
                    badges: [.available: 2]
                )
            }
            .padding(40)
            .background(Color(hex: "f9fafb"))
        }
    }

    return PreviewWrapper()
}
