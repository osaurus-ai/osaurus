//
//  SkillEditorSheet.swift
//  osaurus
//
//  Editor sheet for creating and editing skills with markdown instructions.
//

import AppKit
import SwiftUI

// MARK: - Skill Editor Sheet

struct SkillEditorSheet: View {
    private var theme: ThemeProtocol { themeManager.currentTheme }
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
    @State private var keywords: String = ""
    @State private var instructions: String = ""

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

    private var editingSkill: Skill? {
        if case .edit(let skill) = mode { return skill }
        return nil
    }

    /// True when an edited skill still differs from what's stored. Create
    /// mode is always "changed"; the Save button there is gated on
    /// `canSave` alone.
    private var hasChanges: Bool {
        guard let original = editingSkill else { return true }
        return name.trimmingCharacters(in: .whitespacesAndNewlines) != original.name
            || description.trimmingCharacters(in: .whitespacesAndNewlines) != original.description
            || version.trimmingCharacters(in: .whitespacesAndNewlines) != original.version
            || (author.isEmpty ? nil : author.trimmingCharacters(in: .whitespacesAndNewlines))
                != original.author
            || (category.isEmpty ? nil : category.trimmingCharacters(in: .whitespacesAndNewlines))
                != original.category
            || Self.parseKeywords(keywords) != original.keywords
            || instructions.trimmingCharacters(in: .whitespacesAndNewlines) != original.instructions
    }

    /// Comma-separated keywords field → keyword list, dropping empties.
    /// Nonisolated: pure string work, callable (and testable) off the main actor.
    nonisolated static func parseKeywords(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Upper bounds for the sheet so it never grows past the visible screen
    /// (menu bar / Dock excluded). Keeps the pinned footer — and its "Save
    /// Changes" button — reachable, and keeps the instructions pane on screen,
    /// when accessibility text scaling shrinks the available space (issue #2374).
    private var maxSheetHeight: CGFloat {
        if let visibleHeight = NSScreen.main?.visibleFrame.height {
            return max(400, visibleHeight - 40)
        }
        return 700
    }

    private var maxSheetWidth: CGFloat {
        if let visibleWidth = NSScreen.main?.visibleFrame.width {
            return max(560, visibleWidth - 40)
        }
        return 900
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
        .frame(
            minWidth: 780,
            idealWidth: 900,
            maxWidth: maxSheetWidth,
            minHeight: 400,
            idealHeight: 700,
            maxHeight: maxSheetHeight
        )
        .settingsSheetSurface()
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            if case .edit(let skill) = mode {
                loadSkill(skill)
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        SettingsSheetHeader(
            icon: isEditing ? "pencil.circle.fill" : "sparkles",
            title: headerTitle,
            subtitle: headerSubtitle,
            onClose: onCancel
        )
    }

    private var headerTitle: LocalizedStringKey {
        guard isEditing else { return "Create Skill" }
        return isBuiltIn ? "View Skill" : "Edit Skill"
    }

    private var headerSubtitle: LocalizedStringKey {
        guard isEditing else { return "Define specialized guidance for the AI" }
        return isBuiltIn ? "Preview built-in skill instructions" : "Modify your skill's instructions"
    }

    // MARK: - Form View

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Identity Section
                SkillEditorSection(title: L("editor.section.identity"), icon: "sparkles") {
                    VStack(alignment: .leading, spacing: 16) {
                        // Name
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Name", bundle: .module)
                                .font(SettingsFont.smallLabel)
                                .foregroundColor(themeManager.currentTheme.text.secondary)

                            SkillStyledTextField(
                                placeholder: L("e.g., Web Researcher"),
                                text: $name,
                                icon: nil
                            )
                            .disabled(isBuiltIn)
                        }

                        // Description
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Description", bundle: .module)
                                .font(SettingsFont.smallLabel)
                                .foregroundColor(themeManager.currentTheme.text.secondary)

                            SkillStyledTextField(
                                placeholder: L("Brief description (optional)"),
                                text: $description,
                                icon: nil
                            )
                            .disabled(isBuiltIn)
                        }
                    }
                }

                // Metadata Section
                SkillEditorSection(title: L("Metadata"), icon: "tag.fill") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            // Category
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Category", bundle: .module)
                                    .font(SettingsFont.smallLabel)
                                    .foregroundColor(themeManager.currentTheme.text.secondary)

