//
//  SandboxPluginEditorView.swift
//  osaurus
//
//  Form-based sandbox plugin editor with live JSON preview.
//  Supports both creation and editing.
//

import AppKit
import SwiftUI

// MARK: - SandboxPluginEditorView

struct SandboxPluginEditorView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var plugin: SandboxPlugin
    @State private var collapsedSections: Set<String> = ["Files", "Metadata"]
    @State private var showSaveConfirmation = false
    @State private var metadataText: String = ""
    @State private var metadataValid: Bool = true

    private let isNew: Bool
    private let originalId: String
    private let onSave: (SandboxPlugin) -> Void
    private let onDismiss: () -> Void

    /// Pristine copies of the editable state, captured at init. Used to
    /// disable "Save Changes" while an edited plugin still matches what's
    /// stored.
    private let originalPlugin: SandboxPlugin
    private let originalMetadataText: String

    init(
        plugin: SandboxPlugin,
        isNew: Bool,
        onSave: @escaping (SandboxPlugin) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let serializedMetadata = Self.serializeMetadata(plugin.metadata)
        _plugin = State(initialValue: plugin)
        _metadataText = State(initialValue: serializedMetadata)
        self.isNew = isNew
        self.originalId = plugin.id
        self.originalPlugin = plugin
        self.originalMetadataText = serializedMetadata
        self.onSave = onSave
        self.onDismiss = onDismiss
    }

    /// True when an edited plugin still differs from its stored version.
    /// New plugins are always "changed" so their button stays gated on the
    /// name-required check alone.
    private var hasChanges: Bool {
        guard !isNew else { return true }
        return plugin != originalPlugin || metadataText != originalMetadataText
    }

    var body: some View {
        HSplitView {
            editorPanel
                .frame(minWidth: 380, idealWidth: 420, maxWidth: 480)
            previewPanel
                .frame(minWidth: 400, idealWidth: 500)
        }
        .frame(minWidth: 900, minHeight: 650)
        .background(theme.surface.canvas)
    }
}

// MARK: - Editor Panel

private extension SandboxPluginEditorView {

    var editorPanel: some View {
        VStack(spacing: 0) {
            editorHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    identitySection
                    dependenciesSection
                    setupSection
                    toolsSection
                    filesSection
                    metadataSection
                }
                .padding(theme.space.s16)
            }
            editorFooter
        }
        .background(theme.surface.subtle)
    }

    var editorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isNew ? L("Create Custom Tool") : L("Edit Custom Tool"))
                    .font(SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)
                Spacer()
                SettingsIconButton("xmark", help: "Close", size: .compact, action: { dismiss(); onDismiss() })
            }
            editorTextField(L("Name"), text: $plugin.name, fontSize: 14, weight: .medium, radius: 8)
            editorTextField(L("Short description"), text: $plugin.description, fontSize: 13, radius: 6)
        }
        .padding(theme.space.s16)
    }

    var editorFooter: some View {
        HStack {
            if !isNew {
                Label {
                    Text("Editing \"\(originalId)\"", bundle: .module)
                } icon: {
                    Image(systemName: "pencil")
                }
                .textStyle(.footnote)
                .foregroundColor(theme.text.tertiary)
            }
            Spacer()
            HStack(spacing: 12) {
                Button {
                    dismiss(); onDismiss()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                Button(action: savePlugin) {
                    HStack(spacing: 4) {
                        if showSaveConfirmation { Image(systemName: "checkmark") }
                        Text(
                            LocalizedStringKey(
                                showSaveConfirmation ? "Saved!" : (isNew ? "Create" : "Save Changes")
                            ),
                            bundle: .module
                        )
                    }
                }
                .assignedSettingsButtonStyle(.primary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    plugin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !hasChanges
                )
            }
        }
        .padding(theme.space.s16)
        .background(theme.surface.subtle)
    }
}

// MARK: - Sections

private extension SandboxPluginEditorView {

    var identitySection: some View {
        editorSection(L("editor.section.identity")) {
            labeledField("Author") {
                editorTextField(L("Author name"), text: optionalBinding(\SandboxPlugin.author))
            }
            labeledField(L("Source")) {
                editorTextField(L("URL or repository"), text: optionalBinding(\SandboxPlugin.source))
            }
        }
    }

