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
    @ObservedObject private var themeManager = ThemeManager.shared
    private var skillManager = SkillManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

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

    /// Base skill set for a tab: All, Installed (user-created + plugin), or
    /// Default (built-in).
    private func skills(in tab: SkillsTab) -> [Skill] {
        switch tab {
        case .all: return skillManager.skills
        case .installed: return skillManager.skills.filter { !$0.isBuiltIn }
        case .defaults: return skillManager.skills.filter { $0.isBuiltIn }
        }
    }

    private var tabCounts: [SkillsTab: Int] {
        [
            .all: skillManager.skills.count,
            .installed: skillManager.skills.filter { !$0.isBuiltIn }.count,
            .defaults: skillManager.skills.filter { $0.isBuiltIn }.count,
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
        VStack(spacing: 0) {
            // Header
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            // Progress bar
            if showProgress {
                ProgressView()
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(height: 2)
                    .transition(.opacity)
            } else {
                Spacer().frame(height: 2)
            }

            // Content
            ZStack {
                if skillManager.skills.isEmpty && !skillManager.isRefreshing {
                    SettingsEmptyState(
                        icon: "sparkles",
                        title: L("Create Your First Skill"),
                        subtitle: L("Skills provide specialized knowledge and guidance to the AI."),
                        examples: [
                            .init(
                                icon: "magnifyingglass",
                                title: L("Research Analyst"),
                                description: "Fact-checking and balanced analysis"
                            ),
                            .init(
                                icon: "lightbulb.fill",
                                title: L("Creative Brainstormer"),
                                description: "Generate ideas and explore possibilities"
                            ),
                            .init(
                                icon: "checklist",
                                title: L("Productivity Coach"),
                                description: "Task management and goal setting"
                            ),
                        ],
                        primaryAction: .init(title: "Create Skill", icon: "plus", handler: { isCreating = true }),
                        hasAppeared: hasAppeared
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            let shown = filteredSkills
                            if shown.isEmpty {
                                emptyState
                            }

                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, skill in
                                SkillRow(
                                    skill: skill,
                                    animationDelay: Double(index) * 0.03,
                                    hasAppeared: hasAppeared,
                                    onToggle: { enabled in
                                        Task { @MainActor in
                                            isProcessing = true
                                            defer { isProcessing = false }
                                            await skillManager.setEnabled(enabled, for: skill.id)
                                        }
                                    },
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
                        .padding(24)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                }

                // Toast notification
                if let toast = toastMessage {
                    VStack {
                        Spacer()
                        ThemedToastView(toast.text, type: toast.isError ? .error : .success)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
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
                        withAnimation(.easeIn(duration: 0.2)) {
                            showProgress = true
                        }
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    showProgress = false
                }
            }
        }
        .onAppear {
            Task { @MainActor in
                await skillManager.refresh()
                withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
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

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "sparkles" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(theme.tertiaryText)
            if !searchText.isEmpty {
                Text("No skills match \"\(searchText)\"", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            } else if selectedTab == .installed {
                Text("No installed skills yet", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            } else {
                Text("No skills here", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithTabs(
            title: L("Skills"),
            subtitle: L("Specialized knowledge and guidance for the AI")
        ) {
            HeaderIconButton("arrow.clockwise", isLoading: skillManager.isRefreshing, help: "Refresh skills") {
                Task { @MainActor in
                    await skillManager.refresh()
                }
            }

            HeaderIconButton("square.and.arrow.down", help: "Import skill") {
                importSkill()
            }
            .disabled(isProcessing || skillManager.isRefreshing)

            HeaderPrimaryButton("Create Skill", icon: "plus") {
                isCreating = true
            }
            .disabled(isProcessing || skillManager.isRefreshing)
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: tabCounts,
                searchText: $searchText,
                searchPlaceholder: "Search skills"
            )
        }
    }

    // MARK: - Toast Helper

    @MainActor
    private func showToast(_ message: String, isError: Bool = false) {
        withAnimation(theme.springAnimation()) {
            toastMessage = (message, isError)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((isError ? 3.5 : 2.5) * 1_000_000_000))
            withAnimation(theme.animationQuick()) {
                toastMessage = nil
            }
        }
    }
}

// MARK: - Skill Row

private struct SkillRow: View {
    @Environment(\.theme) private var theme

    let skill: Skill
    let animationDelay: Double
    let hasAppeared: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
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

    private var skillColor: Color {
        let hue = Double(abs(skill.name.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Main row content
            HStack(spacing: 12) {
                // Skill icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(skillColor.opacity(0.1))
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(skillColor)
                }
                .frame(width: 36, height: 36)

                // Skill info and expand button combined
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(skill.name)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundColor(theme.primaryText)

                                if skill.isBuiltIn {
                                    Text("Built-in", bundle: .module)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(theme.secondaryText)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(theme.tertiaryBackground)
                                        )
                                } else if skill.isFromPlugin {
                                    HStack(spacing: 3) {
                                        Image(systemName: "puzzlepiece.extension")
                                            .font(.system(size: 8))
                                        Text(pluginDisplayName)
                                            .font(.system(size: 9, weight: .medium))
                                    }
                                    .foregroundColor(theme.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(theme.accentColor.opacity(0.1))
                                    )
                                }

                                if let category = skill.category {
                                    Text(category)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(skillColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(skillColor.opacity(0.1))
                                        )
                                }
                            }

                            Text(skill.description.isEmpty ? "No description" : skill.description)
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Instructions preview badge
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 10))
                            Text("\(skill.instructions.count) chars", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.tertiaryBackground))

                        // Chevron
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
                        get: { skill.enabled },
                        set: { onToggle($0) }
                    )
                )
                .toggleStyle(SwitchToggleStyle())
                .labelsHidden()
            }

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .padding(.vertical, 4)

                    // Instructions preview
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Instructions", bundle: .module)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            Spacer()

                            if let author = skill.author {
                                Label(author, systemImage: "person")
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
                            }

                            Label {
                                Text("v\(skill.version)", bundle: .module)
                            } icon: {
                                Image(systemName: "tag")
                            }
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)

                            if skill.hasAssociatedFiles {
                                Label {
                                    Text("\(skill.totalFileCount) files", bundle: .module)
                                } icon: {
                                    Image(systemName: "folder")
                                }
                                .font(.system(size: 10))
                                .foregroundColor(theme.tertiaryText)
                            }
                        }

                        ScrollView {
                            Text(skill.instructions)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 180)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                    }

                    // Action buttons
                    HStack(spacing: 8) {
                        if !skill.isFromPlugin {
                            Button(action: onEdit) {
                                HStack(spacing: 4) {
                                    Image(systemName: skill.isBuiltIn ? "eye" : "pencil")
                                        .font(.system(size: 10))
                                    Text(LocalizedStringKey(skill.isBuiltIn ? "View" : "Edit"), bundle: .module)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.accentColor.opacity(0.1))
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            // View-only button for plugin skills
                            Button(action: onEdit) {
                                HStack(spacing: 4) {
                                    Image(systemName: "eye")
                                        .font(.system(size: 10))
                                    Text("View", bundle: .module)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.accentColor.opacity(0.1))
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if !skill.isFromPlugin {
                            Button(action: onExport) {
                                HStack(spacing: 4) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 10))
                                    Text("Export", bundle: .module)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.tertiaryBackground)
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        Spacer()

                        if skill.isFromPlugin {
                            // Info badge for plugin skills
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 10))
                                Text("Managed by plugin", bundle: .module)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(theme.tertiaryText)
                        }

                        if !skill.isBuiltIn && !skill.isFromPlugin {
                            Button(action: { showDeleteConfirm = true }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                    Text("Delete", bundle: .module)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(theme.errorColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.errorColor.opacity(0.1))
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 10)
        .animation(.easeOut(duration: 0.25).delay(animationDelay), value: hasAppeared)
        .themedAlert(
            L("Delete Skill"),
            isPresented: $showDeleteConfirm,
            message: L("Are you sure you want to delete \"\(skill.name)\"? This action cannot be undone."),
            primaryButton: .destructive(L("Delete"), action: onDelete),
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isHovered ? theme.accentColor.opacity(0.2) : theme.cardBorder,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 12 : 6,
                x: 0,
                y: isHovered ? 4 : 2
            )
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        SkillsView()
    }
#endif
