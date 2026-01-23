//
//  PersonasView.swift
//  osaurus
//
//  Management view for creating, editing, and deleting Personas
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Personas View

struct PersonasView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var personaManager = PersonaManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedPersonaId: UUID?
    @State private var isCreating = false
    @State private var editingPersona: Persona?
    @State private var hasAppeared = false
    @State private var successMessage: String?

    // Import/Export
    @State private var showImportPicker = false
    @State private var importError: String?
    @State private var showExportSuccess = false

    /// Custom personas only (excluding built-in)
    private var customPersonas: [Persona] {
        personaManager.personas.filter { !$0.isBuiltIn }
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
                if customPersonas.isEmpty {
                    PersonaEmptyState(
                        hasAppeared: hasAppeared,
                        onCreate: { isCreating = true },
                        onImport: { showImportPicker = true }
                    )
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(minimum: 300), spacing: 20),
                                GridItem(.flexible(minimum: 300), spacing: 20),
                            ],
                            spacing: 20
                        ) {
                            ForEach(Array(customPersonas.enumerated()), id: \.element.id) { index, persona in
                                PersonaCard(
                                    persona: persona,
                                    isActive: personaManager.activePersonaId == persona.id,
                                    animationDelay: Double(index) * 0.05,
                                    hasAppeared: hasAppeared,
                                    onActivate: {
                                        personaManager.setActivePersona(persona.id)
                                        showSuccess("Activated \"\(persona.name)\"")
                                    },
                                    onEdit: {
                                        editingPersona = persona
                                    },
                                    onDuplicate: {
                                        duplicatePersona(persona)
                                    },
                                    onExport: {
                                        exportPersona(persona)
                                    },
                                    onDelete: {
                                        personaManager.delete(id: persona.id)
                                        showSuccess("Deleted \"\(persona.name)\"")
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .sheet(isPresented: $isCreating) {
            PersonaEditorSheet(
                mode: .create,
                onSave: { persona in
                    PersonaStore.save(persona)
                    personaManager.refresh()
                    isCreating = false
                    showSuccess("Created \"\(persona.name)\"")
                },
                onCancel: {
                    isCreating = false
                }
            )
        }
        .sheet(item: $editingPersona) { persona in
            PersonaEditorSheet(
                mode: .edit(persona),
                onSave: { updated in
                    personaManager.update(updated)
                    editingPersona = nil
                    showSuccess("Updated \"\(updated.name)\"")
                },
                onCancel: {
                    editingPersona = nil
                }
            )
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("Import Error", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            if let error = importError {
                Text(error)
            }
        }
        .onAppear {
            personaManager.refresh()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: "Personas",
            subtitle: "Create custom assistant personalities with unique behaviors",
            count: customPersonas.isEmpty ? nil : customPersonas.count
        ) {
            HeaderIconButton("arrow.clockwise", help: "Refresh personas") {
                personaManager.refresh()
            }
            HeaderSecondaryButton("Import", icon: "square.and.arrow.down") {
                showImportPicker = true
            }
            HeaderPrimaryButton("Create Persona", icon: "plus") {
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

    // MARK: - Actions

    private func duplicatePersona(_ persona: Persona) {
        // Generate unique copy name
        let baseName = "\(persona.name) Copy"
        let existingNames = Set(customPersonas.map { $0.name })
        var newName = baseName
        var counter = 1

        while existingNames.contains(newName) {
            counter += 1
            newName = "\(persona.name) Copy \(counter)"
        }

        let duplicated = Persona(
            id: UUID(),
            name: newName,
            description: persona.description,
            systemPrompt: persona.systemPrompt,
            enabledTools: persona.enabledTools,
            themeId: persona.themeId,
            defaultModel: persona.defaultModel,
            temperature: persona.temperature,
            maxTokens: persona.maxTokens,
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )

        PersonaStore.save(duplicated)
        personaManager.refresh()
        showSuccess("Duplicated as \"\(newName)\"")

        // Open editor for the duplicated persona
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            editingPersona = duplicated
        }
    }

    // MARK: - Import/Export

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Unable to access the selected file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                try personaManager.importPersona(from: data)
                showSuccess("Imported persona successfully")
            } catch {
                importError = "Failed to import persona: \(error.localizedDescription)"
            }

        case .failure(let error):
            importError = "Failed to select file: \(error.localizedDescription)"
        }
    }

    private func exportPersona(_ persona: Persona) {
        do {
            let data = try personaManager.exportPersona(persona)

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(persona.name).json"
            panel.title = "Export Persona"
            panel.message = "Choose where to save the persona file"

            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
                showSuccess("Exported \"\(persona.name)\"")
            }
        } catch {
            print("[Osaurus] Failed to export persona: \(error)")
        }
    }
}

// MARK: - Empty State

private struct PersonaEmptyState: View {
    @Environment(\.theme) private var theme

    let hasAppeared: Bool
    let onCreate: () -> Void
    let onImport: () -> Void

    @State private var glowIntensity: CGFloat = 0.6

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Glowing icon
            ZStack {
                // Outer glow
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 25)
                    .opacity(glowIntensity * 0.25)

                // Inner glow
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 88, height: 88)
                    .blur(radius: 12)
                    .opacity(glowIntensity * 0.15)

                // Base circle with gradient
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

                // Icon
                Image(systemName: "theatermasks.fill")
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
                Text("Create Your First Persona")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text("Custom AI assistants with unique prompts, tools, and styles.")
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
                PersonaUseCaseRow(
                    icon: "calendar",
                    title: "Daily Planner",
                    description: "Manage your schedule"
                )
                PersonaUseCaseRow(
                    icon: "message.fill",
                    title: "Message Assistant",
                    description: "Draft and send texts"
                )
                PersonaUseCaseRow(
                    icon: "map.fill",
                    title: "Local Guide",
                    description: "Find places nearby"
                )
            }
            .frame(maxWidth: 320)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 20)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: hasAppeared)

            // Action buttons
            HStack(spacing: 12) {
                Button(action: onImport) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .medium))
                        Text("Import")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.tertiaryBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: onCreate) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Create Persona")
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
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.4), value: hasAppeared)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Start glow animation
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                glowIntensity = 1.0
            }
        }
    }
}

