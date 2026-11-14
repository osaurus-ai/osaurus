//
//  HelpView.swift
//  osaurus
//
//  Settings → Help. Two things on one page:
//
//  - "Report a Problem": describe what went wrong, see exactly what is sent
//    with it, tick the Terms and Privacy box, send.
//  - "Your Reports": everything this account has sent, with the team's
//    replies. A row opens the conversation (`HelpThreadView`).
//
//  Reports are tied to the Osaurus ID, so without one the page explains that
//  and links to Osaurus ID instead of showing a form that cannot send.
//

import SwiftUI

struct HelpView: View {
    @ObservedObject private var support = SupportService.shared
    @Environment(\.theme) private var theme

    @State private var openThreadId: String?
    @State private var description = ""
    @State private var hasConsented = false
    /// What is attached to the report. Built when the page appears and sent
    /// as-is, so the preview and the request are the same value.
    @State private var report: SupportReport?
    @State private var showsIncluded = false
    @State private var isSending = false
    @State private var sendError: String?
    @State private var didSend = false

    var body: some View {
        if let openThreadId {
            HelpThreadView(threadId: openThreadId)
                .settingsBackDestination(L("Help"), verbatim: true) {
                    withAnimation(theme.motion.quick) { self.openThreadId = nil }
                }
        } else {
            helpPage
        }
    }

    // MARK: - Page

