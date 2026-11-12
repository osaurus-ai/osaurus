//
//  ClaudePluginDetailView.swift
//  osaurus
//
//  Detail view for an installed Claude plugin. Mirrors
//  `PluginDetailView`'s layout (hero, banners, sections, external
//  links) with Claude-specific surfaces:
//   - userConfig banner + Configure button.
//   - Components section grouped by kind (skills / schedules /
//     slash commands / MCP) with per-item nested rows. Each row
//     opens a popover preview (`SkillPreviewView`, etc.) with the
//     full content and a "0 imported" placeholder for kinds the
//     plugin didn't ship.
//   - Stdio MCP rows render inline in the MCP group with a Restart
//     button and execution-host badge.
//   - CHANGELOG fetched lazily from `<source>/CHANGELOG.md`.
//   - "Not honored yet" notices for hooks / lspServers / etc. so
//     authors aren't surprised by silently dropped components.
//

import AppKit
import SwiftUI

struct ClaudePluginDetailView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let plugin: ClaudePluginInstalled
    let onBack: () -> Void
    let onUpdate: (() async throws -> Void)?
    let onUninstall: (() async throws -> Void)?
    let onConfigure: (() -> Void)?
    let onChange: () -> Void

    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showDeleteConfirm = false
    @State private var changelogContent: String?
    @State private var didLoadChangelog: Bool = false

    private var snapshot: ClaudePluginManifestSnapshot? { plugin.snapshot }

    private var pluginColor: Color {
        plugin.hasUpdate ? theme.status.warning.foreground : theme.action.primary.default.background
    }

    private var hasUserConfig: Bool {
        !(snapshot?.userConfigSpec.isEmpty ?? true)
    }

    var body: some View {
        SettingsPage {
            detailHeader
        } content: {
            heroMetadata

            if hasUserConfig, let onConfigure {
                userConfigBanner(onConfigure: onConfigure)
            }

            if plugin.needsPostInstallAttention {
                installOutcomeNotice
            }

            if let snap = snapshot, !snap.keywords.isEmpty {
                keywordsSection(snap.keywords)
            }

            componentsSection

            if let snap = snapshot,
                !snap.declaresUnsupportedComponents.isEmpty || snap.declaresHooks
            {
                unsupportedNotice(snapshot: snap)
            }

            if let changelog = changelogContent, !changelog.isEmpty {
                changelogSection(changelog)
            }

            externalLinksSection
        }
        .settingsBackDestination("Plugins") { onBack() }
        .onAppear { loadChangelogIfNeeded() }
        .themedAlert(
            L("Error"),
            isPresented: $showError,
            message: errorMessage ?? L("Unknown error"),
            primaryButton: .primary("OK") {}
        )
        .themedAlert(
            L("Uninstall Plugin"),
            isPresented: $showDeleteConfirm,
            message:
                L("Are you sure you want to uninstall \"\(plugin.displayName)\"? This action cannot be undone."),
            primaryButton: .destructive(L("Uninstall")) {
                guard let onUninstall else { return }
                Task {
                    do {
                        try await onUninstall()
                        onChange()
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    // MARK: - Header

    @ViewBuilder
    private var detailHeader: some View {
        if onUninstall != nil {
            detailHeader {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text("Uninstall", bundle: .module)
                }
            }
        } else {
            detailHeader { EmptyView() }
        }
    }

    private func detailHeader<Overflow: View>(@ViewBuilder overflow: @escaping () -> Overflow) -> some View {
        SettingsPageHeader(
            title: plugin.displayName,
            verbatimTitle: true,
            subtitle: snapshot?.description,
            verbatimSubtitle: true,
            leading: {
                SettingsIconTile(icon: "puzzlepiece.extension.fill", size: 32, tint: pluginColor)
            },
            status: {
                if let version = plugin.version {
                    StatusChip(L("v\(version)"), tone: .neutral)
                }
            },
            primary: {
                if plugin.hasUpdate, let onUpdate {
                    SettingsButton(.primary, "Update", icon: "arrow.up.circle.fill") {
                        Task {
                            do { try await onUpdate() } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }
                }
            },
            overflow: overflow
        )
    }

    // MARK: - Metadata

    private var heroMetadata: some View {
        HStack(spacing: theme.space.s12) {
            if let authorName = snapshot?.authorName, !authorName.isEmpty {
                heroStatBadge(icon: "person", text: authorName, color: theme.text.tertiary)
            }
            if let license = snapshot?.license, !license.isEmpty {
                heroStatBadge(icon: "doc.text", text: license, color: theme.text.tertiary)
            }
            if let snap = snapshot {
                heroStatBadge(
                    icon: "calendar",
                    text: claudePluginRelativeDate(snap.installedAt),
                    color: theme.text.tertiary
                )
            }
            if plugin.totalCount > 0 {
                heroStatBadge(
                    icon: "shippingbox.fill",
                    text: plugin.totalCount == 1
                        ? L("1 artifact")
                        : L("\(plugin.totalCount) artifacts"),
                    color: theme.action.primary.default.background
                )
            }
        }
    }

    private func heroStatBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: theme.space.s4) {
            Image(systemName: icon).glyphSize(.micro)
            Text(text)
                .font(SettingsFont.smallLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(color)
    }

    // MARK: - Sections

    private func userConfigBanner(onConfigure: @escaping () -> Void) -> some View {
        HStack(spacing: theme.space.s10) {
            Image(systemName: "slider.horizontal.3")
                .glyphSize(.body)
                .foregroundColor(theme.text.link)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text("Configuration available", bundle: .module)
                    .font(SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                let fieldCount = snapshot?.userConfigSpec.count ?? 0
                Text(
                    fieldCount == 1
                        ? L("This plugin declared an option you can configure (1 field).")
                        : L("This plugin declared options you can configure (\(fieldCount) fields).")
                )
                .textStyle(.caption)
                .foregroundColor(theme.text.secondary)
            }
            Spacer()
            Button(action: onConfigure) {
                Text("Configure", bundle: .module)
            }
            .assignedSettingsButtonStyle(.primary)
        }
        .padding(theme.space.s12)
        .settingsChrome(.selected)
    }

    private var installOutcomeNotice: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "exclamationmark.circle")
                    .glyphSize(.label, weight: .semibold)
                    .foregroundColor(theme.status.warning.foreground)
                Text("Import needs attention", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Spacer()
            }
            Text(
                "Some declared components require setup, sign-in, or were skipped during import.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.secondary)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                ForEach(installOutcomeMessages, id: \.self) { message in
                    Text("• \(message)")
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(theme.space.s12)
        .settingsChrome(.status(.warning))
    }

    private var installOutcomeMessages: [String] {
        var messages: [String] = []
        if let outcome = snapshot?.installOutcome {
            messages.append(
                contentsOf: outcome.schedulesNeedingCron.map {
                    "Schedule needs review: \($0)"
                }
            )
            messages.append(
                contentsOf: outcome.stdioProvidersNeedingConfiguration.map {
                    providerMessage(
                        prefix: "Stdio MCP needs env vars",
                        provider: $0
                    )
                }
            )
            messages.append(
                contentsOf: outcome.placeholderTokensSkipped.map {
                    providerMessage(
                        prefix: "MCP needs token",
                        provider: $0
                    )
                }
            )
            messages.append(
                contentsOf: outcome.oauthProvidersNeedingSignIn.map {
                    "OAuth sign-in required: \($0)"
                }
            )
            messages.append(
                contentsOf: outcome.stdioProvidersBlockedNoSandbox.map {
                    "Stdio MCP skipped, sandbox unavailable: \($0)"
                }
            )
            messages.append(
                contentsOf: outcome.skippedStdioMCPServers.map {
                    "MCP entry skipped: \($0)"
                }
            )
            messages.append(contentsOf: outcome.errors.map { "Install error: \($0)" })
        }

        if messages.isEmpty, plugin.hasPartialImport {
            let missing = plugin.missingDeclaredCounts
            if missing.skill > 0 {
                messages.append("\(missing.skill) skill\(missing.skill == 1 ? "" : "s") declared but not imported")
            }
            if missing.schedule > 0 {
                messages.append(
                    "\(missing.schedule) schedule\(missing.schedule == 1 ? "" : "s") declared but not imported"
                )
            }
            if missing.command > 0 {
                messages.append(
                    "\(missing.command) command\(missing.command == 1 ? "" : "s") declared but not imported"
                )
            }
            if missing.mcp > 0 {
                messages.append("\(missing.mcp) MCP provider\(missing.mcp == 1 ? "" : "s") declared but not imported")
            }
        }

        return messages.isEmpty
            ? ["Declared components differ from imported artifacts."]
            : messages
    }

    private func providerMessage(
        prefix: String,
        provider: ClaudePluginManifestSnapshot.PendingProvider
    ) -> String {
        guard !provider.missingKeys.isEmpty else {
            return "\(prefix): \(provider.name)"
        }
        return "\(prefix): \(provider.name) (\(provider.missingKeys.joined(separator: ", ")))"
    }

    private func keywordsSection(_ keywords: [String]) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            sectionHeader(title: "Keywords")
            // Simple horizontal-flow using ViewThatFits-style wrap; for
            // brevity we line them up with HStack + wraps via FlexView.
            FlowLayout(spacing: theme.space.s6) {
                ForEach(keywords, id: \.self) { keyword in
                    StatusChip(keyword, tone: .accent)
                }
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
    }

    private var componentsSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            sectionHeader(title: "Components")
            if plugin.totalCount == 0 {
                Text("No artifacts installed for this plugin.", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
            } else {
                VStack(alignment: .leading, spacing: theme.space.s14) {
                    ForEach(ClaudePluginArtifactKind.allCases, id: \.self) { kind in
                        componentGroup(kind: kind)
                    }
                }
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
    }

    @ViewBuilder
    private func componentGroup(kind: ClaudePluginArtifactKind) -> some View {
        let count = plugin.counts[kind]
        VStack(alignment: .leading, spacing: theme.space.s8) {
            groupHeader(kind: kind, count: count)
            if count == 0 {
                groupEmptyPlaceholder(kind: kind)
            } else {
                VStack(spacing: theme.space.s6) {
                    switch kind {
                    case .skill:
                        ForEach(plugin.skills) { skill in
                            skillRow(skill)
                        }
                    case .schedule:
                        ForEach(plugin.schedules) { schedule in
                            scheduleRow(schedule)
                        }
                    case .command:
                        ForEach(plugin.commands) { command in
                            commandRow(command)
                        }
                    case .mcp:
                        ForEach(plugin.mcps) { mcp in
                            mcpRow(mcp)
                        }
                    }
                }
            }
        }
    }

    private func groupHeader(kind: ClaudePluginArtifactKind, count: Int) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: kind.icon)
                .glyphSize(.caption, weight: .medium)
                .foregroundColor(kind.tint(theme))
            Text(kind.titlePlural)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
            if count > 0 {
                Text("\(count)")
                    .font(SettingsFont.smallLabel.monospacedDigit())
                    .foregroundColor(theme.text.secondary)
            } else {
                Text("· 0 imported", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.tertiary)
            }
            Spacer()
        }
    }

    /// Subdued italic placeholder shown for artifact kinds the plugin
    /// declared zero of. Communicates "discovery ran, this plugin just
    /// doesn't ship any" — answers the user's "are we importing
    /// commands?" question for plugins like `claude-for-legal` that
    /// have none.
    @ViewBuilder
    private func groupEmptyPlaceholder(kind: ClaudePluginArtifactKind) -> some View {
        let message: String = {
            let declared = plugin.declaredCount(for: kind)
            if declared > 0 {
                switch kind {
                case .skill:
                    return L("No skills imported; \(declared) declared.")
                case .schedule:
                    return L("No schedules imported; \(declared) declared.")
                case .command:
                    return L("No slash commands imported; \(declared) declared.")
                case .mcp:
                    return L("No MCP providers imported; \(declared) declared.")
                }
            } else {
                switch kind {
                case .skill: return L("No skills shipped with this plugin.")
                case .schedule: return L("No schedules shipped with this plugin.")
                case .command: return L("No slash commands shipped with this plugin.")
                case .mcp: return L("No MCP providers shipped with this plugin.")
                }
            }
        }()
        SettingsEmptyState(inline: kind.icon, title: message)
    }

    // MARK: - Per-kind row builders

    private func skillRow(_ skill: InstalledClaudeSkill) -> some View {
        ArtifactNestedRow(
            theme: theme,
            icon: ClaudePluginArtifactKind.skill.icon,
            tint: ClaudePluginArtifactKind.skill.tint(theme),
            title: skill.name,
            subtitle: skill.description.isEmpty ? (skill.category ?? "Skill") : skill.description,
            subtitleMonospaced: false,
            trailing: { EmptyView() },
            preview: { SkillPreviewView(theme: theme, skill: skill) }
        )
    }

    private func scheduleRow(_ schedule: InstalledClaudeSchedule) -> some View {
        let subtitle: String = {
            if let next = schedule.nextRunText, !next.isEmpty {
                return "\(schedule.frequencyText) (\(next))"
            }
            return schedule.frequencyText
        }()
        return ArtifactNestedRow(
            theme: theme,
            icon: ClaudePluginArtifactKind.schedule.icon,
            tint: ClaudePluginArtifactKind.schedule.tint(theme),
            title: schedule.name,
            subtitle: subtitle,
            subtitleMonospaced: false,
            trailing: {
                if schedule.isEnabled {
                    StatusChip(L("Enabled"), tone: .success, icon: "checkmark.circle.fill")
                } else {
                    StatusChip(L("Paused"), tone: .warning, icon: "pause.circle.fill")
                }
            },
            preview: { SchedulePreviewView(theme: theme, schedule: schedule) }
        )
    }

    private func commandRow(_ command: InstalledClaudeCommand) -> some View {
        let subtitle: String = {
            if !command.description.isEmpty { return command.description }
            return command.templatePreview ?? "Slash command"
        }()
        return ArtifactNestedRow(
            theme: theme,
            icon: command.icon.isEmpty ? ClaudePluginArtifactKind.command.icon : command.icon,
            tint: ClaudePluginArtifactKind.command.tint(theme),
            title: "/\(command.name)",
            subtitle: subtitle,
            subtitleMonospaced: false,
            trailing: { EmptyView() },
            preview: { CommandPreviewView(theme: theme, command: command) }
        )
    }

    private func mcpRow(_ mcp: InstalledClaudeMCP) -> some View {
        ArtifactNestedRow(
            theme: theme,
            icon: mcp.isStdio ? "terminal" : ClaudePluginArtifactKind.mcp.icon,
            tint: ClaudePluginArtifactKind.mcp.tint(theme),
            title: mcp.name,
            subtitle: mcp.subtitle,
            subtitleMonospaced: mcp.isStdio,
            subtitleTruncation: mcp.isStdio ? .middle : .tail,
            trailing: {
                transportBadge(for: mcp)
                if mcp.isStdio {
                    executionHostBadge(for: mcp.executionHost)
                    MCPRestartButton(providerId: mcp.id, theme: theme)
                }
                if !mcp.enabled {
                    StatusChip(L("Disabled"), tone: .warning, icon: "pause.circle.fill")
                }
            },
            preview: { MCPPreviewView(theme: theme, mcp: mcp) }
        )
    }

    @ViewBuilder
    private func transportBadge(for mcp: InstalledClaudeMCP) -> some View {
        if mcp.isStdio {
            StatusChip("stdio", tint: theme.dataInk(.purple), icon: "terminal")
        } else {
            StatusChip("HTTP", tone: .accent, icon: "network")
        }
    }

    private func executionHostBadge(for host: MCPProviderExecutionHost) -> some View {
        let isSandbox = host == .sandbox
        return StatusChip(
            isSandbox ? "Sandbox" : "Host",
            tint: isSandbox ? theme.action.primary.default.background : theme.dataInk(.orange),
            icon: isSandbox ? "shield.lefthalf.filled" : "macwindow"
        )
    }

    private func unsupportedNotice(snapshot: ClaudePluginManifestSnapshot) -> some View {
        let parts: [String] = {
            var list: [String] = []
            if snapshot.declaresHooks { list.append("hooks") }
            list.append(contentsOf: snapshot.declaresUnsupportedComponents)
            return list
        }()
        return HStack(spacing: theme.space.s10) {
            Image(systemName: "exclamationmark.bubble")
                .glyphSize(.body)
                .foregroundColor(theme.status.warning.foreground)
            SettingsRowText(compact: true) {
                Text("Some components are not honored yet", bundle: .module)
            } description: {
                Text(
                    "This plugin declared: \(parts.joined(separator: ", ")). Osaurus stores the metadata but does not yet execute these surfaces.",
                    bundle: .module
                )
                .foregroundColor(theme.text.secondary)
            }
            Spacer()
        }
        .padding(theme.space.s12)
        .settingsChrome(.status(.warning))
    }

    private func changelogSection(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            sectionHeader(title: "Changelog")
            ScrollView {
                Text(content)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 240)
            .padding(theme.space.s12)
            .settingsChrome(.control)
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
    }

    private var externalLinksSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            sectionHeader(title: "External links")
            VStack(spacing: theme.space.s6) {
                if let repo = snapshot?.repository, !repo.isEmpty,
                    let url = URL(string: repo)
                {
                    linkRow(icon: "chevron.left.forwardslash.chevron.right", title: "Repository", url: url)
                } else if let snap = snapshot,
                    let url = URL(string: snap.githubSourceURL)
                {
                    linkRow(
                        icon: "chevron.left.forwardslash.chevron.right",
                        title: "Source on GitHub",
                        url: url
                    )
                }
                if let homepage = snapshot?.homepage, !homepage.isEmpty,
                    let url = URL(string: homepage)
                {
                    linkRow(icon: "globe", title: "Homepage", url: url)
                }
                if let authorURL = snapshot?.authorURL, !authorURL.isEmpty,
                    let url = URL(string: authorURL)
                {
                    linkRow(icon: "person.circle", title: "Author", url: url)
                }
                if let email = snapshot?.authorEmail, !email.isEmpty,
                    let url = URL(string: "mailto:\(email)")
                {
                    linkRow(icon: "envelope", title: email, url: url)
                }
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
    }

    private func linkRow(icon: String, title: String, url: URL) -> some View {
        Button(action: { NSWorkspace.shared.open(url) }) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: icon)
                    .glyphSize(.caption)
                    .foregroundColor(theme.text.link)
                Text(title)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.primary)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .glyphSize(.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .settingsChrome(.inset)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func sectionHeader(title: String) -> some View {
        SettingsSectionHeader(title: title)
    }

    // MARK: - Helpers

    private func loadChangelogIfNeeded() {
        guard !didLoadChangelog, let snap = snapshot else { return }
        didLoadChangelog = true
        Task { @MainActor in
            let path: String = {
                guard let p = snap.sourcePath, !p.isEmpty else {
                    return "CHANGELOG.md"
                }
                return "\(p)/CHANGELOG.md"
            }()
            let repo = GitHubRepo(
                owner: snap.sourceOwner,
                name: snap.sourceRepo,
                branch: snap.sourceBranch ?? "main"
            )
            let content = await GitHubFetchLimiter.shared.runNoThrow {
                await GitHubSkillService.shared.fetchOptionalFileContent(
                    from: repo,
                    path: path
                )
            }
            if let content {
                changelogContent = content
            }
        }
    }

}

/// Shared "X ago" formatter used by the hero header (installedAt) and
/// the schedule preview (lastRunAt). Kept file-private so the rest of
/// the module doesn't pick it up by accident.
fileprivate func claudePluginRelativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

// MARK: - Shared nested row primitives

/// Shared "nested row" recipe used by every kind under Components.
/// Keeps the icon-box + title/subtitle + trailing badge stack
/// consistent and matches the recipe already used by `linkRow` and the
/// older `componentRow` (44pt-ish row, corner 8, primaryBackground
/// .opacity 0.45).
///
/// Tapping the icon + title region toggles a Preview popover anchored
/// to the trailing edge; the trailing slot retains its own gesture
/// recognizers so Restart / inline buttons keep working.
private struct ArtifactNestedRow<Trailing: View, Preview: View>: View {
    let theme: ThemeProtocol
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let subtitleMonospaced: Bool
    let subtitleTruncation: Text.TruncationMode
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let preview: () -> Preview

    @State private var isHovering = false
    @State private var showPreview = false

    init(
        theme: ThemeProtocol,
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        subtitleMonospaced: Bool = false,
        subtitleTruncation: Text.TruncationMode = .tail,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder preview: @escaping () -> Preview
    ) {
        self.theme = theme
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.subtitleMonospaced = subtitleMonospaced
        self.subtitleTruncation = subtitleTruncation
        self.trailing = trailing
        self.preview = preview
    }

    var body: some View {
        HStack(spacing: theme.space.s10) {
            // Leading region — the only area that triggers the popover.
            // Wrapping the tap gesture here (instead of on the whole
            // row) keeps the trailing controls free for their own
            // gestures (Restart button, etc.).
            HStack(spacing: theme.space.s10) {
                Image(systemName: icon)
                    .glyphSize(.caption, weight: .medium)
                    .foregroundColor(tint)
                    .frame(width: 28, height: 28)
                    .settingsChrome(.tinted(tint))

                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(title)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .textStyle(subtitleMonospaced ? .code : .caption)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(1)
                            .truncationMode(subtitleTruncation)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { showPreview.toggle() }
            .onPopoverHover { isHovering = $0 }
            .popover(isPresented: $showPreview, arrowEdge: .trailing) {
                preview()
                    .frame(width: 420)
            }

            HStack(spacing: theme.space.s6) {
                trailing()
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.inset)
        .animation(theme.motion.quick, value: isHovering)
    }
}

/// Inline Restart button rendered in the trailing slot of stdio MCP
/// rows. Reconnects the subprocess via `MCPProviderManager.reconnect`.
private struct MCPRestartButton: View {
    let providerId: UUID
    let theme: ThemeProtocol

    @State private var isRestarting = false

    var body: some View {
        Button(action: restart) {
            HStack(spacing: theme.space.s4) {
                if isRestarting {
                    SettingsSpinner(size: .mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .glyphSize(.micro, weight: .semibold)
                }
                Text("Restart", bundle: .module)
                    .font(SettingsFont.smallLabel)
            }
            .foregroundColor(theme.text.link)
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s4)
            .settingsChrome(.selected)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isRestarting)
        .localizedHelp("Restart the stdio MCP subprocess")
    }

    private func restart() {
        guard !isRestarting else { return }
        isRestarting = true
        Task { @MainActor in
            try? await MCPProviderManager.shared.reconnect(providerId: providerId)
            isRestarting = false
        }
    }
}

// MARK: - Preview popovers

/// Shared chrome for every per-kind preview popover. Provides the
/// header (icon box + title + optional subtitle + status pills) and a
/// scrollable body slot so each kind's preview reads consistently.
private struct ArtifactPreviewCard<Pills: View, Content: View>: View {
    let theme: ThemeProtocol
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String?
    @ViewBuilder let pills: () -> Pills
    @ViewBuilder let content: () -> Content

    init(
        theme: ThemeProtocol,
        icon: String,
        tint: Color,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder pills: @escaping () -> Pills,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.theme = theme
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.pills = pills
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            HStack(alignment: .top, spacing: theme.space.s12) {
                Image(systemName: icon)
                    .glyphSize(.medium, weight: .medium)
                    .foregroundColor(tint)
                    .frame(width: 36, height: 36)
                    .settingsChrome(.tinted(tint))
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(title)
                        .font(SettingsFont.cardTitle)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(2)
                    }
                    pills()
                        .padding(.top, theme.space.s2)
                }
                Spacer(minLength: 0)
            }
            .padding(theme.space.s12)

            Divider().background(theme.border.subtle)

            content()
                .padding(theme.space.s12)
        }
        .background(theme.surface.raised)
    }
}