    var dependenciesSection: some View {
        editorSection(L("Dependencies"), itemCount: plugin.dependencies?.count) {
            Text("System packages installed via apk", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
            stringListEditor(
                binding: Binding(
                    get: { plugin.dependencies ?? [] },
                    set: { plugin.dependencies = $0.isEmpty ? nil : $0 }
                ),
                placeholder: L("Package name (e.g. python3)")
            )
        }
    }

    var setupSection: some View {
        editorSection(L("Setup Command")) {
            Text("Shell command run after dependencies are installed", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
            codeField(
                text: Binding(
                    get: { plugin.setup ?? "" },
                    set: { plugin.setup = $0.isEmpty ? nil : $0 }
                ),
                placeholder: L("e.g. pip install -r requirements.txt")
            )
        }
    }

    var toolsSection: some View {
        editorSection(L("Tools"), itemCount: plugin.tools?.count) {
            if let tools = plugin.tools, !tools.isEmpty {
                ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                    toolCard(index: index, tool: tool)
                }
            }
            Button(action: addTool) {
                Label {
                    Text("Add Tool", bundle: .module)
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .assignedSettingsButtonStyle(.secondary)
        }
    }

    var filesSection: some View {
        editorSection(L("Files"), itemCount: plugin.files?.count) {
            Text("Files seeded into the plugin directory", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)

            let files = plugin.files ?? [:]
            ForEach(Array(files.keys.sorted()), id: \.self) { path in
                fileCard(path: path)
            }

            Button(action: addFile) {
                Label {
                    Text("Add File", bundle: .module)
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .assignedSettingsButtonStyle(.secondary)
        }
    }

    var metadataSection: some View {
        editorSection(L("Metadata"), itemCount: plugin.metadata?.count) {
            Text("Custom JSON data preserved across exports and imports", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)

            codeField(
                text: $metadataText,
                placeholder: "{ \"key\": \"value\" }",
                minHeight: 80
            )
            .onChange(of: metadataText) {
                parseMetadataText(metadataText)
            }

            if !metadataValid {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .glyphSize(10)
                    Text("Invalid JSON", bundle: .module)
                        .font(SettingsFont.rowDescription)
                }
                .foregroundColor(theme.status.error.foreground)
            }
        }
    }
}

// MARK: - Tool Card & Parameters

private extension SandboxPluginEditorView {

    func toolCard(index: Int, tool: SandboxToolSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "wrench")
                    .glyphSize(10)
                    .foregroundColor(theme.text.link)
                Text(tool.id.isEmpty ? L("New Tool") : tool.id)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Spacer()
                Button(action: { removeTool(at: index) }) {
                    Image(systemName: "trash")
                        .glyphSize(11)
                        .foregroundColor(theme.status.error.foreground)
                }
                .buttonStyle(PlainButtonStyle())
            }

            labeledField("ID") {
                editorTextField("tool_id", text: toolBinding(index: index, keyPath: \.id))
            }
            labeledField("Description") {
                editorTextField(L("What this tool does"), text: toolDescriptionBinding(index: index))
            }
            labeledField("Run Command") {
                codeField(text: toolRunBinding(index: index), placeholder: "Shell command to execute")
            }
            parametersEditor(toolIndex: index)
        }
        .padding(theme.space.s8)
        .settingsChrome(.subtle)
    }

    func parametersEditor(toolIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Parameters", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                Spacer()
                Button(action: { addParameter(to: toolIndex) }) {
                    Label {
                        Text("Add", bundle: .module)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
            }

            let params = plugin.tools?[toolIndex].parameters ?? [:]
            ForEach(Array(params.keys.sorted()), id: \.self) { key in
                parameterRow(key: key, toolIndex: toolIndex)
            }
        }
    }

    func parameterRow(key: String, toolIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(key.isEmpty ? "new_param" : key)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                Spacer()
                Button(action: { removeParameter(key, from: toolIndex) }) {
                    Image(systemName: "trash")
                        .glyphSize(10)
                        .foregroundColor(theme.status.error.foreground)
                }
                .buttonStyle(PlainButtonStyle())
            }

            labeledField("Name") {
                DeferredRenameField(
                    "parameter_name",
                    initialValue: key
                ) { newKey in
                    renameParameter(oldKey: key, newKey: newKey, toolIndex: toolIndex)
                }
            }
            labeledField("Type") {
                AssignedBaseSegmentedPicker(
                    selection: parameterTypeBinding(key: key, toolIndex: toolIndex),
                    options: [.init("string", "string"), .init("number", "number"), .init("boolean", "boolean")]
                )
                .fixedSize()
                .accessibilityLabel(Text("Type", bundle: .module))
            }
            HStack {
                Text("Optional", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                Spacer()
                Toggle("", isOn: parameterOptionalBinding(key: key, toolIndex: toolIndex))
                    .settingsSwitch()
            }
        }
        .padding(theme.space.s8)
        .settingsChrome(.control)
    }
}

// MARK: - File Card

private extension SandboxPluginEditorView {

