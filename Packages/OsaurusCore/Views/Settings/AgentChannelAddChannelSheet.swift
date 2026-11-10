//
//  AgentChannelAddChannelSheet.swift
//  osaurus
//
//  Unified "Add Channel" flow: one catalog of every channel type (guided
//  native providers plus the advanced custom HTTP definition). Picking a
//  provider transitions within the same sheet into its focused setup flow.
//

import SwiftUI

struct AgentChannelAddChannelSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Badges describing which native providers are already configured, so a
    /// re-pick reads as "edit the existing connection", not a second copy.
    let nativeBadges: [AgentChannelKind: AgentChannelStatusPresentation]
    /// Whether picking the channel adds another account of it, because its
    /// first one is already set up.
    var opensNewAccount: (AgentChannelKind) -> Bool = { _ in false }
    /// Called after a custom connection is created so the channel list refreshes.
    let onDidChange: () -> Void

    @State private var selectedKind: AgentChannelKind?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        Group {
            switch selectedKind {
            case .discord:
                DiscordSettingsView(onBack: goBack, newAccount: opensNewAccount(.discord))
            case .slack:
                SlackSettingsView(onBack: goBack, newAccount: opensNewAccount(.slack))
            case .telegram:
                TelegramSettingsView(onBack: goBack, newAccount: opensNewAccount(.telegram))
            case .imessage:
                IMessageSettingsView(onBack: goBack)
            case .whatsapp:
                WhatsAppSettingsView(onBack: goBack)
            case .email:
                EmailSettingsView(onBack: goBack, newAccount: opensNewAccount(.email))
            case .n8n:
                N8nSettingsView(
                    connection: nil,
                    onBack: goBack,
                    onDidChange: onDidChange
                )
            case .customHTTP:
                AgentChannelCustomConnectionSheet(
                    connection: nil,
                    onBack: goBack,
                    onDidChange: onDidChange
                )
            case nil:
                picker
            }
        }
        .environment(\.theme, themeManager.currentTheme)
    }

    /// Spring shared by the catalog ↔ setup swap in both directions. The
    /// state change must happen inside `withAnimation`: the back chevron
    /// lives deep inside the setup scaffold, and a plain assignment from its
    /// action does not reliably animate the container swap on macOS.
    @MainActor private static var swapAnimation: Animation { ThemeManager.shared.currentTheme.motion.springAnimation }

    private func select(_ kind: AgentChannelKind) {
        withAnimation(Self.swapAnimation) {
            selectedKind = kind
        }
    }

    private func goBack() {
        withAnimation(Self.swapAnimation) {
            selectedKind = nil
        }
    }

    // MARK: - Picker

    private var picker: some View {
        VStack(spacing: 0) {
            SettingsSheetHeader(
                icon: "plus.bubble.fill",
                title: "Add Channel",
                subtitle: "Let agents read and reply where your team already talks.",
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AgentChannelAddCatalog.choices, id: \.self) { kind in
                        if AgentChannelAddCatalog.isAdvanced(kind) {
                            advancedDivider
                        }
                        AgentChannelCard(
                            icon: kind.icon,
                            gradient: kind.brandGradient,
                            title: kind.displayName,
                            subtitle: opensNewAccount(kind)
                                ? ChannelAccounts.addAnotherTagline(kind)
                                : AgentChannelAddCatalog.tagline(for: kind),
                            badge: opensNewAccount(kind) ? nil : nativeBadges[kind]
                        ) {
                            select(kind)
                        }
                    }
                }
                .padding(theme.settingsSheetInset)
            }
        }
        .fittedSheetFrame(width: SettingsSheetWidth.regular, height: 520)
        .settingsSheetSurface()
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge)
                .stroke(theme.border.subtle, lineWidth: theme.stroke.default)
        )
    }

    private var advancedDivider: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(theme.border.default)
                .frame(height: 1)
            Text("Advanced", bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)
                .fixedSize()
            Rectangle()
                .fill(theme.border.default)
                .frame(height: 1)
        }
        .padding(.top, theme.space.s8)
    }
}
