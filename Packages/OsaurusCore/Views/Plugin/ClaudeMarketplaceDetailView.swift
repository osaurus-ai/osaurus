//
//  ClaudeMarketplaceDetailView.swift
//  osaurus
//
//  Detail surface for a browsable Claude marketplace entry. Lazily resolves
//  the plugin's full manifest (the expensive directory-probe step deferred by
//  the browse grid) to reveal its components and README, with a prominent
//  Install call-to-action. Visually mirrors `ClaudePluginDetailView`.
//

import AppKit
import SwiftUI

struct ClaudeMarketplaceDetailView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let entry: MarketplacePlugin
    let repo: GitHubRepo?
    let isInstalled: Bool
    let onBack: () -> Void
    let onInstall: () async throws -> Void

    @State private var hasAppeared = false
    @State private var manifest: ClaudePluginManifest?
    @State private var isResolving = false
    @State private var resolveError: String?
    @State private var readmeContent: String?
    @State private var didStartResolve = false

    @State private var isInstalling = false
    @State private var errorMessage: String?
    @State private var showError = false

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

    var body: some View {
        VStack(spacing: 0) {
            detailHeaderBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroHeader.padding(.bottom, 8)
                    componentsSection
                    if let readme = readmeContent, !readme.isEmpty {
                        readmeSection(readme)
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
            resolveIfNeeded()
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
        if isInstalled {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                Text("Installed", bundle: .module).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.green)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
        } else if let manifest, !manifest.hasImportableComponents {
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
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(accent))
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

    // MARK: - Components

    private var componentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Components", icon: "shippingbox.fill")
            if isResolving {
                resolvingPlaceholder
            } else if let error = resolveError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(theme.warningColor)
            } else if let manifest {
                componentChips(for: manifest)
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

    private var resolvingPlaceholder: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.7)
            Text("Inspecting plugin contents…", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            Spacer()
        }
    }

    @ViewBuilder
    private func componentChips(for manifest: ClaudePluginManifest) -> some View {
        if !manifest.hasImportableComponents {
            notImportablePanel(for: manifest)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !manifest.skills.isEmpty {
                    componentGroup(
                        kind: .skill,
                        count: manifest.skills.count,
                        names: manifest.skills.map(\.displayName)
                    )
                }
                if !manifest.agents.isEmpty {
                    componentGroup(
                        kind: .schedule,
                        count: manifest.agents.count,
                        names: manifest.agents.map(\.displayName)
                    )
                }
                if !manifest.commands.isEmpty {
                    componentGroup(
                        kind: .command,
                        count: manifest.commands.count,
                        names: manifest.commands.map { "/\($0.displayName)" }
                    )
                }
                if manifest.mcpJsonPath != nil {
                    componentGroup(kind: .mcp, count: 1, names: ["MCP server(s)"])
                }
            }
        }
    }

    /// Shown when a resolved plugin has nothing Osaurus can import. Explains
    /// the supported set and lists what the plugin actually ships (hooks /
    /// unsupported components) so the user understands why there's no install.
    @ViewBuilder
    private func notImportablePanel(for manifest: ClaudePluginManifest) -> some View {
        let shipped = shippedComponentLabels(for: manifest)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing to import into Osaurus", bundle: .module)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Osaurus imports skills, agents, commands, and MCP servers. This plugin ships none of those.",
                        bundle: .module
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !shipped.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("It ships", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                    FlowLayout(spacing: 6) {
                        ForEach(shipped, id: \.self) { label in
                            Text(label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(theme.tertiaryText.opacity(0.12))
                                )
                        }
                    }
                }
            }

            if entry.homepage != nil {
                Text("Open the homepage below to learn what it does.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    /// Human-readable labels for the unsupported parts a plugin declares.
    private func shippedComponentLabels(for manifest: ClaudePluginManifest) -> [String] {
        var labels: [String] = []
        if manifest.declaresHooks { labels.append("Hooks") }
        labels.append(
            contentsOf: manifest.declaresUnsupportedComponents.map {
                $0.prefix(1).uppercased() + $0.dropFirst()
            }
        )
        return labels
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

    // MARK: - README

    private func readmeSection(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "README", icon: "doc.text.fill")
            MarkdownMessageView(text: content, baseWidth: 600)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        Button(action: { NSWorkspace.shared.open(url) }) {
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

    private func resolveIfNeeded() {
        guard !didStartResolve, let repo else { return }
        didStartResolve = true
        isResolving = true
        Task { @MainActor in
            defer { isResolving = false }
            do {
                let resolved = try await GitHubSkillService.shared.resolveManifest(
                    rootRepo: repo,
                    entry: entry
                )
                manifest = resolved
                await loadReadme(for: resolved)
            } catch let err as GitHubSkillError {
                resolveError = err.localizedDescription
            } catch {
                resolveError = error.localizedDescription
            }
        }
    }

    /// Best-effort README fetch from the plugin's source. Picks the README
    /// discovered during manifest resolution (`auxMarkdownPaths`) and falls
    /// back to `<source>/README.md`.
    private func loadReadme(for manifest: ClaudePluginManifest) async {
        let readmePath: String =
            manifest.auxMarkdownPaths.first(where: { $0.hasSuffix("README.md") })
            ?? (manifest.source.isEmpty ? "README.md" : "\(manifest.source)/README.md")
        let content = await GitHubFetchLimiter.shared.runNoThrow {
            await GitHubSkillService.shared.fetchOptionalFileContent(
                from: manifest.sourceRepo,
                path: readmePath
            )
        }
        if let content {
            readmeContent = content
        }
    }
}
