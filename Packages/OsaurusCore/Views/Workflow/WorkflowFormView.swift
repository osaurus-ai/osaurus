//
//  WorkflowFormView.swift
//  osaurus
//
//  One form for dialog nodes and for a workflow's input. Dialog fields
//  render as declared; input schemas are turned into fields first
//  (`WorkflowFormFields.fields(fromInputSchema:)`), and the entered
//  values are turned back into typed JSON with `inputValue(_:fields:)`.
//

import AppKit
import SwiftUI

enum WorkflowFormFields {

    /// Top-level schema properties as form fields. Nested objects and
    /// arrays are entered as JSON text.
    static func fields(fromInputSchema schema: JSONValue) -> [DialogField] {
        guard let obj = schema.objectValue, let props = obj["properties"]?.objectValue else { return [] }
        let required = Set(obj["required"]?.arrayStrings ?? [])
        return WorkflowDraftPatcher.fieldOrder(schema).compactMap { key -> DialogField? in
            guard let prop = props[key]?.objectValue else { return nil }
            let label = prop["title"]?.stringValue ?? humanized(key)
            let help = prop["description"]?.stringValue
            let types = typeNames(prop)
            let type: DialogFieldType
            var options: [String]?
            if let list = prop["enum"]?.arrayStrings, !list.isEmpty {
                type = .choice
                options = list
            } else if types.contains("number") || types.contains("integer") {
                type = .number
            } else if types.contains("boolean") {
                type = .bool
            } else if types.contains("object") || types.contains("array") {
                type = .longText
            } else if prop["format"]?.stringValue == "date" {
                type = .date
            } else if prop["format"]?.stringValue == "folder" {
                type = .folder
            } else if prop["format"]?.stringValue == "file" {
                type = .file
            } else {
                type = isLongText(prop, help: help) ? .longText : .text
            }
            return DialogField(
                key: key, label: label, type: type, required: required.contains(key),
                defaultValue: prop["default"], options: options, help: help)
        }
    }

    /// Typed input for a schema-derived form: numbers parsed, JSON fields
    /// decoded, empty optionals dropped.
    static func inputValue(_ values: [String: JSONValue], fields: [DialogField], schema: JSONValue) -> JSONValue {
        let props = schema.objectValue?["properties"]?.objectValue ?? [:]
        var out: [String: JSONValue] = [:]
        for field in fields {
            guard var value = values[field.key] else { continue }
            if case .string(let raw) = value {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty, !field.required { continue }
                let types = props[field.key].map(typeNames) ?? []
                if types.contains("integer"), let n = Int(text) {
                    value = .number(Double(n))
                } else if field.type == .number, let n = Double(text) {
                    value = .number(n)
                } else if types.contains("object") || types.contains("array"), let parsed = JSONValue.parse(text) {
                    value = parsed
                }
            }
            out[field.key] = value
        }
        return .object(out)
    }

    static func initialValues(_ fields: [DialogField], prefill: [String: JSONValue]) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for field in fields {
            if let v = prefill[field.key] ?? field.defaultValue {
                values[field.key] = v
            } else if field.type == .bool {
                values[field.key] = .bool(false)
            }
        }
        return values
    }

    private static func typeNames(_ prop: [String: JSONValue]) -> [String] {
        switch prop["type"] {
        case .string(let t)?: return [t]
        case .array(let list)?: return list.compactMap(\.stringValue)
        default: return []
        }
    }

    private static func typeNames(_ prop: JSONValue) -> [String] {
        prop.objectValue.map(typeNames) ?? []
    }

    /// A string meant to hold several lines: declared long or multiline, or
    /// described as one item per line.
    private static func isLongText(_ prop: [String: JSONValue], help: String?) -> Bool {
        if (prop["maxLength"].flatMap(numberValue) ?? 0) > 200 { return true }
        if let format = prop["format"]?.stringValue, ["textarea", "multiline", "long_text"].contains(format) {
            return true
        }
        let described = help?.lowercased() ?? ""
        return described.contains("per line") || described.contains("multiple lines")
    }

    private static func numberValue(_ v: JSONValue) -> Double? {
        if case .number(let n) = v { return n }
        return nil
    }

    static func humanized(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// The text a value shows in a text-like control.
    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s)?: return s
        case .number?: return BindingRenderer.textValue(value!)
        case nil, .null?: return ""
        case let other?: return other.prettyJSONString
        }
    }
}

