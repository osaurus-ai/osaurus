//
//  SkillsView.swift
//  osaurus
//
//  Management view for creating, editing, and viewing skills.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Skills View

struct SkillsView: View {
    @ObservedObject private var badgeStore = ManagementBadgeStore.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    private var skillManager = SkillManager.shared

    private var theme: any ThemeProtocol { themeManager.currentTheme }

    @State private var isCreating = false
    @State private var editingSkill: Skill?
    @State private var hasAppeared = false
    @State private var toastMessage: (text: String, isError: Bool)?
    @State private var exportingSkill: Skill?
    @State private var isProcessing = false
    @State private var showProgress = false
    @State private var searchText = ""
    @State private var selectedTab: SkillsTab = .all
    @State private var pendingOverwriteImportURL: URL?
    @State private var pendingOverwriteSkillName = ""
    @State private var showOverwriteConfirmation = false
    @State private var showGitHubImport = false
    /// Bumped after a GitHub plugin install so the Claude Plugins marketplace
    /// re-reads installed state.
    @State private var claudePluginInstallGeneration = 0

    /// Base skill set for a tab, sliced by source: shipped with Osaurus,
    /// created/imported by the user, or installed as part of a plugin.
    private func skills(in tab: SkillsTab) -> [Skill] {
        switch tab {
        case .all: return skillManager.skills
        case .custom: return skillManager.skills.filter { !$0.isBuiltIn && !$0.isFromPlugin }
        // The Claude Plugins tab shows the marketplace, not the skill list.
        case .claudePlugins: return []
        }
    }

    private var tabCounts: [SkillsTab: Int] {
        [
            .all: skillManager.skills.count,
            .custom: skillManager.skills.filter { !$0.isBuiltIn && !$0.isFromPlugin }.count,
        ]
    }

