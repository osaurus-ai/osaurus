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
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedPersona: Persona?
    @State private var isCreating = false
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
        ZStack {
            // Grid view
            if selectedPersona == nil {
                gridContent
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            // Detail view
            if let persona = selectedPersona {
                PersonaDetailView(
                    persona: persona,
                    onBack: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedPersona = nil
                        }
                    },
                    onDuplicate: { p in
                        duplicatePersona(p)
                    },
                    onExport: { p in
                        exportPersona(p)
                    },
                    onDelete: { p in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedPersona = nil
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            personaManager.delete(id: p.id)
                            showSuccess("Deleted \"\(p.name)\"")
                        }
                    },
                    showSuccess: { msg in
                        showSuccess(msg)
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            // Success toast
            if let message = successMessage {
                VStack {
                    Spacer()
                    ThemedToastView(message, type: .success)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
                .zIndex(100)
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
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .themedAlert(
            "Import Error",
            isPresented: Binding(
                get: { importError != nil },
                set: { newValue in
                    if !newValue { importError = nil }
                }
            ),
            message: importError,
            primaryButton: .primary("OK") { importError = nil }
        )
        .onAppear {
            personaManager.refresh()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Grid Content

    private var gridContent: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content
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
                                onSelect: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        selectedPersona = persona
                                    }
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

    private func showSuccess(_ message: String) {
        withAnimation(theme.springAnimation()) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.animationQuick()) {
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

        // Open detail for the duplicated persona
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                selectedPersona = duplicated
            }
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
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var scheduleManager = ScheduleManager.shared

    let persona: Persona
    let isActive: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
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

    /// Get tool count
    private var toolCount: Int? {
        guard let tools = persona.enabledTools, !tools.isEmpty else { return nil }
        return tools.values.filter { $0 }.count
    }

    /// Get skill count
    private var skillCount: Int? {
        guard let skills = persona.enabledSkills, !skills.isEmpty else { return nil }
        return skills.values.filter { $0 }.count
    }

    /// Schedule count for this persona
    private var scheduleCount: Int {
        scheduleManager.schedules.filter { $0.personaId == persona.id }.count
    }

    /// Get theme info if assigned
    private var assignedTheme: CustomTheme? {
        guard let themeId = persona.themeId else { return nil }
        return themeManager.installedThemes.first { $0.metadata.id == themeId }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                // Header row
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

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(persona.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)

                            if isActive {
                                Text("Active")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(theme.successColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(theme.successColor.opacity(0.12))
                                    )
                            }
                        }

                        if !persona.description.isEmpty {
                            Text(persona.description)
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    // Context menu button
                    Menu {
                        Button(action: onSelect) {
                            Label("Open", systemImage: "arrow.right.circle")
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

                // System prompt preview
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
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                    } else {
                        Text(persona.systemPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(3)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground.opacity(0.5))
                )

                // Summary badges
                summaryBadges
                    .frame(minHeight: 24)

                // Subtle open hint
                HStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Open")
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundColor(theme.tertiaryText)
                    .opacity(isHovered ? 1 : 0)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isActive ? personaColor.opacity(0.3) : theme.cardBorder,
                                lineWidth: isActive ? 1.5 : 1
                            )
                    )
                    .shadow(
                        color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                        radius: isHovered ? 10 : 5,
                        x: 0,
                        y: isHovered ? 3 : 2
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .onHover { hovering in
            isHovered = hovering
        }
        .themedAlert(
            "Delete Persona",
            isPresented: $showDeleteConfirm,
            message: "Are you sure you want to delete \"\(persona.name)\"? This action cannot be undone.",
            primaryButton: .destructive("Delete", action: onDelete),
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: - Summary Badges

    @ViewBuilder
    private var summaryBadges: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let model = persona.defaultModel {
                    ConfigBadge(icon: "cube.fill", text: formatModelName(model), color: .blue)
                }
                if let count = toolCount {
                    ConfigBadge(icon: "wrench.and.screwdriver.fill", text: "\(count) tools", color: .orange)
                }
                if let count = skillCount {
                    ConfigBadge(icon: "sparkles", text: "\(count) skills", color: .cyan)
                }
                if scheduleCount > 0 {
                    ConfigBadge(
                        icon: "clock.fill",
                        text: "\(scheduleCount) schedule\(scheduleCount == 1 ? "" : "s")",
                        color: .green
                    )
                }
                if let temp = persona.temperature {
                    ConfigBadge(icon: "thermometer.medium", text: String(format: "%.1f", temp), color: .red)
                }
                if let customTheme = assignedTheme {
                    ThemePreviewBadge(theme: customTheme)
                }

                // Default state
                if persona.defaultModel == nil && toolCount == nil && skillCount == nil
                    && scheduleCount == 0 && persona.temperature == nil && assignedTheme == nil
                {
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
        }
    }

    private func formatModelName(_ model: String) -> String {
        if let last = model.split(separator: "/").last {
            return String(last)
        }
        return model
    }
}

// MARK: - Persona Detail View

private struct PersonaDetailView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var personaManager = PersonaManager.shared
    @ObservedObject private var scheduleManager = ScheduleManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let persona: Persona
    let onBack: () -> Void
    let onDuplicate: (Persona) -> Void
    let onExport: (Persona) -> Void
    let onDelete: (Persona) -> Void
    let showSuccess: (String) -> Void

    // MARK: - Editable State

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var systemPrompt: String = ""
    @State private var temperature: String = ""
    @State private var maxTokens: String = ""
    @State private var selectedThemeId: UUID?

    // MARK: - UI State

    @State private var hasAppeared = false
    @State private var saveIndicator: String?
    @State private var saveDebounceTask: Task<Void, Never>?
    @State private var showDeleteConfirm = false

    // Model picker
    @State private var modelOptions: [ModelOption] = []
    @State private var showModelPicker = false
    @State private var selectedModel: String?

    // Schedule creation
    @State private var showCreateSchedule = false

    /// Current persona (refreshed from manager)
    private var currentPersona: Persona {
        personaManager.persona(for: persona.id) ?? persona
    }

    /// Schedules linked to this persona
    private var linkedSchedules: [Schedule] {
        scheduleManager.schedules.filter { $0.personaId == persona.id }
    }

    /// Chat sessions for this persona
    private var chatSessions: [ChatSessionData] {
        ChatSessionsManager.shared.sessions(for: persona.id)
    }

    /// Tasks for this persona
    private var agentTasks: [AgentTask] {
        (try? IssueStore.listTasks(personaId: persona.id)) ?? []
    }

    /// Generate a consistent color based on persona name
    private var personaColor: Color {
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    /// Resolved enabled tool count using PersonaManager's effective overrides
    private var resolvedEnabledToolCount: Int {
        let overrides = personaManager.effectiveToolOverrides(for: persona.id)
        let tools = ToolRegistry.shared.listUserTools(withOverrides: overrides, excludeInternal: true)
        return tools.filter { $0.enabled }.count
    }

    /// Resolved enabled skill count using PersonaManager's effective overrides
    private var resolvedEnabledSkillCount: Int {
        let skills = SkillManager.shared.skills
        return skills.filter { skill in
            if let overrides = personaManager.effectiveSkillOverrides(for: persona.id),
                let value = overrides[skill.name]
            {
                return value
            }
            return skill.enabled
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            detailHeaderBar

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Hero header
                    heroHeader
                        .padding(.bottom, 8)

                    // Sections (all always expanded, ordered by importance)
                    identitySection
                    systemPromptSection
                    generationSection
                    capabilitiesSection
                    themeSection
                    schedulesSection
                    historySection
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hasAppeared)
        .onAppear {
            loadPersonaData()
            selectedModel = currentPersona.defaultModel
            loadModelOptions()
            withAnimation { hasAppeared = true }
        }
        .themedAlert(
            "Delete Persona",
            isPresented: $showDeleteConfirm,
            message: "Are you sure you want to delete \"\(currentPersona.name)\"? This action cannot be undone.",
            primaryButton: .destructive("Delete") { onDelete(currentPersona) },
            secondaryButton: .cancel("Cancel")
        )
        .sheet(isPresented: $showCreateSchedule) {
            ScheduleEditorSheet(
                mode: .create,
                onSave: { schedule in
                    ScheduleManager.shared.create(
                        name: schedule.name,
                        instructions: schedule.instructions,
                        personaId: schedule.personaId,
                        frequency: schedule.frequency,
                        isEnabled: schedule.isEnabled
                    )
                    showCreateSchedule = false
                    showSuccess("Created schedule \"\(schedule.name)\"")
                },
                onCancel: { showCreateSchedule = false },
                initialPersonaId: persona.id
            )
            .environment(\.theme, themeManager.currentTheme)
        }
    }

    // MARK: - Detail Header Bar

    private var detailHeaderBar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Personas")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            if let indicator = saveIndicator {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text(indicator)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.successColor)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            HStack(spacing: 6) {
                Button {
                    onDuplicate(currentPersona)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Duplicate")

                Button {
                    onExport(currentPersona)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Export")

                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.errorColor)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.errorColor.opacity(0.1)))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Delete")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        HStack(spacing: 20) {
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
                    .strokeBorder(personaColor.opacity(0.5), lineWidth: 2.5)
                Text(name.isEmpty ? "?" : name.prefix(1).uppercased())
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(personaColor)
            }
            .frame(width: 72, height: 72)
            .animation(.spring(response: 0.3), value: name)

            VStack(alignment: .leading, spacing: 6) {
                Text(name.isEmpty ? "Untitled Persona" : name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(theme.primaryText)

                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    let toolCount = resolvedEnabledToolCount
                    let totalTools = ToolRegistry.shared.listTools().count
                    statBadge(icon: "wrench.and.screwdriver", text: "\(toolCount)/\(totalTools) tools", color: .orange)

                    let skillCount = resolvedEnabledSkillCount
                    let totalSkills = SkillManager.shared.skills.count
                    statBadge(icon: "sparkles", text: "\(skillCount)/\(totalSkills) skills", color: .cyan)

                    if !linkedSchedules.isEmpty {
                        statBadge(
                            icon: "clock",
                            text: "\(linkedSchedules.count) schedule\(linkedSchedules.count == 1 ? "" : "s")",
                            color: .green
                        )
                    }
                    statBadge(
                        icon: "calendar",
                        text: "Created \(persona.createdAt.formatted(date: .abbreviated, time: .omitted))",
                        color: theme.tertiaryText
                    )
                }
                .padding(.top, 2)
            }

            Spacer()
        }
    }

    private func statBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
        }
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        PersonaDetailSection(title: "Identity", icon: "person.circle.fill") {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
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
            .onChange(of: name) { debouncedSave() }
            .onChange(of: description) { debouncedSave() }
        }
    }

    // MARK: - System Prompt Section

    private var systemPromptSection: some View {
        PersonaDetailSection(title: "System Prompt", icon: "brain") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if systemPrompt.isEmpty {
                        Text("Enter instructions for this persona...")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(theme.placeholderText)
                            .padding(.top, 12)
                            .padding(.leading, 16)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $systemPrompt)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160, maxHeight: 300)
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

                Text("Instructions that define this persona's behavior. Leave empty to use global settings.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .onChange(of: systemPrompt) { debouncedSave() }
        }
    }

    // MARK: - Generation Section

    private var generationSection: some View {
        PersonaDetailSection(title: "Generation", icon: "cpu") {
            VStack(spacing: 16) {
                // Model selector
                VStack(alignment: .leading, spacing: 6) {
                    Label("Default Model", systemImage: "cube.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    Button {
                        showModelPicker.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            if let model = selectedModel {
                                Text(formatModelName(model))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)
                            } else {
                                Text("Default (from global settings)")
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.placeholderText)
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.tertiaryText)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                        ModelPickerView(
                            options: modelOptions,
                            selectedModel: Binding(
                                get: { selectedModel },
                                set: { newModel in
                                    selectedModel = newModel
                                    personaManager.updateDefaultModel(for: persona.id, model: newModel)
                                    showSaveIndicator()
                                }
                            ),
                            personaId: persona.id,
                            onDismiss: { showModelPicker = false }
                        )
                    }

                    if selectedModel != nil {
                        Button {
                            selectedModel = nil
                            personaManager.updateDefaultModel(for: persona.id, model: nil)
                            showSaveIndicator()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 10))
                                Text("Reset to default")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Temperature", systemImage: "thermometer.medium")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)

                        StyledTextField(placeholder: "0.7", text: $temperature, icon: nil)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Max Tokens", systemImage: "number")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)

                        StyledTextField(placeholder: "4096", text: $maxTokens, icon: nil)
                    }
                }

                Text("Leave empty to use default values from global settings.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .onChange(of: temperature) { debouncedSave() }
            .onChange(of: maxTokens) { debouncedSave() }
        }
    }

    // MARK: - Abilities Section

    private var capabilitiesSection: some View {
        PersonaDetailSection(
            title: "Abilities",
            icon: "wrench.and.screwdriver",
            subtitle: "\(resolvedEnabledToolCount + resolvedEnabledSkillCount) enabled"
        ) {
            CapabilitiesSelectorView(personaId: persona.id, isInline: true)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Theme Section

    private var themeSection: some View {
        PersonaDetailSection(title: "Visual Theme", icon: "paintpalette.fill") {
            VStack(alignment: .leading, spacing: 12) {
                themePickerGrid

                Text("Optionally assign a visual theme to this persona.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private var themePickerGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
            ThemeOptionCard(
                name: "Default",
                colors: [theme.accentColor, theme.primaryBackground, theme.successColor],
                isSelected: selectedThemeId == nil,
                onSelect: {
                    selectedThemeId = nil; savePersona()
                }
            )

            ForEach(themeManager.installedThemes, id: \.metadata.id) { customTheme in
                ThemeOptionCard(
                    name: customTheme.metadata.name,
                    colors: [
                        Color(themeHex: customTheme.colors.accentColor),
                        Color(themeHex: customTheme.colors.primaryBackground),
                        Color(themeHex: customTheme.colors.successColor),
                    ],
                    isSelected: selectedThemeId == customTheme.metadata.id,
                    onSelect: {
                        selectedThemeId = customTheme.metadata.id; savePersona()
                    }
                )
            }
        }
    }

    // MARK: - Schedules Section

    private var schedulesSection: some View {
        PersonaDetailSection(
            title: "Schedules",
            icon: "clock.fill",
            subtitle: linkedSchedules.isEmpty ? "None" : "\(linkedSchedules.count)"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if linkedSchedules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 24))
                            .foregroundColor(theme.tertiaryText)
                        Text("No schedules linked to this persona")
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    ForEach(linkedSchedules) { schedule in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(schedule.isEnabled ? theme.successColor : theme.tertiaryText)
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(schedule.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(theme.primaryText)

                                HStack(spacing: 8) {
                                    Text(schedule.frequency.displayDescription)
                                        .font(.system(size: 11))
                                        .foregroundColor(theme.secondaryText)

                                    if let nextRun = schedule.nextRunDescription {
                                        Text("Next: \(nextRun)")
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.tertiaryText)
                                    }
                                }
                            }

                            Spacer()

                            Text(schedule.isEnabled ? "Active" : "Paused")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(schedule.isEnabled ? theme.successColor : theme.tertiaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(
                                            (schedule.isEnabled ? theme.successColor : theme.tertiaryText).opacity(0.1)
                                        )
                                )
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                    }
                }

                Button {
                    showCreateSchedule = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                        Text("Create Schedule")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - History Section

    private var historySection: some View {
        PersonaDetailSection(
            title: "History",
            icon: "clock.arrow.circlepath",
            subtitle:
                "\(chatSessions.count) chat\(chatSessions.count == 1 ? "" : "s"), \(agentTasks.count) task\(agentTasks.count == 1 ? "" : "s")"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                // Chat sessions
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.accentColor)
                            Text("RECENT CHATS")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.secondaryText)
                                .tracking(0.3)
                        }
                        Spacer()
                        Button {
                            ChatWindowManager.shared.createWindow(personaId: persona.id)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("New Chat")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    if chatSessions.isEmpty {
                        Text("No chat sessions yet")
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(chatSessions.prefix(5)) { session in
                            ClickableHistoryRow {
                                ChatWindowManager.shared.createWindow(
                                    personaId: persona.id,
                                    sessionData: session
                                )
                            } content: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(theme.primaryText)
                                            .lineLimit(1)

                                        Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.tertiaryText)
                                    }
                                    Spacer()
                                    HStack(spacing: 4) {
                                        Text("\(session.turns.count) turns")
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.tertiaryText)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundColor(theme.tertiaryText)
                                    }
                                }
                            }
                        }
                        if chatSessions.count > 5 {
                            Text("and \(chatSessions.count - 5) more...")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.leading, 4)
                        }
                    }
                }

                Rectangle()
                    .fill(theme.primaryBorder)
                    .frame(height: 1)

                // Agent tasks
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accentColor)
                        Text("RECENT TASKS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .tracking(0.3)
                    }

                    if agentTasks.isEmpty {
                        Text("No agent tasks yet")
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(agentTasks.prefix(5)) { task in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(taskStatusColor(task.status))
                                    .frame(width: 6, height: 6)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(theme.primaryText)
                                        .lineLimit(1)

                                    Text(task.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 10))
                                        .foregroundColor(theme.tertiaryText)
                                }
                                Spacer()
                                Text(task.status.rawValue.capitalized)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(taskStatusColor(task.status))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.inputBackground.opacity(0.5))
                            )
                        }
                        if agentTasks.count > 5 {
                            Text("and \(agentTasks.count - 5) more...")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.leading, 4)
                        }
                    }
                }
            }
        }
    }

    private func taskStatusColor(_ status: AgentTaskStatus) -> Color {
        switch status {
        case .active: return theme.accentColor
        case .completed: return theme.successColor
        case .cancelled: return theme.tertiaryText
        }
    }

    // MARK: - Data Loading

    private func loadPersonaData() {
        name = persona.name
        description = persona.description
        systemPrompt = persona.systemPrompt
        temperature = persona.temperature.map { String($0) } ?? ""
        maxTokens = persona.maxTokens.map { String($0) } ?? ""
        selectedThemeId = persona.themeId
    }

    private func loadModelOptions() {
        Task {
            var options: [ModelOption] = []

            if AppConfiguration.shared.foundationModelAvailable {
                options.append(.foundation())
            }

            let localModels = await Task.detached(priority: .userInitiated) {
                ModelManager.discoverLocalModels()
            }.value
            for model in localModels {
                options.append(.fromMLXModel(model))
            }

            let remoteModels = await MainActor.run {
                RemoteProviderManager.shared.cachedAvailableModels()
            }
            for providerInfo in remoteModels {
                for modelId in providerInfo.models {
                    options.append(
                        .fromRemoteModel(
                            modelId: modelId,
                            providerName: providerInfo.providerName,
                            providerId: providerInfo.providerId
                        )
                    )
                }
            }

            await MainActor.run {
                modelOptions = options
            }
        }
    }

    private func formatModelName(_ model: String) -> String {
        if let last = model.split(separator: "/").last {
            return String(last)
        }
        return model
    }

    // MARK: - Save

    private func debouncedSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            savePersona()
        }
    }

    private func savePersona() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // Preserve existing tool/skill overrides managed by CapabilitiesSelectorView
        let current = currentPersona

        let updated = Persona(
            id: persona.id,
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            enabledTools: current.enabledTools,
            enabledSkills: current.enabledSkills,
            themeId: selectedThemeId,
            defaultModel: selectedModel,
            temperature: Float(temperature),
            maxTokens: Int(maxTokens),
            isBuiltIn: false,
            createdAt: persona.createdAt,
            updatedAt: Date()
        )

        personaManager.update(updated)
        showSaveIndicator()
    }

    private func showSaveIndicator() {
        withAnimation(.easeOut(duration: 0.2)) {
            saveIndicator = "Saved"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                saveIndicator = nil
            }
        }
    }
}

