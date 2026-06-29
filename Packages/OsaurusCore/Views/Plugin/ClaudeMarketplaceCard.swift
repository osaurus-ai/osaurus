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
    static func color(for categoryKey: String) -> Color {
        let hue: Double
        switch categoryKey {
        case "development": hue = 0.58
        case "productivity": hue = 0.09
        case "database": hue = 0.48
        case "security": hue = 0.99
        case "monitoring": hue = 0.78
        case "design": hue = 0.92
        case "deployment": hue = 0.38
        case "testing": hue = 0.68
        case "learning": hue = 0.52
        case "location": hue = 0.44
        case "math": hue = 0.13
        case ClaudeMarketplaceCategory.otherKey:
            return Color(hue: 0, saturation: 0, brightness: 0.6)
        default:
            hue = Double(abs(categoryKey.hashValue % 360)) / 360.0
        }
        return Color(hue: hue, saturation: 0.32, brightness: 0.72)
    }
}

// MARK: - Card

struct ClaudeMarketplaceCard: View {
    @Environment(\.theme) private var theme

    let entry: MarketplacePlugin
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    let onInstall: () async throws -> Void

    @State private var isHovered = false
    @State private var isInstalling = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var categoryKey: String { ClaudeMarketplaceService.categoryKey(for: entry) }
    /// Calm app accent drives the icon + primary action on every card.
    private var accent: Color { theme.accentColor }
    /// Muted per-category tint, used only for the small category badge.
    private var categoryColor: Color { ClaudeMarketplacePalette.color(for: categoryKey) }

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
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                descriptionView
                Spacer(minLength: 0)
                footerRow
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
            .overlay(hoverGradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
            .shadow(
                color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 10 : 5,
                x: 0,
                y: isHovered ? 3 : 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay),
            value: hasAppeared
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .themedAlert(
            "Installation Failed",
            isPresented: $showError,
            message: errorMessage ?? "Unknown error",
            primaryButton: .primary("OK") {}
        )
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.16), accent.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 18))
                    .foregroundColor(accent)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                categoryBadge
            }

            Spacer(minLength: 8)
            installControl
        }
    }

    private var categoryBadge: some View {
        Text(ClaudeMarketplaceCategory(id: categoryKey, count: 0).displayName)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(categoryColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(categoryColor.opacity(0.14)))
    }

    @ViewBuilder
    private var descriptionView: some View {
        if let description = entry.description, !description.isEmpty {
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(3)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            if let hint = componentHint {
                HStack(spacing: 3) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 9, weight: .medium))
                    Text(hint)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundColor(theme.tertiaryText)
                .layoutPriority(1)
            }
            Spacer(minLength: 6)
            if let author = entry.author?.name, !author.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "person")
                        .font(.system(size: 9, weight: .medium))
                    Text(author)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundColor(theme.tertiaryText)
            }
            trustStatusBadge
            if entry.homepage != nil {
                Image(systemName: "link")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private var installControl: some View {
        if isInstalling {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 28, height: 28)
        } else if trustPreview.importabilityStatus == .blocked {
            Image(systemName: "minus.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(theme.tertiaryText.opacity(0.12))
                )
        } else {
            Button(action: install) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(
                        trustPreview.importabilityStatus == .requiresReview
                            ? theme.warningColor : accent
                    )
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(
                            (trustPreview.importabilityStatus == .requiresReview
                                ? theme.warningColor : accent).opacity(0.12)
                        )
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .localizedHelp(
                trustPreview.importabilityStatus == .requiresReview
                    ? "Review manifest and install" : "Install"
            )
        }
    }

    private var trustStatusBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: trustBadgeIcon)
                .font(.system(size: 9, weight: .medium))
            Text(trustBadgeText)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(trustBadgeColor)
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
            return trustPreview.source.isMarketplaceRepo ? "Official" : "External source"
        case .requiresReview:
            return "Review"
        case .blocked:
            return "Blocked"
        }
    }

    private var trustBadgeColor: Color {
        switch trustPreview.importabilityStatus {
        case .importable:
            return theme.tertiaryText
        case .requiresReview:
            return theme.warningColor
        case .blocked:
            return theme.tertiaryText
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isHovered ? accent.opacity(0.3) : theme.cardBorder,
                lineWidth: isHovered ? 1.5 : 1
            )
    }

    private var hoverGradient: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [accent.opacity(isHovered ? 0.06 : 0), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
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
