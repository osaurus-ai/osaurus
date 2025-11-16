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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Loaded Models")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: { Task { await refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Refresh")
            }

            if items.isEmpty {
                Text("No models currently cached.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(items, id: \.name) { item in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(item.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(theme.primaryText)
                                    if item.isCurrent {
                                        Text("In Use")
                                            .font(.system(size: 10, weight: .semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule()
                                                    .fill(theme.accentColor.opacity(0.15))
                                            )
                                            .overlay(
                                                Capsule().stroke(theme.accentColor, lineWidth: 1)
                                            )
                                            .foregroundColor(theme.accentColor)
                                    }
                                }
                                Text(formatBytes(item.bytes))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(theme.secondaryText)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task {
                                    await MLXService().unloadRuntimeModel(named: item.name)
                                    await refresh()
                                }
                            } label: {
                                Text("Unload")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.cardBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.cardBorder, lineWidth: 1)
                                )
                        )
                    }
                }
            }

            Divider()

            HStack {
                Button(role: .destructive) {
                    Task {
                        isClearingAll = true
                        await MLXService().clearRuntimeCache()
                        await refresh()
                        isClearingAll = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Clear All")
                    }
                }
                .buttonStyle(.bordered)
                .tint(theme.errorColor)

                Spacer()
            }
        }
        .onAppear {
            Task { await refresh() }
        }
    }

    private func refresh() async {
        items = await MLXService().cachedRuntimeSummaries()
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
