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
            if customPersonas.isEmpty {
                emptyStateView
                    .opacity(hasAppeared ? 1 : 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(customPersonas) { persona in
                            PersonaCard(
                                persona: persona,
                                isActive: personaManager.activePersonaId == persona.id,
                                onSelect: {
                                    personaManager.setActivePersona(persona.id)
                                },
                                onEdit: {
                                    editingPersona = persona
                                },
                                onExport: {
                                    exportPersona(persona)
                                },
                                onDelete: {
                                    personaManager.delete(id: persona.id)
                                }
                            )
                        }
                    }
                    .padding(24)
                }
                .opacity(hasAppeared ? 1 : 0)
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
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Personas")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text("Create and manage different assistant personalities")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button(action: { showImportPicker = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12, weight: .medium))
                            Text("Import")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 14)
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

                    Button(action: { isCreating = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                            Text("New Persona")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.accentColor)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(theme.accentColor.opacity(0.1))
                        .frame(width: 80, height: 80)

                    Image(systemName: "person.crop.rectangle.stack")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }

                VStack(spacing: 8) {
                    Text("No Custom Personas")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Create personas with custom system prompts, models, and settings for different use cases.")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }

                Button(action: { isCreating = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Create Your First Persona")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                showExportSuccess = true
            }
        } catch {
            print("[Osaurus] Failed to export persona: \(error)")
        }
    }
}

// MARK: - Persona Card

private struct PersonaCard: View {
    @Environment(\.theme) private var theme

    let persona: Persona
    let isActive: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                // Persona icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isActive ? theme.accentColor.opacity(0.1) : theme.tertiaryBackground)
                    Text(persona.name.prefix(1).uppercased())
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(persona.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        if persona.isBuiltIn {
                            Text("Built-in")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(theme.tertiaryBackground)
                                )
                        }

                        if isActive {
                            Text("Active")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.successColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(theme.successColor.opacity(0.1))
                                )
                        }
                    }

                    Text(persona.description.isEmpty ? "No description" : persona.description)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                // Actions
                HStack(spacing: 8) {
                    if !isActive {
                        Button(action: onSelect) {
                            Text("Activate")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.primaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.tertiaryBackground)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    Menu {
                        if !persona.isBuiltIn {
                            Button("Edit", action: onEdit)
                        }
                        Button("Export", action: onExport)
                        if !persona.isBuiltIn {
                            Divider()
                            Button("Delete", role: .destructive) {
                                showDeleteConfirm = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28)
                }
                .opacity(isHovered || isActive ? 1 : 0.5)
            }

            // System prompt preview
            if !persona.systemPrompt.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Prompt")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .textCase(.uppercase)

                    Text(persona.systemPrompt)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.inputBackground)
                        )
                }
            }

            // Configuration badges
            HStack(spacing: 8) {
                if let model = persona.defaultModel {
                    ConfigBadge(icon: "cube", text: model.split(separator: "/").last.map(String.init) ?? model)
                }
                if persona.temperature != nil {
                    ConfigBadge(icon: "thermometer", text: "Custom temp")
                }
                if persona.enabledTools != nil {
                    ConfigBadge(icon: "wrench", text: "Custom tools")
                }
                if persona.themeId != nil {
                    ConfigBadge(icon: "paintpalette", text: "Custom theme")
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isActive ? theme.accentColor.opacity(0.3) : theme.cardBorder, lineWidth: 1)
                )
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .alert("Delete Persona", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Are you sure you want to delete \"\(persona.name)\"? This action cannot be undone.")
        }
    }
}

// MARK: - Config Badge

private struct ConfigBadge: View {
    @Environment(\.theme) private var theme

    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(theme.tertiaryBackground)
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
    @State private var defaultModel: String = ""
    @State private var temperature: String = ""
    @State private var maxTokens: String = ""
    @State private var selectedThemeId: UUID?
    @State private var enabledTools: [String: Bool] = [:]
    @State private var showToolsSection = false