    /// Skills for the selected tab, further narrowed by the search query
    /// (name, description, category, or keywords).
    private var filteredSkills: [Skill] {
        let base = skills(in: selectedTab)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return base }
        return base.filter { skill in
            skill.name.lowercased().contains(query)
                || skill.description.lowercased().contains(query)
                || (skill.category?.lowercased().contains(query) ?? false)
                || skill.keywords.contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            // Header
            headerView
                .settingsHeaderEntrance(hasAppeared: hasAppeared)

            // Progress bar
            if showProgress {
                SettingsProgressBar(value: nil, height: 2)
                    .transition(.opacity)
            } else {
                Spacer().frame(height: 2)
            }

            // Content
            ZStack {
                if selectedTab == .claudePlugins {
                    ClaudePluginsMarketplaceView(
                        searchText: searchText,
                        installGeneration: claudePluginInstallGeneration
                    )
                        .opacity(hasAppeared ? 1 : 0)
                } else if skillManager.skills.isEmpty && !skillManager.isRefreshing {
                    SettingsEmptyState(
                        icon: "sparkles",
                        title: "Create Your First Skill",
                        subtitle: "Skills are reusable instructions that every custom agent can use automatically.",
                        examples: [
                            .init(
                                icon: "magnifyingglass",
                                title: L("Web Researcher"),
                                description: "Live web research with cited sources"
                            ),
                            .init(
                                icon: "gearshape.2.fill",
                                title: L("Mac Automator"),
                                description: "Control Mac apps with AppleScript"
                            ),
                            .init(
                                icon: "calendar",
                                title: L("Personal Organizer"),
                                description: "Manage calendar, reminders, and mail"
                            ),
                        ],
                        primaryAction: .init(title: "Create Skill", icon: "plus", handler: { isCreating = true }),
                        hasAppeared: hasAppeared
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: theme.space.s8) {
                            availabilityHint

                            let shown = filteredSkills
                            if shown.isEmpty {
                                emptyState
                            } else {
                                SettingsGroup {
                                    ForEach(shown) { skill in
                                        SkillRow(
                                            skill: skill,
                                            onEdit: {
                                                editingSkill = skill
                                            },
                                            onExport: {
                                                exportingSkill = skill
                                            },
                                            onDelete: {
                                                Task { @MainActor in
                                                    isProcessing = true
                                                    defer { isProcessing = false }
                                                    await skillManager.delete(id: skill.id)
                                                    showToast(L("Deleted \"\(skill.name)\""))
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        .settingsPageInsets()
                    }
                    .opacity(hasAppeared ? 1 : 0)
                }

                // Toast notification
                if let toast = toastMessage {
                    VStack {
                        Spacer()
                        ThemedToastView(toast.text, type: toast.isError ? .error : .success)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, theme.space.s16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
        .sheet(isPresented: $isCreating) {
            SkillEditorSheet(
                mode: .create,
                onSave: { skill in
                    Task { @MainActor in
                        isProcessing = true
                        defer { isProcessing = false }
                        await skillManager.create(
                            name: skill.name,
                            description: skill.description,
                            version: skill.version,
                            author: skill.author,
                            category: skill.category,
                            keywords: skill.keywords,
                            instructions: skill.instructions
                        )
                        isCreating = false
                        showToast(L("Created \"\(skill.name)\""))
                    }
                },
                onCancel: {
                    isCreating = false
                }
            )
        }
        .sheet(item: $editingSkill) { skill in
            SkillEditorSheet(
                mode: .edit(skill),
                onSave: { updated in
                    Task { @MainActor in
                        isProcessing = true
                        defer { isProcessing = false }
                        await skillManager.update(updated)
                        editingSkill = nil
                        showToast(L("Updated \"\(updated.name)\""))
                    }
                },
                onCancel: {
                    editingSkill = nil
                }
            )
        }
        .sheet(isPresented: $showGitHubImport) {
            GitHubImportSheet(
                onImport: { skills in
                    Task { @MainActor in
                        _ = await skillManager.importSkillsFromMarkdown(skills)
                        showGitHubImport = false
                        claudePluginInstallGeneration += 1
                        showToast(skills.count == 1 ? L("Imported 1 item") : L("Imported \(skills.count) items"))
                    }
                },
                onCancel: { showGitHubImport = false },
                onPluginInstallComplete: { report in
                    Task { @MainActor in
                        await skillManager.refresh()
                        claudePluginInstallGeneration += 1
                        let total =
                            report.totalImportedSkills + report.totalImportedAgents
                            + report.totalImportedCommands + report.totalImportedMCPProviders
                        if total > 0 {
                            showToast(total == 1 ? L("Installed 1 item") : L("Installed \(total) items"))
                        }
                    }
                }
            )
        }
        .alert(L("Replace Existing Skill?"), isPresented: $showOverwriteConfirmation) {
            Button(L("Cancel"), role: .cancel) {
                pendingOverwriteImportURL = nil
                pendingOverwriteSkillName = ""
            }
            Button(L("Replace"), role: .destructive) {
                guard let url = pendingOverwriteImportURL else { return }
                pendingOverwriteImportURL = nil
                pendingOverwriteSkillName = ""
                Task { @MainActor in
                    await performSkillImport(from: url, overwriteExisting: true)
                }
            }
        } message: {
            Text(
                L(
                    "A skill named \"\(pendingOverwriteSkillName)\" already exists. Replacing it overwrites its SKILL.md, references, and assets."
                )
            )
        }
        .onChange(of: isProcessing || skillManager.isRefreshing) { _, newValue in
            if newValue {
                // Delay showing the progress bar to avoid flickering for fast operations
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)  // 2.5 seconds
                    if isProcessing || skillManager.isRefreshing {
                        withAnimation(theme.motion.quick) {
                            showProgress = true
                        }
                    }
                }
            } else {
                withAnimation(theme.motion.quick) {
                    showProgress = false
                }
            }
        }
        .onAppear {
            Task { @MainActor in
                await skillManager.refresh()
                withAnimation(theme.motion.standard.delay(0.05)) {
                    hasAppeared = true
                }
            }
        }
        .onChange(of: exportingSkill) { _, skill in
            if let skill = skill {
                Task { @MainActor in
                    exportSkill(skill)
                }
            }
        }
    }

    // MARK: - Export

    /// Export a user-created skill as SKILL.md or a ZIP bundle with
    /// associated files. Kept here so the in-row Export button keeps
    /// working after the broader Import dropdown migrated to the
    /// Plugins tab.
    @MainActor
    private func exportSkill(_ skill: Skill) {
        let panel = NSSavePanel()

        if skill.hasAssociatedFiles {
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = "\(skill.xplaceholder_agentSkillsNamex).zip"
            panel.title = L("Export Skill (Agent Skills Format)")
            panel.message = L("Export as ZIP archive with all associated files")
        } else {
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "SKILL.md"
            panel.title = L("Export Skill (Agent Skills Format)")
            panel.message = L("Export as Agent Skills compatible SKILL.md file")
        }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { @MainActor in
                    self.isProcessing = true
                    defer { self.isProcessing = false }
                    do {
                        if skill.hasAssociatedFiles {
                            let zipURL = try await skillManager.exportSkillAsZip(skill)
                            try FileManager.default.copyItem(at: zipURL, to: url)
                            try? FileManager.default.removeItem(at: zipURL)
                            self.showToast(L("Exported \"\(skill.name)\" as ZIP"))
                        } else {
                            let content = skillManager.exportSkillAsAgentSkills(skill)
                            try content.write(to: url, atomically: true, encoding: .utf8)
                            self.showToast(L("Exported \"\(skill.name)\" as SKILL.md"))
                        }
                    } catch {
                        self.showToast(L("Export failed: \(error.localizedDescription)"), isError: true)
                    }
                }
            }
            self.exportingSkill = nil
        }
    }

    // MARK: - Import

    /// Import a third-party skill from disk: either a SKILL.md file or a ZIP
    /// bundle carrying nested `references/`/`assets/` resources. Uses an
    /// AppKit `NSOpenPanel` (not SwiftUI `.fileImporter`) to avoid the dialog
    /// freeze that previously affected the import flow.
    @MainActor
    private func importSkill() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "md") ?? .plainText]
        panel.title = L("Import Skill")
        panel.message = L("Choose a SKILL.md file or a ZIP bundle to import")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await self.performSkillImport(from: url, overwriteExisting: false)
            }
        }
    }

