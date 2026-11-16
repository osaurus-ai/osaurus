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
        case .imessage: "iMessage"
        case .whatsapp: "WhatsApp"
        case .email: "Email"
        case .n8n: "n8n"
        case .customHTTP: "Custom HTTP"
        }
    }

    var icon: String {
        switch self {
        case .discord: "bubble.left.and.bubble.right.fill"
        case .slack: "number"
        case .telegram: "paperplane.fill"
        case .imessage: "message.fill"
        case .whatsapp: "phone.bubble.fill"
        case .email: "envelope.fill"
        case .n8n: "arrow.triangle.branch"
        case .customHTTP: "curlybraces"
        }
    }

}

// MARK: - Status Tone Colors

extension AgentChannelStatusTone {
    func color(_ theme: ThemeProtocol) -> Color {
        switch self {
        case .neutral: return theme.text.tertiary
        case .success: return theme.status.success.foreground
        case .warning: return theme.status.warning.foreground
        case .error: return theme.status.error.foreground
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
        StatusChip(presentation.label, tint: color, showsDot: true)
    }
}

// MARK: - Channel Card

/// On/off accessory for `AgentChannelCard`.
struct AgentChannelCardEnabledToggle {
    var isOn: Bool
    var anchorId: String? = nil
    var onChange: (Bool) -> Void
}

/// One channel (native integration or custom connection) as a library row
/// that opens the channel's configuration sheet.
struct AgentChannelCard: View {
    @Environment(\.theme) private var theme

    let icon: String
    let gradient: [Color]
    let title: String
    let subtitle: String
    var subtitleIsMonospaced = false
    var badge: AgentChannelStatusPresentation?
    /// Optional second line, e.g. which agent(s) answer this channel.
    var detail: String?
    var anchorId: String?
    /// Optional on/off switch before the chevron, so stored connections (n8n)
    /// can be enabled and disabled without opening the sheet.
    var enabledToggle: AgentChannelCardEnabledToggle?
    let action: () -> Void

    var body: some View {
        LibraryRow(
            title: title,
            subtitle: [subtitle, detail].compactMap { $0 }.joined(separator: "\n"),
            monospacedSubtitle: subtitleIsMonospaced,
            showsChevron: true,
            anchorId: anchorId,
            action: action
        ) {
            SettingsIconTile(icon: icon, size: 32, gradient: gradient)
        } badges: {
            if let badge {
                AgentChannelStatusBadge(presentation: badge)
            }
        } trailing: {
            if let enabledToggle {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabledToggle.isOn },
                        set: { enabledToggle.onChange($0) }
                    )
                )
                .settingsSwitch()
                .help(
                    enabledToggle.isOn
                        ? L("Channel enabled — turn off to refuse every request with 403")
                        : L("Channel disabled — turn on to accept requests again")
                )
                .settingsLandingAnchor(enabledToggle.anchorId)
            }
        }
    }
}

// MARK: - Setup Scaffold

private struct ChannelSheetIsEditingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set when a channel sheet opens on a connection that is already set
    /// up: its sections read as tabs, Status first, with no Back / Continue.
    var channelSheetIsEditing: Bool {
        get { self[ChannelSheetIsEditingKey.self] }
        set { self[ChannelSheetIsEditingKey.self] = newValue }
    }
}

/// A new account's sheet before its token or mail account is in: only the
/// first section is open, and the footer's one action creates the account.
struct AgentChannelPendingAccount {
    var actionTitle: String
    var isWorking: Bool
    var canConnect: Bool
    var connect: () -> Void
}