                                SkillStyledTextField(
                                    placeholder: L("e.g., productivity"),
                                    text: $category,
                                    icon: nil
                                )
                                .disabled(isBuiltIn)
                            }

                            // Version
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Version", bundle: .module)
                                    .font(SettingsFont.smallLabel)
                                    .foregroundColor(themeManager.currentTheme.text.secondary)

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
                            Text("Author", bundle: .module)
                                .font(SettingsFont.smallLabel)
                                .foregroundColor(themeManager.currentTheme.text.secondary)

                            SkillStyledTextField(
                                placeholder: L("Your name (optional)"),
                                text: $author,
                                icon: nil
                            )
                            .disabled(isBuiltIn)
                        }

                        // Keywords — the discovery signal capabilities_discover
                        // searches. Built-in skills ship rich keyword lists;
                        // custom skills without them are only found by name +
                        // description.
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Keywords", bundle: .module)
                                .font(SettingsFont.smallLabel)
                                .foregroundColor(themeManager.currentTheme.text.secondary)

                            SkillStyledTextField(
                                placeholder: L("Comma-separated, e.g. research, web, citations"),
                                text: $keywords,
                                icon: nil
                            )
                            .disabled(isBuiltIn)

                            Text(
                                "Help the AI find this skill: add words users would say when they need it.",
                                bundle: .module
                            )
                            .font(SettingsFont.footnote)
                            .foregroundColor(themeManager.currentTheme.text.tertiary)
                        }
                    }
                }

            }
            .padding(theme.space.s16)
        }
        .background(themeManager.currentTheme.surface.overlay)
    }

    // MARK: - Instructions Editor

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Editor header
            HStack {
                Image(systemName: "doc.text")
                    .glyphSize(12, weight: .semibold)
                    .foregroundColor(themeManager.currentTheme.text.link)

                Text("Instructions", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(themeManager.currentTheme.text.secondary)

                Spacer()

                Text(instructions.count == 1 ? L("1 character") : L("\(instructions.count) characters"))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(themeManager.currentTheme.text.tertiary)
            }
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s12)
            .background(themeManager.currentTheme.surface.subtle)

            // Editor area
            ZStack(alignment: .topLeading) {
                if instructions.isEmpty && !isBuiltIn {
                    Text(
                        "Write guidance for the AI...\n\nExample:\n## When to use this skill\n- Describe scenarios\n\n## Guidelines\n- Add specific guidance",
                        bundle: .module
                    )
                    .font(SettingsFont.mono)
                    .foregroundColor(themeManager.currentTheme.text.placeholder)
                    .padding(theme.space.s16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                }

                if isBuiltIn {
                    // Read-only view for built-in skills
                    ScrollView {
                        Text(instructions)
                            .font(SettingsFont.mono)
                            .foregroundColor(themeManager.currentTheme.text.primary)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(theme.space.s16)
                            .textSelection(.enabled)
                    }
                } else {
                    ThemedNSTextView(
                        text: $instructions,
                        textColor: themeManager.currentTheme.text.primary,
                        font: themeManager.currentTheme.nsFont(.code),
                        textInset: 16
                    )
                }
            }
            .background(themeManager.currentTheme.surface.raised)
        }
        .background(
            Rectangle()
                .fill(themeManager.currentTheme.surface.raised)
                .overlay(
                    Rectangle()
                        .stroke(themeManager.currentTheme.border.strong, lineWidth: theme.stroke.default)
                )
        )
    }

    // MARK: - Footer View

    private var footerView: some View {
        SettingsSheetFooter(
            primary: isBuiltIn
                ? nil
                : .init(label: isEditing ? "Save Changes" : "Create Skill", isEnabled: canSave && hasChanges) {
                    saveSkill()
                },
            secondary: .init(label: isBuiltIn ? "Close" : "Cancel", handler: onCancel),
            hint: isBuiltIn ? nil : "+ Enter to save"
        )
    }

    // MARK: - Helpers

    private func loadSkill(_ skill: Skill) {
        name = skill.name
        description = skill.description
        version = skill.version
        author = skill.author ?? ""
        category = skill.category ?? ""
        keywords = skill.keywords.joined(separator: ", ")
        instructions = skill.instructions
    }

    private func saveSkill() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedInstructions.isEmpty else { return }

        // Fields the editor does not expose (references, assets, directory,
        // plugin association) pass through from the edited skill unchanged.
        // Rebuilding with defaults here erased imported keywords from
        // SKILL.md on every edit — a permanent discovery regression.
        let skill = Skill(
            id: existingId ?? UUID(),
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            version: version.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.isEmpty ? nil : author.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category.isEmpty ? nil : category.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: Self.parseKeywords(keywords),
            instructions: trimmedInstructions,
            isBuiltIn: false,
            createdAt: existingCreatedAt ?? Date(),
            updatedAt: Date(),
            references: editingSkill?.references ?? [],
            assets: editingSkill?.assets ?? [],
            directoryName: editingSkill?.directoryName,
            pluginId: editingSkill?.pluginId
        )

        onSave(skill)
    }
}

