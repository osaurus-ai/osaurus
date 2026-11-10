//
//  SavedAnswersSection.swift
//  osaurus
//
//  Remembered dialog answers for one installed workflow, with edit and
//  clear. Shared by the workflow settings page and the setup wizard.
//

import SwiftUI

struct SavedAnswersSection: View {
    let workflowID: UUID
    let definition: WorkflowDefinition

    @ObservedObject private var store = SavedAnswersStore.shared
    @State private var editing: String?
    @State private var draft: [String: JSONValue] = [:]

    @Environment(\.theme) private var theme

    private struct Entry: Identifiable {
        let nodeID: String
        let field: DialogField
        var id: String { SavedAnswersStore.key(nodeID: nodeID, fieldKey: field.key) }
    }

    /// Every remembered or prefill-last field the workflow asks for, with
    /// the node that asks it.
    private var rememberedFields: [Entry] {
        definition.nodes.flatMap { node -> [Entry] in
            guard case .dialog(let spec) = node.kind else { return [] }
            return spec.fields.compactMap { field in
                switch field.persistence {
                case .remember, .alwaysAsk(prefillLast: true): return Entry(nodeID: node.id, field: field)
                case .alwaysAsk(prefillLast: false): return nil
                }
            }
        }
    }

    var body: some View {
        if !rememberedFields.isEmpty { section }
    }

    /// Nothing renders for a workflow that remembers no answers.
    private var section: some View {
        let _ = store.revision
        let saved = Dictionary(uniqueKeysWithValues: store.all(workflowID: workflowID).map { ($0.id, $0) })
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved Answers", bundle: .module)
                    .textStyle(.body, weight: 600)
                    .foregroundColor(theme.text.primary)
                Spacer()
                if !saved.isEmpty {
                    Button {
                        store.clearAll(workflowID: workflowID)
                    } label: {
                        Text("Clear All", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary)
                }
            }
            Text(
                "Answers remembered on this Mac. Every agent that calls this workflow uses them; they are never exported.",
                bundle: .module
            )
            .textStyle(.caption)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            if rememberedFields.isEmpty {
                Text("This workflow does not remember any answers.", bundle: .module)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                    .padding(.vertical, theme.space.s6)
            } else {
                ForEach(rememberedFields, id: \.id) { entry in
                    row(entry.nodeID, entry.field, saved: saved[entry.id])
                }
            }
        }
        .settingsLandingAnchor("workflows.savedAnswers")
    }

    private func saveEdit(_ nodeID: String, _ field: DialogField) {
        let cleaned = DialogCoordinator.normalize(draft, fields: [field])
        if let value = cleaned[field.key] {
            store.save(workflowID: workflowID, nodeID: nodeID, field: field, value: value)
        }
        editing = nil
    }

    @ViewBuilder
    private func row(_ nodeID: String, _ field: DialogField, saved: SavedAnswer?) -> some View {
        let entryID = SavedAnswersStore.key(nodeID: nodeID, fieldKey: field.key)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                        .textStyle(.body, weight: 500)
                        .foregroundColor(theme.text.primary)
                    Text(preview(field, saved: saved))
                        .textStyle(.caption)
                        .foregroundColor(saved == nil ? theme.text.tertiary : theme.text.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if editing != entryID {
                    Button {
                        draft = [field.key: saved == nil || field.type == .secret
                            ? (field.defaultValue ?? .string(""))
                            : (store.value(workflowID: workflowID, nodeID: nodeID, fieldKey: field.key) ?? .string(""))]
                        editing = entryID
                    } label: {
                        Text(saved == nil ? "Set" : "Edit", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary)
                    if saved != nil {
                        Button {
                            store.clear(workflowID: workflowID, nodeID: nodeID, fieldKey: field.key)
                        } label: {
                            Text("Clear", bundle: .module)
                        }
                        .assignedSettingsButtonStyle(.secondary)
                    }
                }
            }
            if editing == entryID {
                WorkflowFormView(fields: [field], values: $draft, onSubmit: { saveEdit(nodeID, field) })
                HStack {
                    Spacer()
                    Button {
                        editing = nil
                    } label: {
                        Text("Cancel", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary)
                    Button {
                        saveEdit(nodeID, field)
                    } label: {
                        Text("Save", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.primary)
                }
            }
        }
        .padding(theme.space.s12)
        .settingsChrome(.inset)
    }

    private func preview(_ field: DialogField, saved: SavedAnswer?) -> String {
        guard let saved else { return L("Not saved yet") }
        if saved.isSecret { return L("Stored in Keychain") }
        return WorkflowFormFields.text(saved.value)
    }
}
