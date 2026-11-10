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
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.secondary)

            HStack(spacing: 12) {
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
                            .glyphSize(14, weight: .medium)
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

// MARK: - Status Badge
struct StatusBadge: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: String
    /// Status tone; `nil` draws the neutral (stopped / inactive) badge.
    let kind: ThemeStatusKind?
    let isAnimating: Bool

    private var pulses: Bool { isAnimating && !reduceMotion }

    /// Neutral badges reuse the subtle surface with tertiary text.
    private var tone: ThemeStatusSet<Color> {
        if let kind { return theme.status[kind] }
        return ThemeStatusSet(
            foreground: theme.text.tertiary, background: theme.surface.subtle, border: theme.border.default)
    }

    private var color: Color { tone.foreground }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                // Pulse ring
                Circle()
                    .stroke(color.opacity(0.3), lineWidth: theme.stroke.focus)
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulses ? 1.6 : 1.0)
                    .opacity(pulses ? 0 : 0.6)
                    .animation(
                        pulses ? theme.motion.loop(.easeOut, duration: 1.2) : theme.motion.standard,
                        value: pulses
                    )

                // Core dot
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }

            Text(status)
                .font(SettingsFont.smallLabel)
                .foregroundColor(color)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s6)
        .background(Capsule().fill(tone.background))
        .overlay(
            Capsule()
                .strokeBorder(
                    tone.border,
                    lineWidth: theme.stroke.default
                )
        )
    }
}

// MARK: - System Resource Monitor
struct SystemResourceMonitor: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var monitor = SystemMonitorService.shared
    @State private var isHoveringCPU = false
    @State private var isHoveringRAM = false
    @State private var isHoveringModels = false
    @State private var showResourcePopover = false
    @State private var cachedModelCount: Int = 0

    var body: some View {
        HStack(spacing: 12) {
            // CPU Usage
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .glyphSize(11, weight: .medium)
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

                ProgressView(value: monitor.cpuUsage / 100.0)
                    .progressViewStyle(MinimalProgressViewStyle(color: colorForUsage(monitor.cpuUsage)))
                    .frame(height: 4)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .glyphSize(11, weight: .medium)
                        .foregroundColor(theme.text.secondary)
                    Text("RAM", bundle: .module)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)

                    // Models indicator button
                    Button(action: { showResourcePopover.toggle() }) {
                        HStack(spacing: 2) {
                            Image(systemName: "cube.box")
                                .glyphSize(9, weight: .medium)

                            if cachedModelCount > 0 {
                                Text("\(cachedModelCount)", bundle: .module)
                                    .font(SettingsFont.monoSmall)
                                    .contentTransition(.numericText())
                            }
                        }
                        .foregroundColor(
                            isHoveringModels
                                ? theme.action.tertiary.hover.foreground : theme.text.tertiary
                        )
                        .padding(.horizontal, theme.space.s4)
                        .padding(.vertical, theme.space.s2)
                        .background(
                            Capsule()
                                .fill(
                                    isHoveringModels
                                        ? theme.action.tertiary.hover.background
                                        : theme.action.tertiary.default.background)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { hovering in
                        withAnimation(theme.motion.quick) {
                            isHoveringModels = hovering
                        }
                    }
                    .help(Text(localized: "Loaded Models\(cachedModelCount > 0 ? " (\(cachedModelCount))" : "")"))

                    Spacer()

                    Text("\(Int(monitor.memoryUsage))%", bundle: .module)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(colorForUsage(monitor.memoryUsage))
                        .contentTransition(.numericText())
                }

                ProgressView(value: monitor.memoryUsage / 100.0)
                    .progressViewStyle(MinimalProgressViewStyle(color: colorForUsage(monitor.memoryUsage)))
                    .frame(height: 4)
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

// MARK: - Minimal Progress View Style
struct MinimalProgressViewStyle: ProgressViewStyle {
    @Environment(\.theme) private var theme
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Tint the track with the fill color so it stays visible on
                // any background. `tertiaryBackground` sits too close to
                // `primaryBackground` in the dark themes to read as a track.
                RoundedRectangle(cornerRadius: theme.radius.small)
                    .fill(color.opacity(0.18))
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: theme.radius.small)
                    .fill(color)
                    .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0), height: 4)
                    .animation(theme.motion.standard, value: configuration.fractionCompleted)
            }
        }
        .frame(height: 4)
    }
}