    @MainActor
    private func performSkillImport(from url: URL, overwriteExisting: Bool) async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            if url.pathExtension.lowercased() == "zip" {
                let result = try await skillManager.importSkillFromZip(url, overwriteExisting: overwriteExisting)
                showImportSuccess(for: result.skill, notes: result.notes)
            } else {
                // Read off the main thread so a large file can't hang the UI.
                let content = try await Task.detached(priority: .userInitiated) {
                    try String(contentsOf: url, encoding: .utf8)
                }.value
                let skill = try await skillManager.importSkillFromMarkdown(
                    content,
                    overwriteExisting: overwriteExisting
                )
                showImportSuccess(for: skill, notes: [])
            }
        } catch SkillFileError.skillAlreadyExists(let name) {
            pendingOverwriteImportURL = url
            pendingOverwriteSkillName = name
            showOverwriteConfirmation = true
        } catch {
            showToast(
                L("Import failed: \(error.localizedDescription)"),
                isError: true
            )
        }
    }

    @MainActor
    private func showImportSuccess(for skill: Skill, notes: [String]) {
        let note = notes.first.map { " \($0)" } ?? ""
        showToast(L("Imported \"\(skill.name)\"") + note)
    }

    // MARK: - Availability Hint

    /// One-line explanation of the library contract: no toggles, no per-agent
    /// assignment — everything installed is available to custom agents.
    private var availabilityHint: some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "info.circle")
                .glyphSize(.footnote, weight: .medium)
                .foregroundColor(theme.text.link)
            Text(
                "A skill loads only when it is relevant. Type /skill-name in chat to use one explicitly.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.selected)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        SettingsEmptyState(
            inline: searchText.isEmpty ? "sparkles" : "magnifyingglass",
            title: searchText.isEmpty
                ? (selectedTab == .custom ? "No skills of your own yet — create or import one" : "No skills here")
                : L("No skills match \"\(searchText)\"")
        )
        .padding(.vertical, theme.settingsSectionGap)
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(
            title: "Skills",
            subtitle: "Reusable instructions, automatically available to every custom agent",
            count: badgeStore.headerCount(for: .skills),
            onRefresh: { Task { @MainActor in await skillManager.refresh() } },
            refreshHelp: "Refresh skills",
            isRefreshing: skillManager.isRefreshing,
            primary: {
                SettingsMenuButton(.primary, "Add Skill", icon: "plus") {
                    Button(action: { isCreating = true }) {
                        Label(L("Create Skill"), systemImage: "plus")
                    }
                    Button(action: { importSkill() }) {
                        Label(L("Import Skill"), systemImage: "square.and.arrow.down")
                    }
                    Button(action: { showGitHubImport = true }) {
                        Label(L("Import Claude plugin from GitHub"), systemImage: "link.badge.plus")
                    }
                }
                .disabled(isProcessing || skillManager.isRefreshing)
            },
            toolbar: {
                SettingsTabsRow(
                    selection: $selectedTab,
                    counts: tabCounts,
                    searchText: $searchText,
                    searchPlaceholder: "Search skills"
                )
            }
        )
    }

    // MARK: - Toast Helper

    @MainActor
    private func showToast(_ message: String, isError: Bool = false) {
        withAnimation(theme.motion.springAnimation) {
            toastMessage = (message, isError)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((isError ? 3.5 : 2.5) * 1_000_000_000))
            withAnimation(theme.motion.quick) {
                toastMessage = nil
            }
        }
    }
}