/// Shared chrome for channel configuration sheets: brand-tile header with a
/// close (and optional back) button, a persistent section rail on the left,
/// one focused section of content at a time on the right, and a pinned
/// footer bar around the caller's actions.
///
/// First-time setup walks the numbered sections with Back / Continue. A
/// connection that is already set up opens as tabs instead, Status first.
struct AgentChannelSetupScaffold<Content: View, StatusBar: View, FooterLeading: View, FooterTrailing: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.channelSheetIsEditing) private var isEditingEnvironment

    let icon: String
    let gradient: [Color]
    let title: String
    let subtitle: String
    let sections: [AgentChannelSetupSection]
    @Binding var selection: String
    let sectionStatus: (String) -> AgentChannelSetupSectionStatus
    /// Shown as a back chevron in the header when the sheet is hosted inside
    /// the unified Add Channel picker.
    var onBack: (() -> Void)?
    /// Set while a new account waits for its token or mail account.
    var pendingAccount: AgentChannelPendingAccount?
    private let contentBuilder: (String) -> Content
    let statusBar: StatusBar
    let footerLeading: FooterLeading
    let footerTrailing: FooterTrailing

    init(
        icon: String,
        gradient: [Color],
        title: String,
        subtitle: String,
        sections: [AgentChannelSetupSection],
        selection: Binding<String>,
        sectionStatus: @escaping (String) -> AgentChannelSetupSectionStatus,
        onBack: (() -> Void)? = nil,
        pendingAccount: AgentChannelPendingAccount? = nil,
        @ViewBuilder content: @escaping (String) -> Content,
        @ViewBuilder statusBar: () -> StatusBar,
        @ViewBuilder footerLeading: () -> FooterLeading,
        @ViewBuilder footerTrailing: () -> FooterTrailing
    ) {
        self.icon = icon
        self.gradient = gradient
        self.title = title
        self.subtitle = subtitle
        self.sections = sections
        self._selection = selection
        self.sectionStatus = sectionStatus
        self.onBack = onBack
        self.pendingAccount = pendingAccount
        self.contentBuilder = content
        self.statusBar = statusBar()
        self.footerLeading = footerLeading()
        self.footerTrailing = footerTrailing()
    }

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var isEditing: Bool { isEditingEnvironment && pendingAccount == nil }

    private static var verifyId: String { AgentChannelProviderSetupSection.verify.rawValue }

    /// Tabs put Status (the live check) first and drop the step captions'
    /// "do this next" reading.
    private var displayedSections: [AgentChannelSetupSection] {
        guard isEditing, let verify = sections.first(where: { $0.id == Self.verifyId }) else { return sections }
        let status = AgentChannelSetupSection(
            id: verify.id, title: L("Status"), icon: "waveform.path.ecg", caption: L("Health and live check"))
        return [status] + sections.filter { $0.id != Self.verifyId }
    }

    private func isLocked(_ section: AgentChannelSetupSection) -> Bool {
        pendingAccount != nil && section.id != sections.first?.id
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            header

            HStack(spacing: theme.space.s0) {
                sectionRail

                ThemeHairlineDivider(axis: .vertical)

                ScrollView {
                    contentBuilder(selection)
                        .padding(theme.space.s24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(selection)
                }
            }

            footerBar
        }
        .fittedSheetFrame(width: 800, height: 640)
        .background(theme.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge)
                .stroke(theme.border.subtle, lineWidth: theme.stroke.default)
        )
        .environment(\.theme, themeManager.currentTheme)
    }

    private var header: some View {
        HStack(spacing: theme.space.s12) {
            if let onBack {
                SettingsIconButton("chevron.left", help: "Back to channel choices", size: .compact, action: onBack)
            }

            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(
                        LinearGradient(
                            colors: gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: icon)
                    .glyphSize(.large, weight: .semibold)
                    .foregroundColor(FixedPalette.onMedia)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(title)
                    .font(SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)

                Text(subtitle)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
            }

            Spacer()

            SettingsIconButton("xmark", help: "Close", size: .compact) { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s16)
        .background(theme.surface.subtle)
    }

    private var sectionRail: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            ForEach(Array(displayedSections.enumerated()), id: \.element.id) { index, section in
                railRow(section, number: index + 1)
            }
            Spacer(minLength: 0)
        }
        .padding(theme.space.s12)
        .frame(width: 192, alignment: .topLeading)
        .background(theme.surface.subtle)
    }

    private func railRow(_ section: AgentChannelSetupSection, number: Int) -> some View {
        let status = sectionStatus(section.id)
        let isSelected = selection == section.id
        let locked = isLocked(section)
        return Button {
            withAnimation(theme.motion.quick) {
                selection = section.id
            }
        } label: {
            HStack(spacing: theme.space.s8) {
                Group {
                    if isEditing {
                        tabIndicator(section, status: status, isSelected: isSelected)
                    } else {
                        railIndicator(status, number: number)
                    }
                }
                .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(section.title)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)
                        .lineLimit(1)

                    if let caption = section.caption {
                        Text(caption)
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium))
            .settingsChrome(isSelected ? .selected : nil)
            .opacity(locked ? 0.45 : 1)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(locked)
        .help(locked ? Text("Connect first", bundle: .module) : Text(verbatim: ""))
    }

    /// A tab's icon; a warning mark when the section needs attention.
    private func tabIndicator(
        _ section: AgentChannelSetupSection, status: AgentChannelSetupSectionStatus, isSelected: Bool
    ) -> some View {
        Image(systemName: status == .attention ? "exclamationmark.triangle.fill" : section.icon)
            .glyphSize(.footnote, weight: .semibold)
            .foregroundColor(
                status == .attention
                    ? theme.status.warning.foreground : isSelected ? theme.text.primary : theme.text.tertiary
            )
    }

    @ViewBuilder
    private func railIndicator(_ status: AgentChannelSetupSectionStatus, number: Int) -> some View {
        ZStack {
            Circle()
                .fill(indicatorFill(status))
            switch status {
            case .complete:
                Image(systemName: "checkmark")
                    .glyphSize(.tiny, weight: .bold)
                    .foregroundColor(theme.status.success.foreground)
            case .attention:
                Image(systemName: "exclamationmark")
                    .glyphSize(.tiny, weight: .bold)
                    .foregroundColor(theme.status.warning.foreground)
            case .pending:
                Text("\(number)")
                    .font(SettingsFont.chip)
                    .foregroundColor(theme.text.secondary)
            }
        }
    }

    private func indicatorFill(_ status: AgentChannelSetupSectionStatus) -> Color {
        switch status {
        case .complete: return theme.status.success.background
        case .attention: return theme.status.warning.background
        case .pending: return theme.surface.hover
        }
    }

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            statusBar

            if let pendingAccount {
                HStack(spacing: theme.space.s10) {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel", bundle: .module)
                    }
                    .buttonStyle(.settings())
                    AgentChannelSheetActionButton(
                        title: pendingAccount.actionTitle,
                        busyTitle: L("Connecting..."),
                        isBusy: pendingAccount.isWorking,
                        isPrimary: true,
                        action: pendingAccount.connect
                    )
                    .disabled(!pendingAccount.canConnect || pendingAccount.isWorking)
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                navigationFooter
            }
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s16)
        .background(
            theme.surface.subtle
                .overlay(
                    ThemeHairlineDivider(),
                    alignment: .top
                )
        )
    }

    private var navigationFooter: some View {
        HStack(spacing: theme.space.s10) {
            footerLeading

            Spacer()

            if !isEditing {
                if let previous = AgentChannelSetupFlow.previous(before: selection, in: sections) {
                    Button {
                        withAnimation(theme.motion.quick) {
                            selection = previous
                        }
                    } label: {
                        Text("Back", bundle: .module)
                    }
                    .assignedSettingsButtonStyle()
                }

                if let next = AgentChannelSetupFlow.next(after: selection, in: sections) {
                    Button {
                        withAnimation(theme.motion.quick) {
                            selection = next
                        }
                    } label: {
                        HStack(spacing: theme.space.s4) {
                            Text("Continue", bundle: .module)
                            Image(systemName: "chevron.right")
                                .glyphSize(.micro, weight: .semibold)
                        }
                    }
                    .assignedSettingsButtonStyle()
                }
            }

            footerTrailing
        }
    }
}

