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

    @ObservedObject private var themeManager = ThemeManager.shared

    let mode: Mode
    let onSave: (Skill) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var version: String = "1.0.0"
    @State private var author: String = ""
    @State private var category: String = ""
    @State private var instructions: String = ""
    @State private var enabled: Bool = true

    @State private var hasAppeared = false

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

            // Content - Split view with form and instructions
            HSplitView {
                // Left side: Form
                formView
                    .frame(minWidth: 320, idealWidth: 360)

                // Right side: Instructions editor
                instructionsEditor
                    .frame(minWidth: 400, idealWidth: 500)
            }

            // Footer
            footerView
        }
        .frame(width: 900, height: 700)
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
            if case .edit(let skill) = mode {
                loadSkill(skill)
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
                Image(systemName: isEditing ? "pencil.circle.fill" : "sparkles")
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
                Text(isEditing ? (isBuiltIn ? "View Skill" : "Edit Skill") : "Create Skill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)

                Text(
                    isEditing
                        ? (isBuiltIn ? "Preview built-in skill instructions" : "Modify your skill's instructions")
                        : "Define specialized guidance for the AI"
                )
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

    // MARK: - Form View

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Identity Section
                SkillEditorSection(title: "Identity", icon: "sparkles") {
                    VStack(alignment: .leading, spacing: 16) {
                        // Name
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Name")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(themeManager.currentTheme.secondaryText)

                            SkillStyledTextField(
                                placeholder: "e.g., Research Analyst",
                                text: $name,
                                icon: nil
                            )
                            .disabled(isBuiltIn)
                        }

                        // Description
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Description")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(themeManager.currentTheme.secondaryText)

                            SkillStyledTextField(
                                placeholder: "Brief description (optional)",
                                text: $description,
                                icon: nil
                            )
                            .disabled(isBuiltIn)
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
                                    .foregroundColor(themeManager.currentTheme.secondaryText)

                                SkillStyledTextField(
                                    placeholder: "e.g., productivity",
                                    text: $category,
                                    icon: nil
                                )
                                .disabled(isBuiltIn)
                            }

                            // Version
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Version")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(themeManager.currentTheme.secondaryText)

                                SkillStyledTextField(
                                    placeholder: "1.0.0",
                                    text: $version,
                                    icon: nil
                                )
                                .disabled(isBuiltIn)
                            }
                            .frame(width: 80)
                        }

                        // Author
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Author")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(themeManager.currentTheme.secondaryText)

                            SkillStyledTextField(
                                placeholder: "Your name (optional)",
                                text: $author,
                                icon: nil
                            )
                            .disabled(isBuiltIn)
                        }
                    }
                }

                // Status Section
                SkillEditorSection(title: "Status", icon: "checkmark.circle.fill") {
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(
                                    enabled
                                        ? themeManager.currentTheme.successColor
                                        : themeManager.currentTheme.tertiaryText
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enabled")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(themeManager.currentTheme.primaryText)
                                Text(enabled ? "Skill is available for use" : "Skill is hidden")
                                    .font(.system(size: 11))
                                    .foregroundColor(themeManager.currentTheme.tertiaryText)
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
                            .fill(themeManager.currentTheme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        enabled
                                            ? themeManager.currentTheme.successColor.opacity(0.3)
                                            : themeManager.currentTheme.inputBorder,
                                        lineWidth: 1
                                    )
                            )
                    )
                }
            }
            .padding(20)
        }
        .background(themeManager.currentTheme.primaryBackground)
    }

    // MARK: - Instructions Editor

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Editor header
            HStack {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text("INSTRUCTIONS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .tracking(0.5)

                Spacer()

                Text("\(instructions.count) characters")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(themeManager.currentTheme.secondaryBackground)

            // Editor area
            ZStack(alignment: .topLeading) {
                if instructions.isEmpty && !isBuiltIn {
                    Text(
                        "Write guidance for the AI...\n\nExample:\n## When to use this skill\n- Describe scenarios\n\n## Guidelines\n- Add specific guidance"
                    )
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.placeholderText)
                    .padding(16)
                    .allowsHitTesting(false)
                }

                if isBuiltIn {
                    // Read-only view for built-in skills
                    ScrollView {
                        Text(instructions)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.primaryText)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .textSelection(.enabled)
                    }
                } else {
                    TextEditor(text: $instructions)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.primaryText)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                }
            }
            .background(themeManager.currentTheme.inputBackground)
        }
        .background(
            Rectangle()
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    Rectangle()
                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Footer View

    private var footerView: some View {
        HStack(spacing: 12) {
            // Keyboard hint
            if !isBuiltIn {
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
            }

            if isBuiltIn {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                    Text("Built-in skills are read-only")
                        .font(.system(size: 12))
                }
                .foregroundColor(themeManager.currentTheme.tertiaryText)
            }

            Spacer()

            Button(isBuiltIn ? "Close" : "Cancel", action: onCancel)
                .buttonStyle(SkillSecondaryButtonStyle())

            if !isBuiltIn {
                Button(isEditing ? "Save Changes" : "Create Skill") {
                    saveSkill()
                }
                .buttonStyle(SkillPrimaryButtonStyle())
                .disabled(!canSave)
                .keyboardShortcut(.return, modifiers: .command)
            }
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

    // MARK: - Helpers

    private func loadSkill(_ skill: Skill) {
        name = skill.name
        description = skill.description
        version = skill.version
        author = skill.author ?? ""
        category = skill.category ?? ""
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

private struct SkillStyledTextField: View {
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

// MARK: - Button Styles

private struct SkillPrimaryButtonStyle: ButtonStyle {
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

private struct SkillSecondaryButtonStyle: ButtonStyle {
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
    SkillEditorSheet(
        mode: .create,
        onSave: { _ in },
        onCancel: {}
    )
}
