//
//  NotificationRoutingSettingsView.swift
//  osaurus
//
//  Settings → General → Notifications: one row per kind of "needs you"
//  moment with a menu of the channels it reaches (in the app, desktop,
//  paired phone; push later). The rows sit directly in the Notifications
//  section so each is its own row. Backed by `NotificationPreferencesStore`;
//  routing happens in `AttentionCenter`.
//

import SwiftUI

struct NotificationRouteRow: View {
    let category: NotificationCategory
    @Binding var prefs: NotificationPreferences
    /// The master Show Notifications switch: off, nothing shows in the app.
    let appNotificationsOn: Bool

    var body: some View {
        SettingsRow(
            title: category.settingsTitle,
            description: category.settingsDescription,
            anchorId: category.anchorId
        ) {
            SettingsMenuButton(.secondary, summary, size: .compact, verbatim: true) {
                ForEach(NotificationChannelID.deliverable, id: \.self) { channel in
                    Toggle(isOn: binding(channel)) {
                        Label(channel.displayName, systemImage: channel.icon)
                    }
                    .settingsCheckbox()
                    .disabled(channel == .inApp && !appNotificationsOn)
                    .help(Text(verbatim: channel.help))
                }
                Divider()
                Button {
                } label: {
                    Label(L("Push (coming soon)"), systemImage: NotificationChannelID.push.icon)
                }
                .disabled(true)
            }
            .accessibilityLabel(
                Text(verbatim: "\(L(String.LocalizationValue(category.settingsTitle))), \(summary)"))
        }
    }

    /// The trigger's label: where this kind reaches you now.
    private var summary: String {
        let on = NotificationChannelID.deliverable.filter { isOn($0) }
        return on.isEmpty ? L("Off") : on.map(\.displayName).joined(separator: ", ")
    }

    private func isOn(_ channel: NotificationChannelID) -> Bool {
        if channel == .inApp, !appNotificationsOn { return false }
        return prefs.isOn(category, channel)
    }

    private func binding(_ channel: NotificationChannelID) -> Binding<Bool> {
        Binding(
            get: { isOn(channel) },
            set: { on in
                prefs.set(category, channel, on)
                NotificationPreferencesStore.save(prefs)
            }
        )
    }
}

extension NotificationChannelID {
    /// Channels that deliver today, in menu order. Push keeps its stored
    /// value for when a transport ships.
    static let deliverable: [NotificationChannelID] = [.inApp, .desktop, .phone]

    var icon: String {
        switch self {
        case .inApp: return "macwindow"
        case .desktop: return "bell"
        case .phone: return "iphone"
        case .push: return "app.badge"
        }
    }

    var help: String {
        switch self {
        case .inApp: return L("A toast and the Inbox badge inside Osaurus.")
        case .desktop: return L("macOS notifications with Allow, Deny and Reply.")
        case .phone: return L("Shown on your iPhone through Sync, which can answer it.")
        case .push: return L("Push to your phone. Not available yet.")
        }
    }
}

extension NotificationCategory {
    /// Settings row title: a catalog key, the exact label in
    /// `SettingsSearchIndex`.
    var settingsTitle: String {
        switch self {
        case .approvals: return "Approvals"
        case .questions: return "Questions from Agents"
        case .messages: return "Inbound Messages"
        case .sharedConversations: return "Shared Agent Conversations"
        case .agentNotices: return "Agent Notifications"
        }
    }

    /// Settings row description (catalog key).
    var settingsDescription: String {
        switch self {
        case .approvals: return "Tool calls, teammates' requests on your shared agents, config changes and secrets"
        case .questions: return "Clarifying questions and workflow forms"
        case .messages: return "Channel messages and messages from teammates"
        case .sharedConversations: return "Someone starts talking to one of your shared agents"
        case .agentNotices: return "An agent asks for your attention"
        }
    }

    /// Settings-search landing anchor of the row.
    var anchorId: String {
        switch self {
        case .approvals: return "settings.notifications.approvals"
        case .questions: return "settings.notifications.questions"
        case .messages: return "settings.notifications.messages"
        case .sharedConversations: return "settings.notifications.sharedConversations"
        case .agentNotices: return "settings.notifications.agentNotices"
        }
    }
}
