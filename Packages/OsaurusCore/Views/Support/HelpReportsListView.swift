//
//  HelpReportsListView.swift
//  osaurus
//
//  Every report this account has sent, pushed from Help's "All Reports".
//  Two tabs over the one list: reports still in progress, and resolved ones
//  (marked resolved by the user or closed by the team). A row opens the
//  conversation.
//

import SwiftUI

enum HelpReportsTab: String, CaseIterable, AnimatedTabItem {
    case open
    case resolved

    var title: String {
        switch self {
        case .open: return L("Open")
        case .resolved: return L("Resolved")
        }
    }

    func contains(_ thread: OsaurusRouterSupportThread) -> Bool {
        switch self {
        case .open: return thread.isOpen
        case .resolved: return !thread.isOpen
        }
    }
}

struct HelpReportsListView: View {
    let onOpen: (String) -> Void

    @ObservedObject private var support = SupportService.shared
    @Environment(\.theme) private var theme

    @State private var tab: HelpReportsTab = .open

    private var counts: [HelpReportsTab: Int] {
        Dictionary(uniqueKeysWithValues: HelpReportsTab.allCases.map { tab in
            (tab, support.threads.filter(tab.contains).count)
        })
    }

    /// Unread replies per tab, so a reply on a resolved report is findable.
    private var badges: [HelpReportsTab: Int] {
        Dictionary(uniqueKeysWithValues: HelpReportsTab.allCases.map { tab in
            (tab, support.threads.filter { tab.contains($0) && $0.unread }.count)
        })
    }

    var body: some View {
        SettingsPage {
            HelpColumn(header: true) {
                SettingsPageHeader(
                    title: "All Reports",
                    subtitle: "Everything you have sent, with our replies.",
                    onRefresh: { Task { await support.refreshIfDue(trigger: .helpOpened) } },
                    refreshHelp: "Check for replies",
                    isRefreshing: support.isRefreshing,
                    toolbar: {
                        SettingsTabsRow(selection: $tab, counts: counts, badges: badges, showSearch: false)
                    }
                )
            }
        } content: {
            HelpColumn {
                SettingsSection {
                    let threads = support.threads.filter(tab.contains)
                    if threads.isEmpty {
                        switch tab {
                        case .open:
                            SettingsEmptyState(
                                inline: "tray",
                                title: "No open reports",
                                hint: "Reports you send stay here until they are resolved."
                            )
                        case .resolved:
                            SettingsEmptyState(
                                inline: "checkmark.circle",
                                title: "No resolved reports",
                                hint: "Reports you mark as resolved, or that we close, move here."
                            )
                        }
                    } else {
                        ForEach(threads) { thread in
                            HelpThreadRow(thread: thread) { onOpen(thread.id) }
                        }
                    }
                }
            }
        }
        .onAppear {
            if tab == .open, counts[.open] == 0, counts[.resolved, default: 0] > 0 {
                tab = .resolved
            }
        }
    }
}
