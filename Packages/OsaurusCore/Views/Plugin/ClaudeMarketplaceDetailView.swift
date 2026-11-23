//
//  ClaudeMarketplaceDetailView.swift
//  osaurus
//
//  Detail surface for a browsable Claude marketplace entry. Renders the
//  plugin's importable components from the precomputed bundled catalog so
//  opening a detail makes zero GitHub requests; only the explicit Install
//  action resolves the manifest live. Visually mirrors `ClaudePluginDetailView`.
//

import AppKit
import SwiftUI

struct ClaudeMarketplaceDetailView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let entry: MarketplacePlugin
    let onBack: () -> Void
    let onInstall: () async throws -> Void

    @State private var isInstalling = false
    @State private var errorMessage: String?
    @State private var showError = false

    /// Precomputed importable components for this plugin, from the bundled
    /// catalog. `nil` means the plugin is unclassified (e.g. newly added
    /// upstream), in which case we show a neutral "details unavailable" state
    /// rather than fetching live.
    private var componentSummary: ClaudeMarketplaceImportabilityCatalog.ComponentSummary? {
        trustPreview.componentSummary
    }

    private var trustPreview: ClaudeMarketplaceTrustPreview {
        ClaudeMarketplaceImportabilityCatalog.bundled.trustPreview(for: entry)
    }

    private var categoryKey: String { ClaudeMarketplaceService.categoryKey(for: entry) }
    /// Calm app accent for the icon + primary action.
    private var accent: Color { theme.action.primary.default.background }
    /// Muted per-category tint, used only for the small category badge.
    private var categoryColor: Color { ClaudeMarketplacePalette.color(for: categoryKey, theme: theme) }

    private var displayName: String {
        entry.name
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Total importable artifacts the plugin ships, as a short label for the
    /// hero stat badge (mirrors the installed detail's "N artifacts" badge).
    private func componentCountText(
        _ summary: ClaudeMarketplaceImportabilityCatalog.ComponentSummary
    ) -> String {
        let total =
            summary.skills.count + summary.agents.count + summary.commands.count
            + (summary.mcp ? 1 : 0)
        return "\(total) component\(total == 1 ? "" : "s")"
    }

    var body: some View {
        SettingsPage {
            detailHeader
        } content: {
            heroMetadata
            trustSection
            componentsSection
            externalLinksSection
        }
        .settingsBackDestination("Plugins") { onBack() }
        .themedAlert(
            "Installation Failed",
            isPresented: $showError,
            message: errorMessage ?? "Unknown error",
            primaryButton: .primary("OK") {}
        )
    }

    // MARK: - Header

    private var detailHeader: some View {
        SettingsPageHeader(
            title: displayName,
            verbatimTitle: true,
            subtitle: entry.description,
            verbatimSubtitle: true,
            leading: {
                SettingsIconTile(icon: "puzzlepiece.extension.fill", size: 32, tint: accent)
            },
            status: {
                StatusChip(ClaudeMarketplaceCategory(id: categoryKey, count: 0).displayName, tint: categoryColor)
            },
            primary: { installControl }
        )
    }

    private var heroMetadata: some View {
        HStack(spacing: theme.space.s12) {
            if let author = entry.author?.name, !author.isEmpty {
                heroStatBadge(icon: "person", text: author, color: theme.text.tertiary)
            }
            if let license = entry.license, !license.isEmpty {
                heroStatBadge(icon: "doc.text", text: license, color: theme.text.tertiary)
            }
            if let summary = componentSummary, !summary.isEmpty {
                heroStatBadge(
                    icon: "shippingbox.fill",
                    text: componentCountText(summary),
                    color: theme.action.primary.default.background
                )
            }
            heroStatBadge(
                icon: trustStatusIcon,
                text: trustPreview.statusTitle,
                color: trustStatusColor
            )
        }
    }

    @ViewBuilder
    private var installControl: some View {
        if trustPreview.importabilityStatus == .blocked {
            StatusChip(L("Not importable"), tone: .neutral)
        } else {
            SettingsButton(
                trustPreview.importabilityStatus == .requiresReview ? .secondary : .primary,
                "Install",
                icon: "arrow.down.circle.fill",
                isLoading: isInstalling,
                action: install
            )
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

    // MARK: - Trust preview

    private var trustStatusIcon: String {
        switch trustPreview.importabilityStatus {
        case .importable:
            return "checkmark.seal"
        case .requiresReview:
            return "exclamationmark.triangle"
        case .blocked:
            return "minus.circle"
        }
    }

    private var trustStatusColor: Color {
        switch trustPreview.importabilityStatus {
        case .importable:
            return theme.status.success.foreground
        case .requiresReview:
            return theme.status.warning.foreground
        case .blocked:
            return theme.text.tertiary
        }
    }

    private var trustSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            sectionHeader(title: "Trust preview")
            HStack(alignment: .top, spacing: theme.space.s10) {
                Image(systemName: trustStatusIcon)
                    .glyphSize(.label, weight: .semibold)
                    .foregroundColor(trustStatusColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    Text(trustPreview.statusTitle)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    Text(trustPreview.reason)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(theme.space.s8)
            .settingsChrome(.tinted(trustStatusColor))

            VStack(spacing: theme.space.s8) {
                trustRow(
                    icon: "checkmark.seal",
                    title: "Listing",
                    value: trustPreview.source.isOfficialMarketplace
                        ? "Official Claude marketplace"
                        : "Marketplace catalog"
                )
                trustRow(
                    icon: "building.2",
                    title: "Owner",
                    value: trustPreview.source.owner
                )
                trustRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Repo",
                    value: trustPreview.source.repositoryURLLabel
                )
                if let path = trustPreview.source.path {
                    trustRow(icon: "folder", title: "Path", value: path)
                }
            }

            let indicators = trustPreview.capabilityIndicators
            if !indicators.isEmpty {
                FlowLayout(spacing: theme.space.s6) {
                    ForEach(indicators) { indicator in
                        trustCapabilityBadge(indicator)
                    }
                }
                .padding(.top, theme.space.s2)
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
    }

    private func trustRow(icon: String, title: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(.footnote, weight: .medium)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 16)
            Text(title, bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func trustCapabilityBadge(
        _ indicator: ClaudeMarketplaceTrustPreview.CapabilityIndicator
    ) -> some View {
        let color: Color =
            switch indicator.severity {
            case .normal:
                theme.status.info.foreground
            case .sensitive:
                theme.status.warning.foreground
            case .unsupported:
                theme.text.tertiary
            }
        let text =
            if let count = indicator.count {
                "\(indicator.label) \(count)"
            } else {
                indicator.label
            }
        return StatusChip(text, tint: color)
    }

    // MARK: - Components

    @ViewBuilder
    private var componentsSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            sectionHeader(title: "Components")
            if let summary = componentSummary {
                if summary.isEmpty {
                    notImportablePanel
                } else {
                    componentChips(for: summary)
                }
            } else {
                unclassifiedPanel
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
    }

    @ViewBuilder
    private func componentChips(
        for summary: ClaudeMarketplaceImportabilityCatalog.ComponentSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s14) {
            if !summary.skills.isEmpty {
                componentGroup(
                    kind: .skill,
                    count: summary.skills.count,
                    names: summary.skills
                )
            }
            if !summary.agents.isEmpty {
                componentGroup(
                    kind: .schedule,
                    count: summary.agents.count,
                    names: summary.agents
                )
            }
            if !summary.commands.isEmpty {
                componentGroup(
                    kind: .command,
                    count: summary.commands.count,
                    names: summary.commands.map { "/\($0)" }
                )
            }
            if summary.mcp {
                componentGroup(kind: .mcp, count: 1, names: [L("MCP server")])
            }
        }
    }

    /// Shown when the catalog classified the plugin as importing nothing
    /// Osaurus supports. These are normally hidden from the grid, so this is a
    /// safety net rather than a common state.
    private var notImportablePanel: some View {
        infoPanel(
            title: "Nothing to import into Osaurus",
            message:
                "Osaurus imports skills, agents, commands, and MCP servers. This plugin ships none of those."
        )
    }

    /// Shown when the bundled catalog has not classified this plugin yet
    /// (e.g. it was added upstream after the last catalog refresh).
    private var unclassifiedPanel: some View {
        infoPanel(
            title: "Component details unavailable",
            message:
                "This plugin isn't in the bundled catalog yet. Install to import its skills, agents, commands, and MCP servers, or open the homepage to learn more."
        )
    }

    private func infoPanel(title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            HStack(alignment: .top, spacing: theme.space.s8) {
                Image(systemName: "info.circle")
                    .glyphSize(.label, weight: .medium)
                    .foregroundColor(theme.text.tertiary)
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    Text(title, bundle: .module)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    Text(message, bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func componentGroup(
        kind: ClaudePluginArtifactKind,
        count: Int,
        names: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: kind.icon)
                    .glyphSize(.caption, weight: .medium)
                    .foregroundColor(kind.tint(theme))
                Text(kind.titlePlural)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text("\(count)")
                    .font(SettingsFont.smallLabel.monospacedDigit())
                    .foregroundColor(theme.text.secondary)
                Spacer()
            }
            FlowLayout(spacing: theme.space.s6) {
                ForEach(names, id: \.self) { name in
                    StatusChip(name, tint: kind.tint(theme))
                }
            }
        }
    }

    // MARK: - External links

    @ViewBuilder
    private var externalLinksSection: some View {
        let homepageURL = entry.homepage.flatMap { URL(string: $0) }
        let repoURL = entry.repository.flatMap { URL(string: $0) }
        if homepageURL != nil || repoURL != nil {
            VStack(alignment: .leading, spacing: theme.space.s10) {
                sectionHeader(title: "External links")
                VStack(spacing: theme.space.s6) {
                    if let repoURL {
                        linkRow(
                            icon: "chevron.left.forwardslash.chevron.right",
                            title: "Repository",
                            url: repoURL
                        )
                    }
                    if let homepageURL {
                        linkRow(icon: "globe", title: "Homepage", url: homepageURL)
                    }
                }
            }
            .padding(theme.space.s16)
            .settingsChrome(.card)
        }
    }

    private func linkRow(icon: String, title: LocalizedStringKey, url: URL) -> some View {
        Button(
            action: { NSWorkspace.shared.open(url) },
            label: {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: icon)
                        .glyphSize(.caption)
                        .foregroundColor(theme.text.link)
                    Text(title, bundle: .module)
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
        )
        .buttonStyle(PlainButtonStyle())
    }

    private func sectionHeader(title: String) -> some View {
        SettingsSectionHeader(title: title)
    }

    // MARK: - Actions

    private func install() {
        guard !isInstalling else { return }
        isInstalling = true
        Task {
            defer { isInstalling = false }
            do {
                try await onInstall()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}
