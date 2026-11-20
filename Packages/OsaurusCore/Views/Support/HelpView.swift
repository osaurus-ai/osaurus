//
//  HelpView.swift
//  osaurus
//
//  Help, a page of the main window (`ChatWindowState.MainSurface.help`),
//  opened from the rail. On one page:
//
//  - "Announcements": what the Osaurus team is announcing right now, still
//    here after its dialog was dismissed (`HelpAnnouncementCard`).
//  - "Report a Problem": pick what it is about, fill in the details, describe
//    it, review exactly what is sent, send (`HelpReportForm`).
//  - "Your Reports": the reports still in progress, with the team's replies.
//    A row opens the conversation (`HelpThreadView`); "All Reports" opens
//    every report, open and resolved (`HelpReportsListView`).
//  - "Other Ways to Get Help": the docs, Discord and GitHub issues.
//
//  Reports are tied to the Osaurus ID, so without one the page explains that
//  and links to Osaurus ID instead of showing a form that cannot send.
//

import SwiftUI

struct HelpView: View {
    @ObservedObject private var support = SupportService.shared
    @ObservedObject private var announcements = AnnouncementsService.shared
    @Environment(\.theme) private var theme

    /// Pages pushed over Help, last on top.
    @State private var path: [HelpRoute] = []

    /// Reports shown on the Help page itself; the rest are one click away.
    static let homeReportLimit = 3

    var body: some View {
        switch path.last {
        case .thread(let id)?:
            HelpThreadView(threadId: id)
                .settingsBackDestination(path.count > 1 ? L("All Reports") : L("Help"), verbatim: true) { pop() }
        case .allReports?:
            HelpReportsListView(onOpen: { push(.thread($0)) })
                .settingsBackDestination(L("Help"), verbatim: true) { pop() }
        case nil:
            helpPage
        }
    }

    private func push(_ route: HelpRoute) {
        withAnimation(theme.motion.quick) { path.append(route) }
    }

    private func pop() {
        withAnimation(theme.motion.quick) { _ = path.popLast() }
    }

    // MARK: - Page

    private var helpPage: some View {
        SettingsPage {
            HelpColumn(header: true) {
                SettingsPageHeader(
                    title: "Help",
                    subtitle: "Tell us what went wrong. We read every report and reply here.",
                    // Unread replies: the same number as the rail dot.
                    count: support.unreadCount > 0 ? support.unreadCount : nil,
                    onRefresh: hasIdentity ? { Task { await support.refreshIfDue(trigger: .helpOpened) } } : nil,
                    refreshHelp: "Check for replies",
                    isRefreshing: support.isRefreshing
                )
            }
        } content: {
            HelpColumn {
                if !announcements.standingAnnouncements.isEmpty {
                    announcementsSection
                }
                if hasIdentity {
                    HelpReportForm(onOpenThread: { push(.thread($0)) })
                    reportsSection
                } else {
                    identityRequiredSection
                }
                otherHelpSection
            }
        }
        .task { await support.refreshIfDue(trigger: .helpOpened) }
        // Same 30-minute throttle as activation, so an announcement the
        // team ended leaves this page without a request per visit.
        .task { await announcements.refreshIfDue(trigger: .activation) }
    }

    /// `existsCached()`: this recomputes on every body pass, and the
    /// synchronous keychain check can block the main thread. The signer
    /// still verifies the identity before any request is sent.
    private var hasIdentity: Bool { OsaurusIdentity.existsCached() }

    /// Live announcements, kept here after their dialog is dismissed.
    private var announcementsSection: some View {
        SettingsSection(title: "Announcements") {
            ForEach(announcements.standingAnnouncements) { announcement in
                HelpAnnouncementCard(announcement: announcement)
            }
        }
    }

    private var identityRequiredSection: some View {
        SettingsSection(title: "Report a Problem") {
            SettingsEmptyState(
                inline: "person.crop.circle.badge.questionmark",
                title: "Set up your Osaurus ID to get help here",
                hint: "Reports and replies are tied to your Osaurus ID, so we can answer you in the app.",
                action: .init(title: L("Open Osaurus ID"), icon: "person.crop.circle") {
                    AppDelegate.shared?.showManagementWindow(initialTab: .identity)
                }
            )
        }
    }

    // MARK: - Your Reports

    /// Reports still in progress, plus a resolved one with a reply the user
    /// has not read, newest first.
    static func homeThreads(_ threads: [OsaurusRouterSupportThread]) -> [OsaurusRouterSupportThread] {
        Array(threads.filter { $0.isOpen || $0.unread }.prefix(homeReportLimit))
    }