    func fileCard(path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .glyphSize(10)
                    .foregroundColor(theme.text.link)
                DeferredRenameField(
                    "filename.ext",
                    initialValue: path,
                    fontSize: 11
                ) { newPath in
                    renameFile(oldPath: path, newPath: newPath)
                }
                Button(action: { removeFile(path) }) {
                    Image(systemName: "minus.circle")
                        .glyphSize(12)
                        .foregroundColor(theme.status.error.foreground)
                }
                .buttonStyle(PlainButtonStyle())
            }
            codeField(text: fileContentBinding(path: path), placeholder: "File contents...", minHeight: 60)
        }
        .padding(theme.space.s8)
        .settingsChrome(.inset)
    }
}

// MARK: - JSON Preview Panel

private extension SandboxPluginEditorView {

    var previewPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("JSON Preview", bundle: .module)
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
                Spacer()
                Text("Updates as you edit", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(theme.space.s16)
            .background(theme.surface.subtle)

            GeometryReader { geo in
                ScrollView {
                    CodeBlockView(
                        code: prettyJSON,
                        language: "json",
                        baseWidth: max(geo.size.width - 24, 300)
                    )
                    .padding(theme.space.s12)
                }
            }
            .background(theme.surface.canvas)
        }
        .environment(\.theme, theme)
    }

    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(plugin),
            let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }
}

// MARK: - Actions

private extension SandboxPluginEditorView {

    func savePlugin() {
        guard !plugin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSave(plugin)
        showSaveConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showSaveConfirmation = false
            dismiss()
            onDismiss()
        }
    }

    func addTool() {
        if plugin.tools == nil { plugin.tools = [] }
        plugin.tools?.append(SandboxToolSpec(id: "", description: "", run: ""))
    }

    func removeTool(at index: Int) {
        plugin.tools?.remove(at: index)
        if plugin.tools?.isEmpty == true { plugin.tools = nil }
    }

    func addParameter(to toolIndex: Int) {
        let name = "param\((plugin.tools?[toolIndex].parameters?.count ?? 0) + 1)"
        if plugin.tools?[toolIndex].parameters == nil { plugin.tools?[toolIndex].parameters = [:] }
        plugin.tools?[toolIndex].parameters?[name] = SandboxParameterSpec(type: "string")
    }

    func removeParameter(_ key: String, from toolIndex: Int) {
        plugin.tools?[toolIndex].parameters?.removeValue(forKey: key)
        if plugin.tools?[toolIndex].parameters?.isEmpty == true { plugin.tools?[toolIndex].parameters = nil }
    }

    func renameParameter(oldKey: String, newKey: String, toolIndex: Int) {
        guard !newKey.isEmpty, oldKey != newKey,
            let spec = plugin.tools?[toolIndex].parameters?[oldKey]
        else { return }
        plugin.tools?[toolIndex].parameters?.removeValue(forKey: oldKey)
        plugin.tools?[toolIndex].parameters?[newKey] = spec
    }

    func addFile() {
        if plugin.files == nil { plugin.files = [:] }
        plugin.files?["file\((plugin.files?.count ?? 0) + 1).txt"] = ""
    }

    func removeFile(_ path: String) {
        plugin.files?.removeValue(forKey: path)
        if plugin.files?.isEmpty == true { plugin.files = nil }
    }

    func renameFile(oldPath: String, newPath: String) {
        guard !newPath.isEmpty, oldPath != newPath,
            let content = plugin.files?[oldPath]
        else { return }
        plugin.files?.removeValue(forKey: oldPath)
        plugin.files?[newPath] = content
    }

    static func serializeMetadata(_ metadata: [String: JSONValue]?) -> String {
        guard let metadata, !metadata.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(metadata),
            let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }

    func parseMetadataText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            plugin.metadata = nil
            metadataValid = true
            return
        }
        guard let data = trimmed.data(using: .utf8),
            let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
            metadataValid = false
            return
        }
        plugin.metadata = parsed
        metadataValid = true
    }
}

// MARK: - Bindings

private extension SandboxPluginEditorView {