// MARK: - Sheet Action Button

/// Footer button with a built-in busy spinner, used for Save / Test actions
/// in channel sheets.
struct AgentChannelSheetActionButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let busyTitle: String
    let isBusy: Bool
    var isPrimary = false
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s6) {
                if isBusy {
                    SettingsSpinner(size: .mini)
                }
                Text(LocalizedStringKey(isBusy ? busyTitle : title), bundle: .module)
            }
        }
        .assignedSettingsButtonStyle(isDestructive ? .destructive : (isPrimary ? .primary : .secondary))
    }
}

// MARK: - Advanced Disclosure

/// Collapsed-by-default section for rarely used options, so channel sheets
/// stay focused on the fields most users need. Now the shared
/// `SettingsAdvancedDisclosure` (DesignSystem); kept as a name so the
/// channel sheets read the same as before.
typealias AgentChannelAdvancedSection = SettingsAdvancedDisclosure

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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s6) {
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)

                if let requirementHint {
                    Text(verbatim: "·")
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                    Text(LocalizedStringKey(requirementHint), bundle: .module)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                }

                Spacer()

                if saved {
                    HStack(spacing: theme.space.s4) {
                        Image(systemName: "lock.fill")
                            .glyphSize(.tiny)
                        Text("Stored in Keychain", bundle: .module)
                            .font(SettingsFont.footnote)
                    }
                    .foregroundColor(theme.text.tertiary)

                    Button(action: onRemove) {
                        Text("Remove", bundle: .module)
                            .font(SettingsFont.chip)
                            .foregroundColor(theme.status.error.foreground)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Text("Not saved", bundle: .module)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
            }

            SettingsTextField(placeholder: promptText, text: $text, monospaced: true, isSecure: true)
        }
    }

    private var promptText: String {
        saved ? L("Leave blank to keep current") : LCached(placeholder)
    }
}

