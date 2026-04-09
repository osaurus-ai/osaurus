//
//  SandboxPluginEditorView.swift
//  osaurus
//
//  Form-based sandbox plugin editor with live JSON preview.
//  Supports both creation and editing, modeled on ThemeEditorView.
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

    init(
        plugin: SandboxPlugin,
        isNew: Bool,
        onSave: @escaping (SandboxPlugin) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _plugin = State(initialValue: plugin)
        _metadataText = State(initialValue: Self.serializeMetadata(plugin.metadata))
        self.isNew = isNew
        self.originalId = plugin.id
        self.onSave = onSave
        self.onDismiss = onDismiss
    }

    var body: some View {
        HSplitView {
            editorPanel
                .frame(minWidth: 380, idealWidth: 420, maxWidth: 480)
            previewPanel
                .frame(minWidth: 400, idealWidth: 500)
        }
        .frame(minWidth: 900, minHeight: 650)
        .background(theme.primaryBackground)
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
                .padding(20)
            }
            editorFooter
        }
        .background(theme.secondaryBackground)
    }

    var editorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isNew ? "Create Plugin" : "Edit Plugin")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: {
                    dismiss(); onDismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(PlainButtonStyle())
            }
            editorTextField("Plugin Name", text: $plugin.name, fontSize: 14, weight: .medium, radius: 8)
            editorTextField("Short description", text: $plugin.description, fontSize: 13, radius: 6)
        }
        .padding(16)
    }

    var editorFooter: some View {
        HStack {
            if !isNew {
                Label { Text("Editing \"\(originalId)\"", bundle: .module) } icon: { Image(systemName: "pencil") }
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            HStack(spacing: 12) {
                Button {
                    dismiss(); onDismiss()
                } label: { Text("Cancel", bundle: .module) }
                .buttonStyle(.bordered)
                Button(action: savePlugin) {
                    HStack(spacing: 4) {
                        if showSaveConfirmation { Image(systemName: "checkmark") }
                        Text(showSaveConfirmation ? "Saved!" : (isNew ? "Create Plugin" : "Save Changes"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(plugin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .background(theme.secondaryBackground)
    }
}

// MARK: - Sections

private extension SandboxPluginEditorView {

    var identitySection: some View {
        editorSection("Identity") {
            labeledField("Author") {
                editorTextField("Author name", text: optionalBinding(\SandboxPlugin.author))
            }
            labeledField("Source") {
                editorTextField("URL or repository", text: optionalBinding(\SandboxPlugin.source))
            }
        }
    }

    var dependenciesSection: some View {
        editorSection("Dependencies", itemCount: plugin.dependencies?.count) {
            Text("System packages installed via apk", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            stringListEditor(
                binding: Binding(
                    get: { plugin.dependencies ?? [] },
                    set: { plugin.dependencies = $0.isEmpty ? nil : $0 }
                ),
                placeholder: "Package name (e.g. python3)"
            )
        }
    }

    var setupSection: some View {
        editorSection("Setup Command") {
            Text("Shell command run after dependencies are installed", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            codeField(
                text: Binding(
                    get: { plugin.setup ?? "" },
                    set: { plugin.setup = $0.isEmpty ? nil : $0 }
                ),
                placeholder: "e.g. pip install -r requirements.txt"
            )
        }
    }

    var toolsSection: some View {
        editorSection("Tools", itemCount: plugin.tools?.count) {
            if let tools = plugin.tools, !tools.isEmpty {
                ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                    toolCard(index: index, tool: tool)
                }
            }
            Button(action: addTool) { Label { Text("Add Tool", bundle: .module) } icon: { Image(systemName: "plus") } }
                .buttonStyle(.bordered)
        }
    }

    var filesSection: some View {
        editorSection("Files", itemCount: plugin.files?.count) {
            Text("Files seeded into the plugin directory", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

            let files = plugin.files ?? [:]
            ForEach(Array(files.keys.sorted()), id: \.self) { path in
                fileCard(path: path)
            }

            Button(action: addFile) { Label { Text("Add File", bundle: .module) } icon: { Image(systemName: "plus") } }
                .buttonStyle(.bordered)
        }
    }

    var metadataSection: some View {
        editorSection("Metadata", itemCount: plugin.metadata?.count) {
            Text("Custom JSON data preserved across exports and imports", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

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
                        .font(.system(size: 10))
                    Text("Invalid JSON", bundle: .module)
                        .font(.system(size: 11))
                }
                .foregroundColor(theme.errorColor)
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
                    .font(.system(size: 10))
                    .foregroundColor(theme.accentColor)
                Text(tool.id.isEmpty ? "New Tool" : tool.id)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: { removeTool(at: index) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorColor)
                }
                .buttonStyle(PlainButtonStyle())
            }

            labeledField("ID") {
                editorTextField("tool_id", text: toolBinding(index: index, keyPath: \.id))
            }
            labeledField("Description") {
                editorTextField("What this tool does", text: toolDescriptionBinding(index: index))
            }
            labeledField("Run Command") {
                codeField(text: toolRunBinding(index: index), placeholder: "Shell command to execute")
            }
            parametersEditor(toolIndex: index)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.cardBorder, lineWidth: 1))
        )
    }

    func parametersEditor(toolIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Parameters", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Button(action: { addParameter(to: toolIndex) }) { Label { Text("Add", bundle: .module) } icon: { Image(systemName: "plus") } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: { removeParameter(key, from: toolIndex) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(theme.errorColor.opacity(0.7))
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
                Picker("", selection: parameterTypeBinding(key: key, toolIndex: toolIndex)) {
                    Text("string", bundle: .module).tag("string")
                    Text("number", bundle: .module).tag("number")
                    Text("boolean", bundle: .module).tag("boolean")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Text("Optional", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Toggle("", isOn: parameterOptionalBinding(key: key, toolIndex: toolIndex))
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .labelsHidden()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.cardBorder.opacity(0.5), lineWidth: 1))
        )
    }
}

// MARK: - File Card

private extension SandboxPluginEditorView {

    func fileCard(path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(theme.accentColor)
                DeferredRenameField(
                    "filename.ext",
                    initialValue: path,
                    fontSize: 11
                ) { newPath in
                    renameFile(oldPath: path, newPath: newPath)
                }
                Button(action: { removeFile(path) }) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor.opacity(0.7))
                }
                .buttonStyle(PlainButtonStyle())
            }
            codeField(text: fileContentBinding(path: path), placeholder: "File contents...", minHeight: 60)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground.opacity(0.5)))
    }
}

