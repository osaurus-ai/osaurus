//
//  ModelCacheInspectorView.swift
//  osaurus
//
//  Popover UI to inspect and manage cached MLX models.
//

import SwiftUI

struct ModelCacheInspectorView: View {
    @Environment(\.theme) private var theme
    @State private var items: [ModelRuntime.ModelCacheSummary] = []
    @State private var isClearingAll = false
    @State private var isRefreshing = false
    @State private var isHoveringRefresh = false

    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.accentColor.opacity(0.15))
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [theme.accentColor.opacity(0.1), Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "cube.box.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.accentColor.opacity(0.2), lineWidth: 1)
                    )

                    Text("Loaded Models")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                }

                Spacer()

                RefreshButton(isRefreshing: isRefreshing, isHovered: $isHoveringRefresh) {
                    Task { await refresh() }
                }
            }

            if items.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(theme.tertiaryText)

                    Text("No models currently cached.")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(items, id: \.name) { item in
                        ModelCacheRow(
                            item: item,
                            onUnload: {
                                Task {
                                    await MLXService.shared.unloadRuntimeModel(named: item.name)
                                    await refresh()
                                }
                            }
                        )
                    }
                }
            }

            // Divider
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [theme.cardBorder.opacity(0.3), theme.cardBorder, theme.cardBorder.opacity(0.3)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)

            // Actions
            HStack {
                ClearAllButton(isClearing: isClearingAll) {
                    Task {
                        isClearingAll = true
                        await MLXService.shared.clearRuntimeCache()
                        await refresh()
                        isClearingAll = false
                    }
                }
                .disabled(items.isEmpty)
                .opacity(items.isEmpty ? 0.5 : 1.0)

                Spacer()

                // Model count badge
                if !items.isEmpty {
                    Text("\(items.count) model\(items.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
            }
        }
        .onAppear {
            Task { await refresh() }
        }
    }

    private func refresh() async {
        isRefreshing = true
        items = await MLXService.shared.cachedRuntimeSummaries()
        isRefreshing = false
        onRefresh?()
    }
}

// MARK: - Refresh Button
private struct RefreshButton: View {
    @Environment(\.theme) private var theme
    let isRefreshing: Bool
    @Binding var isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.buttonBackground.opacity(isHovered ? 0.95 : 0.7))

                if isHovered {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(0.1), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                        value: isRefreshing
                    )
            }
            .frame(width: 26, height: 26)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.2 : 0.1),
                                theme.buttonBorder.opacity(isHovered ? 0.3 : 0.15),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isRefreshing)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help("Refresh")
    }
}

// MARK: - Model Cache Row
private struct ModelCacheRow: View {
    @Environment(\.theme) private var theme
    let item: ModelRuntime.ModelCacheSummary
    let onUnload: () -> Void

    @State private var isHovered = false
    @State private var isUnloadHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    if item.isCurrent {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(theme.successColor)
                                .frame(width: 5, height: 5)
                            Text("Active")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(theme.successColor)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(theme.successColor.opacity(0.12))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(theme.successColor.opacity(0.25), lineWidth: 1)
                        )
                    }
                }

                Text(formatBytes(item.bytes))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            // Unload button
            Button(action: onUnload) {
                Text("Unload")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isUnloadHovered ? theme.errorColor : theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.buttonBackground.opacity(isUnloadHovered ? 0.95 : 0.7))

                            if isUnloadHovered {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.errorColor.opacity(0.08))
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isUnloadHovered ? theme.errorColor.opacity(0.3) : theme.buttonBorder.opacity(0.5),
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isUnloadHovered = hovering
                }
            }
        }
        .padding(10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.cardBackground.opacity(isHovered ? 0.95 : 0.8))

                if isHovered {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(0.04), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.glassEdgeLight.opacity(isHovered ? 0.15 : 0.08),
                            theme.cardBorder.opacity(isHovered ? 0.4 : 0.3),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "~0 MB" }
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        if gb >= 1.0 { return String(format: "%.2f GB", gb) }
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Clear All Button
private struct ClearAllButton: View {
    @Environment(\.theme) private var theme
    let isClearing: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isClearing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                Text("Clear All")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHovered ? .white : theme.errorColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? theme.errorColor : theme.errorColor.opacity(0.1))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                isHovered ? Color.white.opacity(0.2) : theme.errorColor.opacity(0.3),
                                theme.errorColor.opacity(isHovered ? 0.4 : 0.15),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? theme.errorColor.opacity(0.3) : .clear,
                radius: 4,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isClearing)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
