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
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var skillManager = SkillManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var isCreating = false
    @State private var editingSkill: Skill?
    @State private var hasAppeared = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var searchText: String = ""
    @State private var showImportPicker = false
    @State private var exportingSkill: Skill?

    private var filteredSkills: [Skill] {
        if searchText.isEmpty {
            return skillManager.skills
        }
        let query = searchText.lowercased()
        return skillManager.skills.filter { skill in
            skill.name.lowercased().contains(query)
                || skill.description.lowercased().contains(query)
                || (skill.category?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content
            ZStack {
                if skillManager.skills.isEmpty {
                    SkillEmptyState(
                        hasAppeared: hasAppeared,
                        onCreate: { isCreating = true }
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(filteredSkills.enumerated()), id: \.element.id) { index, skill in
                                SkillCard(
                                    skill: skill,
                                    animationDelay: Double(index) * 0.03,
                                    hasAppeared: hasAppeared,
                                    onToggle: { enabled in
                                        skillManager.setEnabled(enabled, for: skill.id)
                                    },
                                    onEdit: {
                                        editingSkill = skill
                                    },
                                    onExport: {
                                        exportingSkill = skill
                                    },
                                    onDelete: {
                                        skillManager.delete(id: skill.id)
                                        showSuccess("Deleted \"\(skill.name)\"")
                                    }
                                )
                            }
                        }
                        .padding(24)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                }

                // Success toast
                if let message = successMessage {
                    VStack {
                        Spacer()
                        successToast(message)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 20)
                    }
                }

                // Error toast
                if let message = errorMessage {
                    VStack {
                        Spacer()
                        errorToast(message)
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
                    skillManager.create(
                        name: skill.name,
                        description: skill.description,
                        version: skill.version,
                        author: skill.author,
                        category: skill.category,
                        icon: skill.icon,
                        instructions: skill.instructions
                    )
                    isCreating = false
                    showSuccess("Created \"\(skill.name)\"")
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
                    skillManager.update(updated)
                    editingSkill = nil
                    showSuccess("Updated \"\(updated.name)\"")
                },
                onCancel: {
                    editingSkill = nil
                }
            )
        }
        .onAppear {
            skillManager.refresh()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [
                .json,
                UTType(filenameExtension: "md") ?? .plainText,
                .zip,
                UTType(filenameExtension: "zip") ?? .archive,
            ],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .onChange(of: exportingSkill) { _, skill in
            if let skill = skill {
                exportSkill(skill)
            }
        }
    }

    // MARK: - Import/Export

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            do {
                // Start accessing the security-scoped resource
                guard url.startAccessingSecurityScopedResource() else {
                    showError("Cannot access file")
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }

                let ext = url.pathExtension.lowercased()

                if ext == "zip" {
                    // Import from ZIP archive (Agent Skills compatible)
                    let skill = try skillManager.importSkillFromZip(url)
                    let fileCount = skill.totalFileCount
                    if fileCount > 0 {
                        showSuccess("Imported \"\(skill.name)\" with \(fileCount) files")
                    } else {
                        showSuccess("Imported \"\(skill.name)\"")
                    }
                } else if ext == "json" {
                    // Import from JSON
                    let content = try String(contentsOf: url, encoding: .utf8)
                    guard let data = content.data(using: .utf8) else {
                        showError("Invalid file content")
                        return
                    }
                    let skill = try skillManager.importSkill(from: data)
                    showSuccess("Imported \"\(skill.name)\"")
                } else {
                    // Import from Markdown (SKILL.md or .md)
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let skill = try skillManager.importSkillFromMarkdown(content)
                    showSuccess("Imported \"\(skill.name)\"")
                }
            } catch {
                showError("Import failed: \(error.localizedDescription)")
            }

        case .failure(let error):
            showError("Import failed: \(error.localizedDescription)")
        }
    }

    private func exportSkill(_ skill: Skill) {
        let panel = NSSavePanel()

        // If skill has associated files, export as ZIP; otherwise just SKILL.md
        if skill.hasAssociatedFiles {
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = "\(skill.agentSkillsName).zip"
            panel.title = "Export Skill (Agent Skills Format)"
            panel.message = "Export as ZIP archive with all associated files"
        } else {
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "SKILL.md"
            panel.title = "Export Skill (Agent Skills Format)"
            panel.message = "Export as Agent Skills compatible SKILL.md file"
        }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    if skill.hasAssociatedFiles {
                        // Export as ZIP
                        let zipURL = try skillManager.exportSkillAsZip(skill)
                        try FileManager.default.copyItem(at: zipURL, to: url)
                        try? FileManager.default.removeItem(at: zipURL)
                        DispatchQueue.main.async {
                            showSuccess("Exported \"\(skill.name)\" as ZIP")
                        }
                    } else {
                        // Export as SKILL.md
                        let content = skillManager.exportSkillAsAgentSkills(skill)
                        try content.write(to: url, atomically: true, encoding: .utf8)
                        DispatchQueue.main.async {
                            showSuccess("Exported \"\(skill.name)\" as SKILL.md")
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        showError("Export failed: \(error.localizedDescription)")
                    }
                }
            }
            DispatchQueue.main.async {
                exportingSkill = nil
            }
        }
    }

    private func showError(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            errorMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation(.easeOut(duration: 0.2)) {
                errorMessage = nil
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: "Skills",
            subtitle: "Specialized knowledge and guidance for the AI",
            count: skillManager.skills.isEmpty ? nil : skillManager.enabledCount
        ) {
            HeaderIconButton("arrow.clockwise", help: "Refresh skills") {
                skillManager.refresh()
            }
            HeaderIconButton("square.and.arrow.down", help: "Import skill") {
                showImportPicker = true
            }
            HeaderPrimaryButton("Create Skill", icon: "plus") {
                isCreating = true
            }
        }
    }

    // MARK: - Success Toast

    private func successToast(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(theme.successColor)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(theme.cardBackground)
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        )
        .overlay(
            Capsule()
                .stroke(theme.successColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func errorToast(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(theme.errorColor)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(theme.cardBackground)
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        )
        .overlay(
            Capsule()
                .stroke(theme.errorColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func showSuccess(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.2)) {
                successMessage = nil
            }
        }
    }
}

