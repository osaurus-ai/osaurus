//
//  ModelCacheInspectorView.swift
//  osaurus
//
//  Popover UI to inspect and manage cached MLX models.
//

import Foundation
import SwiftUI

struct ModelCacheInspectorView: View {
    @Environment(\.theme) private var theme
    @State private var items: [ModelRuntime.ModelCacheSummary] = []
    @State private var imageItem: ImageGenerationService.LoadedModelSummary?
    @State private var isUnloadingImageModel = false
    @State private var isClearingAll = false
    @State private var isRefreshing = false
    @State private var isHoveringRefresh = false
    @State private var unloadingNames: Set<String> = []
    @State private var unloadFailure: String?

    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s14) {
            // Header
            HStack {
                HStack(spacing: theme.space.s8) {
                    SettingsIconTile(icon: "cube.box.fill", size: 28)

                    Text("Loaded Models", bundle: .module)
                        .font(SettingsFont.cardTitle)
                        .foregroundColor(theme.text.primary)
                }

                Spacer()

                RefreshButton(isRefreshing: isRefreshing, isHovered: $isHoveringRefresh) {
                    Task { await refresh() }
                }
            }

            if items.isEmpty && imageItem == nil {
                SettingsEmptyState(inline: "tray", title: "No models currently cached.")
            } else {
                VStack(spacing: theme.space.s8) {
                    ForEach(items, id: \.name) { item in
                        ModelCacheRow(
                            item: item,
                            isUnloading: unloadingNames.contains(item.name),
                            onUnload: {
                                Task { await unload(item) }
                            }
                        )
                    }
                    if let imageItem {
                        ImageModelCacheRow(
                            item: imageItem,
                            isUnloading: isUnloadingImageModel,
                            onUnload: {
                                Task { await unloadImageModel() }
                            }
                        )
                    }
                }
            }

            if let unloadFailure {
                Label(unloadFailure, systemImage: "exclamationmark.triangle.fill")
                    .textStyle(.footnote, weight: 500)
                    .foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("model-cache-unload-failure")
            }

            // Divider
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            theme.border.subtle, theme.border.default, theme.border.subtle,
                        ],
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
                        await ImageGenerationService.shared.unload()
                        await refresh()
                        isClearingAll = false
                    }
                }
                .disabled(items.isEmpty && imageItem == nil)
                .opacity(items.isEmpty && imageItem == nil ? 0.5 : 1.0)

                Spacer()

                // Model count badge
                if loadedModelCount > 0 {
                    Text("\(loadedModelCount) model\(loadedModelCount == 1 ? "" : "s")", bundle: .module)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)
                }
            }
        }
        .onAppear {
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelRuntimeResidencyChanged)) { _ in
            Task { await refresh() }
        }
    }

    private var loadedModelCount: Int {
        items.count + (imageItem == nil ? 0 : 1)
    }

    private func refresh() async {
        isRefreshing = true
        items = await MLXService.shared.cachedRuntimeSummaries()
        imageItem = await ImageGenerationService.shared.loadedModelSummary()
        isRefreshing = false
        onRefresh?()
    }

    @MainActor
    private func unloadImageModel() async {
        guard !isUnloadingImageModel else { return }
        isUnloadingImageModel = true
        await ImageGenerationService.shared.unload()
        isUnloadingImageModel = false
        await refresh()
    }

    @MainActor
    private func unload(_ item: ModelRuntime.ModelCacheSummary) async {
        guard unloadingNames.insert(item.name).inserted else { return }
        unloadFailure = nil

        let didUnload = await MLXService.shared.unloadRuntimeModel(named: item.name)
        unloadingNames.remove(item.name)
        await refresh()

        guard didUnload else {
            unloadFailure = String(
                localized:
                    "Couldn't unload \(item.name) because it is still in use. Stop its active request and try again.",
                bundle: .module
            )
            return
        }
    }
}

// Note: the previous `InferenceSchedulerSection` HUD was retired together
// with the osaurus-side priority scheduler. MLX inference is now serialized
// inside vmlx-swift's `BatchEngine`, which exposes its own queue depth
// counters via signposts. A new HUD can be added here when needed.

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
                    .fill((isHovered ? theme.action.secondary.hover.background : theme.action.secondary.default.background))

                if isHovered {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.surface.hover, Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Image(systemName: "arrow.clockwise")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundColor(isHovered ? theme.text.link : theme.text.secondary)
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing ? theme.motion.loop(duration: 0.8) : theme.motion.standard,
                        value: isRefreshing
                    )
            }
            .frame(width: 26, height: 26)
            .overlay(
                Circle()
                    .strokeBorder(
                        isHovered ? theme.border.default : theme.border.subtle,
                        lineWidth: theme.stroke.default
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isRefreshing)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
        .localizedHelp("Refresh")
    }
}

// MARK: - Model Cache Row
private struct ModelCacheRow: View {
    @Environment(\.theme) private var theme
    let item: ModelRuntime.ModelCacheSummary
    let isUnloading: Bool
    let onUnload: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: theme.space.s10) {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack(spacing: theme.space.s6) {
                    Text(item.name)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)

                    if item.isCurrent {
                        StatusChip(L("Active"), tone: .success, showsDot: true)
                    }
                }

                Text(formatBytes(item.bytes))
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }

            Spacer()

            // Unload button
            Button(action: onUnload) {
                Text(isUnloading ? "Unloading…" : "Unload", bundle: .module)
            }
            .assignedSettingsButtonStyle(.secondary, isLoading: isUnloading, size: .compact)
            .disabled(isUnloading)
            .accessibilityIdentifier("model-cache-unload-\(item.name)")
        }
        .padding(theme.space.s8)
        .settingsChrome(.surface)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
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

/// Row for the resident image gen/edit model — same affordance as the LLM
/// rows so image weights can be released without quitting the app (#2425).
private struct ImageModelCacheRow: View {
    @Environment(\.theme) private var theme
    let item: ImageGenerationService.LoadedModelSummary
    let isUnloading: Bool
    let onUnload: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: theme.space.s10) {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack(spacing: theme.space.s6) {
                    Text(item.name)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)

                    StatusChip(L("Image"), tone: .accent, icon: "photo")
                        .overlay(
                            Capsule().strokeBorder(theme.border.strong, lineWidth: theme.stroke.default)
                        )
                }

                Text(formatBytes(item.bytes))
                    .font(SettingsFont.chip)
                    .foregroundColor(theme.text.secondary)
            }

            Spacer()

            Button(action: onUnload) {
                Text(isUnloading ? "Unloading…" : "Unload", bundle: .module)
            }
            .assignedSettingsButtonStyle(.secondary, isLoading: isUnloading, size: .compact)
            .disabled(isUnloading)
            .accessibilityIdentifier("image-model-cache-unload-\(item.name)")
        }
        .padding(theme.space.s8)
        .settingsChrome(.surface)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
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
    let isClearing: Bool
    let action: () -> Void

    var body: some View {
        SettingsButton(.destructive, "Clear All", icon: "trash", isLoading: isClearing, size: .compact, action: action)
    }
}
