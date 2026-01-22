//
//  SkillEditorSheet.swift
//  osaurus
//
//  Editor sheet for creating and editing skills with markdown instructions.
//

import SwiftUI

// MARK: - Skill Editor Sheet

struct SkillEditorSheet: View {
    enum Mode {
        case create
        case edit(Skill)
    }

    @Environment(\.theme) private var theme

    let mode: Mode
    let onSave: (Skill) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var version: String = "1.0.0"
    @State private var author: String = ""
    @State private var category: String = ""
    @State private var icon: String = "sparkles"
    @State private var instructions: String = ""
    @State private var enabled: Bool = true

    @State private var hasAppeared = false
    @State private var showIconPicker = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var existingId: UUID? {
        if case .edit(let skill) = mode { return skill.id }
        return nil
    }

    private var existingCreatedAt: Date? {
        if case .edit(let skill) = mode { return skill.createdAt }
        return nil
    }

    private var isBuiltIn: Bool {
        if case .edit(let skill) = mode { return skill.isBuiltIn }
        return false
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Content - Split view with form and preview
            HSplitView {
                // Left side: Form
                formView
                    .frame(minWidth: 350, idealWidth: 400)

                // Right side: Instructions editor
                instructionsEditor
                    .frame(minWidth: 400, idealWidth: 500)
            }

            // Footer
            footerView
        }
        .frame(width: 900, height: 700)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAppeared)
        .onAppear {
            if case .edit(let skill) = mode {
                loadSkill(skill)
            }
            withAnimation {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.2),
                                theme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: isEditing ? "pencil.circle.fill" : "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.7),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Skill" : "Create Skill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(isEditing ? "Modify your skill's instructions" : "Define specialized guidance for the AI")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(theme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            theme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.03),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Form View

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Basic Info Section
                SkillEditorSection(title: "Basic Info", icon: "info.circle.fill") {
                    VStack(alignment: .leading, spacing: 16) {
                        // Name field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Name")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.secondaryText)

                            SkillTextField(
                                placeholder: "e.g., Code Review Expert",
                                text: $name,
                                icon: "textformat"
                            )
                        }

                        // Description field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Description")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.secondaryText)

                            SkillTextField(
                                placeholder: "Brief description of what this skill provides",
                                text: $description,
                                icon: "text.alignleft"
                            )
                        }
                    }
                }

                // Metadata Section
                SkillEditorSection(title: "Metadata", icon: "tag.fill") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            // Category
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Category")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.secondaryText)

                                SkillTextField(
                                    placeholder: "e.g., development",
                                    text: $category,
                                    icon: "folder"
                                )
                            }

                            // Version
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Version")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.secondaryText)

                                SkillTextField(
                                    placeholder: "1.0.0",
                                    text: $version,
                                    icon: "number"
                                )
                            }
                            .frame(width: 100)
                        }

                        HStack(spacing: 12) {
                            // Author
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Author")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.secondaryText)

                                SkillTextField(
                                    placeholder: "Your name",
                                    text: $author,
                                    icon: "person"
                                )
                            }

                            // Icon
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Icon")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.secondaryText)

                                Button(action: { showIconPicker.toggle() }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: icon)
                                            .font(.system(size: 14))
                                            .foregroundColor(theme.accentColor)

                                        Text(icon)
                                            .font(.system(size: 13))
                                            .foregroundColor(theme.primaryText)

                                        Spacer()

                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 10))
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
                                .popover(isPresented: $showIconPicker) {
                                    IconPickerView(selectedIcon: $icon)
                                }
                            }
                            .frame(width: 140)
                        }
                    }
                }

                // Enable toggle
                SkillEditorSection(title: "Status", icon: "checkmark.circle.fill") {
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(
                                    enabled
                                        ? theme.successColor : theme.tertiaryText
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enabled")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                Text(enabled ? "Skill is available in catalog" : "Skill is hidden from catalog")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.tertiaryText)
                            }
                        }

                        Spacer()

                        Toggle("", isOn: $enabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        enabled
                                            ? theme.successColor.opacity(0.3)
                                            : theme.inputBorder,
                                        lineWidth: 1
                                    )
                            )
                    )
                }
            }
            .padding(20)
        }
        .background(theme.primaryBackground)
    }

    // MARK: - Instructions Editor

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Editor header
            HStack {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text("INSTRUCTIONS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)

                Spacer()

                Text("\(instructions.count) characters")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(theme.secondaryBackground)

            // Editor area
            ZStack(alignment: .topLeading) {
                if instructions.isEmpty {
                    Text(
                        "Write markdown instructions for the AI...\n\nExample:\n## When to use this skill\n- Describe scenarios\n\n## Guidelines\n- Add specific guidance"
                    )
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.placeholderText)
                    .padding(16)
                    .allowsHitTesting(false)
                }

                TextEditor(text: $instructions)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(12)
            }
            .background(theme.inputBackground)
        }
        .background(
            Rectangle()
                .fill(theme.inputBackground)
                .overlay(
                    Rectangle()
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 12) {
            if isBuiltIn {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                    Text("Built-in skills cannot be edited")
                        .font(.system(size: 12))
                }
                .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(SkillSecondaryButtonStyle())

            Button(isEditing ? "Save Changes" : "Create Skill") {
                saveSkill()
            }
            .buttonStyle(SkillPrimaryButtonStyle())
            .disabled(!canSave || isBuiltIn)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    // MARK: - Helpers

    private func loadSkill(_ skill: Skill) {
        name = skill.name
        description = skill.description
        version = skill.version
        author = skill.author ?? ""
        category = skill.category ?? ""
        icon = skill.icon ?? "sparkles"
        instructions = skill.instructions
        enabled = skill.enabled
    }

    private func saveSkill() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedInstructions.isEmpty else { return }

        let skill = Skill(
            id: existingId ?? UUID(),
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            version: version.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.isEmpty ? nil : author.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category.isEmpty ? nil : category.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            enabled: enabled,
            instructions: trimmedInstructions,
            isBuiltIn: false,
            createdAt: existingCreatedAt ?? Date(),
            updatedAt: Date()
        )

        onSave(skill)
    }
}