// MARK: - Editor Section

private struct SkillEditorSection<Content: View>: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .glyphSize(12, weight: .semibold)
                    .foregroundColor(themeManager.currentTheme.text.link)

                Text(title)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(themeManager.currentTheme.text.secondary)
            }

            content()
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
    }
}

// MARK: - Styled Text Field

private struct SkillStyledTextField: View {
    private var theme: ThemeProtocol { themeManager.currentTheme }
    @ObservedObject private var themeManager = ThemeManager.shared

    let placeholder: String
    @Binding var text: String
    let icon: String?

    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon = icon {
                Image(systemName: icon)
                    .glyphSize(12, weight: .medium)
                    .foregroundColor(
                        isFocused
                            ? themeManager.currentTheme.action.primary.default.background
                            : themeManager.currentTheme.text.tertiary
                    )
                    .frame(width: 16)
            }

            ThemedNSTextField(
                placeholder: placeholder,
                text: $text,
                textColor: themeManager.currentTheme.text.primary,
                placeholderColor: themeManager.currentTheme.text.placeholder,
                font: themeManager.currentTheme.nsFont(.label, weight: .regular),
                onFocusChange: { editing in
                    withAnimation(theme.motion.quick) {
                        isFocused = editing
                    }
                }
            )
            .frame(height: 18)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.control)
        .settingsFocusRing(isFocused, radius: theme.radius.medium)
    }
}

// MARK: - Button Styles

// MARK: - AppKit-Backed Text Field
//

/// NSTextField subclass that reports no intrinsic size that lets SwiftUI's
/// explicit .frame() win and silences the `min <= max` fault SwiftUI raises
/// when a representable returns a fractional intrinsic height.
private final class NoIntrinsicSizeTextField: NSTextField {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private struct ThemedNSTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let textColor: Color
    let placeholderColor: Color
    let font: NSFont
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NoIntrinsicSizeTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.font = font
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderAttributedString = Self.attributedPlaceholder(
            placeholder,
            color: placeholderColor,
            font: font
        )
        field.textColor = NSColor(textColor)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.textColor = NSColor(textColor)
        field.placeholderAttributedString = Self.attributedPlaceholder(
            placeholder,
            color: placeholderColor,
            font: font
        )
    }

    private static func attributedPlaceholder(
        _ string: String,
        color: Color,
        font: NSFont
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .foregroundColor: NSColor(color),
                .font: font,
            ]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ThemedNSTextField

        init(_ parent: ThemedNSTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onFocusChange(false)
        }
    }
}

// MARK: - AppKit-Backed Text View
//
// Wraps NSTextView so we can zero out lineFragmentPadding and set
// textContainerInset explicitly letting a sibling SwiftUI placeholder
// with matching .padding align pixel-perfectly with the caret.

private struct ThemedNSTextView: NSViewRepresentable {
    @Binding var text: String
    let textColor: Color
    let font: NSFont
    let textInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = font
        textView.textColor = NSColor(textColor)
        textView.insertionPointColor = NSColor(textColor)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: textInset, height: textInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.textColor = NSColor(textColor)
        textView.insertionPointColor = NSColor(textColor)
        textView.textContainerInset = NSSize(width: textInset, height: textInset)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ThemedNSTextView

        /// Undo state scoped to this editor's lifetime — keeps stale undo
        /// actions targeting a deallocated text view out of the window's
        /// undo manager (production crash APPLE-MACOS-TG). Created lazily in
        /// the delegate callback because `UndoManager` is main-actor-bound.
        private var editorUndoManager: UndoManager?

        init(_ parent: ThemedNSTextView) {
            self.parent = parent
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            if let editorUndoManager { return editorUndoManager }
            let manager = UndoManager()
            editorUndoManager = manager
            return manager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        SkillEditorSheet(
            mode: .create,
            onSave: { _ in },
            onCancel: {}
        )
    }
#endif
