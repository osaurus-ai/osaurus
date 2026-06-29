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

    @State private var hasAppeared = false

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
    private var accent: Color { theme.accentColor }
    /// Muted per-category tint, used only for the small category badge.
    private var categoryColor: Color { ClaudeMarketplacePalette.color(for: categoryKey) }

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
        VStack(spacing: 0) {
            detailHeaderBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroHeader.padding(.bottom, 8)
                    trustSection
                    componentsSection
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
        }
        .themedAlert(
            "Installation Failed",
            isPresented: $showError,
            message: errorMessage ?? "Unknown error",
            primaryButton: .primary("OK") {}
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
                            colors: [accent.opacity(0.2), accent.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(accent.opacity(0.3), lineWidth: 2)
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 28))
                    .foregroundColor(accent)
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(displayName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    Text(ClaudeMarketplaceCategory(id: categoryKey, count: 0).displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(categoryColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(categoryColor.opacity(0.14)))
                }

                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    if let author = entry.author?.name, !author.isEmpty {
                        heroStatBadge(icon: "person", text: author, color: theme.tertiaryText)
                    }
                    if let license = entry.license, !license.isEmpty {
                        heroStatBadge(icon: "doc.text", text: license, color: theme.tertiaryText)
                    }
                    if let summary = componentSummary, !summary.isEmpty {
                        heroStatBadge(
                            icon: "shippingbox.fill",
                            text: componentCountText(summary),
                            color: theme.accentColor
                        )
                    }
                    heroStatBadge(
                        icon: trustStatusIcon,
                        text: trustPreview.statusTitle,
                        color: trustStatusColor
                    )
                }
            }

            Spacer(minLength: 0)

            installControl
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.secondaryBackground)
        )
    }

    @ViewBuilder
    private var installControl: some View {
        if trustPreview.importabilityStatus == .blocked {
            HStack(spacing: 5) {
                Image(systemName: "minus.circle").font(.system(size: 12))
                Text("Not importable", bundle: .module).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryText.opacity(0.10))
            )
        } else if isInstalling {
            ProgressView()
                .scaleEffect(0.9)
                .frame(width: 100, height: 36)
        } else {
            Button(action: install) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 12))
                    Text("Install", bundle: .module).font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(trustPreview.importabilityStatus == .requiresReview ? theme.warningColor : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            trustPreview.importabilityStatus == .requiresReview
                                ? theme.warningColor.opacity(0.12)
                                : accent
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
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
            return theme.successColor
        case .requiresReview:
            return theme.warningColor
        case .blocked:
            return theme.tertiaryText
        }
    }

    private var trustSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Trust preview", icon: "shield.lefthalf.filled")
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: trustStatusIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(trustStatusColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(trustPreview.statusTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(trustPreview.reason)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(trustStatusColor.opacity(0.10))
            )

            VStack(spacing: 8) {
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
                FlowLayout(spacing: 6) {
                    ForEach(indicators) { indicator in
                        trustCapabilityBadge(indicator)
                    }
                }
                .padding(.top, 2)
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

    private func trustRow(icon: String, title: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 16)
            Text(title, bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
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
                theme.infoColor
            case .sensitive:
                theme.warningColor
            case .unsupported:
                theme.tertiaryText
            }
        let text =
            if let count = indicator.count {
                "\(indicator.label) \(count)"
            } else {
                indicator.label
            }
        return Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Components

    @ViewBuilder
    private var componentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Components", icon: "shippingbox.fill")
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
    private func componentChips(
        for summary: ClaudeMarketplaceImportabilityCatalog.ComponentSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
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
                componentGroup(kind: .mcp, count: 1, names: ["MCP server(s)"])
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title, bundle: .module)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(message, bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: kind.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(kind.tint(theme))
                Text(kind.titlePlural)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(theme.secondaryText)
                Spacer()
            }
            FlowLayout(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(kind.tint(theme).opacity(0.12)))
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
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(title: "External links", icon: "link")
                VStack(spacing: 6) {
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
    }

    private func linkRow(icon: String, title: LocalizedStringKey, url: URL) -> some View {
        Button(
            action: { NSWorkspace.shared.open(url) },
            label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(theme.accentColor)
                    Text(title, bundle: .module)
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
        )
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