// MARK: - Empty State

private struct SkillEmptyState: View {
    @Environment(\.theme) private var theme

    let hasAppeared: Bool
    let onCreate: () -> Void

    @State private var glowIntensity: CGFloat = 0.6

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Glowing icon
            ZStack {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 25)
                    .opacity(glowIntensity * 0.25)

                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 12)
                    .opacity(glowIntensity * 0.15)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.15),
                                theme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)

                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.8)
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: hasAppeared)

            // Text content
            VStack(spacing: 8) {
                Text("Create Your First Skill")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text("Skills provide specialized knowledge and guidance to the AI.")
                    .font(.system(size: 14))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 15)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: hasAppeared)

            // Example use cases
            VStack(spacing: 8) {
                SkillUseCaseRow(
                    icon: "checkmark.shield",
                    title: "Code Review Expert",
                    description: "Security and performance focused reviews"
                )
                SkillUseCaseRow(
                    icon: "doc.text",
                    title: "Technical Writer",
                    description: "Documentation best practices"
                )
                SkillUseCaseRow(
                    icon: "ant",
                    title: "Debug Assistant",
                    description: "Systematic debugging approach"
                )
            }
            .frame(maxWidth: 320)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 20)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)

            // Action button
            Button(action: onCreate) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Create Skill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.4), value: hasAppeared)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                glowIntensity = 1.0
            }
        }
    }
}

// MARK: - Use Case Row

private struct SkillUseCaseRow: View {
    @Environment(\.theme) private var theme

    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.accentColor.opacity(0.1))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground.opacity(0.5))
        )
    }
}

// MARK: - Skill Card

