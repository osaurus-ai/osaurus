//
//  BrowserSettingsView.swift
//  OsaurusCore — Native Browser Use
//
//  Settings panel for the native Browser Use feature. Organized top-down like
//  the Computer Use panel: what the feature is, how to turn it on (a
//  custom-agent capability toggled in each agent's Subagents tab — the
//  Default agent never gets browser access), the safety model, and the
//  session catalog — one card per agent profile with its live/saved state,
//  last page, observed sign-in badges, and open/close/reset controls. Reset
//  is destructive (wipes the WebKit profile) and always confirms first.
//

import SwiftUI

struct BrowserSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }


    /// Session catalog snapshot. The catalog is a plain file store (not
    /// observable), so the view snapshots it on appear and re-snapshots after
    /// every action and on the refresh button.
    @State private var records: [BrowserSessionRecord] = []

    /// Pending destructive confirmations.
    @State private var agentPendingReset: BrowserSessionRecord?
    @State private var showResetAllConfirm = false

    var body: some View {
        SettingsPage {
            headerView
        } content: {
            aboutCard
            enableCard
                .settingsLandingAnchor("browser.enable")
            consentCard
            sessionsCard
                .settingsLandingAnchor("browser.sessions")
        }
        .environment(\.theme, themeManager.currentTheme)
        .onAppear { refreshRecords() }
        .alert(
            Text("Reset this browser session?", bundle: .module),
            isPresented: Binding(
                get: { agentPendingReset != nil },
                set: { if !$0 { agentPendingReset = nil } }
            ),
            presenting: agentPendingReset
        ) { record in
            Button(role: .destructive) {
                let agentId = record.agentId
                agentPendingReset = nil
                Task {
                    await BrowserSessionManager.shared.resetSession(for: agentId)
                    refreshRecords()
                }
            } label: {
                Text("Reset Session", bundle: .module)
            }
            Button(role: .cancel) {
                agentPendingReset = nil
            } label: {
                Text("Cancel", bundle: .module)
            }
        } message: { record in
            Text(
                "This permanently deletes \(agentDisplayName(for: record.agentId))'s browsing data — cookies, sign-ins, and history. The agent starts over with a fresh profile.",
                bundle: .module
            )
        }
        .alert(
            Text("Reset all browser sessions?", bundle: .module),
            isPresented: $showResetAllConfirm
        ) {
            Button(role: .destructive) {
                showResetAllConfirm = false
                Task {
                    await BrowserSessionManager.shared.resetAllSessions()
                    refreshRecords()
                }
            } label: {
                Text("Reset All", bundle: .module)
            }
            Button(role: .cancel) {
                showResetAllConfirm = false
            } label: {
                Text("Cancel", bundle: .module)
            }
        } message: {
            Text(
                "This permanently deletes every agent's browsing data — all cookies, sign-ins, and history.",
                bundle: .module
            )
        }
    }

    private func refreshRecords() {
        records = BrowserSessionCatalog.allRecords()
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(
            title: "Browser Use",
            subtitle: "Let agents browse the web in their own persistent sessions",
            onRefresh: { refreshRecords() },
            refreshHelp: "Refresh session list"
        )
    }

    // MARK: - About card

    private var aboutCard: some View {
        SettingsSection(title: "What It Is") {
            VStack(alignment: .leading, spacing: 12) {
                bodyText(
                    "When you turn it on for an agent, Browser Use lets that agent browse the web for you — navigating pages, reading content, filling forms, and working through a goal step by step, with every action shown in a live feed."
                )

                VStack(alignment: .leading, spacing: 8) {
                    aboutRow(
                        icon: "person.crop.rectangle",
                        text:
                            "Each agent gets its own isolated browser profile. Cookies and sign-ins persist between chats but are never shared with other agents or your regular browser."
                    )
                    aboutRow(
                        icon: "key",
                        text:
                            "Sign-ins happen in a browser window you type into directly — agents never see or ask for your passwords."
                    )
                    aboutRow(
                        icon: "checkmark.circle",
                        text: "Checks each step as it goes — and you can stop it any time."
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func aboutRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .glyphSize(12, weight: .medium)
                .foregroundColor(theme.text.link)
                .frame(width: 18, alignment: .center)
                .padding(.top, theme.space.s2)
            Text(LocalizedStringKey(text), bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Enable card

    private var enableCard: some View {
        SettingsSection(title: "Turn It On") {
            VStack(alignment: .leading, spacing: 14) {
                bodyText(
                    "Browser Use is off by default and can only be enabled per custom agent — the built-in Default agent never gets browser access."
                )

                VStack(alignment: .leading, spacing: 10) {
                    stepRow(number: 1, text: "Open the Agents tab and select a custom agent.")
                    stepRow(number: 2, text: "Open Abilities → Subagents and turn on Browser Use.")
                    stepRow(
                        number: 3,
                        text: "Optionally pick a different model for the browsing subagent."
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.link)
                .frame(width: 18, height: 18)
                .background(Circle().fill(theme.status.info.background))
            Text(LocalizedStringKey(text), bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Consent card (safety)

    private var consentCard: some View {
        SettingsSection(title: "Staying in Control") {
            VStack(alignment: .leading, spacing: 10) {
                consentRow(
                    icon: "checkmark.circle.fill",
                    color: theme.status.success.foreground,
                    text: L(
                        "Reading pages and ordinary navigation run automatically, following your Computer Use autonomy level."
                    )
                )
                consentRow(
                    icon: "questionmark.circle.fill",
                    color: theme.status.warning.foreground,
                    text: L(
                        "Typing pauses for your approval; submitting, purchasing, sending, or clearing data always asks first."
                    )
                )
                consentRow(
                    icon: "stop.circle.fill",
                    color: theme.action.primary.default.background,
                    text: L("You can stop a run at any time from the activity feed in chat.")
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func consentRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .glyphSize(12)
                .foregroundColor(color)
                .padding(.top, theme.space.s2)
            Text(text)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sessions card

    private var sessionsCard: some View {
        SettingsSection(title: "Sessions") {
            VStack(alignment: .leading, spacing: 12) {
                bodyText(
                    "One browser profile per agent. Open a session to see it live (or restore it at its last page). Sign-in badges reflect what Osaurus has actually observed — never guessed from cookies."
                )

                if records.isEmpty {
                    SettingsEmptyState(
                        inline: "globe",
                        title: "No sessions yet",
                        hint: "A session appears here the first time an agent uses the browser."
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(records) { record in
                            sessionRow(record)
                        }
                    }

                    HStack {
                        Spacer()
                        Button {
                            showResetAllConfirm = true
                        } label: {
                            Label(L("Reset All Sessions"), systemImage: "trash")
                        }
                        .assignedSettingsButtonStyle(.destructive, size: .compact)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sessionRow(_ record: BrowserSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .glyphSize(16, weight: .medium)
                    .foregroundColor(record.isActive ? theme.status.success.foreground : theme.text.secondary)
                    .frame(width: 32, height: 32)
                    .settingsChrome(record.isActive ? .status(.success) : .subtle)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agentDisplayName(for: record.agentId))
                            .font(SettingsFont.sectionTitle)
                            .foregroundColor(theme.text.primary)
                        statusPill(
                            record.isActive ? L("Active") : L("Saved"),
                            color: record.isActive ? theme.status.success.foreground : theme.text.tertiary
                        )
                    }
                    Text(sessionSubtitle(record))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    BrowserSessionManager.shared.openSessionWindow(for: record.agentId)
                    refreshRecords()
                } label: {
                    Label(L("Open"), systemImage: "macwindow")
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
                .localizedHelp("Open this session in a window")

                if record.isActive {
                    Button {
                        BrowserSessionManager.shared.closeSession(for: record.agentId)
                        refreshRecords()
                    } label: {
                        Label(L("Close"), systemImage: "xmark")
                    }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                    .localizedHelp("Close the live session (keeps its data)")
                }

                Button {
                    agentPendingReset = record
                } label: {
                    Image(systemName: "trash")
                        .glyphSize(12)
                        .foregroundColor(theme.status.error.foreground)
                        .padding(theme.space.s6)
                }
                .buttonStyle(PlainButtonStyle())
                .localizedHelp("Reset this session (deletes its browsing data)")
            }

            if !record.services.isEmpty {
                serviceBadges(record)
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.control)
    }

    /// Observed per-service sign-in badges, most recently defined first.
    private func serviceBadges(_ record: BrowserSessionRecord) -> some View {
        // Wrapping flow isn't needed for the handful of hosts a session
        // typically touches; a simple wrapping HStack via LazyVGrid keeps it
        // dependency-free.
        let hosts = record.services.keys.sorted()
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(hosts, id: \.self) { host in
                let status = record.services[host] ?? .unknown
                HStack(spacing: 5) {
                    Image(systemName: authIcon(status))
                        .glyphSize(9)
                        .foregroundColor(authColor(status))
                    Text(host)
                        .font(SettingsFont.chip)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)
                    Text(status.displayLabel)
                        .font(SettingsFont.chip)
                        .foregroundColor(authColor(status))
                }
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s4)
                .settingsChrome(.subtle, radius: theme.radius.small)
            }
        }
    }

    private func authIcon(_ status: BrowserAuthStatus) -> String {
        switch status {
        case .observedSignedIn: return "checkmark.seal.fill"
        case .signInRequired: return "lock.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func authColor(_ status: BrowserAuthStatus) -> Color {
        switch status {
        case .observedSignedIn: return theme.status.success.foreground
        case .signInRequired: return theme.status.warning.foreground
        case .unknown: return theme.text.tertiary
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        StatusChip(text, tint: color)
    }

    // MARK: - Row copy helpers

    private func agentDisplayName(for agentId: UUID) -> String {
        if agentId == Agent.defaultId { return "Osaurus" }
        if let agent = agentManager.agent(for: agentId) { return agent.name }
        return L("Deleted agent")
    }

    private func sessionSubtitle(_ record: BrowserSessionRecord) -> String {
        var parts: [String] = []
        if let title = record.lastTitle, !title.isEmpty {
            parts.append(title)
        }
        if let domain = record.lastDomain, !domain.isEmpty {
            parts.append(domain)
        }
        if let activity = record.lastActivity {
            parts.append(Self.relativeFormatter.localizedString(for: activity, relativeTo: Date()))
        }
        if parts.isEmpty { return L("Never used") }
        return parts.joined(separator: " · ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Text helpers

    private func bodyText(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

}