    private var helpPage: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Help",
                subtitle: "Tell us what went wrong. We read every report and reply here.",
                // Unread replies: the same number as the sidebar badge and
                // the rail dot, read from the source the badge store reads.
                count: support.unreadCount > 0 ? support.unreadCount : nil,
                onRefresh: hasIdentity ? { Task { await support.refreshIfDue(trigger: .helpOpened) } } : nil,
                refreshHelp: "Check for replies",
                isRefreshing: support.isRefreshing
            )
        } content: {
            if hasIdentity {
                reportSection
                reportsSection
            } else {
                identityRequiredSection
            }
        }
        .task {
            description = support.draftDescription
            report = await SupportReportBuilder.buildCurrent()
            await support.refreshIfDue(trigger: .helpOpened)
        }
        .onChange(of: description) { _, value in
            support.draftDescription = value
            if didSend, !value.isEmpty { didSend = false }
        }
    }

    /// `existsCached()`: this recomputes on every body pass, and the
    /// synchronous keychain check can block the main thread. The signer
    /// still verifies the identity before any request is sent.
    private var hasIdentity: Bool { OsaurusIdentity.existsCached() }

    private var identityRequiredSection: some View {
        SettingsSection(title: "Report a Problem", anchorId: "help.report") {
            SettingsEmptyState(
                inline: "person.crop.circle.badge.questionmark",
                title: "Set up your Osaurus ID to get help here",
                hint: "Reports and replies are tied to your Osaurus ID, so we can answer you in the app.",
                action: .init(title: L("Open Osaurus ID"), icon: "person.crop.circle") {
                    ManagementStateManager.shared.selectedTab = .identity
                }
            )
        }
    }

    // MARK: - Report a Problem

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isTooLong: Bool {
        trimmedDescription.count > OsaurusRouterSupportLimits.maxMessageLength
    }

    private var isLongEnough: Bool {
        trimmedDescription.count >= OsaurusRouterSupportLimits.minDescriptionLength
    }

    /// The router allows three reports that are not closed. Say so before
    /// the user writes a fourth, rather than after they press Send.
    private var isAtOpenLimit: Bool {
        support.openThreadCount >= OsaurusRouterSupportLimits.maxOpenThreads
    }

    private var canSend: Bool {
        hasConsented && isLongEnough && !isTooLong && !isSending && !isAtOpenLimit && report != nil
    }

    private var descriptionHint: String {
        if isTooLong {
            return String(
                format: L("%1$lld characters over the %2$lld character limit."),
                trimmedDescription.count - OsaurusRouterSupportLimits.maxMessageLength,
                OsaurusRouterSupportLimits.maxMessageLength
            )
        }
        return L("What you did, what you expected, and what happened instead. Please do not paste passwords or keys.")
    }

    private var reportSection: some View {
        SettingsSection(title: "Report a Problem", anchorId: "help.report") {
            if isAtOpenLimit {
                SettingsEmptyState(
                    inline: "tray.full",
                    title: "You have 3 open reports",
                    hint: "Add to one of them below. You can send a new report once one is closed."
                )
            } else {
                SettingsFieldRow(label: "What went wrong?", hint: descriptionHint, verbatimHint: true) {
                    SettingsTextEditor(
                        text: $description,
                        placeholder: L("Describe the problem"),
                        minHeight: 120,
                        maxHeight: 280,
                        isInvalid: isTooLong
                    )
                    .disabled(isSending)
                }

                SettingsRow(
                    title: "What's Included",
                    description:
                        "Your description, the Osaurus and macOS versions, your Mac model, chip and memory, and diagnostics: the current agent's name and model, tool names, and the timing and status of recent requests. Never your chats, files or keys."
                ) {
                    SettingsButton(.tertiary, showsIncluded ? "Hide Details" : "Show Details", size: .compact) {
                        withAnimation(theme.motion.quick) { showsIncluded.toggle() }
                    }
                }
                if showsIncluded {
                    includedPreview
                }

                consentRow
                sendRow
            }
        }
    }

    @ViewBuilder
    private var includedPreview: some View {
        if let report {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                ScrollView {
                    Text(verbatim: report.previewJSON)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(theme.space.s12)
                }
                .frame(maxHeight: 280)
                .settingsChrome(.code)
                .accessibilityLabel(Text("Details sent with the report", bundle: .module))

                Text(verbatim: includedFootnote(report))
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsRowChrome()
        } else {
            SettingsEmptyState(loading: "Collecting details…")
        }
    }

    private func includedFootnote(_ report: SupportReport) -> String {
        if report.diagnostics == nil {
            return L("Diagnostics were too large to attach, so this report is sent without them.")
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(report.diagnosticsBytes), countStyle: .file)
        return String(
            format: L("This is everything sent besides your description (%@). Identifiers are one-way fingerprints."),
            size
        )
    }

    /// The box is beside the sentence, not around it, so the Terms and
    /// Privacy links stay clickable.
    private var consentRow: some View {
        HStack(alignment: .center, spacing: theme.space.s10) {
            Toggle(isOn: $hasConsented) { EmptyView() }
                .settingsCheckbox(showsLabel: false)
                .accessibilityLabel(Text("I agree to send this report", bundle: .module))
                .disabled(isSending)
            MarkdownLinkText(
                markdown: Self.consentMarkdown,
                style: .bodySmall,
                textColor: theme.text.primary
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .settingsRowChrome()
    }

    static var consentMarkdown: String {
        String(
            format: L("I agree to send this report and the details listed above to Osaurus, under the [Terms](%1$@) and [Privacy Policy](%2$@)."),
            OsaurusWebLinks.terms.absoluteString,
            OsaurusWebLinks.privacy.absoluteString
        )
    }

    private var sendRow: some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            Group {
                if let sendError {
                    Text(verbatim: sendError)
                        .foregroundColor(theme.status[.error].foreground)
                } else if didSend {
                    Text("Report sent. We will reply on this page.", bundle: .module)
                        .foregroundColor(theme.status[.success].foreground)
                } else if !trimmedDescription.isEmpty, !isLongEnough {
                    Text("Add a little more detail to send.", bundle: .module)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            .font(SettingsFont.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsButton(.primary, "Send Report", icon: "paperplane.fill", isLoading: isSending) {
                send()
            }
            .disabled(!canSend)
        }
        .settingsRowChrome()
    }

    private func send() {
        guard canSend, let report else { return }
        let text = trimmedDescription
        isSending = true
        sendError = nil
        didSend = false
        Task {
            do {
                try await support.submit(description: text, report: report)
                description = ""
                hasConsented = false
                showsIncluded = false
                didSend = true
                // The next report gets fresh diagnostics, not this one's.
                self.report = await SupportReportBuilder.buildCurrent()
            } catch {
                sendError = SupportService.userMessage(for: error)
            }
            isSending = false
        }
    }

    // MARK: - Your Reports

    private var reportsSection: some View {
        SettingsSection(
            title: "Your Reports",
            footer: support.threads.isEmpty
                ? nil
                : "Replies show up here. Osaurus checks for them when it opens, while you have an open report.",
            anchorId: "help.reports"
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
                ForEach(support.threads) { thread in
                    LibraryRow(
                        title: thread.subject,
                        subtitle: Self.activityLine(for: thread),
                        showsChevron: true,
                        action: {
                            withAnimation(theme.motion.quick) { openThreadId = thread.id }
                        },
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
        }
    }

    /// "Sent 3 hours ago" until the team answers, then "Updated …".
    static func activityLine(for thread: OsaurusRouterSupportThread, now: Date = Date()) -> String {
        guard let date = thread.lastActivityDate else { return "" }
        let when = date.formatted(.relative(presentation: .named))
        return String(
            format: thread.lastStaffMessageAt == nil ? L("Sent %@") : L("Updated %@"),
            when
        )
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
            StatusChip(L("Closed"), tone: .neutral)
        }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        HelpView()
    }
#endif