// MARK: - Clickable History Row

private struct ClickableHistoryRow<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isHovered
                                ? themeManager.currentTheme.tertiaryBackground.opacity(0.7)
                                : themeManager.currentTheme.inputBackground.opacity(0.5)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Detail Section Component

private struct PersonaDetailSection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let icon: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header (always visible, non-interactive)
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)
                    .frame(width: 20)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .tracking(0.5)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            // Content (always visible)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
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

// MARK: - Persona Editor Sheet (Create only)

private struct PersonaEditorSheet: View {
    enum Mode {
        case create
    }

    @Environment(\.theme) private var theme
    @ObservedObject private var themeManager = ThemeManager.shared

    let mode: Mode
    let onSave: (Persona) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var systemPrompt: String = ""
    @State private var temperature: String = ""
    @State private var maxTokens: String = ""
    @State private var selectedThemeId: UUID?
    @State private var hasAppeared = false

    /// Generate a consistent color based on persona name
    private var personaColor: Color {
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Identity Section
                    EditorSection(title: "Identity", icon: "person.circle.fill") {
                        VStack(spacing: 16) {
                            HStack(spacing: 16) {
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

                    // Generation Settings
                    EditorSection(title: "Generation", icon: "cpu") {
                        VStack(spacing: 16) {
                            HStack(spacing: 16) {
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
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
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

                            Text("Optionally assign a visual theme to this persona.")
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
        .frame(width: 580, height: 620)
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
            withAnimation { hasAppeared = true }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(spacing: 12) {
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
                Image(systemName: "person.crop.circle.badge.plus")
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
                Text("Create Persona")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                Text("Build your custom AI assistant")
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

    // MARK: - Footer View

    private var footerView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("\u{2318}")
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

            Button("Create Persona") {
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

        let persona = Persona(
            id: UUID(),
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            enabledTools: nil,
            enabledSkills: nil,
            themeId: selectedThemeId,
            defaultModel: nil,
            temperature: Float(temperature),
            maxTokens: Int(maxTokens),
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )

        onSave(persona)
    }
}

// MARK: - Editor Section

private struct EditorSection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

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
    @ObservedObject private var themeManager = ThemeManager.shared

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
    @ObservedObject private var themeManager = ThemeManager.shared

    let name: String
    let colors: [Color]
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
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

// MARK: - Button Styles

private struct PrimaryButtonStyle: ButtonStyle {
    @ObservedObject private var themeManager = ThemeManager.shared

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
    @ObservedObject private var themeManager = ThemeManager.shared

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
