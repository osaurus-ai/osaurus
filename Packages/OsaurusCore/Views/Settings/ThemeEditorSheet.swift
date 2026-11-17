//
//  ThemeEditorSheet.swift
//  osaurus
//
//  The simple theme editor (accent, tone, contrast, corners, transparency, readability)
//  and the JSON editor for everything else. Both paint the draft app-wide
//  while open, and Cancel puts the saved theme back.
//

import SwiftUI

// MARK: - Editor

struct ThemeEditorSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var store = ThemeLibraryStore.shared

    let original: ThemeDocument
    let isNew: Bool
    /// Saves the draft and hands the saved theme to the JSON editor.
    let onEditJSON: (ThemeDocument) -> Void
    let onClose: () -> Void

    @State private var draft: ThemeDocument
    @State private var customAccent: String
    @State private var preview: ThemePreviewCache.Entry?
    @State private var errorMessage: String?

    init(original: ThemeDocument, isNew: Bool, onEditJSON: @escaping (ThemeDocument) -> Void, onClose: @escaping () -> Void) {
        self.original = original
        self.isNew = isNew
        self.onEditJSON = onEditJSON
        self.onClose = onClose
        _draft = State(initialValue: original)
        if case .custom(let hex) = original.preferences.accent {
            _customAccent = State(initialValue: hex)
        } else {
            _customAccent = State(initialValue: ThemeGenerator.previewAccent(original.preferences.accent).light)
        }
    }

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameConflict: Bool {
        store.all.contains { $0.id != draft.id && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }
    }

    var body: some View {
        SettingsSheet(
            icon: "paintpalette",
            title: isNew ? "New Theme" : "Edit Theme",
            subtitle: "Changes preview across Osaurus while this is open.",
            width: SettingsSheetWidth.wide,
            primary: .init(
                label: isNew ? "Create Theme" : "Save Changes",
                isEnabled: !trimmedName.isEmpty && !nameConflict,
                handler: save
            ),
            secondary: .init(label: "Cancel", handler: cancel),
            warning: errorMessage ?? (nameConflict ? L("A theme with this name already exists.") : nil),
            onClose: cancel
        ) {
            previewSection
            SettingsSection(title: "Theme") {
                SettingsTextFieldRow(label: "Name", text: $draft.name, placeholder: L("My Theme"))
                SettingsRow(
                    title: "Accent",
                    description: "Buttons, links and focus. Any color is adjusted to stay readable.",
                    anchorId: "settings.general.themes.accent"
                ) {
                    SettingsSwatchPicker(
                        swatches: swatches,
                        selection: accentSelection,
                        customColor: customAccentBinding,
                        customPreview: customPreview
                    )
                }
                SettingsPickerRow(
                    title: "Tone",
                    description: "The tint of backgrounds and borders",
                    anchorId: "settings.general.themes.tone",
                    selection: $draft.preferences.tone,
                    options: ThemeTone.allCases.map { .init($0, $0.label, verbatim: true) }
                )
                SettingsPickerRow(
                    title: "Appearance",
                    description: "Lock this theme to light or dark, or follow the Appearance setting",
                    anchorId: "settings.general.themes.appearance",
                    selection: $draft.appearance,
                    options: ThemeAppearance.allCases.map { .init($0, $0.label, verbatim: true) }
                )
                SettingsPickerRow(
                    title: "Contrast",
                    description: "High raises text and border contrast to 7:1",
                    anchorId: "settings.general.themes.contrast",
                    selection: $draft.preferences.contrast,
                    options: ThemeContrastLevel.allCases.map { .init($0, $0.label, verbatim: true) }
                )
                SettingsPickerRow(
                    title: "Corners",
                    anchorId: "settings.general.themes.corners",
                    selection: $draft.preferences.corners,
                    options: ThemeCorners.allCases.map { .init($0, $0.label, verbatim: true) }
                )
                SettingsPickerRow(
                    title: "Transparency",
                    description: "How much of the desktop shows through the icon rail and title bar",
                    anchorId: "settings.general.themes.transparency",
                    selection: $draft.preferences.transparency,
                    options: ThemeTransparency.allCases.map { .init($0, $0.label, verbatim: true) }
                )
            }
            readabilitySection
            advancedSection
        }
        .onAppear { themeManager.applyLiveDraft(draft) }
        .onChange(of: draft) { _, newValue in themeManager.applyLiveDraft(newValue) }
        .onDisappear { themeManager.endLiveDraft() }
        .task(id: CompileKey(document: draft, highContrast: themeManager.systemIncreaseContrast)) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let document = draft
            let result = try? await ThemeCompiler.compileDetached(document, highContrast: themeManager.systemIncreaseContrast)
            guard !Task.isCancelled else { return }
            preview = result.map { ThemePreviewCache.entry(document, $0) }
        }
    }

    private struct CompileKey: Equatable {
        let document: ThemeDocument
        let highContrast: Bool
    }

    // MARK: Preview

    @ViewBuilder private var previewSection: some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            if let preview {
                ForEach(Array(preview.modes.enumerated()), id: \.offset) { _, mode in
                    SettingsThemePreview(theme: mode, caption: mode.isDark ? L("Dark") : L("Light"))
                }
            } else {
                SettingsThemePreview(theme: theme)
            }
        }
        if let findings = preview?.contrastFindings, !findings.isEmpty {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                ForEach(findings.prefix(4)) { finding in
                    SettingsFindingRow(severity: .warning, title: finding.message)
                }
            }
        }
    }

    // MARK: Readability

    private var readabilitySection: some View {
        SettingsSection(title: "Readability") {
            SettingsPickerRow(
                title: "Reading Size",
                description: "Larger chat and body text. Stacks with Text Size.",
                anchorId: "settings.general.themes.readingSize",
                selection: $draft.preferences.readability.readingSize,
                options: ThemeReadingSize.allCases.map { .init($0, $0.label, verbatim: true) }
            )
            SettingsPickerRow(
                title: "Line Spacing",
                anchorId: "settings.general.themes.lineSpacing",
                selection: $draft.preferences.readability.lineSpacing,
                options: ThemeLineSpacing.allCases.map { .init($0, $0.label, verbatim: true) }
            )
            SettingsRow(
                title: "Interface Font",
                description: "Readable families such as Atkinson Hyperlegible or Lexend appear once installed",
                anchorId: "settings.general.themes.uiFont"
            ) {
                SettingsFontPicker(kind: .ui, selection: $draft.preferences.readability.uiFont)
            }
            SettingsRow(title: "Code Font", description: "Code blocks and terminal output", anchorId: "settings.general.themes.codeFont") {
                SettingsFontPicker(kind: .code, selection: $draft.preferences.readability.codeFont)
            }
            SettingsToggle(
                title: "Stronger Outlines",
                description: "Thicker borders and focus rings",
                anchorId: "settings.general.themes.strongerOutlines",
                isOn: $draft.preferences.readability.strongerOutlines
            )
            SettingsToggle(
                title: "Larger Controls",
                description: "Taller buttons, fields and rows",
                anchorId: "settings.general.themes.largerControls",
                isOn: $draft.preferences.readability.largerControls
            )
        }
    }

    // MARK: Advanced

    @ViewBuilder private var advancedSection: some View {
        if draft.hasOverrides {
            SettingsCallout(
                icon: "curlybraces",
                title: L("This theme has JSON edits"),
                message: L("\(draft.overrides?.tokens.count ?? 0) tokens set in JSON take precedence over the choices above.")
            ) {
                SettingsButton(.secondary, "Edit JSON…") { saveThen(onEditJSON) }
            }
        } else {
            SettingsSection(title: "Advanced") {
                SettingsRow(
                    title: "Edit JSON",
                    description: "Fine-tune any color, size or font token. Values are kept within safe ranges.",
                    anchorId: "settings.general.themes.json"
                ) {
                    SettingsButton(.secondary, "Edit JSON…") { saveThen(onEditJSON) }
                }
            }
        }
    }

    // MARK: Accent

    private var swatches: [SettingsSwatchPicker.Swatch] {
        ThemeAccentSwatch.allCases.map { swatch in
            let pair = ThemeGenerator.previewAccent(.swatch(swatch), tone: draft.preferences.tone)
            return .init(id: swatch.rawValue, label: swatch.label, color: Color(themeHex: theme.isDark ? pair.dark : pair.light))
        }
    }

    private var customPreview: Color {
        let pair = ThemeGenerator.previewAccent(.custom(customAccent), tone: draft.preferences.tone)
        return Color(themeHex: theme.isDark ? pair.dark : pair.light)
    }

    private var accentSelection: Binding<String?> {
        Binding(
            get: {
                if case .swatch(let swatch) = draft.preferences.accent { return swatch.rawValue }
                return nil
            },
            set: { id in
                guard let id, let swatch = ThemeAccentSwatch(rawValue: id) else { return }
                draft.preferences.accent = .swatch(swatch)
            }
        )
    }

    private var customAccentBinding: Binding<String> {
        Binding(
            get: { customAccent },
            set: { hex in
                customAccent = hex
                draft.preferences.accent = .custom(hex)
            }
        )
    }

    // MARK: Actions

    private func persist() throws -> ThemeDocument {
        var document = draft
        document.name = trimmedName
        return try store.save(document)
    }

    private func save() {
        do {
            let saved = try persist()
            themeManager.setActiveTheme(saved.id)
            themeManager.endLiveDraft()
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveThen(_ next: (ThemeDocument) -> Void) {
        guard !trimmedName.isEmpty, !nameConflict else { return }
        do {
            next(try persist())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancel() {
        themeManager.endLiveDraft()
        onClose()
    }
}

// MARK: - JSON Editor

struct ThemeJSONSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var store = ThemeLibraryStore.shared

    let original: ThemeDocument
    let onClose: () -> Void

    @State private var text: String
    @State private var validation: ThemeJSONValidation
    @State private var saveFindings: [ThemePolicyFinding] = []

    init(original: ThemeDocument, onClose: @escaping () -> Void) {
        self.original = original
        self.onClose = onClose
        let text = ThemeDocumentCodec.encodeString(original)
        _text = State(initialValue: text)
        _validation = State(initialValue: ThemeTokenPolicy.validateJSON(text, base: ThemeCompiler.library))
    }

    private var findings: [SettingsJSONEditor.Finding] {
        (validation.findings + saveFindings).map {
            .init(id: $0.id, severity: $0.severity == .error ? .error : .warning, message: $0.message, line: $0.line)
        }
    }

    var body: some View {
        SettingsSheet(
            icon: "curlybraces",
            title: "Edit JSON",
            subtitle: "Token values outside safe ranges are clamped or rejected.",
            width: SettingsSheetWidth.wide,
            primary: .init(label: "Save Changes", isEnabled: !validation.hasErrors, handler: save),
            secondary: .init(label: "Cancel", handler: cancel),
            onClose: cancel
        ) {
            SettingsJSONEditor(text: $text, findings: findings)
            HStack(spacing: theme.settingsControlGap) {
                SettingsButton(.secondary, "Reset to Preferences", icon: "arrow.uturn.backward") { resetOverrides() }
                    .disabled(!(validation.document?.hasOverrides ?? false))
                    .help(Text("Remove every JSON token edit and keep the simple choices", bundle: .module))
                Spacer(minLength: 0)
                SettingsButton(.tertiary, "Reveal in Finder", icon: "folder") { store.revealInFinder(id: original.id) }
            }
        }
        .onChange(of: text) { _, newValue in
            saveFindings = []
            validation = ThemeTokenPolicy.validateJSON(newValue, base: ThemeCompiler.library)
            if var document = validation.document {
                document.id = original.id
                themeManager.applyLiveDraft(document)
            }
        }
        .onDisappear { themeManager.endLiveDraft() }
    }

    @Environment(\.theme) private var theme

    private func resetOverrides() {
        guard var document = validation.document else { return }
        document.overrides = nil
        text = ThemeDocumentCodec.encodeString(document)
    }

    private func save() {
        let result = store.updateJSON(id: original.id, text: text)
        guard result.document != nil, !result.hasErrors else {
            saveFindings = result.findings.filter { $0.severity == .error }
            return
        }
        themeManager.endLiveDraft()
        onClose()
    }

    private func cancel() {
        themeManager.endLiveDraft()
        onClose()
    }
}
