//
//  WorkflowInputBindingEditor.swift
//  osaurus
//
//  "Inputs" for an automation that runs a workflow: one row per input the
//  workflow declares (title, Required, description), each bound to a value
//  from the trigger, a custom template, or a fixed value, with a preview
//  of what a sample run passes.
//

import SwiftUI

struct WorkflowInputBindingEditor: View {
    @Environment(\.theme) private var theme

    let fields: [DialogField]
    let schema: JSONValue
    let triggerValues: [EventTriggerValue]
    let samplePayload: JSONValue
    @Binding var mapping: [String: String]

    /// Rows switched to "Custom template" / "Fixed value" before any text
    /// is typed.
    @State private var editingKinds: [String: WorkflowInputBinding.Kind] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Inputs", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(
                    fields.count == 1 ? L("1 input") : L("\(fields.count) inputs")
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                Spacer()
            }
            VStack(spacing: 0) {
                ForEach(Array(fields.enumerated()), id: \.element.key) { index, field in
                    if index > 0 { Divider().opacity(0.5) }
                    row(field)
                }
            }
            .background(theme.surface.raised)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: theme.stroke.default))
            .settingsLandingAnchor("automations.workflowInputs")

            Text(
                "Previews use a sample run. An input left empty gets no value; a required one must be filled in.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func kind(_ field: DialogField) -> WorkflowInputBinding.Kind {
        if let editing = editingKinds[field.key] { return editing }
        let stored = WorkflowInputBinding.kind(of: mapping[field.key])
        // A binding to a path the trigger does not list (a body field
        // without a sample) is still editable as text.
        if case .triggerValue(let path) = stored, !triggerValues.contains(where: { $0.path == path }) {
            return .template
        }
        return stored
    }

    private func row(_ field: DialogField) -> some View {
        let current = kind(field)
        let missing = field.required && WorkflowInputBinding.kind(of: mapping[field.key]) == .unset
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: field.label)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                if field.required {
                    StatusChip(L("Required"), tone: missing ? .warning : .neutral)
                }
                Text(verbatim: field.key)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                Spacer(minLength: 8)
                bindMenu(field, current: current)
            }
            if let help = field.help, !help.isEmpty {
                Text(verbatim: help)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            valueEditor(field, kind: current)
            if let preview = WorkflowInputBinding.preview(
                field: field.key, mapping: mapping, payload: samplePayload, schema: schema)
            {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "eye")
                        .glyphSize(9)
                    Text(preview.isEmpty ? L("Sample run: (empty)") : L("Sample run: \(preview)"))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            } else if missing {
                Text("Choose a value: the workflow needs it.", bundle: .module)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.status.warning.foreground)
            }
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }

    @ViewBuilder
    private func valueEditor(_ field: DialogField, kind: WorkflowInputBinding.Kind) -> some View {
        switch kind {
        case .unset:
            EmptyView()
        case .triggerValue(let path):
            let value = triggerValues.first { $0.path == path }
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .glyphSize(9)
                    .foregroundColor(theme.text.link)
                Text(verbatim: value?.label ?? path)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.primary)
                Text(verbatim: "{{\(path)}}")
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s4)
            .settingsChrome(.selected)
        case .template, .fixed:
            SettingsTextField(
                placeholder: kind == .fixed
                    ? placeholder(for: field) : L("e.g. New issue: {{webhook.body.issue.title}}"),
                text: Binding(
                    get: { mapping[field.key] ?? "" },
                    set: { mapping[field.key] = $0.isEmpty ? nil : $0 }),
                icon: kind == .fixed ? "textformat" : "curlybraces")
        }
    }

    private func placeholder(for field: DialogField) -> String {
        if let options = field.options, !options.isEmpty { return options.joined(separator: " / ") }
        switch field.type {
        case .number: return L("A number")
        case .bool: return L("true or false")
        case .longText: return L("Text or JSON")
        default: return L("A fixed value")
        }
    }

    private func bindMenu(_ field: DialogField, current: WorkflowInputBinding.Kind) -> some View {
        SettingsActionMenu(accessibilityLabel: L("Input source")) {
            Section(L("From the trigger")) {
                ForEach(triggerValues) { value in
                    Button {
                        editingKinds[field.key] = nil
                        mapping[field.key] = value.template
                    } label: {
                        let checked = current == .triggerValue(value.path)
                        let title = value.example.map { "\(value.label) — \(Self.short($0))" } ?? value.label
                        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
            Divider()
            Button(L("Custom template…")) {
                // Keeps what is there: a trigger value becomes editable text.
                editingKinds[field.key] = .template
            }
            Button(L("Fixed value…")) {
                editingKinds[field.key] = .fixed
                if WorkflowInputBinding.kind(of: mapping[field.key]) != .fixed { mapping[field.key] = nil }
                if mapping[field.key] == nil, let first = field.options?.first { mapping[field.key] = first }
            }
            if !field.required {
                Divider()
                Button(L("Leave empty")) {
                    editingKinds[field.key] = nil
                    mapping[field.key] = nil
                }
            }
        } label: {
            Text(menuTitle(current))
        }
        .fixedSize()
    }

    private func menuTitle(_ kind: WorkflowInputBinding.Kind) -> String {
        switch kind {
        case .unset: L("Bind to…")
        case .triggerValue: L("Trigger value")
        case .template: L("Custom template")
        case .fixed: L("Fixed value")
        }
    }

    static func short(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 32 ? String(oneLine.prefix(31)) + "…" : oneLine
    }
}

/// "Insert a value" for agent instructions: the same trigger values, as
/// `{{…}}` appended to the text.
struct EventTriggerValueInsertMenu: View {
    @Environment(\.theme) private var theme

    let values: [EventTriggerValue]
    let onInsert: (String) -> Void

    var body: some View {
        SettingsMenuButton(.tertiary, "Insert a value from the trigger", icon: "curlybraces", size: .compact) {
            ForEach(values) { value in
                Button {
                    onInsert(value.template)
                } label: {
                    Text(value.example.map { "\(value.label) — \(WorkflowInputBindingEditor.short($0))" } ?? value.label)
                }
            }
        }
    }
}
