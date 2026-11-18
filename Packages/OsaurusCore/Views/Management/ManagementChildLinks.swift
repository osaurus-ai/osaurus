//
//  ManagementChildLinks.swift
//  osaurus
//
//  Drill-in rows from a category page to its child tabs (Chat → Commands,
//  Themes; Osaurus ID → Wallet & Credits, Workspaces; …), and the container
//  a child tab renders in: a back bar to its parent above the page.
//

import SwiftUI

/// A group of navigation rows for `parent.children`. Badges mirror the ones
/// the sidebar used to show on those tabs.
struct ManagementChildLinks: View {
    let parent: ManagementTab
    var title: String? = nil
    /// Restricts / reorders the rows; defaults to every child.
    var tabs: [ManagementTab]? = nil

    var body: some View {
        SettingsSection(title: title) {
            ManagementChildLinkRows(parent: parent, tabs: tabs)
        }
    }
}

/// The rows of `ManagementChildLinks` without their group, for a page that
/// puts every link it has in one group.
struct ManagementChildLinkRows: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var badgeStore = ManagementBadgeStore.shared
    @ObservedObject private var stateManager = ManagementStateManager.shared

    let parent: ManagementTab
    var tabs: [ManagementTab]? = nil

    var body: some View {
        ForEach(tabs ?? parent.children) { child in
            SettingsNavigationRow(
                icon: child.icon,
                title: child.label,
                subtitle: child.subtitle,
                badge: badgeStore.snapshot.counts[child],
                badgeHighlight: badgeStore.snapshot.highlights.contains(child)
            ) {
                withAnimation(theme.motion.quick) {
                    stateManager.selectedTab = child
                }
            }
        }
    }
}

/// A child tab's page, whose header draws a back line to its parent category.
struct ManagementChildContainer<Content: View>: View {
    @ObservedObject private var stateManager = ManagementStateManager.shared

    let tab: ManagementTab
    @ViewBuilder let content: Content

    var body: some View {
        if let parent = tab.parent {
            content
                .settingsBackDestination(parent.label, verbatim: true) {
                    stateManager.selectedTab = parent
                }
        } else {
            content
        }
    }
}