/// Skill preview: instructions body in a constrained ScrollView plus
/// keyword chips. The full editor lives in the Skills tab; this is a
/// read-only quick look.
private struct SkillPreviewView: View {
    let theme: ThemeProtocol
    let skill: InstalledClaudeSkill

    var body: some View {
        ArtifactPreviewCard(
            theme: theme,
            icon: ClaudePluginArtifactKind.skill.icon,
            tint: ClaudePluginArtifactKind.skill.tint(theme),
            title: skill.name,
            subtitle: skill.description.isEmpty ? nil : skill.description,
            pills: {
                HStack(spacing: theme.space.s6) {
                    if let category = skill.category, !category.isEmpty {
                        StatusChip(category, tone: .accent, icon: "tag")
                    }
                }
            },
            content: {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    metadataRow
                    if !skill.keywords.isEmpty {
                        keywordChips
                    }
                    instructionsBlock
                }
            }
        )
    }

    private var metadataRow: some View {
        HStack(spacing: theme.space.s12) {
            PreviewMeta(theme: theme, icon: "tag", label: "v\(skill.version)")
            if let author = skill.author, !author.isEmpty {
                PreviewMeta(theme: theme, icon: "person", label: author)
            }
            if skill.referenceCount > 0 {
                PreviewMeta(
                    theme: theme,
                    icon: "doc.text",
                    label: "\(skill.referenceCount) reference\(skill.referenceCount == 1 ? "" : "s")"
                )
            }
            if skill.assetCount > 0 {
                PreviewMeta(
                    theme: theme,
                    icon: "paperclip",
                    label: "\(skill.assetCount) asset\(skill.assetCount == 1 ? "" : "s")"
                )
            }
            Spacer(minLength: 0)
        }
    }

    private var keywordChips: some View {
        FlowLayout(spacing: theme.space.s4) {
            ForEach(skill.keywords, id: \.self) { keyword in
                StatusChip(keyword, tone: .accent)
            }
        }
    }

    @ViewBuilder
    private var instructionsBlock: some View {
        if skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No instructions body.", bundle: .module)
                .font(SettingsFont.rowDescription.italic())
                .foregroundColor(theme.text.tertiary)
        } else {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Instructions", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                ScrollView {
                    Text(skill.instructions)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(theme.space.s8)
                }
                .frame(maxHeight: 280)
                .settingsChrome(.inset)
            }
        }
    }
}

