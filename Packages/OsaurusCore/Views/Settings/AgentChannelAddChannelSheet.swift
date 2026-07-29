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
    /// Called after a custom connection is created so the channel list refreshes.
    let onDidChange: () -> Void

    @State private var selectedKind: AgentChannelKind?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        Group {
            switch selectedKind {
            case .discord:
                DiscordSettingsView(onBack: goBack)
            case .slack:
                SlackSettingsView(onBack: goBack)
            case .telegram:
                TelegramSettingsView(onBack: goBack)
            case .imessage:
                IMessageSettingsView(onBack: goBack)
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
    private static let swapAnimation = Animation.spring(response: 0.3, dampingFraction: 0.85)

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
            header

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
                            subtitle: AgentChannelAddCatalog.tagline(for: kind),
                            badge: nativeBadges[kind]
                        ) {
                            select(kind)
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 560, height: 520)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "plus.bubble.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Add Channel", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Let agents read and reply where your team already talks.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(theme.secondaryBackground)
    }

    private var advancedDivider: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(theme.cardBorder)
                .frame(height: 1)
            Text("Advanced", bundle: .module)
                .textCase(.uppercase)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.5)
                .fixedSize()
            Rectangle()
                .fill(theme.cardBorder)
                .frame(height: 1)
        }
        .padding(.top, 8)
    }
}
