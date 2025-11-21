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
        ToolSettingsRow(entry: entry) {
            reload()
        }
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

// MARK: - Tool Settings Row with Policy/Grants
private struct ToolSettingsRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    let onChange: () -> Void
    @State private var isExpanded: Bool = false
    @State private var refreshToken: Int = 0

    var body: some View {
        let info = ToolRegistry.shared.policyInfo(for: entry.name)
        GlassListRow {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text(entry.description)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { entry.enabled },
                            set: { newValue in
                                ToolRegistry.shared.setEnabled(newValue, for: entry.name)
                                onChange()
                            }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide permissions" : "Show permissions")
                }

                if isExpanded, let info {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Permission policy")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Spacer()
                            if let configured = info.configuredPolicy {
                                Text("Overridden to \(configured.rawValue.uppercased())")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText)
                            } else {
                                Text("Using default")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText)
                            }
                        }
                        HStack(spacing: 8) {
                            PolicySegmentedControl(
                                value: info.configuredPolicy ?? info.effectivePolicy
                            ) { newValue in
                                ToolRegistry.shared.setPolicy(newValue, for: entry.name)
                                bump()
                            }
                            if info.configuredPolicy != nil {
                                Button("Reset to Default") {
                                    ToolRegistry.shared.clearPolicy(for: entry.name)
                                    bump()
                                }
                                .font(.system(size: 11, weight: .medium))
                            }
                        }
                        Text(
                            "Default: \(info.defaultPolicy.rawValue.uppercased())  •  Effective: \(info.effectivePolicy.rawValue.uppercased())"
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)

                        if info.isPermissioned, !info.requirements.isEmpty {
                            Divider()
                            Text("Requirement grants")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(info.requirements, id: \.self) { req in
                                    HStack(spacing: 8) {
                                        Toggle(
                                            req,
                                            isOn: Binding(
                                                get: { info.grantsByRequirement[req] ?? false },
                                                set: { val in
                                                    ToolRegistry.shared.setGrant(val, requirement: req, for: entry.name)
                                                    bump()
                                                }
                                            )
                                        )
                                        .font(.system(size: 12))
                                    }
                                }
                            }
                        }
                    }
                    .id(refreshToken)
                }
            }
        }
    }

    private func bump() {
        refreshToken &+= 1
        onChange()
    }
}

private struct PolicySegmentedControl: View {
    let value: ToolPermissionPolicy
    let onChange: (ToolPermissionPolicy) -> Void

    var body: some View {
        Picker(
            "",
            selection: Binding(
                get: { value },
                set: { onChange($0) }
            )
        ) {
            Text("Auto").tag(ToolPermissionPolicy.auto)
            Text("Ask").tag(ToolPermissionPolicy.ask)
            Text("Deny").tag(ToolPermissionPolicy.deny)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
    }
}