/// Schedule preview: frequency + next run + instructions body.
private struct SchedulePreviewView: View {
    let theme: ThemeProtocol
    let schedule: InstalledClaudeSchedule

    var body: some View {
        ArtifactPreviewCard(
            theme: theme,
            icon: ClaudePluginArtifactKind.schedule.icon,
            tint: ClaudePluginArtifactKind.schedule.tint(theme),
            title: schedule.name,
            subtitle: schedule.frequencyText,
            pills: {
                if schedule.isEnabled {
                    StatusChip(L("Enabled"), tone: .success, icon: "checkmark.circle.fill")
                } else {
                    StatusChip(L("Paused"), tone: .warning, icon: "pause.circle.fill")
                }
            },
            content: {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    metadataRow
                    instructionsBlock
                }
            }
        )
    }

    private var metadataRow: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            if let next = schedule.nextRunText, !next.isEmpty {
                PreviewMeta(
                    theme: theme,
                    icon: "clock.arrow.circlepath",
                    label: "Next run: \(next)"
                )
            }
            if let last = schedule.lastRunAt {
                PreviewMeta(
                    theme: theme,
                    icon: "clock",
                    label: "Last run: \(claudePluginRelativeDate(last))"
                )
            }
            if let folder = schedule.folderPath, !folder.isEmpty {
                PreviewMeta(theme: theme, icon: "folder", label: folder)
            }
        }
    }

    @ViewBuilder
    private var instructionsBlock: some View {
        if schedule.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No instructions configured.", bundle: .module)
                .font(SettingsFont.rowDescription.italic())
                .foregroundColor(theme.text.tertiary)
        } else {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Instructions", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                ScrollView {
                    Text(schedule.instructions)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(theme.space.s8)
                }
                .frame(maxHeight: 240)
                .settingsChrome(.inset)
            }
        }
    }
}

