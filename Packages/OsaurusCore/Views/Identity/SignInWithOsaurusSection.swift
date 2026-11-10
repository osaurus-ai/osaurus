//
//  SignInWithOsaurusSection.swift
//  OsaurusCore
//
//  Identity tab: what "Sign In with Osaurus" is and the recent sign-in
//  requests from websites.
//

import SwiftUI

struct SignInWithOsaurusSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var history = LoginWithOsaurusHistory.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    private static let visibleEntries = 10

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        SettingsSection(
            title: "Sign In with Osaurus",
            subtitle:
                "Osaurus websites such as store.osaurus.ai can ask you to sign in with your Osaurus identity. You approve each request and confirm with Touch ID or your password. The website receives your address, never your keys."
        ) {
            SettingsRow(title: "Recent Sign-ins", description: "") {
                if !history.entries.isEmpty {
                    SettingsButton(.tertiary, "Clear history", size: .compact) {
                        history.clear()
                    }
                }
            }
            if history.entries.isEmpty {
                SettingsEmptyState(inline: "person.badge.key", title: "No sign-ins yet")
            } else {
                ForEach(history.entries.prefix(Self.visibleEntries)) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: LoginWithOsaurusHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: entry.outcome))
                .glyphSize(12, weight: .semibold)
                .foregroundColor(color(for: entry.outcome))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.host)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(verbatim: summary(for: entry))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
            }

            Spacer()

            Text(verbatim: Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
        }
    }

    private func summary(for entry: LoginWithOsaurusHistoryEntry) -> String {
        switch entry.outcome {
        case .signedIn:
            guard let address = entry.address else { return L("Signed in") }
            return L("Signed in as \(SharedAgentIdentity.shortAddress(address))")
        case .cancelled:
            return L("Cancelled")
        case .failed:
            return L("Failed (\(entry.errorCode ?? "unknown"))")
        }
    }

    private func icon(for outcome: LoginWithOsaurusHistoryEntry.Outcome) -> String {
        switch outcome {
        case .signedIn: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for outcome: LoginWithOsaurusHistoryEntry.Outcome) -> Color {
        switch outcome {
        case .signedIn: return theme.status.success.foreground
        case .cancelled: return theme.text.secondary
        case .failed: return theme.status.warning.foreground
        }
    }
}
