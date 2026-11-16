//
//  ClaudeMarketplaceCard.swift
//  osaurus
//
//  Grid card for a browsable Claude marketplace entry (not yet resolved /
//  installed). Renders entirely from the cheap `marketplace.json` metadata
//  (name, description, author, category) and exposes a one-click Install
//  that resolves + installs the plugin on demand.
//

import SwiftUI

// MARK: - Category color

/// Muted, low-saturation hue per discovery category. Used ONLY for the small
/// category badge so categories stay scannable without the alarming, fully
/// saturated system colors (e.g. bright red for "security") bleeding onto the
/// card icon and the primary Install action — those use the app accent.
enum ClaudeMarketplacePalette {
    /// Calm, desaturated category tint for the badge.
    static func color(for categoryKey: String, theme: any ThemeProtocol) -> Color {
        let ink: DataInk
        switch categoryKey {
        case "development": ink = .blue
        case "productivity": ink = .orange
        case "database": ink = .teal
        case "security": ink = .red
        case "monitoring": ink = .purple
        case "design": ink = .pink
        case "deployment": ink = .green
        case "testing": ink = .indigo
        case "learning": ink = .cyan
        case "location": ink = .teal
        case "math": ink = .orange
        case ClaudeMarketplaceCategory.otherKey: ink = .gray
        default: return theme.dataInk(seed: categoryKey)
        }
        return theme.dataInk(ink)
    }
}

// MARK: - Card

struct ClaudeMarketplaceCard: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let entry: MarketplacePlugin
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    let onInstall: () async throws -> Void

    @State private var isInstalling = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var categoryKey: String { ClaudeMarketplaceService.categoryKey(for: entry) }
    /// Calm app accent drives the icon + primary action on every card.
    private var accent: Color { theme.action.primary.default.background }
    /// Muted per-category tint, used only for the small category badge.
    private var categoryColor: Color { ClaudeMarketplacePalette.color(for: categoryKey, theme: theme) }

    /// Precomputed importable component summary (skills / agents / commands /
    /// MCP) for this plugin, from the bundled catalog. Drives the at-a-glance
    /// "what does this ship" hint without any network access.
    private var componentSummary: ClaudeMarketplaceImportabilityCatalog.ComponentSummary? {
        trustPreview.componentSummary
    }

    private var trustPreview: ClaudeMarketplaceTrustPreview {
        ClaudeMarketplaceImportabilityCatalog.bundled.trustPreview(for: entry)
    }

    /// Compact "6 skills · 1 MCP" hint, or nil when there's nothing to import
    /// or the plugin isn't classified yet.
    private var componentHint: String? {
        guard let summary = componentSummary, !summary.isEmpty else { return nil }
        var parts: [String] = []
        if !summary.skills.isEmpty {
            parts.append("\(summary.skills.count) skill\(summary.skills.count == 1 ? "" : "s")")
        }
        if !summary.agents.isEmpty {
            parts.append("\(summary.agents.count) agent\(summary.agents.count == 1 ? "" : "s")")
        }
        if !summary.commands.isEmpty {
            parts.append(
                "\(summary.commands.count) command\(summary.commands.count == 1 ? "" : "s")"
            )
        }
        if summary.mcp { parts.append("MCP") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        LibraryCard(
            title: displayName,
            animationDelay: animationDelay,
            hasAppeared: hasAppeared,
            action: onSelect
        ) {
            LibraryIcon(symbol: "puzzlepiece.extension.fill", tint: accent)
        } badges: {
            StatusChip(ClaudeMarketplaceCategory(id: categoryKey, count: 0).displayName, tint: categoryColor)
        } accessory: {
            installControl
        } content: {
            if let description = entry.description, !description.isEmpty {
                LibraryCardPreview(text: description, lines: 3)
            }
        } footer: {
            LibraryStatRow(stats: footerStats)
        }
        .themedAlert(
            "Installation Failed",
            isPresented: $showError,
            message: errorMessage ?? "Unknown error",
            primaryButton: .primary("OK") {}
        )
    }

    private var footerStats: [LibraryStat] {
        var stats: [LibraryStat] = []
        if let hint = componentHint {
            stats.append(LibraryStat(icon: "shippingbox.fill", text: hint, priority: 2))
        }
        if let author = entry.author?.name, !author.isEmpty {
            stats.append(LibraryStat(icon: "person", text: author))
        }
        stats.append(
            LibraryStat(
                icon: trustBadgeIcon,
                text: trustBadgeText,
                isWarning: trustPreview.importabilityStatus == .requiresReview
            )
        )
        if entry.homepage != nil {
            stats.append(LibraryStat(icon: "link", help: L("Has a homepage")))
        }
        return stats
    }

    private var installControl: some View {
        let status = trustPreview.importabilityStatus
        return SettingsIconButton(
            status == .blocked ? "minus.circle" : "arrow.down.circle",
            isLoading: isInstalling,
            help: status == .requiresReview ? "Review manifest and install" : "Install",
            size: .compact,
            isActive: status == .importable,
            action: install
        )
        .disabled(status == .blocked)
    }

    private var trustBadgeIcon: String {
        switch trustPreview.importabilityStatus {
        case .importable:
            return trustPreview.source.isMarketplaceRepo ? "checkmark.seal" : "arrow.up.right.square"
        case .requiresReview:
            return "exclamationmark.triangle"
        case .blocked:
            return "minus.circle"
        }
    }

    private var trustBadgeText: String {
        switch trustPreview.importabilityStatus {
        case .importable:
            return trustPreview.source.isMarketplaceRepo ? L("Official") : L("External source")
        case .requiresReview:
            return L("Review")
        case .blocked:
            return L("Blocked")
        }
    }

    private var trustBadgeColor: Color {
        switch trustPreview.importabilityStatus {
        case .importable:
            return theme.text.tertiary
        case .requiresReview:
            return theme.status.warning.foreground
        case .blocked:
            return theme.text.tertiary
        }
    }

    private var displayName: String {
        entry.name
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

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
