//
//  ToolsManagerView.swift
//  osaurus
//
//  Manage chat tools: search and toggle enablement.
//

import AppKit
import Foundation
import SwiftUI
import CryptoKit
import OsaurusRepository

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

                // Installed Plugins quick actions
                InstalledPluginsSummaryView()
                    .frame(maxWidth: 360)

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
            VStack(alignment: .leading, spacing: 12) {
                // Main row content
                HStack(spacing: 12) {
                    // Tool info and expand button combined
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    }) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                Text(entry.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryText)
                            }

                            Spacer()

                            // Permission indicator
                            if let info = info {
                                HStack(spacing: 6) {
                                    Image(systemName: iconForPolicy(info.effectivePolicy))
                                        .font(.system(size: 11))
                                        .foregroundColor(colorForPolicy(info.effectivePolicy))
                                    Text(info.effectivePolicy.rawValue.capitalized)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(theme.secondaryText)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(theme.secondaryBackground)
                                )
                            }

                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.tertiaryText)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Enable toggle - separate from expand area
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
                }

                // Expanded permissions section
                if isExpanded, let info {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider()

                        // Permission policy section
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Permission Policy")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.primaryText)

                                Spacer()

                                if info.configuredPolicy != nil {
                                    Button("Use Default") {
                                        ToolRegistry.shared.clearPolicy(for: entry.name)
                                        bump()
                                    }
                                    .font(.system(size: 10))
                                    .buttonStyle(.plain)
                                    .foregroundColor(theme.accentColor)
                                }
                            }

                            // Simple segmented picker
                            Picker(
                                "",
                                selection: Binding(
                                    get: { info.configuredPolicy ?? info.effectivePolicy },
                                    set: { newValue in
                                        ToolRegistry.shared.setPolicy(newValue, for: entry.name)
                                        bump()
                                    }
                                )
                            ) {
                                Label("Auto", systemImage: "sparkles").tag(ToolPermissionPolicy.auto)
                                Label("Ask", systemImage: "questionmark.circle").tag(ToolPermissionPolicy.ask)
                                Label("Deny", systemImage: "xmark.circle").tag(ToolPermissionPolicy.deny)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            if let configured = info.configuredPolicy, configured != info.defaultPolicy {
                                Text("Default is \(info.defaultPolicy.rawValue)")
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
                            }
                        }

                        // Required permissions section (if applicable)
                        if info.isPermissioned, !info.requirements.isEmpty {
                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Required Permissions")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.primaryText)

                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(info.requirements, id: \.self) { req in
                                        Toggle(
                                            isOn: Binding(
                                                get: { info.grantsByRequirement[req] ?? false },
                                                set: { val in
                                                    ToolRegistry.shared.setGrant(val, requirement: req, for: entry.name)
                                                    bump()
                                                }
                                            )
                                        ) {
                                            Text(req)
                                                .font(.system(size: 11))
                                                .foregroundColor(theme.primaryText)
                                        }
                                        .toggleStyle(.checkbox)
                                    }
                                }
                                .padding(.leading, 2)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .id(refreshToken)
                }
            }
        }
    }

    private func bump() {
        refreshToken &+= 1
        onChange()
    }

    private func iconForPolicy(_ policy: ToolPermissionPolicy) -> String {
        switch policy {
        case .auto:
            return "sparkles"
        case .ask:
            return "questionmark.circle"
        case .deny:
            return "xmark.circle"
        }
    }

    private func colorForPolicy(_ policy: ToolPermissionPolicy) -> Color {
        switch policy {
        case .auto:
            return theme.accentColor
        case .ask:
            return .orange
        case .deny:
            return theme.errorColor
        }
    }
}

// MARK: - Installed Plugins Summary
private struct InstalledPluginsSummaryView: View {
    @Environment(\.theme) private var theme
    @State private var summaryText: String = ""
    @State private var isVerifying: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundColor(theme.accentColor)
            Text(summaryText.isEmpty ? "No plugins" : summaryText)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: { Task { await verifyAll() } }) {
                Text(isVerifying ? "Verifying..." : "Verify")
                    .font(.system(size: 11, weight: .medium))
            }
            .disabled(isVerifying)
            .buttonStyle(.bordered)
        }
        .onAppear { refreshSummary() }
    }

    private func refreshSummary() {
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        let url =
            supportDir
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent("receipts.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else {
            summaryText = ""
            return
        }
        struct IndexDump: Decodable { let receipts: [String: [String: PluginReceipt]] }
        if let index = try? JSONDecoder().decode(IndexDump.self, from: data) {
            let count = index.receipts.count
            let ids = index.receipts.keys.sorted()
            summaryText = count == 0 ? "" : "\(count) plugin\(count == 1 ? "" : "s"): \(ids.joined(separator: ", "))"
        } else {
            summaryText = ""
        }
    }

    private func verifyAll() async {
        isVerifying = true
        defer { isVerifying = false }
        let fm = FileManager.default
        let root = ToolsPaths.toolsRootDirectory()
        guard let pluginDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for pluginDir in pluginDirs where pluginDir.hasDirectoryPath {
            let currentLink = pluginDir.appendingPathComponent("current")
            let versionDir: URL?
            if let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
                versionDir = pluginDir.appendingPathComponent(dest, isDirectory: true)
            } else {
                versionDir = nil
            }
            guard let vdir = versionDir else { continue }
            let receiptURL = vdir.appendingPathComponent("receipt.json")
            guard let rdata = try? Data(contentsOf: receiptURL),
                let receipt = try? JSONDecoder().decode(PluginReceipt.self, from: rdata)
            else { continue }
            let dylibURL = vdir.appendingPathComponent(receipt.dylib_filename)
            guard let dylibData = try? Data(contentsOf: dylibURL) else { continue }
            let digest = CryptoKit.SHA256.hash(data: dylibData)
            let sha = Data(digest).map { String(format: "%02x", $0) }.joined()
            if sha.lowercased() != receipt.dylib_sha256.lowercased() {
                // Show a non-blocking alert via notification center
                let note = NSUserNotification()
                note.title = "Plugin verification failed"
                note.informativeText = "\(receipt.plugin_id) @ \(receipt.version)"
                NSUserNotificationCenter.default.deliver(note)
            }
        }
        refreshSummary()
    }
}