// MARK: - Section Heading

/// Small bold heading for a group of fields inside a setup section, used
/// where the rail already conveys progress so no step number is needed.
struct AgentChannelSectionHeading: View {
    let title: String
    /// Optional one-line explanation under the heading.
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        SettingsSectionHeader(title: title, subtitle: detail)
    }
}

// MARK: - Auto-Reply Off Notice


/// Inline warning shown under the dispatch routing controls when the
/// responding agent's applicable plugin tools exceed the channel preload
/// ceiling. Past the cap, the overflow tools are not preloaded into channel
/// sessions and small local models rarely self-serve through
/// `capabilities_load`, so without this notice the degradation is invisible:
/// installing one more plugin silently changes which tools "just work" over
/// the channel. Renders nothing when the agent is within the cap.
struct AgentChannelPluginPreloadOverflowNotice: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let agentId: UUID?

    private var overflowCount: Int {
        guard let agentId else { return 0 }
        return AgentChannelInboundRelay.preloadOverflowCount(
            registered: ToolRegistry.shared.registeredPluginToolNames,
            granted: AgentManager.shared.effectiveEnabledToolNames(for: agentId)
        )
    }

    var body: some View {
        let overflow = overflowCount
        if overflow > 0 {
            Label {
                Text(
                    "This agent has \(overflow) more plugin tools than channel messages preload. The extra tools may not respond over this channel. Narrow the agent's tool selection to make every tool available.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .glyphSize(.micro)
            }
            .foregroundColor(themeManager.currentTheme.status.warning.foreground)
        }
    }
}

// MARK: - Copyable Command

