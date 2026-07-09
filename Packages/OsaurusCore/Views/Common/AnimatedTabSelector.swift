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
    /// Tabs to render, in order. Defaults to every case; callers with a
    /// dynamic subset (e.g. Themes only shows filters that have results) pass
    /// their own list so empty tabs don't clutter the selector.
    let tabs: [Tab]
    let counts: [Tab: Int]?
    let badges: [Tab: Int]?

    @Namespace private var tabNamespace

    init(
        selection: Binding<Tab>,
        tabs: [Tab]? = nil,
        counts: [Tab: Int]? = nil,
        badges: [Tab: Int]? = nil
    ) {
        self._selection = selection
        self.tabs = tabs ?? Array(Tab.allCases)
        self.counts = counts
        self.badges = badges
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { tab in
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
                    Text("(\(count))", bundle: .module)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(isSelected ? theme.secondaryText : theme.tertiaryText)
                }

                if let badge = badge, badge > 0 {
                    Text("\(badge)", bundle: .module)
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
                // Previously used `.matchedGeometryEffect(id: "tab_indicator",
                // in: namespace)` inside the `isSelected` branch. Every
                // `AnimatedTabButton` shares the same namespace + id, so during
                // selection transitions SwiftUI can briefly have two rows both
                // claim to be the geometry source, tripping a Debug-only
                // precondition (same crash signature as SidebarNavigation).
                // Switched to a conditional fill + animation: keeps the
                // selected-fade + shadow, drops the cross-row slide that the
                // geometry effect was providing.
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? theme.cardBackground
                            : (isHovering ? theme.secondaryBackground.opacity(0.5) : Color.clear)
                    )
                    .shadow(
                        color: isSelected
                            ? theme.shadowColor.opacity(theme.shadowOpacity) : .clear,
                        radius: isSelected ? 4 : 0,
                        x: 0,
                        y: isSelected ? 2 : 0
                    )
                    .animation(.easeOut(duration: 0.2), value: isSelected)
                    .animation(.easeOut(duration: 0.15), value: isHovering)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Tools Tab (for ToolsManagerView)

enum ToolsTab: String, CaseIterable, AnimatedTabItem {
    case available = "Available"
    case remote = "Remote"
    case sandbox = "Sandbox"

    var title: String {
        switch self {
        case .available: return L("Available")
        case .remote: return L("Remote")
        case .sandbox: return L("Sandbox")
        }
    }
}

// MARK: - Skills Tab (for SkillsView)

enum SkillsTab: String, CaseIterable, AnimatedTabItem {
    case all = "All"
    case installed = "Installed"
    case defaults = "Default"

    var title: String {
        switch self {
        case .all: return L("All")
        case .installed: return L("Installed")
        case .defaults: return L("Default")
        }
    }
}

// MARK: - Plugins Tab (for PluginsView)

enum PluginsTab: String, CaseIterable, AnimatedTabItem {
    case installed = "Installed"
    case browse = "Browse"
    case claude = "Claude Plugins"

    var title: String {
        switch self {
        case .installed: return L("Installed")
        case .browse: return L("Browse")
        case .claude: return L("Claude Plugins")
        }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        struct PreviewWrapper: View {
            @State private var modelTab: ModelListTab = .all
            @State private var toolsTab: ToolsTab = .available
            @State private var pluginsTab: PluginsTab = .installed

            var body: some View {
                VStack(spacing: 40) {
                    AnimatedTabSelector(
                        selection: $modelTab,
                        counts: [.all: 150, .downloaded: 3]
                    )

                    AnimatedTabSelector(
                        selection: $toolsTab,
                        counts: [.available: 8, .remote: 2]
                    )

                    AnimatedTabSelector(
                        selection: $pluginsTab,
                        counts: [.installed: 3, .browse: 24],
                        badges: [.browse: 2]
                    )
                }
                .padding(40)
                .background(Color(hex: "f9fafb"))
            }
        }

        return PreviewWrapper()
    }
#endif