// MARK: - Skill Row

private struct SkillRow: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let skill: Skill
    let onEdit: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @State private var isExpanded = false
    @State private var showDeleteConfirm = false

    /// Display name of the source plugin, or "Plugin" as fallback
    private var pluginDisplayName: String {
        guard let pluginId = skill.pluginId else { return L("Plugin") }
        if let plugin = PluginRepositoryService.shared.plugins.first(where: { $0.pluginId == pluginId }) {
            return L("From: \(plugin.displayName)")
        }
        return L("Plugin")
    }

    private var skillColor: Color { theme.dataInk(seed: skill.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            LibraryRow(
                title: skill.name,
                subtitle: skill.description.isEmpty ? L("No description") : skill.description,
                action: {
                    withAnimation(theme.motion.springAnimation) {
                        isExpanded.toggle()
                    }
                }
            ) {
                SettingsIconTile(icon: "sparkles", size: 32, tint: skillColor)
            } badges: {
                if skill.isBuiltIn {
                    StatusChip(L("Built-in"), tone: .neutral)
                } else if skill.isFromPlugin {
                    StatusChip(pluginDisplayName, tone: .accent, icon: "puzzlepiece.extension")
                }
                if let category = skill.category {
                    StatusChip(category, tint: skillColor)
                }
            } trailing: {
                Text(
                    skill.instructions.count == 1
                        ? L("1 character")
                        : L("\(skill.instructions.count) characters")
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(1)

                SettingsChevron()
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            } menu: {
                Button(skill.isBuiltIn || skill.isFromPlugin ? L("View") : L("Edit"), action: onEdit)
                if !skill.isFromPlugin {
                    Button(L("Export"), action: onExport)
                }
                if !skill.isBuiltIn && !skill.isFromPlugin {
                    Divider()
                    Button(L("Delete"), role: .destructive) { showDeleteConfirm = true }
                }
            }

            if isExpanded {
                expandedContent
                    .padding(.leading, 32 + theme.space.s12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .themedAlert(
            L("Delete Skill"),
            isPresented: $showDeleteConfirm,
            message: L("Are you sure you want to delete \"\(skill.name)\"? This action cannot be undone."),
            primaryButton: .destructive(L("Delete"), action: onDelete),
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            LibraryStatRow(stats: metaStats)

            ScrollView {
                Text(skill.instructions)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
            .settingsChrome(.control)

            if skill.isFromPlugin {
                SettingsRowDescription(text: "Managed by its plugin — uninstall in Plugins to remove")
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
        }
        .padding(.bottom, theme.space.s6)
    }

    private var metaStats: [LibraryStat] {
        var stats: [LibraryStat] = [LibraryStat(icon: "tag", text: L("v\(skill.version)"))]
        if let author = skill.author {
            stats.append(LibraryStat(icon: "person", text: author))
        }
        if skill.hasAssociatedFiles {
            stats.append(
                LibraryStat(
                    icon: "folder",
                    text: skill.totalFileCount == 1 ? L("1 file") : L("\(skill.totalFileCount) files")))
        }
        return stats
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        SkillsView()
    }
#endif
