//
//  AgentChannelSettingsComponents.swift
//  osaurus
//
//  Shared UI building blocks for Agent Channel settings: channel cards,
//  the configuration sheet scaffold, secret rows, and status banners.
//

import SwiftUI

#if os(macOS)
    import AppKit
#endif

// MARK: - Channel Visual Identity

extension AgentChannelKind {
    var displayName: String {
        switch self {
        case .discord: "Discord"
        case .slack: "Slack"
        case .telegram: "Telegram"
        case .customHTTP: "Custom HTTP"
        }
    }

    var icon: String {
        switch self {
        case .discord: "bubble.left.and.bubble.right.fill"
        case .slack: "number"
        case .telegram: "paperplane.fill"
        case .customHTTP: "curlybraces"
        }
    }

    /// Two-stop brand gradient for the card and sheet icon tiles, mirroring
    /// the provider-preset gradients used across the Providers tab.
    var brandGradient: [Color] {
        switch self {
        case .discord: [Color(hex: "5865F2"), Color(hex: "4051D3")]
        case .slack: [Color(hex: "611F69"), Color(hex: "4A154B")]
        case .telegram: [Color(hex: "2AABEE"), Color(hex: "1E96C8")]
        case .customHTTP: [Color(hex: "64748B"), Color(hex: "475569")]
        }
    }
}

// MARK: - Status Tone Colors

extension AgentChannelStatusTone {
    func color(_ theme: ThemeProtocol) -> Color {
        switch self {
        case .neutral: return theme.tertiaryText
        case .success: return theme.successColor
        case .warning: return theme.warningColor
        case .error: return theme.errorColor
        }
    }
}

// MARK: - Status Badge

/// Compact dot + label capsule showing a humanized channel status, used on
/// channel cards and the transport health card.
struct AgentChannelStatusBadge: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let presentation: AgentChannelStatusPresentation

    var body: some View {
        let color = presentation.tone.color(themeManager.currentTheme)
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(presentation.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Channel Card

/// Full-width card for one channel (native integration or custom connection).
/// The whole card is a button that opens the channel's configuration sheet,
/// mirroring `ProviderRowCard`.
struct AgentChannelCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let icon: String
    let gradient: [Color]
    let title: String
    let subtitle: String
    var subtitleIsMonospaced = false
    var badge: AgentChannelStatusPresentation?
    var anchorId: String?
    let action: () -> Void

    @State private var isHovered = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: gradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)

                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        if let badge {
                            AgentChannelStatusBadge(presentation: badge)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 12, design: subtitleIsMonospaced ? .monospaced : .default))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isHovered ? theme.accentColor.opacity(0.4) : theme.cardBorder,
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
        .settingsLandingAnchor(anchorId)
    }
}

// MARK: - Sheet Scaffold

/// Shared chrome for channel configuration sheets: brand-tile header with a
/// close button, scrollable content, and a pinned footer bar. Matches the
/// provider edit sheets in size and structure.
struct AgentChannelSheetScaffold<Content: View, Footer: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    let icon: String
    let gradient: [Color]
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(
        icon: String,
        gradient: [Color],
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.icon = icon
        self.gradient = gradient
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = footer()
    }

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                content
                    .padding(24)
            }

            footerBar
        }
        .frame(width: 560, height: 640)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder, lineWidth: 1)
        )
        .environment(\.theme, themeManager.currentTheme)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(subtitle)
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

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            footer
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }
}

// MARK: - Sheet Action Button

/// Footer button with a built-in busy spinner, used for Save / Test actions
/// in channel sheets.
struct AgentChannelSheetActionButton: View {
    let title: String
    let busyTitle: String
    let isBusy: Bool
    var isPrimary = false
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
                Text(LocalizedStringKey(isBusy ? busyTitle : title), bundle: .module)
            }
        }
        .buttonStyle(SettingsButtonStyle(isPrimary: isPrimary, isDestructive: isDestructive))
    }
}

// MARK: - Advanced Disclosure

/// Collapsed-by-default section for rarely used options, so channel sheets
/// stay focused on the fields most users need.
struct AgentChannelAdvancedSection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var isExpanded = false

    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Advanced", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundColor(themeManager.currentTheme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Secret Field

/// Keychain-backed credential field following the provider edit sheet pattern:
/// an uppercase label row showing Keychain state (with a Remove action once a
/// secret is saved) above the secure field. Pending input is persisted by the
/// sheet's footer Save action, not by a per-field button.
struct AgentChannelSecretField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Field label, rendered uppercase, e.g. "Bot Token".
    let label: String
    /// Requirement context shown next to the label, e.g. "Required" or
    /// "Optional — enables Socket Mode receive".
    var requirementHint: String?
    /// Format example shown while no secret is saved, e.g. "xoxb-...".
    var placeholder: String = ""
    @Binding var text: String
    let saved: Bool
    let onRemove: () -> Void

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(label), bundle: .module)
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.5)

                if let requirementHint {
                    Text(verbatim: "·")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                    Text(LocalizedStringKey(requirementHint), bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()

                if saved {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                        Text("Stored in Keychain", bundle: .module)
                            .font(.system(size: 10))
                    }
                    .foregroundColor(theme.tertiaryText)

                    Button(action: onRemove) {
                        Text("Remove", bundle: .module)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.errorColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Text("Not saved", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            SecureField(text: $text, prompt: promptText) {
                Text(LocalizedStringKey(label), bundle: .module)
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
    }

    private var promptText: Text {
        if saved {
            return Text("Leave blank to keep current", bundle: .module)
        }
        return Text(LocalizedStringKey(placeholder), bundle: .module)
    }
}

// MARK: - Setup Link

/// Accent-colored external link for "where do I create this bot" guidance,
/// mirroring the provider setup links on the Providers tab.
struct AgentChannelSetupLink: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let url: URL

    var body: some View {
        Button {
            #if os(macOS)
                NSWorkspace.shared.open(url)
            #endif
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 11))
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(themeManager.currentTheme.accentColor)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Multiline Field

struct AgentChannelMultilineSettingsField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    @Binding var text: String
    /// Example values shown while the field is empty, e.g. "C0123ABC — one per line".
    var placeholder: String = ""
    let help: String

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)

            ZStack(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(LocalizedStringKey(placeholder), bundle: .module)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.placeholderText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
            }
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )

            Text(LocalizedStringKey(help), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Inline Status Message

/// Inline result banner for settings actions (save, test connection, webhook
/// checks). Failures and diagnostic notes render as individual detail rows
/// instead of one joined line. Success messages without details auto-dismiss
/// after a short delay via `onAutoClear`; errors and detailed results persist
/// until replaced.
struct AgentChannelInlineStatusMessage: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let message: String
    var details: [String] = []
    let isError: Bool
    var onAutoClear: (() -> Void)?

    private static let autoClearDelay: Duration = .milliseconds(2500)

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var tint: Color {
        isError ? theme.warningColor : theme.successColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(tint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            ForEach(details, id: \.self) { detail in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.top, 2)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 21)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.08))
        )
        .task(id: message) {
            guard onAutoClear != nil, !isError, details.isEmpty else { return }
            try? await Task.sleep(for: Self.autoClearDelay)
            guard !Task.isCancelled else { return }
            onAutoClear?()
        }
    }
}