// MARK: - Use Case Row

private struct PersonaUseCaseRow: View {
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

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Text(description)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground.opacity(0.5))
        )
    }
}

// MARK: - Persona Card

private struct PersonaCard: View {
    @Environment(\.theme) private var theme
    @StateObject private var themeManager = ThemeManager.shared

    let persona: Persona
    let isActive: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    /// Generate a consistent color based on persona name
    private var personaColor: Color {
        let hash = abs(persona.name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    /// Get tool configuration summary
    private var toolsSummary: String? {
        guard let tools = persona.enabledTools, !tools.isEmpty else { return nil }
        let enabled = tools.values.filter { $0 }.count
        let total = tools.count
        return "\(enabled)/\(total) tools"
    }

    /// Get skill configuration summary
    private var skillsSummary: String? {
        guard let skills = persona.enabledSkills, !skills.isEmpty else { return nil }
        let enabled = skills.values.filter { $0 }.count
        let total = skills.count
        return "\(enabled)/\(total) skills"
    }

    /// Get theme info if assigned
    private var assignedTheme: CustomTheme? {
        guard let themeId = persona.themeId else { return nil }
        return themeManager.installedThemes.first { $0.metadata.id == themeId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row - Name and actions only
            HStack(alignment: .center, spacing: 12) {
                // Avatar with colored ring
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [personaColor.opacity(0.15), personaColor.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Circle()
                        .strokeBorder(personaColor.opacity(0.4), lineWidth: 2)

                    Text(persona.name.prefix(1).uppercased())
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(personaColor)
                }
                .frame(width: 36, height: 36)

                // Name with active badge
                HStack(spacing: 8) {
                    Text(persona.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(theme.successColor)
                    }
                }

                Spacer(minLength: 8)

                // Quick actions (visible on hover)
                HStack(spacing: 4) {
                    Group {
                        QuickActionButton(icon: "pencil", help: "Edit") {
                            onEdit()
                        }

                        QuickActionButton(icon: "doc.on.doc", help: "Duplicate") {
                            onDuplicate()
                        }

                        QuickActionButton(icon: "square.and.arrow.up", help: "Export") {
                            onExport()
                        }
                    }
                    .opacity(isHovered ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: isHovered)

                    // More menu (always visible)
                    Menu {
                        Button(action: onEdit) {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(action: onDuplicate) {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        Button(action: onExport) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24)
                }
            }

            // Description section - fixed height to maintain card alignment
            Text(persona.description.isEmpty ? " " : persona.description)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .opacity(persona.description.isEmpty ? 0 : 1)

            // System prompt section - always visible
            VStack(alignment: .leading, spacing: 6) {
                Text("SYSTEM PROMPT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.5)

                if persona.systemPrompt.isEmpty {
                    Text("No system prompt defined")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .italic()
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                } else {
                    Text(persona.systemPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(4)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground.opacity(0.5))
            )

            // Configuration badges - always visible with fixed height
            configurationBadges
                .frame(minHeight: 26)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isActive ? theme.accentColor.opacity(0.4) : theme.cardBorder,
                            lineWidth: isActive ? 1.5 : 1
                        )
                )
                .shadow(
                    color: isActive ? theme.accentColor.opacity(0.15) : Color.black.opacity(isHovered ? 0.08 : 0.04),
                    radius: isHovered ? 10 : 5,
                    x: 0,
                    y: isHovered ? 3 : 2
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive {
                onActivate()
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering && !isActive {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .alert("Delete Persona", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Are you sure you want to delete \"\(persona.name)\"? This action cannot be undone.")
        }
    }

    // MARK: - Configuration Badges

    @ViewBuilder
    private var configurationBadges: some View {
        let hasBadges =
            persona.defaultModel != nil || toolsSummary != nil || skillsSummary != nil
            || persona.temperature != nil || persona.maxTokens != nil || assignedTheme != nil

        if hasBadges {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Model badge
                    if let model = persona.defaultModel {
                        ConfigBadge(
                            icon: "cube.fill",
                            text: formatModelName(model),
                            color: .blue
                        )
                    }

                    // Tools badge
                    if let tools = toolsSummary {
                        ConfigBadge(
                            icon: "wrench.and.screwdriver.fill",
                            text: tools,
                            color: .orange
                        )
                    }

                    // Skills badge
                    if let skills = skillsSummary {
                        ConfigBadge(
                            icon: "sparkles",
                            text: skills,
                            color: .cyan
                        )
                    }

                    // Temperature badge
                    if let temp = persona.temperature {
                        ConfigBadge(
                            icon: "thermometer.medium",
                            text: String(format: "%.1f", temp),
                            color: .red
                        )
                    }

                    // Max tokens badge
                    if let tokens = persona.maxTokens {
                        ConfigBadge(
                            icon: "number",
                            text: formatTokens(tokens),
                            color: .purple
                        )
                    }

                    // Theme preview
                    if let customTheme = assignedTheme {
                        ThemePreviewBadge(theme: customTheme)
                    }
                }
            }
        } else {
            // Default state when no configuration overrides
            HStack(spacing: 5) {
                Image(systemName: "gearshape")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                Text("Default configuration")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                Capsule()
                    .fill(theme.tertiaryBackground.opacity(0.5))
            )
        }
    }

    private func formatModelName(_ model: String) -> String {
        if let last = model.split(separator: "/").last {
            return String(last)
        }
        return model
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return "\(tokens / 1000)K tokens"
        }
        return "\(tokens) tokens"
    }
}

// MARK: - Quick Action Button

private struct QuickActionButton: View {
    @Environment(\.theme) private var theme

    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(isHovered ? theme.tertiaryBackground : theme.tertiaryBackground.opacity(0.5))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .help(help)
    }
}

// MARK: - Config Badge

private struct ConfigBadge: View {
    @Environment(\.theme) private var theme

    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)

            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            Capsule()
                .fill(color.opacity(0.1))
                .overlay(
                    Capsule()
                        .stroke(color.opacity(0.2), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Theme Preview Badge

private struct ThemePreviewBadge: View {
    @Environment(\.theme) private var currentTheme

    let theme: CustomTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.pink)

            Text(theme.metadata.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(currentTheme.secondaryText)
                .lineLimit(1)

            // Color swatches
            HStack(spacing: 2) {
                colorDot(theme.colors.accentColor)
                colorDot(theme.colors.primaryBackground)
                colorDot(theme.colors.successColor)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            Capsule()
                .fill(Color.pink.opacity(0.1))
                .overlay(
                    Capsule()
                        .stroke(Color.pink.opacity(0.2), lineWidth: 0.5)
                )
        )
    }

    private func colorDot(_ hex: String) -> some View {
        Circle()
            .fill(Color(themeHex: hex))
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
            )
    }
}

// MARK: - Persona Editor Sheet

private struct PersonaEditorSheet: View {
    enum Mode {
        case create
        case edit(Persona)
    }

    @Environment(\.theme) private var theme
    @StateObject private var themeManager = ThemeManager.shared

    let mode: Mode
    let onSave: (Persona) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var systemPrompt: String = ""
    @State private var temperature: String = ""
    @State private var maxTokens: String = ""
    @State private var selectedThemeId: UUID?
    @State private var enabledTools: [String: Bool] = [:]
    @State private var showToolsSection = false
    @State private var enabledSkills: [String: Bool] = [:]
    @State private var showSkillsSection = false
    @State private var hasAppeared = false

    /// All available tools from the registry
    private var availableTools: [ToolRegistry.ToolEntry] {
        ToolRegistry.shared.listTools()
    }

    /// All available skills from the manager
    private var availableSkills: [Skill] {
        SkillManager.shared.skills
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var existingId: UUID? {
        if case .edit(let persona) = mode { return persona.id }
        return nil
    }

    private var existingCreatedAt: Date? {
        if case .edit(let persona) = mode { return persona.createdAt }
        return nil
    }

    /// Generate a consistent color based on persona name
    private var personaColor: Color {
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Polished Header
            headerView

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Identity Section
                    EditorSection(title: "Identity", icon: "person.circle.fill") {
                        VStack(spacing: 16) {
                            // Name with preview avatar
                            HStack(spacing: 16) {
                                // Live avatar preview
                                ZStack {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [personaColor.opacity(0.2), personaColor.opacity(0.05)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                    Circle()
                                        .strokeBorder(personaColor.opacity(0.5), lineWidth: 2)
                                    Text(name.isEmpty ? "?" : name.prefix(1).uppercased())
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                        .foregroundColor(personaColor)
                                }
                                .frame(width: 52, height: 52)
                                .animation(.spring(response: 0.3), value: name)

                                VStack(alignment: .leading, spacing: 12) {
                                    StyledTextField(
                                        placeholder: "e.g., Code Assistant",
                                        text: $name,
                                        icon: "textformat"
                                    )
                                }
                            }

                            StyledTextField(
                                placeholder: "Brief description (optional)",
                                text: $description,
                                icon: "text.alignleft"
                            )
                        }
                    }

                    // System Prompt Section
                    EditorSection(title: "System Prompt", icon: "brain") {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                // Themed placeholder overlay
                                if systemPrompt.isEmpty {
                                    Text("Enter instructions for this persona...")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(themeManager.currentTheme.placeholderText)
                                        .padding(.top, 12)
                                        .padding(.leading, 16)
                                        .allowsHitTesting(false)
                                }

                                TextEditor(text: $systemPrompt)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(themeManager.currentTheme.primaryText)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 140, maxHeight: 200)
                                    .padding(12)
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(themeManager.currentTheme.inputBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                    )
                            )

                            Text(
                                "Instructions that define this persona's behavior. Leave empty to use global settings."
                            )
                            .font(.system(size: 11))
                            .foregroundColor(themeManager.currentTheme.tertiaryText)
                        }
                    }

                    // Generation Settings Section
                    EditorSection(title: "Generation", icon: "cpu") {
                        VStack(spacing: 16) {
                            HStack(spacing: 16) {
                                // Temperature
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Temperature", systemImage: "thermometer.medium")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(themeManager.currentTheme.secondaryText)

                                    StyledTextField(
                                        placeholder: "0.7",
                                        text: $temperature,
                                        icon: nil
                                    )
                                }

                                // Max Tokens
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Max Tokens", systemImage: "number")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(themeManager.currentTheme.secondaryText)

                                    StyledTextField(
                                        placeholder: "4096",
                                        text: $maxTokens,
                                        icon: nil
                                    )
                                }
                            }

                            Text("Leave empty to use default values from global settings.")
                                .font(.system(size: 11))
                                .foregroundColor(themeManager.currentTheme.tertiaryText)
                        }
                    }

                    // Theme Section
                    EditorSection(title: "Visual Theme", icon: "paintpalette.fill") {
                        VStack(alignment: .leading, spacing: 12) {
                            themePickerGrid

                            Text("Optionally assign a visual theme to this persona.")
                                .font(.system(size: 11))
                                .foregroundColor(themeManager.currentTheme.tertiaryText)
                        }
                    }

                    // Tools Configuration
                    EditorSection(title: "Tools", icon: "wrench.and.screwdriver") {
                        VStack(alignment: .leading, spacing: 12) {
                            // Custom accordion header - fully clickable
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showToolsSection.toggle()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                                        .rotationEffect(.degrees(showToolsSection ? 90 : 0))

                                    Text(showToolsSection ? "Hide tool overrides" : "Configure tool overrides")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(themeManager.currentTheme.secondaryText)

                                    if !enabledTools.isEmpty {
                                        Text("(\(enabledTools.count) modified)")
                                            .font(.system(size: 11))
                                            .foregroundColor(themeManager.currentTheme.accentColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule()
                                                    .fill(themeManager.currentTheme.accentColor.opacity(0.1))
                                            )
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(themeManager.currentTheme.tertiaryBackground.opacity(0.5))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            // Expandable content with height animation
                            VStack(alignment: .leading, spacing: 8) {
                                if availableTools.isEmpty {
                                    Text("No tools available")
                                        .font(.system(size: 12))
                                        .foregroundColor(themeManager.currentTheme.secondaryText)
                                        .padding(.vertical, 8)
                                } else {
                                    LazyVStack(spacing: 0) {
                                        ForEach(availableTools, id: \.name) { tool in
                                            ToolToggleRow(
                                                tool: tool,
                                                isEnabled: enabledTools[tool.name] ?? tool.enabled,
                                                hasOverride: enabledTools[tool.name] != nil,
                                                onToggle: { enabled in
                                                    enabledTools[tool.name] = enabled
                                                },
                                                onReset: {
                                                    enabledTools.removeValue(forKey: tool.name)
                                                }
                                            )
                                        }
                                    }
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(themeManager.currentTheme.inputBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                            )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }

                                if !enabledTools.isEmpty {
                                    Button(action: { enabledTools.removeAll() }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.uturn.backward")
                                                .font(.system(size: 10))
                                            Text("Reset All to Default")
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(themeManager.currentTheme.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 4)
                                }
                            }
                            .frame(maxHeight: showToolsSection ? .infinity : 0)
                            .opacity(showToolsSection ? 1 : 0)
                            .clipped()

                            Text("Override which tools are available when using this persona.")
                                .font(.system(size: 11))
                                .foregroundColor(themeManager.currentTheme.tertiaryText)
                        }
                    }

                    // Skills Configuration
                    EditorSection(title: "Skills", icon: "sparkles") {
                        VStack(alignment: .leading, spacing: 12) {
                            // Custom accordion header - fully clickable
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showSkillsSection.toggle()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                                        .rotationEffect(.degrees(showSkillsSection ? 90 : 0))

                                    Text(showSkillsSection ? "Hide skill overrides" : "Configure skill overrides")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(themeManager.currentTheme.secondaryText)

                                    if !enabledSkills.isEmpty {
                                        Text("(\(enabledSkills.count) modified)")
                                            .font(.system(size: 11))
                                            .foregroundColor(themeManager.currentTheme.accentColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule()
                                                    .fill(themeManager.currentTheme.accentColor.opacity(0.1))
                                            )
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(themeManager.currentTheme.tertiaryBackground.opacity(0.5))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            // Expandable content with height animation
                            VStack(alignment: .leading, spacing: 8) {
                                if availableSkills.isEmpty {
                                    Text("No skills available")
                                        .font(.system(size: 12))
                                        .foregroundColor(themeManager.currentTheme.secondaryText)
                                        .padding(.vertical, 8)
                                } else {
                                    LazyVStack(spacing: 0) {
                                        ForEach(availableSkills) { skill in
                                            SkillToggleRow(
                                                skill: skill,
                                                isEnabled: enabledSkills[skill.name] ?? skill.enabled,
                                                hasOverride: enabledSkills[skill.name] != nil,
                                                onToggle: { enabled in
                                                    enabledSkills[skill.name] = enabled
                                                },
                                                onReset: {
                                                    enabledSkills.removeValue(forKey: skill.name)
                                                }
                                            )
                                        }
                                    }
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(themeManager.currentTheme.inputBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                            )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }

                                if !enabledSkills.isEmpty {
                                    Button(action: { enabledSkills.removeAll() }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.uturn.backward")
                                                .font(.system(size: 10))
                                            Text("Reset All to Default")
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(themeManager.currentTheme.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 4)
                                }
                            }
                            .frame(maxHeight: showSkillsSection ? .infinity : 0)
                            .opacity(showSkillsSection ? 1 : 0)
                            .clipped()

                            Text("Override which skills are available when using this persona.")
                                .font(.system(size: 11))
                                .foregroundColor(themeManager.currentTheme.tertiaryText)
                        }
                    }
                }
                .padding(24)
            }

            // Footer
            footerView
        }
        .frame(width: 580, height: 720)
        .background(themeManager.currentTheme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeManager.currentTheme.primaryBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAppeared)
        .onAppear {
            if case .edit(let persona) = mode {
                name = persona.name
                description = persona.description
                systemPrompt = persona.systemPrompt
                temperature = persona.temperature.map { String($0) } ?? ""
                maxTokens = persona.maxTokens.map { String($0) } ?? ""
                selectedThemeId = persona.themeId
                enabledTools = persona.enabledTools ?? [:]
                showToolsSection = !(persona.enabledTools?.isEmpty ?? true)
                enabledSkills = persona.enabledSkills ?? [:]
                showSkillsSection = !(persona.enabledSkills?.isEmpty ?? true)
            }
            withAnimation {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(spacing: 12) {
            // Icon with gradient background
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                themeManager.currentTheme.accentColor.opacity(0.2),
                                themeManager.currentTheme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: isEditing ? "pencil.circle.fill" : "person.crop.circle.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                themeManager.currentTheme.accentColor,
                                themeManager.currentTheme.accentColor.opacity(0.7),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Persona" : "Create Persona")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                Text(isEditing ? "Modify your AI assistant" : "Build your custom AI assistant")
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(themeManager.currentTheme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            themeManager.currentTheme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [
                            themeManager.currentTheme.accentColor.opacity(0.03),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Theme Picker Grid

    @ViewBuilder
    private var themePickerGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
            // Default option
            ThemeOptionCard(
                name: "Default",
                colors: [
                    themeManager.currentTheme.accentColor,
                    themeManager.currentTheme.primaryBackground,
                    themeManager.currentTheme.successColor,
                ],
                isSelected: selectedThemeId == nil,
                onSelect: { selectedThemeId = nil }
            )

            // Installed themes
            ForEach(themeManager.installedThemes, id: \.metadata.id) { customTheme in
                ThemeOptionCard(
                    name: customTheme.metadata.name,
                    colors: [
                        Color(themeHex: customTheme.colors.accentColor),
                        Color(themeHex: customTheme.colors.primaryBackground),
                        Color(themeHex: customTheme.colors.successColor),
                    ],
                    isSelected: selectedThemeId == customTheme.metadata.id,
                    onSelect: { selectedThemeId = customTheme.metadata.id }
                )
            }
        }
    }

    // MARK: - Footer View

    private var footerView: some View {
        HStack(spacing: 12) {
            // Keyboard hint
            HStack(spacing: 4) {
                Text("⌘")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(themeManager.currentTheme.tertiaryBackground)
                    )
                Text("+ Enter to save")
                    .font(.system(size: 11))
            }
            .foregroundColor(themeManager.currentTheme.tertiaryText)

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(SecondaryButtonStyle())

            Button(isEditing ? "Save Changes" : "Create Persona") {
                savePersona()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            themeManager.currentTheme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(themeManager.currentTheme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    private func savePersona() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // Preserve existing defaultModel from persona being edited (model is now auto-persisted via chat)
        let existingDefaultModel: String? = {
            if case .edit(let existingPersona) = mode {
                return existingPersona.defaultModel
            }
            return nil
        }()

        let persona = Persona(
            id: existingId ?? UUID(),
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            enabledTools: enabledTools.isEmpty ? nil : enabledTools,
            enabledSkills: enabledSkills.isEmpty ? nil : enabledSkills,
            themeId: selectedThemeId,
            defaultModel: existingDefaultModel,
            temperature: Float(temperature),
            maxTokens: Int(maxTokens),
            isBuiltIn: false,
            createdAt: existingCreatedAt ?? Date(),
            updatedAt: Date()
        )

        onSave(persona)
    }
}

// MARK: - Editor Section

private struct EditorSection<Content: View>: View {
    @StateObject private var themeManager = ThemeManager.shared

    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.currentTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(themeManager.currentTheme.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Styled Text Field

private struct StyledTextField: View {
    @StateObject private var themeManager = ThemeManager.shared

    let placeholder: String
    @Binding var text: String
    let icon: String?

    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        isFocused ? themeManager.currentTheme.accentColor : themeManager.currentTheme.tertiaryText
                    )
                    .frame(width: 16)
            }

            ZStack(alignment: .leading) {
                // Themed placeholder overlay
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(themeManager.currentTheme.placeholderText)
                        .allowsHitTesting(false)
                }

                TextField(
                    "",
                    text: $text,
                    onEditingChanged: { editing in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isFocused = editing
                        }
                    }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(themeManager.currentTheme.primaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isFocused
                                ? themeManager.currentTheme.accentColor.opacity(0.5)
                                : themeManager.currentTheme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }
}

// MARK: - Theme Option Card

private struct ThemeOptionCard: View {
    @StateObject private var themeManager = ThemeManager.shared

    let name: String
    let colors: [Color]
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                // Color swatches
                HStack(spacing: 4) {
                    ForEach(0 ..< min(3, colors.count), id: \.self) { index in
                        Circle()
                            .fill(colors[index])
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                }

                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isSelected
                                    ? themeManager.currentTheme.accentColor : themeManager.currentTheme.inputBorder,
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.2), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Tool Toggle Row

private struct ToolToggleRow: View {
    @StateObject private var themeManager = ThemeManager.shared

    let tool: ToolRegistry.ToolEntry
    let isEnabled: Bool
    let hasOverride: Bool
    let onToggle: (Bool) -> Void
    let onReset: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.primaryText)

                    if hasOverride {
                        Text("Modified")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(themeManager.currentTheme.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(themeManager.currentTheme.accentColor.opacity(0.1))
                            )
                    }
                }

                Text(tool.description)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer()

            // Reset button (only when overridden)
            if hasOverride && isHovered {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }

            // Toggle
            Toggle(
                "",
                isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? themeManager.currentTheme.tertiaryBackground.opacity(0.5) : Color.clear)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Skill Toggle Row

private struct SkillToggleRow: View {
    @StateObject private var themeManager = ThemeManager.shared

    let skill: Skill
    let isEnabled: Bool
    let hasOverride: Bool
    let onToggle: (Bool) -> Void
    let onReset: () -> Void

    @State private var isHovered = false

    /// Generate a consistent color based on skill name
    private var skillColor: Color {
        let hash = abs(skill.name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Skill icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(skillColor.opacity(0.1))
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(skillColor)
            }
            .frame(width: 24, height: 24)

            // Skill info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.primaryText)

                    if skill.isBuiltIn {
                        Text("Built-in")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(themeManager.currentTheme.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(themeManager.currentTheme.tertiaryBackground)
                            )
                    }

                    if hasOverride {
                        Text("Modified")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(themeManager.currentTheme.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(themeManager.currentTheme.accentColor.opacity(0.1))
                            )
                    }
                }

                Text(skill.description)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer()

            // Reset button (only when overridden)
            if hasOverride && isHovered {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }

            // Toggle
            Toggle(
                "",
                isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? themeManager.currentTheme.tertiaryBackground.opacity(0.5) : Color.clear)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Button Styles

private struct PrimaryButtonStyle: ButtonStyle {
    @StateObject private var themeManager = ThemeManager.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.accentColor)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    @StateObject private var themeManager = ThemeManager.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(themeManager.currentTheme.primaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

#Preview {
    PersonasView()
}
