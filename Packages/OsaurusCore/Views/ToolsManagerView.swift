//
//  ToolsManagerView.swift
//  osaurus
//
//  Manage chat tools: search and toggle enablement, browse and install plugins.
//

import AppKit
import CryptoKit
import Foundation
import OsaurusRepository
import SwiftUI

private enum ToolsTab: String, CaseIterable {
    case installed = "Installed"
    case browse = "Browse"
}

struct ToolsManagerView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var repoService = PluginRepositoryService.shared
    @Environment(\.theme) private var theme

    @State private var selectedTab: ToolsTab = .installed
    @State private var searchText: String = ""
    @State private var toolEntries: [ToolRegistry.ToolEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            ManagerHeader(title: "Tools", subtitle: "Manage and discover tools for chat")
            Divider()
            contentView
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            reload()
            // Trigger initial refresh if repository is empty
            if repoService.plugins.isEmpty {
                Task { await repoService.refresh() }
            }
        }
        .onChange(of: searchText) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            reload()
        }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            // Tabs + Search bar
            HStack(spacing: 12) {
                ForEach(ToolsTab.allCases, id: \.self) { tab in
                    TabPill(
                        title: tab.rawValue,
                        isSelected: selectedTab == tab,
                        count: countForTab(tab),
                        badge: badgeForTab(tab),
                        action: { selectedTab = tab }
                    )
                }

                Spacer()

                if selectedTab == .browse {
                    Button(action: {
                        Task { await repoService.refresh() }
                    }) {
                        HStack(spacing: 4) {
                            if repoService.isRefreshing {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            }
                            Text(repoService.isRefreshing ? "Refreshing..." : "Refresh")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .disabled(repoService.isRefreshing)
                    .buttonStyle(.bordered)
                } else {
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
                }

                SearchField(text: $searchText, placeholder: "Search tools")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(theme.secondaryBackground)

            switch selectedTab {
            case .installed:
                installedTabContent
            case .browse:
                browseTabContent
            }
        }
    }

    // MARK: - Installed Tab

    private var installedTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if filteredEntries.isEmpty {
                    Text("No tools match your search")
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .padding(.vertical, 40)
                } else {
                    ForEach(filteredEntries) { entry in
                        ToolSettingsRow(entry: entry, repoService: repoService) {
                            reload()
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Browse Tab

    private var browseTabContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if repoService.isRefreshing && repoService.plugins.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading repository...")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                    }
                    .padding(.vertical, 60)
                } else if filteredPlugins.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 32))
                            .foregroundColor(theme.tertiaryText)
                        Text(
                            searchText.isEmpty
                                ? "No plugins available"
                                : "No plugins match your search"
                        )
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                    }
                    .padding(.vertical, 60)
                } else {
                    ForEach(filteredPlugins) { plugin in
                        PluginRow(plugin: plugin, repoService: repoService)
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Helpers

    private func countForTab(_ tab: ToolsTab) -> Int {
        switch tab {
        case .installed:
            return filteredEntries.count
        case .browse:
            return filteredPlugins.count
        }
    }

    private func badgeForTab(_ tab: ToolsTab) -> Int? {
        switch tab {
        case .installed:
            return repoService.updatesAvailableCount > 0 ? repoService.updatesAvailableCount : nil
        case .browse:
            return nil
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

    private var filteredPlugins: [PluginState] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repoService.plugins }
        let q = query.lowercased()
        return repoService.plugins.filter { plugin in
            let candidates = [
                plugin.spec.plugin_id.lowercased(),
                (plugin.spec.name ?? "").lowercased(),
                (plugin.spec.description ?? "").lowercased(),
            ]
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

// MARK: - Plugin Row (Browse Tab)

private struct PluginRow: View {
    @Environment(\.theme) private var theme
    let plugin: PluginState
    @ObservedObject var repoService: PluginRepositoryService
    @State private var errorMessage: String?
    @State private var showError: Bool = false

    var body: some View {
        GlassListRow {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    // Plugin icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor.opacity(0.15))
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 18))
                            .foregroundColor(theme.accentColor)
                    }
                    .frame(width: 40, height: 40)

                    // Plugin info
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(plugin.spec.name ?? plugin.spec.plugin_id)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            if let version = plugin.latestVersion {
                                Text("v\(version.description)")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.tertiaryText)
                            }

                            if plugin.hasUpdate {
                                updateBadge
                            }
                        }

                        if let description = plugin.spec.description {
                            Text(description)
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(2)
                        }

                        // Metadata row
                        HStack(spacing: 12) {
                            if let authors = plugin.spec.authors, !authors.isEmpty {
                                Label(authors.joined(separator: ", "), systemImage: "person")
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
                            }

                            if let license = plugin.spec.license {
                                Label(license, systemImage: "doc.text")
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
                            }

                            if let tools = plugin.spec.capabilities?.tools, !tools.isEmpty {
                                Label("\(tools.count) tool\(tools.count == 1 ? "" : "s")", systemImage: "wrench")
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
                            }
                        }
                    }

                    Spacer()

                    // Action button
                    actionButton
                }

                // Show tools provided
                if let tools = plugin.spec.capabilities?.tools, !tools.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Provides:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)

                        FlowLayout(spacing: 6) {
                            ForEach(tools, id: \.name) { tool in
                                HStack(spacing: 4) {
                                    Image(systemName: "function")
                                        .font(.system(size: 9))
                                    Text(tool.name)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(theme.secondaryBackground)
                                )
                                .foregroundColor(theme.primaryText)
                            }
                        }
                    }
                }
            }
        }
        .alert("Installation Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var updateBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 10))
            Text("Update")
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.orange.opacity(0.2))
        )
        .foregroundColor(.orange)
    }

    @ViewBuilder
    private var actionButton: some View {
        if plugin.isInstalling {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 80)
        } else if plugin.hasUpdate {
            Button(action: { upgrade() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 11))
                    Text("Update")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        } else if plugin.isInstalled {
            Menu {
                Button(role: .destructive) {
                    uninstall()
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text("Installed")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 90)
        } else {
            Button(action: { install() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11))
                    Text("Install")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func install() {
        Task {
            do {
                try await repoService.install(pluginId: plugin.spec.plugin_id)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func upgrade() {
        Task {
            do {
                try await repoService.upgrade(pluginId: plugin.spec.plugin_id)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func uninstall() {
        do {
            try repoService.uninstall(pluginId: plugin.spec.plugin_id)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Flow Layout for Tool Tags

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), positions)
    }
}

// MARK: - Tool Settings Row with Policy/Grants

private struct ToolSettingsRow: View {
    @Environment(\.theme) private var theme
    let entry: ToolRegistry.ToolEntry
    @ObservedObject var repoService: PluginRepositoryService
    let onChange: () -> Void
    @State private var isExpanded: Bool = false
    @State private var refreshToken: Int = 0

    // Check if this tool's plugin has an update
    private var pluginState: PluginState? {
        // Match tool name prefix to plugin_id (tools are named like plugin.toolname)
        let parts = entry.name.split(separator: "_")
        if parts.count >= 2 {
            // For external tools, try to find matching plugin
            for plugin in repoService.plugins {
                if let tools = plugin.spec.capabilities?.tools {
                    if tools.contains(where: { $0.name == entry.name }) {
                        return plugin
                    }
                }
            }
        }
        return nil
    }

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
                                HStack(spacing: 6) {
                                    Text(entry.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(theme.primaryText)

                                    // Show update badge if plugin has update
                                    if let plugin = pluginState, plugin.hasUpdate {
                                        updateBadge
                                    }
                                }
                                Text(entry.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryText)
                            }

                            Spacer()

                            // Update button if available
                            if let plugin = pluginState, plugin.hasUpdate {
                                Button(action: {
                                    Task {
                                        try? await repoService.upgrade(pluginId: plugin.spec.plugin_id)
                                    }
                                }) {
                                    Text("Update")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .controlSize(.small)
                            }

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

    private var updateBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 9))
        }
        .foregroundColor(.orange)
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
                NotificationService.shared.postPluginVerificationFailed(
                    name: receipt.plugin_id,
                    version: receipt.version.description
                )
            }
        }
        refreshSummary()
    }
}