    private var reportsSection: some View {
        let shown = Self.homeThreads(support.threads)
        return SettingsSection(
            title: "Your Reports",
            footer: support.threads.isEmpty
                ? nil
                : "Replies show up here, and a dot on the Help icon means one is waiting."
        ) {
            if support.threads.isEmpty {
                if let error = support.refreshError, !support.hasLoaded {
                    SettingsEmptyState(
                        inline: "exclamationmark.triangle",
                        title: "Could not load your reports",
                        hint: error,
                        action: .init(title: L("Try Again"), icon: "arrow.clockwise") {
                            Task { await support.refreshIfDue(trigger: .helpOpened) }
                        }
                    )
                } else if !support.hasLoaded {
                    SettingsEmptyState(loading: "Loading your reports…")
                } else {
                    SettingsEmptyState(
                        inline: "tray",
                        title: "No reports yet",
                        hint: "Reports you send show up here, along with our replies."
                    )
                }
            } else {
                if shown.isEmpty {
                    SettingsEmptyState(
                        inline: "checkmark.circle",
                        title: "Nothing in progress",
                        hint: "Your resolved reports are under All Reports."
                    )
                }
                ForEach(shown) { thread in
                    HelpThreadRow(thread: thread) { push(.thread(thread.id)) }
                }
                SettingsNavigationRow(
                    icon: "tray.full",
                    title: "All Reports",
                    subtitle: L("Open and resolved"),
                    badge: support.threads.count
                ) { push(.allReports) }
            }
        }
    }

    // MARK: - Other Ways to Get Help

    private var otherHelpSection: some View {
        SettingsSection(title: "Other Ways to Get Help") {
            SettingsLinkRow(
                title: "Documentation",
                description: "Guides for agents, workflows, models and the iPhone app."
            ) { NSWorkspace.shared.open(OsaurusWebLinks.docs) }
            SettingsLinkRow(
                title: "Discord",
                description: "Ask the community and the Osaurus team."
            ) { NSWorkspace.shared.open(OsaurusWebLinks.discord) }
            SettingsLinkRow(
                title: "GitHub Issues",
                description: "Report a bug in public, or follow one that is already known."
            ) { NSWorkspace.shared.open(OsaurusWebLinks.githubIssues) }
        }
    }

    /// "Sent 3 hours ago" until the team answers, then "Updated …".
    static func activityLine(for thread: OsaurusRouterSupportThread, now: Date = Date()) -> String {
        guard let date = thread.lastActivityDate else { return "" }
        let when = date.formatted(.relative(presentation: .named))
        let activity = String(
            format: thread.lastStaffMessageAt == nil ? L("Sent %@") : L("Updated %@"),
            when
        )
        guard let category = thread.category else { return activity }
        return "\(category.shortLabel) · \(activity)"
    }
}

/// A page pushed over Help.
enum HelpRoute: Equatable {
    case allReports
    case thread(String)
}

/// One report in a list: subject, kind and last activity, unread chip,
/// status.
struct HelpThreadRow: View {
    let thread: OsaurusRouterSupportThread
    let action: () -> Void

    var body: some View {
        LibraryRow(
            title: thread.subject,
            subtitle: HelpView.activityLine(for: thread),
            showsChevron: true,
            action: action,
            badges: {
                if thread.unread {
                    StatusChip(L("New reply"), tone: .accent, showsDot: true)
                }
            },
            trailing: {
                HelpStatusChip(status: thread.status)
            }
        )
    }
}

// MARK: - Column

/// Help's pages read in the Workflows column, centered in the window, so a
/// wide window doesn't stretch the form. The header pads itself by the
/// page inset, so its column is that much wider to line up with the
/// sections.
struct HelpColumn<Content: View>: View {
    @Environment(\.theme) private var theme
    var header = false
    @ViewBuilder let content: Content

    init(header: Bool = false, @ViewBuilder content: () -> Content) {
        self.header = header
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.settingsSectionGap) { content }
            .frame(
                maxWidth: WorkflowLibraryLayout.columnWidth + (header ? 2 * theme.settingsPageInset : 0),
                alignment: .leading
            )
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Status Chip

/// One wording for a report's status on the list and on its page.
struct HelpStatusChip: View {
    let status: OsaurusRouterSupportThread.Status

    var body: some View {
        switch status {
        case .open:
            StatusChip(L("Waiting for us"), tone: .neutral)
        case .answered:
            StatusChip(L("Replied"), tone: .success)
        case .closed:
            StatusChip(L("Resolved"), tone: .neutral)
        }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        HelpView()
    }
#endif
