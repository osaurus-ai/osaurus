//
//  SimpleComponents.swift
//  osaurus
//
//  Minimalistic UI components with clean edges and outline styling
//

import AppKit
import SwiftUI

// MARK: - Copy URL Field
struct CopyableURLField: View {
    @Environment(\.theme) private var theme
    let label: String
    let url: String
    @State private var showCopied = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.secondary)

            HStack(spacing: theme.space.s12) {
                Text(url)
                    .font(SettingsFont.mono)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, theme.space.s12)
                    .padding(.vertical, theme.space.s8)
                    .settingsChrome(.control)

                Button(action: copyURL) {
                    ZStack {
                        Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                            .glyphSize(.body, weight: .medium)
                            .foregroundColor(showCopied ? theme.status.success.foreground : theme.text.primary)
                    }
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(theme.action.secondary.default.background)
                            .overlay(
                                Circle()
                                    .stroke(
                                        isHovering ? theme.border.focus : theme.action.border,
                                        lineWidth: theme.stroke.default
                                    )
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .help(showCopied ? Text(localized: "Copied!") : Text(localized: "Copy to clipboard"))
                .onHover { hovering in
                    isHovering = hovering
                }
            }
        }
    }

    private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)

        withAnimation(theme.motion.quick) {
            showCopied = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(theme.motion.quick) {
                showCopied = false
            }
        }
    }
}

// MARK: - System Resource Monitor
struct SystemResourceMonitor: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var monitor = SystemMonitorService.shared
    @State private var isHoveringCPU = false
    @State private var isHoveringRAM = false
    @State private var showResourcePopover = false
    @State private var cachedModelCount: Int = 0

    var body: some View {
        HStack(spacing: theme.space.s12) {
            // CPU Usage
            VStack(alignment: .leading, spacing: theme.space.s6) {
                HStack(spacing: theme.space.s4) {
                    Image(systemName: "cpu")
                        .glyphSize(.footnote, weight: .medium)
                        .foregroundColor(theme.text.secondary)
                    Text("CPU", bundle: .module)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)
                    Spacer()
                    Text("\(Int(monitor.cpuUsage))%", bundle: .module)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(colorForUsage(monitor.cpuUsage))
                        .contentTransition(.numericText())
                }

                SettingsProgressBar(value: monitor.cpuUsage / 100, tint: colorForUsage(monitor.cpuUsage))
                    .help(Text(localized: "CPU Usage: \(String(format: "%.1f", monitor.cpuUsage))%"))
                    .onHover { hovering in
                        isHoveringCPU = hovering
                    }
                    .overlay(
                        Group {
                            if isHoveringCPU {
                                Text("\(String(format: "%.1f", monitor.cpuUsage))%", bundle: .module)
                                    .font(SettingsFont.monoSmall)
                                    .foregroundColor(theme.text.primary)
                                    .padding(.horizontal, theme.space.s8)
                                    .padding(.vertical, theme.space.s4)
                                    .background(
                                        ZStack {
                                            RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous)
                                                .fill(theme.surface.overlay)
                                            RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous)
                                                .strokeBorder(theme.border.default, lineWidth: theme.stroke.default)
                                        }
                                        .themeElevation(theme.elevation.overlay)
                                    )
                                    .offset(y: -20)
                                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            }
                        }
                    )
            }
            .frame(minWidth: 50)

            // RAM Usage
            VStack(alignment: .leading, spacing: theme.space.s6) {
                HStack(spacing: theme.space.s4) {
                    Image(systemName: "memorychip")
                        .glyphSize(.footnote, weight: .medium)
                        .foregroundColor(theme.text.secondary)
                    Text("RAM", bundle: .module)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)

                    // Models indicator button
                    Button(action: { showResourcePopover.toggle() }) {
                        HStack(spacing: theme.space.s2) {
                            Image(systemName: "cube.box")
                                .glyphSize(.tiny, weight: .medium)

                            if cachedModelCount > 0 {
                                Text("\(cachedModelCount)", bundle: .module)
                                    .font(SettingsFont.monoSmall)
                                    .contentTransition(.numericText())
                            }
                        }
                    }
                    .assignedSettingsButtonStyle(.tertiary, size: .extraExtraSmall)
                    .help(Text(localized: "Loaded Models\(cachedModelCount > 0 ? " (\(cachedModelCount))" : "")"))

                    Spacer()

                    Text("\(Int(monitor.memoryUsage))%", bundle: .module)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(colorForUsage(monitor.memoryUsage))
                        .contentTransition(.numericText())
                }

                SettingsProgressBar(value: monitor.memoryUsage / 100, tint: colorForUsage(monitor.memoryUsage))
                    .help(
                        Text(
                            "Memory: \(String(format: "%.1f", monitor.usedMemoryGB)) GB / \(String(format: "%.1f", monitor.totalMemoryGB)) GB",
                            bundle: .module
                        )
                    )
                    .onHover { hovering in
                        isHoveringRAM = hovering
                    }
                    .overlay(
                        Group {
                            if isHoveringRAM {
                                Text(
                                    "\(String(format: "%.1f", monitor.usedMemoryGB)) / \(String(format: "%.1f", monitor.totalMemoryGB)) GB",
                                    bundle: .module
                                )
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.primary)
                                .padding(.horizontal, theme.space.s8)
                                .padding(.vertical, theme.space.s4)
                                .background(
                                    ZStack {
                                        RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous)
                                            .fill(theme.surface.overlay)
                                        RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous)
                                            .strokeBorder(theme.border.default, lineWidth: theme.stroke.default)
                                    }
                                    .themeElevation(theme.elevation.overlay)
                                )
                                .offset(y: -20)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            }
                        }
                    )
            }
            .frame(minWidth: 50)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .fill(theme.surface.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .strokeBorder(
                    theme.border.default,
                    lineWidth: theme.stroke.default
                )
        )
        .onAppear {
            Task { await refreshModelCount() }
        }
        .onChange(of: showResourcePopover) { _, isShowing in
            if !isShowing {
                // Refresh count when popover closes
                Task { await refreshModelCount() }
            }
        }
        .popover(
            isPresented: $showResourcePopover,
            attachmentAnchor: .point(.bottom),
            arrowEdge: .top
        ) {
            ModelCacheInspectorView(onRefresh: {
                Task { await refreshModelCount() }
            })
            .frame(minWidth: 300)
            .padding(theme.space.s12)
        }
    }

    private func refreshModelCount() async {
        let llmCount = await MLXService.shared.cachedRuntimeSummaries().count
        let imageLoaded = await ImageGenerationService.shared.loadedModelSummary() != nil
        cachedModelCount = llmCount + (imageLoaded ? 1 : 0)
    }

    private func colorForUsage(_ usage: Double) -> Color {
        switch usage {
        case 0 ..< 50:
            return theme.status.success.foreground
        case 50 ..< 80:
            return theme.status.warning.foreground
        default:
            return theme.status.error.foreground
        }
    }
}