    func optionalBinding(_ keyPath: WritableKeyPath<SandboxPlugin, String?>) -> Binding<String> {
        Binding(
            get: { plugin[keyPath: keyPath] ?? "" },
            set: { plugin[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    func toolBinding(index: Int, keyPath: WritableKeyPath<SandboxToolSpec, String>) -> Binding<String> {
        Binding(
            get: { plugin.tools?[index][keyPath: keyPath] ?? "" },
            set: { plugin.tools?[index][keyPath: keyPath] = $0 }
        )
    }

    func toolDescriptionBinding(index: Int) -> Binding<String> {
        Binding(
            get: { plugin.tools?[index].description ?? "" },
            set: { newValue in
                guard var tools = plugin.tools, index < tools.count else { return }
                tools[index] = SandboxToolSpec(
                    id: tools[index].id,
                    description: newValue,
                    parameters: tools[index].parameters,
                    run: tools[index].run
                )
                plugin.tools = tools
            }
        )
    }

    func toolRunBinding(index: Int) -> Binding<String> {
        Binding(
            get: { plugin.tools?[index].run ?? "" },
            set: { newValue in
                guard var tools = plugin.tools, index < tools.count else { return }
                tools[index] = SandboxToolSpec(
                    id: tools[index].id,
                    description: tools[index].description,
                    parameters: tools[index].parameters,
                    run: newValue
                )
                plugin.tools = tools
            }
        )
    }

    func parameterTypeBinding(key: String, toolIndex: Int) -> Binding<String> {
        Binding(
            get: { plugin.tools?[toolIndex].parameters?[key]?.type ?? "string" },
            set: { plugin.tools?[toolIndex].parameters?[key]?.type = $0 }
        )
    }

    func parameterOptionalBinding(key: String, toolIndex: Int) -> Binding<Bool> {
        Binding(
            get: { plugin.tools?[toolIndex].parameters?[key]?.default != nil },
            set: { plugin.tools?[toolIndex].parameters?[key]?.default = $0 ? "" : nil }
        )
    }

    func fileContentBinding(path: String) -> Binding<String> {
        Binding(
            get: { plugin.files?[path] ?? "" },
            set: { plugin.files?[path] = $0 }
        )
    }
}

// MARK: - Reusable Components

private extension SandboxPluginEditorView {

    func editorSection<Content: View>(
        _ title: String,
        itemCount: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedSections.contains(title)
        return VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                withAnimation(theme.motion.quick) {
                    if isCollapsed { collapsedSections.remove(title) } else { collapsedSections.insert(title) }
                }
            }) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.secondary)
                    if isCollapsed, let count = itemCount {
                        CountBadge(count)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .glyphSize(10, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(theme.space.s12)
                    .settingsChrome(.surface)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    func editorTextField(
        _ placeholder: String,
        text: Binding<String>,
        fontSize: CGFloat = 13,
        weight: Font.Weight = .regular,
        radius: CGFloat = 6,
        mono: Bool = false
    ) -> some View {
        SettingsTextField(placeholder: placeholder, text: text, monospaced: mono)
    }

    func codeField(text: Binding<String>, placeholder: String, minHeight: CGFloat = 40) -> some View {
        SettingsTextEditor(text: text, placeholder: String(localized: String.LocalizationValue(placeholder), bundle: .module), minHeight: minHeight, monospaced: true)
    }

    func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
            content()
        }
    }

    func stringListEditor(binding: Binding<[String]>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(binding.wrappedValue.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 6) {
                    editorTextField(
                        placeholder,
                        text: Binding(
                            get: { binding.wrappedValue[index] },
                            set: { binding.wrappedValue[index] = $0 }
                        ),
                        fontSize: 12,
                        mono: true
                    )
                    Button(action: { binding.wrappedValue.remove(at: index) }) {
                        Image(systemName: "minus.circle")
                            .glyphSize(12)
                            .foregroundColor(theme.status.error.foreground)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            Button(action: { binding.wrappedValue.append("") }) {
                Label {
                    Text("Add", bundle: .module)
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .assignedSettingsButtonStyle(.secondary)
        }
    }
}

// MARK: - Deferred Rename Field

/// A text field that buffers keystrokes locally and only commits the new value
/// on Enter or focus loss. Prevents SwiftUI identity thrashing when the value
/// is used as a `ForEach` id (e.g. dictionary keys for files / parameters).
private struct DeferredRenameField: View {
    @Environment(\.theme) private var theme

    let placeholder: String
    let initialValue: String
    let fontSize: CGFloat
    let weight: Font.Weight
    let onCommit: (String) -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        _ placeholder: String,
        initialValue: String,
        fontSize: CGFloat = 12,
        weight: Font.Weight = .medium,
        onCommit: @escaping (String) -> Void
    ) {
        self.placeholder = placeholder
        self.initialValue = initialValue
        self.fontSize = fontSize
        self.weight = weight
        self.onCommit = onCommit
        _text = State(initialValue: initialValue)
    }

    var body: some View {
        SettingsTextField(placeholder: placeholder, text: $text, monospaced: true, focus: $isFocused)
            .onSubmit { commit() }
            .onChange(of: isFocused) {
                if !isFocused { commit() }
            }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != initialValue {
            onCommit(trimmed)
        }
    }
}

// MARK: - Default Plugin Factory

extension SandboxPlugin {
    static func blank() -> SandboxPlugin {
        SandboxPlugin(name: "New Plugin", description: "A new sandbox plugin")
    }
}