// MARK: - JSON Preview Panel

private extension SandboxPluginEditorView {

    var previewPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("JSON Preview", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("Updates as you edit", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(16)
            .background(theme.secondaryBackground)

            GeometryReader { geo in
                ScrollView {
                    CodeBlockView(
                        code: prettyJSON,
                        language: "json",
                        baseWidth: max(geo.size.width - 24, 300)
                    )
                    .padding(12)
                }
            }
            .background(theme.primaryBackground)
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isCollapsed { collapsedSections.remove(title) } else { collapsedSections.insert(title) }
                }
            }) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .textCase(.uppercase)
                    if isCollapsed, let count = itemCount {
                        Text("\(count)", bundle: .module)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
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
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(
                mono
                    ? .system(size: fontSize, weight: weight, design: .monospaced)
                    : .system(size: fontSize, weight: weight)
            )
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, fontSize > 13 ? 8 : 6)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(theme.inputBackground)
                    .overlay(RoundedRectangle(cornerRadius: radius).stroke(theme.inputBorder, lineWidth: 1))
            )
    }

    func codeField(text: Binding<String>, placeholder: String, minHeight: CGFloat = 40) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.tertiaryText.opacity(0.5))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.codeBlockBackground)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.inputBorder, lineWidth: 1))
        )
    }

    func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
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
                            .font(.system(size: 12))
                            .foregroundColor(theme.errorColor.opacity(0.7))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            Button(action: { binding.wrappedValue.append("") }) { Label { Text("Add", bundle: .module) } icon: { Image(systemName: "plus") } }
                .buttonStyle(.bordered)
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
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: weight, design: .monospaced))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.inputBackground)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.inputBorder, lineWidth: 1))
            )
            .focused($isFocused)
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
