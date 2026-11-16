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
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let plugin: ClaudePluginInstalled
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    let onUpdate: (() async throws -> Void)?
    let onUninstall: (() async throws -> Void)?
    let onConfigure: (() -> Void)?
    let onChange: (() -> Void)?

    @State private var errorMessage: String?
    @State private var showError = false

    private var pluginColor: Color {
        plugin.hasUpdate ? theme.status.warning.foreground : theme.action.primary.default.background
    }

    var body: some View {
        LibraryCard(
            title: plugin.displayName,
            animationDelay: animationDelay,
            hasAppeared: hasAppeared,
            action: onSelect
        ) {
            LibraryIcon(symbol: "puzzlepiece.extension.fill", tint: pluginColor)
        } badges: {
            if let version = plugin.version {
                StatusChip(L("v\(version)"), tone: .neutral)
            }
            StatusChip(L("Imported"), tone: .accent, icon: "square.and.arrow.down")
            statusBadge
        } content: {
            if let description = plugin.snapshot?.description, !description.isEmpty {
                LibraryCardPreview(text: description)
            } else {
                Text(verbatim: plugin.sourceLabel)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            HStack(spacing: theme.space.s6) {
                ForEach(ClaudePluginArtifactKind.allCases, id: \.self) { kind in
                    let count = plugin.counts[kind]
                    if count > 0 {
                        StatusChip("\(count)", tint: kind.tint(theme), icon: kind.icon)
                    }
                }
                if let license = plugin.snapshot?.license, !license.isEmpty {
                    LibraryStatRow(stats: [LibraryStat(icon: "doc.text", text: license)])
                }
                Spacer(minLength: 0)
            }
        } menu: {
            menuItems
        }
        .themedAlert(
            "Error",
            isPresented: $showError,
            message: errorMessage ?? "Unknown error",
            primaryButton: .primary("OK") {}
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        if plugin.hasUpdate {
            StatusChip(L("Update"), tone: .warning, icon: "arrow.up.circle.fill")
        } else if plugin.needsPostInstallAttention {
            StatusChip(L("Needs setup"), tone: .warning, icon: "exclamationmark.circle.fill")
        }
    }

    @ViewBuilder
    private var menuItems: some View {
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
    }
}
