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

    @State private var hasAppeared = false

    /// Session catalog snapshot. The catalog is a plain file store (not
    /// observable), so the view snapshots it on appear and re-snapshots after
    /// every action and on the refresh button.
    @State private var records: [BrowserSessionRecord] = []

    /// Pending destructive confirmations.
    @State private var agentPendingReset: BrowserSessionRecord?
    @State private var showResetAllConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    aboutCard
                    enableCard
                        .settingsLandingAnchor("browser.enable")
                    consentCard
                    sessionsCard
                        .settingsLandingAnchor("browser.sessions")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            refreshRecords()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
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
        ManagerHeaderWithActions(
            title: L("Browser"),
            subtitle: L("Let agents browse the web in their own persistent sessions")
        ) {
            HeaderSecondaryButton("Refresh", icon: "arrow.clockwise") {
                refreshRecords()
            }
            .localizedHelp("Refresh session list")
        }
    }

    // MARK: - About card

    private var aboutCard: some View {
        SettingsSection(title: "What it is", icon: "globe") {
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)
            Text(LocalizedStringKey(text), bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Enable card

    private var enableCard: some View {
        SettingsSection(title: "Turn it on", icon: "person.2.fill") {
            VStack(alignment: .leading, spacing: 14) {
                bodyText(
                    "Browser Use is off by default and can only be enabled per custom agent — the built-in Default agent never gets browser access."
                )

                VStack(alignment: .leading, spacing: 10) {
                    stepRow(number: 1, text: "Open the Agents tab and select a custom agent.")
                    stepRow(number: 2, text: "Go to Subagents and turn on Browser Use.")
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
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.accentColor)
                .frame(width: 18, height: 18)
                .background(Circle().fill(theme.accentColor.opacity(0.12)))
            Text(LocalizedStringKey(text), bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Consent card (safety)

    private var consentCard: some View {
        SettingsSection(title: "Staying in control", icon: "hand.raised.fill") {
            VStack(alignment: .leading, spacing: 10) {
                consentRow(
                    icon: "checkmark.circle.fill",
                    color: theme.successColor,
                    text: L(
                        "Reading pages and ordinary navigation run automatically, following your Computer Use autonomy level."
                    )
                )
                consentRow(
                    icon: "questionmark.circle.fill",
                    color: theme.warningColor,
                    text: L(
                        "Typing pauses for your approval; submitting, purchasing, sending, or clearing data always asks first."
                    )
                )
                consentRow(
                    icon: "stop.circle.fill",
                    color: theme.accentColor,
                    text: L("You can stop a run at any time from the activity feed in chat.")
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func consentRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sessions card

    private var sessionsCard: some View {
        SettingsSection(title: "Sessions", icon: "rectangle.stack.person.crop") {
            VStack(alignment: .leading, spacing: 12) {
                bodyText(
                    "One browser profile per agent. Open a session to see it live (or restore it at its last page). Sign-in badges reflect what Osaurus has actually observed — never guessed from cookies."
                )

                if records.isEmpty {
                    emptyHint(
                        "No sessions yet. A session appears here the first time an agent uses the browser."
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
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                Text("Reset All Sessions", bundle: .module)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(theme.errorColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .surface(
                                cornerRadius: 6,
                                fill: theme.errorColor.opacity(0.08),
                                stroke: theme.errorColor.opacity(0.3)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(record.isActive ? theme.successColor : theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .surface(
                        cornerRadius: 8,
                        fill: record.isActive
                            ? theme.successColor.opacity(0.12) : theme.tertiaryBackground
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agentDisplayName(for: record.agentId))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        statusPill(
                            record.isActive ? L("Active") : L("Saved"),
                            color: record.isActive ? theme.successColor : theme.tertiaryText
                        )
                    }
                    Text(sessionSubtitle(record))
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    BrowserSessionManager.shared.openSessionWindow(for: record.agentId)
                    refreshRecords()
                } label: {
                    actionLabel(icon: "macwindow", title: L("Open"))
                }
                .buttonStyle(PlainButtonStyle())
                .localizedHelp("Open this session in a window")

                if record.isActive {
                    Button {
                        BrowserSessionManager.shared.closeSession(for: record.agentId)
                        refreshRecords()
                    } label: {
                        actionLabel(icon: "xmark", title: L("Close"))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Close the live session (keeps its data)")
                }

                Button {
                    agentPendingReset = record
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                        .padding(6)
                }
                .buttonStyle(PlainButtonStyle())
                .localizedHelp("Reset this session (deletes its browsing data)")
            }

            if !record.services.isEmpty {
                serviceBadges(record)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(
            cornerRadius: 10,
            fill: theme.inputBackground,
            stroke: record.isActive ? theme.successColor.opacity(0.3) : theme.inputBorder
        )
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
                        .font(.system(size: 9))
                        .foregroundColor(authColor(status))
                    Text(host)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                    Text(status.displayLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(authColor(status))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .surface(cornerRadius: 6, fill: theme.tertiaryBackground)
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
        case .observedSignedIn: return theme.successColor
        case .signInRequired: return theme.warningColor
        case .unknown: return theme.tertiaryText
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.1)))
    }

    private func actionLabel(icon: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(theme.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .surface(cornerRadius: 6, fill: theme.tertiaryBackground, stroke: theme.inputBorder)
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
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(cornerRadius: 8, fill: theme.inputBackground.opacity(0.5))
    }
}

// MARK: - Styling helpers

private extension View {
    /// The panel's standard filled-and-bordered rounded surface (same helper
    /// the Computer Use panel defines privately).
    func surface(
        cornerRadius: CGFloat,
        fill: Color,
        stroke: Color = .clear,
        lineWidth: CGFloat = 1
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(stroke, lineWidth: lineWidth)
                )
        )
    }
}