    /// All available tools from the registry
    private var availableTools: [ToolRegistry.ToolEntry] {
        ToolRegistry.shared.listTools()
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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Persona" : "New Persona")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(themeManager.currentTheme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(20)
            .background(themeManager.currentTheme.secondaryBackground)

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Name
                    FormField(label: "Name", hint: "Give your persona a memorable name") {
                        TextField("e.g., Code Assistant", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(themeManager.currentTheme.inputBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                    )
                            )
                    }

                    // Description
                    FormField(label: "Description", hint: "Optional brief description") {
                        TextField("e.g., Helps with coding tasks", text: $description)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(themeManager.currentTheme.inputBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                    )
                            )
                    }

                    // System Prompt
                    FormField(
                        label: "System Prompt",
                        hint: "Instructions for the AI. Leave empty to use global settings."
                    ) {
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 13, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 120, maxHeight: 200)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(themeManager.currentTheme.inputBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                    )
                            )
                    }

                    Divider()
                        .background(themeManager.currentTheme.primaryBorder)

                    // Advanced Settings
                    Text("Advanced Settings")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                        .textCase(.uppercase)

                    HStack(spacing: 16) {
                        // Temperature
                        FormField(label: "Temperature", hint: "0-2, empty uses default") {
                            TextField("0.7", text: $temperature)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(themeManager.currentTheme.inputBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                        )
                                )
                        }

                        // Max Tokens
                        FormField(label: "Max Tokens", hint: "Empty uses default") {
                            TextField("4096", text: $maxTokens)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(themeManager.currentTheme.inputBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                        )
                                )
                        }
                    }

                    // Theme Picker
                    FormField(label: "Theme", hint: "Optional visual theme for this persona") {
                        Picker("", selection: $selectedThemeId) {
                            Text("Use Global Theme").tag(nil as UUID?)
                            ForEach(themeManager.installedThemes, id: \.metadata.id) { theme in
                                Text(theme.metadata.name).tag(theme.metadata.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    Divider()
                        .background(themeManager.currentTheme.primaryBorder)

                    // Tools Configuration
                    DisclosureGroup(isExpanded: $showToolsSection) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(
                                "Override which tools are available for this persona. Unchecked tools will be disabled when using this persona."
                            )
                            .font(.system(size: 11))
                            .foregroundColor(themeManager.currentTheme.tertiaryText)
                            .padding(.bottom, 4)

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
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(themeManager.currentTheme.inputBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                        )
                                )
                            }

                            if !enabledTools.isEmpty {
                                Button(action: { enabledTools.removeAll() }) {
                                    Text("Reset All to Default")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(themeManager.currentTheme.accentColor)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 4)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.system(size: 12, weight: .medium))
                            Text("Tools Configuration")
                                .font(.system(size: 12, weight: .semibold))
                            if !enabledTools.isEmpty {
                                Text("(\(enabledTools.count) overrides)")
                                    .font(.system(size: 11))
                                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                            }
                        }
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                    }
                }
                .padding(20)
            }

            Divider()
                .background(themeManager.currentTheme.primaryBorder)

            // Footer
            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())

                Button(isEditing ? "Save Changes" : "Create Persona") {
                    savePersona()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 700)
        .background(themeManager.currentTheme.primaryBackground)
        .onAppear {
            if case .edit(let persona) = mode {
                name = persona.name
                description = persona.description
                systemPrompt = persona.systemPrompt
                defaultModel = persona.defaultModel ?? ""
                temperature = persona.temperature.map { String($0) } ?? ""
                maxTokens = persona.maxTokens.map { String($0) } ?? ""
                selectedThemeId = persona.themeId
                enabledTools = persona.enabledTools ?? [:]
                showToolsSection = !(persona.enabledTools?.isEmpty ?? true)
            }
        }
    }

    private func savePersona() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let persona = Persona(
            id: existingId ?? UUID(),
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            enabledTools: enabledTools.isEmpty ? nil : enabledTools,
            themeId: selectedThemeId,
            defaultModel: defaultModel.isEmpty ? nil : defaultModel,
            temperature: Float(temperature),
            maxTokens: Int(maxTokens),
            isBuiltIn: false,
            createdAt: existingCreatedAt ?? Date(),
            updatedAt: Date()
        )

        onSave(persona)
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

// MARK: - Form Field

private struct FormField<Content: View>: View {
    @StateObject private var themeManager = ThemeManager.shared

    let label: String
    let hint: String?
    @ViewBuilder let content: () -> Content

    init(label: String, hint: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.hint = hint
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)

            content()

            if let hint = hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
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
