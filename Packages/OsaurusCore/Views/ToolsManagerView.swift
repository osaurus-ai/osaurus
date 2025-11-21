//
//  ToolsManagerView.swift
//  osaurus
//
//  Manage chat tools: search and toggle enablement.
//

import AppKit
import Foundation
import SwiftUI

struct ToolsManagerView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.theme) private var theme

    @State private var searchText: String = ""
    @State private var toolEntries: [ToolRegistry.ToolEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            ManagerHeader(title: "Tools", subtitle: "Manage available tools for chat")
            Divider()
            contentView
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear { reload() }
        .onChange(of: searchText) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            reload()
        }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            // Tabs + Search bar (styled like ModelDownloadView)
            HStack(spacing: 12) {
                TabPill(title: "All Tools", isSelected: true, count: filteredEntries.count)

                Spacer()

                Button(action: {
                    PluginManager.shared.loadAll()
                    reload()
                }) {
                    Text("Reload")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                SearchField(text: $searchText, placeholder: "Search tools")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(theme.secondaryBackground)

            ScrollView {
                LazyVStack(spacing: 12) {
                    if filteredEntries.isEmpty {
                        Text("No tools match your search")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                            .padding(.vertical, 40)
                    } else {
                        ForEach(filteredEntries) { entry in
                            toolRow(entry)
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private func toolRow(_ entry: ToolRegistry.ToolEntry) -> some View {
        ToggleRow(
            title: entry.name,
            subtitle: entry.description,
            isOn: Binding(
                get: { entry.enabled },
                set: { newValue in
                    ToolRegistry.shared.setEnabled(newValue, for: entry.name)
                    reload()
                }
            )
        )
    }

    private var filteredEntries: [ToolRegistry.ToolEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return toolEntries }
        return toolEntries.filter { e in
            let candidates = [e.name.lowercased(), e.description.lowercased()]
            let q = query.lowercased()
            return candidates.contains { SearchService.fuzzyMatch(query: q, in: $0) }
        }
    }

    private func reload() {
        toolEntries = ToolRegistry.shared.listTools()
    }
}

#Preview {
    ToolsManagerView()
}
