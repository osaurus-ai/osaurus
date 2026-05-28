//
//  ClaudePluginCard.swift
//  osaurus
//
//  Grid card for a Claude plugin installed via GitHub. Visually mirrors
//  the native `PluginCard` (icon, name + version pill, description, stat
//  row, ellipsis menu) but with Claude-specific affordances:
//   - `Imported` chip on the status row.
//   - Per-artifact chips (skills / schedules / commands / MCP).
//   - Update / Configure userConfig / Open on GitHub menu actions.
//

import SwiftUI

struct ClaudePluginCard: View {
    @Environment(\.theme) private var theme

    let plugin: ClaudePluginInstalled
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    let onUpdate: (() async throws -> Void)?
    let onUninstall: (() async throws -> Void)?
    let onConfigure: (() -> Void)?
    let onChange: (() -> Void)?

    @State private var isHovered = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var pluginColor: Color {
        plugin.hasUpdate ? .orange : theme.accentColor
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                descriptionView
                Spacer(minLength: 0)
                statRow
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(16)
            .background(cardBackground)
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
            "Error",
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
                            colors: [pluginColor.opacity(0.15), pluginColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 18))
                    .foregroundColor(pluginColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let version = plugin.version {
                        Text("v\(version)", bundle: .module)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                    importedBadge
                    statusBadge
                }
            }

            Spacer(minLength: 8)
            cardMenu
        }
    }

    private var importedBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 8.5, weight: .semibold))
            Text("Imported", bundle: .module)
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundColor(theme.accentColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.accentColor.opacity(0.14)))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if plugin.hasUpdate {
            StatusCapsuleBadge(icon: "arrow.up.circle.fill", text: "Update", color: .orange)
        }
    }

    @ViewBuilder
    private var descriptionView: some View {
        if let description = plugin.snapshot?.description, !description.isEmpty {
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(plugin.sourceLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statRow: some View {
        HStack(spacing: 6) {
            ForEach(ClaudePluginArtifactKind.allCases, id: \.self) { kind in
                let count = plugin.counts[kind]
                if count > 0 {
                    statChip(icon: kind.icon, count: count, tint: kind.tint(theme))
                }
            }
            if let license = plugin.snapshot?.license, !license.isEmpty {
                statItem(icon: "doc.text", text: license)
            }
            Spacer(minLength: 0)
        }
    }

    private func statChip(icon: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundColor(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.14)))
    }

    private func statItem(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(theme.tertiaryText)
    }

    @ViewBuilder
    private var cardMenu: some View {
        Menu {
            Button(action: onSelect) {
                Label {
                    Text("View Details", bundle: .module)
                } icon: {
                    Image(systemName: "info.circle")
                }
            }
            if let snap = plugin.snapshot {
                Button {
                    if let url = URL(string: snap.githubSourceURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label {
                        Text("Open on GitHub", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }
            if let onConfigure,
                let spec = plugin.snapshot?.userConfigSpec, !spec.isEmpty
            {
                Button(action: onConfigure) {
                    Label {
                        Text("Configure Settings…", bundle: .module)
                    } icon: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            if plugin.hasUpdate, let onUpdate {
                Button {
                    Task {
                        do { try await onUpdate() } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                } label: {
                    Label {
                        Text("Update", bundle: .module)
                    } icon: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                }
            }
            if let onUninstall {
                Divider()
                Button(role: .destructive) {
                    Task {
                        do { try await onUninstall() } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                } label: {
                    Label {
                        Text("Uninstall", bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.tertiaryBackground))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isHovered
                    ? pluginColor.opacity(0.25)
                    : Color.green.opacity(0.2),
                lineWidth: isHovered ? 1.5 : 1
            )
    }

    private var hoverGradient: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [
                        pluginColor.opacity(isHovered ? 0.06 : 0),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}