// MARK: - Editor Section

private struct SkillEditorSection<Content: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Text Field

private struct SkillTextField: View {
    @Environment(\.theme) private var theme

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
                        isFocused ? theme.accentColor : theme.tertiaryText
                    )
                    .frame(width: 16)
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(theme.placeholderText)
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
                .foregroundColor(theme.primaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isFocused
                                ? theme.accentColor.opacity(0.5)
                                : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }
}

// MARK: - Icon Picker

private struct IconPickerView: View {
    @Environment(\.theme) private var theme
    @Binding var selectedIcon: String

    private let icons = [
        "sparkles", "star.fill", "bolt.fill", "lightbulb.fill",
        "brain", "cpu", "terminal", "chevron.left.forwardslash.chevron.right",
        "doc.text", "book.fill", "pencil", "highlighter",
        "checkmark.shield", "lock.fill", "key.fill", "shield.fill",
        "ant", "ladybug", "hare.fill", "tortoise.fill",
        "network", "globe", "cloud.fill", "server.rack",
        "chart.bar.fill", "chart.pie.fill", "function", "sum",
        "person.fill", "person.2.fill", "bubble.left.fill", "text.bubble.fill",
        "folder.fill", "tray.full.fill", "archivebox.fill", "externaldrive.fill",
        "gear", "wrench.fill", "hammer.fill", "paintbrush.fill",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Icon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 8), spacing: 8) {
                ForEach(icons, id: \.self) { iconName in
                    Button(action: { selectedIcon = iconName }) {
                        Image(systemName: iconName)
                            .font(.system(size: 14))
                            .foregroundColor(
                                selectedIcon == iconName
                                    ? .white
                                    : theme.primaryText
                            )
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        selectedIcon == iconName
                                            ? theme.accentColor
                                            : theme.tertiaryBackground
                                    )
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(16)
        .background(theme.cardBackground)
    }
}

// MARK: - Button Styles

private struct SkillPrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.accentColor)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

private struct SkillSecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
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
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

#Preview {
    SkillEditorSheet(
        mode: .create,
        onSave: { _ in },
        onCancel: {}
    )
}
