//
//  WorkflowModelSlotPicker.swift
//  osaurus
//
//  The model a workflow slot runs on: a searchable list of the models that
//  can run the slot, grouped by where they run, with the workflow's own
//  choice first.
//

import SwiftUI

struct WorkflowModelSlotPicker: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var pickerCache = ModelPickerItemCache.shared

    let requirement: ModelRequirement
    let bound: String?
    /// The field's text for a bound model.
    var boundLabel: (String) -> String = { WorkflowModelChoices.displayName($0) }
    let onPick: (String?) -> Void

    private var unboundLabel: String {
        WorkflowModelChoices.suggested(requirement).map {
            L("Workflow's choice (\(WorkflowModelChoices.displayName($0)))")
        } ?? L("Default model")
    }

    var body: some View {
        let choices = WorkflowModelChoices.choices(for: requirement)
        VStack(alignment: .leading, spacing: theme.space.s6) {
            ModelSearchablePicker(
                items: choices.usable,
                selection: Binding(get: { bound }, set: { onPick($0) }),
                noneTitle: unboundLabel,
                label: boundLabel
            )
            if choices.hidden > 0 {
                Text(
                    verbatim: choices.hidden == 1
                        ? L("1 model hidden: it can't enforce structured output or doesn't fit this slot.")
                        : L("\(choices.hidden) models hidden: they can't enforce structured output or don't fit this slot.")
                )
                .textStyle(.caption)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .help(hiddenDetail)
            }
        }
        .onAppear { if !pickerCache.isLoaded { pickerCache.prewarm() } }
    }

    /// The hidden models by reason, for the caption's tooltip.
    private var hiddenDetail: String {
        WorkflowModelChoices.unusable(for: requirement)
            .map { group in "\(group.reason): \(group.items.map(\.displayName).joined(separator: ", "))" }
            .joined(separator: "\n")
    }
}