/// Monospaced command / message row with a copy button, for setup steps that
/// ask the user to paste something elsewhere (BotFather commands, invite
/// URLs, test messages).
struct AgentChannelCopyableCommand: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let command: String
    /// Optional short explanation rendered next to the command.
    var caption: String?
    /// 1 (default) keeps a single truncated line; higher values wrap a recipe.
    var lineLimit: Int = 1
    /// Called after the command is copied, e.g. to show a status toast.
    var onCopied: (() -> Void)?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            if let caption, lineLimit > 1 {
                Text(LocalizedStringKey(caption), bundle: .module)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
            HStack(alignment: lineLimit > 1 ? .top : .center, spacing: theme.space.s8) {
                Text(command)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(lineLimit)
                    .truncationMode(lineLimit > 1 ? .tail : .middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, theme.space.s8)
                    .padding(.vertical, theme.space.s6)
                    .frame(maxWidth: lineLimit > 1 ? .infinity : nil, alignment: .leading)
                    .settingsChrome(.control)
                Button {
                    #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    #endif
                    onCopied?()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .glyphSize(.micro, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.text.link)
                .help(Text("Copy", bundle: .module))

                if let caption, lineLimit == 1 {
                    Text(LocalizedStringKey(caption), bundle: .module)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if lineLimit == 1 {
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Setup Link

/// Accent-colored external link for "where do I create this bot" guidance,
/// mirroring the provider setup links on the Providers tab.
struct AgentChannelSetupLink: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let url: URL

    var body: some View {
        Button {
            #if os(macOS)
                NSWorkspace.shared.open(url)
            #endif
        } label: {
            HStack(spacing: theme.space.s4) {
                Image(systemName: "link.circle.fill")
                    .glyphSize(.footnote)
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(SettingsFont.smallLabel)
            }
            .foregroundColor(themeManager.currentTheme.text.link)
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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)

            SettingsTextEditor(
                text: $text,
                placeholder: placeholder.isEmpty
                    ? nil : String(localized: String.LocalizationValue(placeholder), bundle: .module),
                minHeight: 52,
                monospaced: true
            )

            Text(LocalizedStringKey(help), bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
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
        isError ? theme.status.warning.foreground : theme.status.success.foreground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(alignment: .top, spacing: theme.space.s8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .glyphSize(.label, weight: .semibold)
                    .foregroundColor(tint)
                Text(message)
                    .font(SettingsFont.caption)
                    .foregroundColor(tint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            ForEach(details, id: \.self) { detail in
                HStack(alignment: .top, spacing: theme.space.s8) {
                    Image(systemName: "arrow.turn.down.right")
                        .glyphSize(.micro, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                        .padding(.top, theme.space.s2)
                    Text(detail)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.leading, theme.space.s24)
            }
        }
        .padding(theme.space.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.tinted(tint))
        .task(id: message) {
            guard onAutoClear != nil, !isError, details.isEmpty else { return }
            try? await Task.sleep(for: Self.autoClearDelay)
            guard !Task.isCancelled else { return }
            onAutoClear?()
        }
    }
}

// MARK: - Discovery Selector Search Field

/// Compact inline search field shown above a discovery selector list
/// (channels, people), with a clear button once a query is typed.
struct AgentChannelSelectorSearchField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Placeholder, already localized by the caller.
    let placeholder: String
    @Binding var text: String

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        SearchField(text: $text, placeholder: LocalizedStringKey(placeholder), fillsAvailableWidth: true)
    }
}

// MARK: - Discovery Selector List Card

/// Card rendering an `AgentChannelSelectorList.Shaped` result: selected
/// entries pinned in a "Selected" group above the rest, a notice when the
/// browse cap hid part of the unselected tail, and an empty-state hint when
/// nothing matches. Row content is provider-specific and injected; rows
/// receive the shaped item so selection state travels with the ForEach data
/// and lazy cells refresh when a toggle changes only the selection.
struct AgentChannelSelectorListCard<
    Entry: Identifiable & Equatable, State: Equatable, RowContent: View
>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let shaped: AgentChannelSelectorList.Shaped<Entry, State>
    /// Hint shown when nothing matches, already localized by the caller.
    let emptyText: String
    var maxHeight: CGFloat = 220
    @ViewBuilder let row: (AgentChannelSelectorList.Item<Entry, State>) -> RowContent

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var showsGroupLabels: Bool {
        !shaped.selected.isEmpty && !shaped.unselected.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if shaped.isEmpty {
                Text(emptyText)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, theme.space.s16)
            } else {
                ScrollView {
                    // Deliberately non-lazy: on macOS, LazyVStack cells inside
                    // nested scroll views are re-used without re-invoking row
                    // content, leaving stale selection checkmarks after a
                    // toggle. The shaping cap bounds the row count, so eager
                    // rendering stays cheap.
                    VStack(spacing: 0) {
                        if showsGroupLabels {
                            groupLabel(Text("Selected", bundle: .module))
                        }
                        rows(shaped.selected, dividerAfterLast: !shaped.unselected.isEmpty)
                        if showsGroupLabels {
                            groupLabel(Text("Everything else", bundle: .module))
                        }
                        rows(shaped.unselected, dividerAfterLast: shaped.hiddenCount > 0)
                        if shaped.hiddenCount > 0 {
                            truncationNotice
                        }
                    }
                }
                .frame(maxHeight: maxHeight)
            }
        }
        .settingsChrome(.surface)
    }

    @ViewBuilder
    private func rows(
        _ items: [AgentChannelSelectorList.Item<Entry, State>],
        dividerAfterLast: Bool
    ) -> some View {
        ForEach(items) { item in
            row(item)
            if dividerAfterLast || item.id != items.last?.id {
                Divider().foregroundColor(theme.border.default)
            }
        }
    }

    private func groupLabel(_ label: Text) -> some View {
        HStack {
            label
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.tertiary)
            Spacer()
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.top, theme.space.s8)
        .padding(.bottom, theme.space.s4)
        .background(theme.surface.hover)
    }

    private var truncationNotice: some View {
        Group {
            if shaped.isSearching {
                Text(
                    "\(shaped.hiddenCount) more matches — keep typing to narrow the list.",
                    bundle: .module
                )
            } else {
                Text("\(shaped.hiddenCount) more not shown — search to find them.", bundle: .module)
            }
        }
        .font(SettingsFont.footnote)
        .foregroundColor(theme.text.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, theme.space.s8)
    }
}

// MARK: - Discovery Selector Toggle

/// Capsule toggle for one grant on a selector row (Read, Write, Allow).
/// Selected state is unmistakable: filled checkmark, accent tint, and an
/// accent-tinted capsule instead of the neutral one.
struct AgentChannelSelectorToggle: View {
    /// Title, already localized by the caller.
    let title: String
    let selected: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        FilterChip(title, icon: selected ? "checkmark.circle.fill" : "circle", isSelected: selected, action: action)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
    }
}