struct WorkflowFormView: View {
    let fields: [DialogField]
    @Binding var values: [String: JSONValue]
    /// Field key -> problem, shown under the field.
    var issues: [String: String] = [:]
    /// Return in a single-line field. Return in a long field adds a line.
    var onSubmit: (() -> Void)?
    /// File or folder field key -> what the workflow does with what's
    /// picked (`WorkflowAccessScope.inputCaptions`).
    var accessCaptions: [String: String] = [:]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s16 + theme.space.s4) {
            ForEach(fields) { field in
                if field.type == .bool {
                    switchField(field)
                } else {
                    VStack(alignment: .leading, spacing: theme.space.s6) {
                        header(field)
                        control(for: field)
                            .settingsFieldAccessibility(field.label, help: issues[field.key] ?? field.help)
                        caption(field)
                        accessCaption(field)
                    }
                }
            }
        }
    }

    /// What the workflow does with the picked file or folder.
    @ViewBuilder
    private func accessCaption(_ field: DialogField) -> some View {
        if field.type == .file || field.type == .folder, let text = accessCaptions[field.key] {
            Label {
                Text(verbatim: text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: WorkflowAccessScope.Place.mac.systemImage)
            }
            .textStyle(.caption)
            .foregroundColor(theme.text.secondary)
        }
    }

    /// The label, and Optional beside it. Required is the norm, so it goes
    /// unmarked.
    private func header(_ field: DialogField) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
            SettingsFieldLabel(verbatim: field.label)
            if !field.required, field.type != .bool {
                Text("Optional", bundle: .module)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.tertiary)
            }
            if field.persistence == .remember {
                Spacer(minLength: theme.space.s8)
                Label {
                    Text("Remembered on this Mac", bundle: .module)
                } icon: {
                    Image(systemName: "pin")
                }
                .textStyle(.caption)
                .foregroundColor(theme.text.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The field's problem, else its help.
    @ViewBuilder
    private func caption(_ field: DialogField) -> some View {
        if let issue = issues[field.key] {
            Text(verbatim: issue)
                .textStyle(.caption)
                .foregroundColor(theme.statusInk(.error))
                .fixedSize(horizontal: false, vertical: true)
        } else if let help = field.help, !help.isEmpty {
            Text(verbatim: help)
                .textStyle(.caption)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A yes/no field is one row: what it means on the left, the switch on
    /// the right.
    private func switchField(_ field: DialogField) -> some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                header(field)
                caption(field)
            }
            Spacer(minLength: theme.space.s12)
            Toggle(
                isOn: Binding(
                    get: { values[field.key] == .bool(true) },
                    set: { values[field.key] = .bool($0) })
            ) {
                Text(verbatim: field.label)
            }
            .settingsSwitch()
        }
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { WorkflowFormFields.text(values[key]) },
            set: { values[key] = .string($0) })
    }

    /// A few short options sit side by side; longer lists open a menu.
    static func choicesFitSideBySide(_ options: [String]) -> Bool {
        (2...4).contains(options.count) && options.allSatisfy { $0.count <= 14 }
    }

    @ViewBuilder
    private func control(for field: DialogField) -> some View {
        let invalid = issues[field.key] != nil
        switch field.type {
        case .text, .longText:
            // A value with line breaks (an example, a remembered answer)
            // needs room for them even when the field was declared short.
            // A text view, not a vertical `TextField`: that one lays its whole
            // value out on every measure, so a drafted post hangs the card.
            if field.type == .longText || WorkflowFormFields.text(values[field.key]).contains("\n") {
                let line = theme.lineHeight(.bodySmall)
                SettingsTextEditor(
                    text: textBinding(field.key), minHeight: line * 3, maxHeight: line * 8, isInvalid: invalid)
            } else {
                SettingsTextField(placeholder: "", text: textBinding(field.key), isInvalid: invalid, onSubmit: onSubmit)
            }
        case .number:
            SettingsTextField(
                placeholder: "0", text: textBinding(field.key), monospaced: true, isInvalid: invalid, onSubmit: onSubmit)
                .frame(maxWidth: 200, alignment: .leading)
        case .secret:
            SettingsTextField(
                placeholder: "", text: textBinding(field.key), icon: "key", monospaced: true, isSecure: true,
                revealable: true, isInvalid: invalid, onSubmit: onSubmit)
        case .bool:
            EmptyView()
        case .choice:
            choice(field)
        case .date:
            SettingsDatePicker(
                label: LocalizedStringKey(field.label),
                selection: Binding(
                    get: { Self.dateFormatter.date(from: values[field.key]?.stringValue ?? "") ?? Date() },
                    set: { values[field.key] = .string(Self.dateFormatter.string(from: $0)) })
            )
            .onAppear {
                if values[field.key] == nil { values[field.key] = .string(Self.dateFormatter.string(from: Date())) }
            }
        case .file, .folder:
            WorkflowPathField(
                isFolder: field.type == .folder, path: textBinding(field.key), isInvalid: invalid,
                label: field.label)
        }
    }

    @ViewBuilder
    private func choice(_ field: DialogField) -> some View {
        let options = field.options ?? []
        let selection = Binding(
            get: { values[field.key]?.stringValue ?? "" },
            set: { values[field.key] = .string($0) })
        if field.required, Self.choicesFitSideBySide(options) {
            AssignedBaseSegmentedPicker(
                selection: selection, options: options.map { .init($0, $0, verbatim: true) }, size: .compact,
                minimumOptionWidth: theme.space.s64)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: field.label))
        } else {
            SettingsMenuPicker(selection: selection) {
                if !field.required || values[field.key] == nil {
                    Text("Choose…", bundle: .module).tag("")
                }
                ForEach(options, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .fixedSize()
            .accessibilityLabel(Text(verbatim: field.label))
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// A file or folder input: what's chosen (name over its folder), Choose…,
/// and a drop target. Paths are picked, not typed.
struct WorkflowPathField: View {
    @Environment(\.theme) private var theme
    let isFolder: Bool
    @Binding var path: String
    var isInvalid = false
    let label: String

    @State private var isDropTarget = false
    @State private var isHovered = false

    private var url: URL? { path.isEmpty ? nil : URL(fileURLWithPath: path) }

    var body: some View {
        HStack(spacing: theme.space.s12) {
            Image(systemName: isFolder ? "folder" : "doc")
                .symbolVariant(url == nil ? .none : .fill)
                .font(SettingsFont.glyph)
                .foregroundStyle(url == nil ? theme.text.tertiary : theme.text.secondary)
                .accessibilityHidden(true)
            if let url {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(verbatim: url.lastPathComponent)
                        .textStyle(.bodySmall, weight: 500)
                        .foregroundStyle(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .textStyle(.caption)
                        .foregroundStyle(theme.text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .help(path)
            } else {
                Text(isFolder ? "Choose a folder, or drop one here" : "Choose a file, or drop one here", bundle: .module)
                    .textStyle(.bodySmall)
                    .foregroundStyle(theme.text.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: theme.space.s8)
            if url != nil {
                SettingsIconButton("xmark", help: L("Clear"), size: .compact) { path = "" }
            }
            SettingsButton(.secondary, "Choose…", size: .compact, action: choose)
        }
        .padding(.leading, theme.settingsFieldInset)
        .padding(.trailing, theme.space.s6)
        .padding(.vertical, theme.space.s6)
        .frame(minHeight: theme.controlSize.defaultHeight)
        .settingsInputChrome(isInvalid: isInvalid, isHovered: isHovered, isHighlighted: isDropTarget)
        .onHover { isHovered = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            guard let dropped = urls.first(where: accepts) else { return false }
            path = dropped.path
            return true
        } isTargeted: { isDropTarget = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: url?.lastPathComponent ?? L("None chosen")))
    }

    private func accepts(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue == isFolder
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !isFolder
        panel.canChooseDirectories = isFolder
        panel.allowsMultipleSelection = false
        if let url { panel.directoryURL = url.deletingLastPathComponent() }
        if panel.runModal() == .OK, let chosen = panel.url {
            path = chosen.path
        }
    }
}

/// A dialog node rendered in the same card a chat shows, for the Architect
/// sidebar. Bindings in the message stay unrendered; answers go nowhere.
struct WorkflowDialogPreview: View {
    let title: String
    let message: String
    let fields: [DialogField]
    var workflowName = ""

    @State private var values: [String: JSONValue] = [:]

    var body: some View {
        PromptCard(
            pillIcon: "flowchart",
            pillLabel: "Workflow needs input",
            title: title,
            descriptionMarkdown: message.isEmpty ? nil : message,
            footnote: workflowName.isEmpty
                ? nil
                : PromptCardFootnote(icon: "flowchart", text: "From \(workflowName)"),
            onCancel: {}
        ) {
            WorkflowFormView(fields: fields, values: $values)
                .frame(maxWidth: .infinity, alignment: .leading)
        } inputRow: {
            HStack {
                Spacer()
                Button {} label: { Text("Continue", bundle: .module) }
                    .assignedSettingsButtonStyle(.primary)
                    .disabled(true)
            }
        }
        .onAppear { values = WorkflowFormFields.initialValues(fields, prefill: [:]) }
        .onChange(of: fields) { _, updated in values = WorkflowFormFields.initialValues(updated, prefill: [:]) }
    }
}

/// The values being entered for a pending dialog, and the problems the last
/// answer came back with. Held outside the views so the fields and the
/// Continue button can sit in different parts of a card.
@MainActor
final class WorkflowDialogAnswer: ObservableObject {
    let dialog: PendingDialog
    @Published var values: [String: JSONValue] {
        didSet { DialogCoordinator.shared.saveDraft(for: dialog, values: values) }
    }
    @Published private(set) var issues: [String: String] = [:]
    @Published private(set) var generalIssue: String?

    init(dialog: PendingDialog) {
        self.dialog = dialog
        self.values = WorkflowFormFields.initialValues(dialog.fields, prefill: dialog.prefill)
    }

    /// True when the coordinator accepted the answer.
    func submit() -> Bool {
        issues = [:]
        generalIssue = nil
        switch DialogCoordinator.shared.answer(dialog.id, values: values) {
        case .success:
            return true
        case .failure(.invalid(let problems)):
            var byField: [String: String] = [:]
            var other: [String] = []
            for problem in problems {
                if let field = dialog.fields.first(where: { problem.hasPrefix("$.\($0.key)") }) {
                    byField[field.key] = String(problem.drop(while: { $0 != ":" }).dropFirst())
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    other.append(problem)
                }
            }
            issues = byField
            generalIssue = other.isEmpty ? nil : other.joined(separator: "; ")
        case .failure(let error):
            generalIssue = WorkflowErrorText.text(error)
        }
        return false
    }
}

/// A pending dialog as a card body: the form with its Continue button
/// beneath. The workflow tab uses it; the chat card splits the two parts.
struct WorkflowDialogForm: View {
    var onAnswered: () -> Void = {}

    @StateObject private var answer: WorkflowDialogAnswer

    @Environment(\.theme) private var theme

    init(dialog: PendingDialog, onAnswered: @escaping () -> Void = {}) {
        self.onAnswered = onAnswered
        _answer = StateObject(wrappedValue: WorkflowDialogAnswer(dialog: dialog))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            WorkflowDialogFields(answer: answer, onAnswered: onAnswered)
            HStack {
                Spacer()
                WorkflowDialogContinueButton(answer: answer, onAnswered: onAnswered)
            }
        }
    }
}

/// The dialog's fields and any problem not tied to one field.
struct WorkflowDialogFields: View {
    @ObservedObject var answer: WorkflowDialogAnswer
    var onAnswered: () -> Void = {}

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            WorkflowFormView(
                fields: answer.dialog.fields, values: $answer.values, issues: answer.issues,
                onSubmit: { if answer.submit() { onAnswered() } })
            if let generalIssue = answer.generalIssue {
                Text(generalIssue)
                    .textStyle(.footnote)
                    .foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkflowDialogContinueButton: View {
    @ObservedObject var answer: WorkflowDialogAnswer
    var onAnswered: () -> Void = {}

    var body: some View {
        Button {
            if answer.submit() { onAnswered() }
        } label: {
            Text("Continue", bundle: .module)
        }
        .assignedSettingsButtonStyle(.primary)
        .keyboardShortcut(.defaultAction)
    }
}