private struct SkillCard: View {
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

    private var skillColor: Color {
        let hash = abs(skill.name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack(alignment: .center, spacing: 12) {
                // Skill icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [skillColor.opacity(0.15), skillColor.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(skillColor.opacity(0.3), lineWidth: 1)
                    Image(systemName: skill.icon ?? "sparkles")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(skillColor)
                }
                .frame(width: 40, height: 40)

                // Name and metadata
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(skill.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        if skill.isBuiltIn {
                            Text("Built-in")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(theme.tertiaryBackground)
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

                        if skill.hasAssociatedFiles {
                            HStack(spacing: 2) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 8))
                                Text("\(skill.totalFileCount)")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(theme.tertiaryBackground)
                            )
                        }
                    }

                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Expand button
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainButtonStyle())

                // Enable toggle
                Toggle(
                    "",
                    isOn: Binding(
                        get: { skill.enabled },
                        set: { onToggle($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            // Expanded content - instructions preview
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                        .padding(.vertical, 4)

                    // Instructions preview
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Instructions")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                            Spacer()
                            Text("\(skill.instructions.count) characters")
                                .font(.system(size: 10))
                                .foregroundColor(theme.tertiaryText)
                        }

                        Text(skill.instructions.prefix(500) + (skill.instructions.count > 500 ? "..." : ""))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(10)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.inputBackground)
                            )
                    }

                    // Metadata
                    HStack(spacing: 16) {
                        if let author = skill.author {
                            Label(author, systemImage: "person")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }

                        Label("v\(skill.version)", systemImage: "tag")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)

                        if let dirName = skill.directoryName {
                            Label(dirName, systemImage: "folder")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }

                    // Associated files (references loaded into context, assets for supporting files)
                    if skill.hasAssociatedFiles {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Associated Files")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.secondaryText)

                            HStack(spacing: 12) {
                                if !skill.references.isEmpty {
                                    SkillFileGroup(
                                        icon: "doc.text",
                                        label: "References",
                                        files: skill.references,
                                        color: .blue
                                    )
                                }
                                if !skill.assets.isEmpty {
                                    SkillFileGroup(
                                        icon: "doc.zipper",
                                        label: "Assets",
                                        files: skill.assets,
                                        color: .purple
                                    )
                                }
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.inputBackground.opacity(0.5))
                        )
                    }

                    // Action buttons
                    HStack(spacing: 8) {
                        Button(action: onEdit) {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10))
                                Text("Edit")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.accentColor.opacity(0.1))
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(skill.isBuiltIn)
                        .opacity(skill.isBuiltIn ? 0.5 : 1)

                        Button(action: onExport) {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 10))
                                Text("Export")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.tertiaryBackground)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())

                        Spacer()

                        if !skill.isBuiltIn {
                            Button(action: { showDeleteConfirm = true }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                    Text("Delete")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(theme.errorColor)
                                .padding(.horizontal, 10)
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
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isHovered ? theme.accentColor.opacity(0.3) : theme.cardBorder,
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                    radius: isHovered ? 10 : 5,
                    x: 0,
                    y: isHovered ? 3 : 2
                )
        )
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .alert("Delete Skill", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Are you sure you want to delete \"\(skill.name)\"? This action cannot be undone.")
        }
    }
}

// MARK: - Skill File Group

private struct SkillFileGroup: View {
    @Environment(\.theme) private var theme

    let icon: String
    let label: String
    let files: [SkillFile]
    let color: Color

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundColor(color)

                    Text("\(label) (\(files.count))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.1))
                )
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files) { file in
                        HStack(spacing: 4) {
                            Image(systemName: "doc")
                                .font(.system(size: 9))
                                .foregroundColor(theme.tertiaryText)

                            Text(file.name)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)

                            Spacer()

                            Text(formatFileSize(file.size))
                                .font(.system(size: 9))
                                .foregroundColor(theme.tertiaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}

#Preview {
    SkillsView()
}