/// Slash-command preview: shows the full template body so users can
/// see exactly what gets injected when they pick `/name`.
private struct CommandPreviewView: View {
    let theme: ThemeProtocol
    let command: InstalledClaudeCommand

    var body: some View {
        ArtifactPreviewCard(
            theme: theme,
            icon: command.icon.isEmpty ? ClaudePluginArtifactKind.command.icon : command.icon,
            tint: ClaudePluginArtifactKind.command.tint(theme),
            title: "/\(command.name)",
            subtitle: command.description.isEmpty ? nil : command.description,
            pills: {
                StatusChip(command.kindLabel, tint: ClaudePluginArtifactKind.command.tint(theme), icon: "text.alignleft")
            },
            content: { templateBlock }
        )
    }

    @ViewBuilder
    private var templateBlock: some View {
        if let template = command.template,
            !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Template", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                ScrollView {
                    Text(template)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(theme.space.s8)
                }
                .frame(maxHeight: 280)
                .settingsChrome(.inset)
            }
        } else {
            Text("This command has no template body.", bundle: .module)
                .font(SettingsFont.rowDescription.italic())
                .foregroundColor(theme.text.tertiary)
        }
    }
}

/// MCP preview: full transport details (URL or command line) plus the
/// env dictionary, with sensitive values masked.
private struct MCPPreviewView: View {
    let theme: ThemeProtocol
    let mcp: InstalledClaudeMCP

