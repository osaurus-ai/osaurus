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

    @State private var hasAppeared = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showDeleteConfirm = false
    @State private var changelogContent: String?
    @State private var didLoadChangelog: Bool = false

    private var snapshot: ClaudePluginManifestSnapshot? { plugin.snapshot }

    private var pluginColor: Color {
        plugin.hasUpdate ? .orange : theme.accentColor
    }

    private var hasUserConfig: Bool {
        !(snapshot?.userConfigSpec.isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeaderBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroHeader.padding(.bottom, 8)

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
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hasAppeared)
        .onAppear {
            withAnimation { hasAppeared = true }
            loadChangelogIfNeeded()
        }
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

    // MARK: - Header bar

    private var detailHeaderBar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Plugins", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            HStack(spacing: 6) {
                if onUninstall != nil {
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.errorColor)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(theme.errorColor.opacity(0.1)))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Uninstall")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    // MARK: - Hero

    private var heroHeader: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [pluginColor.opacity(0.2), pluginColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(pluginColor.opacity(0.3), lineWidth: 2)
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 28))
                    .foregroundColor(pluginColor)
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(plugin.displayName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    if let version = plugin.version {
                        Text("v\(version)", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                }

                if let description = snapshot?.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(3)
                }

                HStack(spacing: 12) {
                    if let authorName = snapshot?.authorName, !authorName.isEmpty {
                        heroStatBadge(
                            icon: "person",
                            text: authorName,
                            color: theme.tertiaryText
                        )
                    }
                    if let license = snapshot?.license, !license.isEmpty {
                        heroStatBadge(
                            icon: "doc.text",
                            text: license,
                            color: theme.tertiaryText
                        )
                    }
                    if let snap = snapshot {
                        heroStatBadge(
                            icon: "calendar",
                            text: claudePluginRelativeDate(snap.installedAt),
                            color: theme.tertiaryText
                        )
                    }
                    if plugin.totalCount > 0 {
                        heroStatBadge(
                            icon: "shippingbox.fill",
                            text: "\(plugin.totalCount) artifacts",
                            color: theme.accentColor
                        )
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                if plugin.hasUpdate, let onUpdate {
                    Button {
                        Task {
                            do { try await onUpdate() } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 12))
                            Text("Update", bundle: .module)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(Color.orange)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.secondaryBackground)
        )
    }

    private func heroStatBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(color)
    }

    // MARK: - Sections

    private func userConfigBanner(onConfigure: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14))
                .foregroundColor(theme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Configuration available", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "This plugin declared options you can configure (\(snapshot?.userConfigSpec.count ?? 0) field(s)).",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button(action: onConfigure) {
                Text("Configure", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(theme.accentColor)
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var installOutcomeNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text("Import needs attention", bundle: .module)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
            }
            Text(
                "Some declared components require setup, sign-in, or were skipped during import.",
                bundle: .module
            )
            .font(.system(size: 11.5))
            .foregroundColor(theme.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(installOutcomeMessages, id: \.self) { message in
                    Text("• \(message)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.warningColor.opacity(0.2), lineWidth: 1)
                )
        )
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
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "Keywords", icon: "tag")
            // Simple horizontal-flow using ViewThatFits-style wrap; for
            // brevity we line them up with HStack + wraps via FlexView.
            FlowLayout(spacing: 6) {
                ForEach(keywords, id: \.self) { keyword in
                    Text(keyword)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(theme.accentColor.opacity(0.1))
                        )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var componentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Components", icon: "shippingbox.fill")
            if plugin.totalCount == 0 {
                Text("No artifacts installed for this plugin.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ClaudePluginArtifactKind.allCases, id: \.self) { kind in
                        componentGroup(kind: kind)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func componentGroup(kind: ClaudePluginArtifactKind) -> some View {
        let count = plugin.counts[kind]
        VStack(alignment: .leading, spacing: 8) {
            groupHeader(kind: kind, count: count)
            if count == 0 {
                groupEmptyPlaceholder(kind: kind)
            } else {
                VStack(spacing: 6) {
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
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(kind.tint(theme))
            Text(kind.titlePlural)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(theme.primaryText)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(theme.secondaryText)
            } else {
                Text("· 0 imported", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
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
        Text(message)
            .font(.system(size: 11).italic())
            .foregroundColor(theme.tertiaryText)
            .padding(.leading, 4)
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
            trailing: {
                if !skill.enabled {
                    StatusCapsuleBadge(
                        icon: "pause.circle.fill",
                        text: "Disabled",
                        color: theme.warningColor
                    )
                }
            },
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
                    StatusCapsuleBadge(
                        icon: "checkmark.circle.fill",
                        text: "Enabled",
                        color: theme.successColor
                    )
                } else {
                    StatusCapsuleBadge(
                        icon: "pause.circle.fill",
                        text: "Paused",
                        color: theme.warningColor
                    )
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
                    StatusCapsuleBadge(
                        icon: "pause.circle.fill",
                        text: "Disabled",
                        color: theme.warningColor
                    )
                }
            },
            preview: { MCPPreviewView(theme: theme, mcp: mcp) }
        )
    }

    @ViewBuilder
    private func transportBadge(for mcp: InstalledClaudeMCP) -> some View {
        if mcp.isStdio {
            StatusCapsuleBadge(icon: "terminal", text: "stdio", color: .purple)
        } else {
            StatusCapsuleBadge(
                icon: "network",
                text: "HTTP",
                color: theme.accentColor
            )
        }
    }

    private func executionHostBadge(for host: MCPProviderExecutionHost) -> some View {
        let isSandbox = host == .sandbox
        return StatusCapsuleBadge(
            icon: isSandbox ? "shield.lefthalf.filled" : "macwindow",
            text: isSandbox ? "Sandbox" : "Host",
            color: isSandbox ? theme.accentColor : .orange
        )
    }

    private func unsupportedNotice(snapshot: ClaudePluginManifestSnapshot) -> some View {
        let parts: [String] = {
            var list: [String] = []
            if snapshot.declaresHooks { list.append("hooks") }
            list.append(contentsOf: snapshot.declaresUnsupportedComponents)
            return list
        }()
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 14))
                .foregroundColor(theme.warningColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Some components are not honored yet", bundle: .module)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "This plugin declared: \(parts.joined(separator: ", ")). Osaurus stores the metadata but does not yet execute these surfaces.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.warningColor.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func changelogSection(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Changelog", icon: "list.bullet.clipboard")
            ScrollView {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 240)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var externalLinksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "External links", icon: "link")
            VStack(spacing: 6) {
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
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func linkRow(icon: String, title: String, url: URL) -> some View {
        Button(action: { NSWorkspace.shared.open(url) }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(theme.accentColor)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.primaryBackground.opacity(0.45))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func sectionHeader(title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            Text(title, bundle: .module)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
        }
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
        HStack(spacing: 10) {
            // Leading region — the only area that triggers the popover.
            // Wrapping the tap gesture here (instead of on the whole
            // row) keeps the trailing controls free for their own
            // gestures (Restart button, etc.).
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tint.opacity(0.12))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(tint)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(
                                subtitleMonospaced
                                    ? .system(size: 11, design: .monospaced)
                                    : .system(size: 11)
                            )
                            .foregroundColor(theme.secondaryText)
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

            HStack(spacing: 6) {
                trailing()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    theme.primaryBackground.opacity(isHovering ? 0.7 : 0.45)
                )
        )
        .animation(.easeOut(duration: 0.12), value: isHovering)
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
            HStack(spacing: 4) {
                if isRestarting {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text("Restart", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.accentColor.opacity(0.12))
            )
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(0.14))
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(tint)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                    }
                    pills()
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            Divider().background(theme.primaryBorder.opacity(0.5))

            content()
                .padding(14)
        }
        .background(theme.cardBackground)
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
                HStack(spacing: 6) {
                    if !skill.enabled {
                        StatusCapsuleBadge(
                            icon: "pause.circle.fill",
                            text: "Disabled",
                            color: theme.warningColor
                        )
                    } else {
                        StatusCapsuleBadge(
                            icon: "checkmark.circle.fill",
                            text: "Enabled",
                            color: theme.successColor
                        )
                    }
                    if let category = skill.category, !category.isEmpty {
                        StatusCapsuleBadge(
                            icon: "tag",
                            text: category,
                            color: theme.accentColor
                        )
                    }
                }
            },
            content: {
                VStack(alignment: .leading, spacing: 12) {
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
        HStack(spacing: 12) {
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
        FlowLayout(spacing: 5) {
            ForEach(skill.keywords, id: \.self) { keyword in
                Text(keyword)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.accentColor.opacity(0.1)))
            }
        }
    }

    @ViewBuilder
    private var instructionsBlock: some View {
        if skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No instructions body.", bundle: .module)
                .font(.system(size: 11).italic())
                .foregroundColor(theme.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                ScrollView {
                    Text(skill.instructions)
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 280)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.primaryBackground.opacity(0.4))
                )
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
                    StatusCapsuleBadge(
                        icon: "checkmark.circle.fill",
                        text: "Enabled",
                        color: theme.successColor
                    )
                } else {
                    StatusCapsuleBadge(
                        icon: "pause.circle.fill",
                        text: "Paused",
                        color: theme.warningColor
                    )
                }
            },
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    metadataRow
                    instructionsBlock
                }
            }
        )
    }

    private var metadataRow: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                .font(.system(size: 11).italic())
                .foregroundColor(theme.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                ScrollView {
                    Text(schedule.instructions)
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 240)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.primaryBackground.opacity(0.4))
                )
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
                StatusCapsuleBadge(
                    icon: "text.alignleft",
                    text: command.kindLabel,
                    color: ClaudePluginArtifactKind.command.tint(theme)
                )
            },
            content: { templateBlock }
        )
    }

    @ViewBuilder
    private var templateBlock: some View {
        if let template = command.template,
            !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            VStack(alignment: .leading, spacing: 6) {
                Text("Template", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                ScrollView {
                    Text(template)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 280)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.primaryBackground.opacity(0.4))
                )
            }
        } else {
            Text("This command has no template body.", bundle: .module)
                .font(.system(size: 11).italic())
                .foregroundColor(theme.tertiaryText)
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
                HStack(spacing: 6) {
                    if mcp.isStdio {
                        StatusCapsuleBadge(icon: "terminal", text: "stdio", color: .purple)
                        StatusCapsuleBadge(
                            icon: mcp.executionHost == .sandbox
                                ? "shield.lefthalf.filled" : "macwindow",
                            text: mcp.executionHost == .sandbox ? "Sandbox" : "Host",
                            color: mcp.executionHost == .sandbox
                                ? theme.accentColor : .orange
                        )
                    } else {
                        StatusCapsuleBadge(
                            icon: "network",
                            text: "HTTP",
                            color: theme.accentColor
                        )
                    }
                    if !mcp.enabled {
                        StatusCapsuleBadge(
                            icon: "pause.circle.fill",
                            text: "Disabled",
                            color: theme.warningColor
                        )
                    }
                }
            },
            content: {
                VStack(alignment: .leading, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 4) {
            Text(label, bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.primaryBackground.opacity(0.45))
                )
        }
    }

    private var envBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Environment", bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            VStack(spacing: 4) {
                ForEach(mcp.envEntries) { entry in
                    HStack(spacing: 8) {
                        Text(entry.key)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        if let value = entry.value {
                            Text(value)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            Text("[secret]", bundle: .module)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(theme.warningColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(theme.warningColor.opacity(0.12))
                                )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.primaryBackground.opacity(0.45))
                    )
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
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(label)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(theme.tertiaryText)
    }
}

// Keyword chips are arranged via the shared `FlowLayout` defined in
// `Views/Common/FlowLayout.swift` — no per-view redeclaration needed.