    var body: some View {
        ArtifactPreviewCard(
            theme: theme,
            icon: mcp.isStdio ? "terminal" : ClaudePluginArtifactKind.mcp.icon,
            tint: ClaudePluginArtifactKind.mcp.tint(theme),
            title: mcp.name,
            subtitle: nil,
            pills: {
                HStack(spacing: theme.space.s6) {
                    if mcp.isStdio {
                        StatusChip("stdio", tint: theme.dataInk(.purple), icon: "terminal")
                        StatusChip(
                            mcp.executionHost == .sandbox ? "Sandbox" : "Host",
                            tint: mcp.executionHost == .sandbox
                                ? theme.action.primary.default.background : theme.dataInk(.orange),
                            icon: mcp.executionHost == .sandbox
                                ? "shield.lefthalf.filled" : "macwindow"
                        )
                    } else {
                        StatusChip("HTTP", tone: .accent, icon: "network")
                    }
                    if !mcp.enabled {
                        StatusChip(L("Disabled"), tone: .warning, icon: "pause.circle.fill")
                    }
                }
            },
            content: {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    if mcp.isStdio {
                        monospaceField(label: "Command", value: commandLine)
                        if let cwd = mcp.workingDirectory, !cwd.isEmpty {
                            monospaceField(label: "Working directory", value: cwd)
                        }
                    } else {
                        monospaceField(label: "URL", value: mcp.url)
                    }
                    if !mcp.envEntries.isEmpty {
                        envBlock
                    }
                }
            }
        )
    }

    private var commandLine: String {
        mcp.args.isEmpty
            ? mcp.command
            : "\(mcp.command) \(mcp.args.joined(separator: " "))"
    }

    private func monospaceField(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Text(label, bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
            Text(value)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s8)
                .settingsChrome(.inset)
        }
    }

    private var envBlock: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Text("Environment", bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
            VStack(spacing: theme.space.s4) {
                ForEach(mcp.envEntries) { entry in
                    HStack(spacing: theme.space.s8) {
                        Text(entry.key)
                            .font(SettingsFont.monoSmall)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        if let value = entry.value {
                            Text(value)
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            StatusChip(L("[secret]"), tone: .warning)
                        }
                    }
                    .padding(.horizontal, theme.space.s8)
                    .padding(.vertical, theme.space.s6)
                    .settingsChrome(.inset)
                }
            }
        }
    }
}

/// Tiny icon + label metadata pill used by skill / schedule previews.
private struct PreviewMeta: View {
    let theme: ThemeProtocol
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: theme.space.s4) {
            Image(systemName: icon)
                .glyphSize(.micro)
            Text(label)
                .font(SettingsFont.rowDescription)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(theme.text.tertiary)
    }
}

// Keyword chips are arranged via the shared `FlowLayout` defined in
// `Views/Common/FlowLayout.swift` — no per-view redeclaration needed.
