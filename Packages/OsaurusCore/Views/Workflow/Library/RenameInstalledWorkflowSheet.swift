//
//  RenameInstalledWorkflowSheet.swift
//  osaurus
//
//  Workflows → a workflow's Rename…: the name Settings shows and the one
//  agents and the Orchestrator call (`workflow_<slug>`). Shows the tool
//  name before and after, the numbered name a taken name becomes, and the
//  workflows that call this one as a step (they keep working, since the
//  old name still resolves).
//

import SwiftUI

struct RenameInstalledWorkflowSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = InstalledWorkflowStore.shared

    let workflowID: UUID
    let onDone: () -> Void

    @State private var name = ""
    @State private var errorMessage: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let workflow = store.workflow(id: workflowID)
        VStack(spacing: theme.space.s0) {
            SettingsSheetHeader(
                icon: "pencil",
                title: "Rename Workflow",
                subtitleText: workflow?.name ?? "",
                onClose: onDone
            )
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    SettingsFieldLabel("Workflow Name")
                    SettingsTextField(
                        placeholder: L("e.g., Client Intake"),
                        text: $name,
                        icon: "textformat",
                        autofocus: true
                    )
                    if let workflow {
                        details(workflow)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(SettingsFont.rowDescription).foregroundColor(
                            theme.status.error.foreground
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(theme.space.s24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: "Rename",
                    isEnabled: workflow != nil && !trimmed.isEmpty && trimmed != workflow?.name,
                    handler: rename
                ),
                secondary: SettingsSheetFooter.Action(label: "Cancel", handler: onDone),
                hint: nil
            )
        }
        .fittedSheetFrame(width: 480, height: 340)
        .settingsSheetSurface()
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge).stroke(
                theme.border.subtle,
                lineWidth: theme.stroke.default
            )
        )
        .onAppear { if name.isEmpty { name = workflow?.name ?? "" } }
    }

    @ViewBuilder
    private func details(_ workflow: InstalledWorkflow) -> some View {
        let next = store.renamedName(for: trimmed, id: workflow.id)
        VStack(alignment: .leading, spacing: theme.space.s6) {
            if let next, next != workflow.name {
                if next != trimmed {
                    note(L("Another workflow or tool already uses “\(trimmed)”, so it will be named “\(next)”."))
                }
                note(
                    L(
                        "Agents and the Orchestrator will call it \(InstalledWorkflow.toolName(for: next)) instead of \(workflow.toolName)."
                    )
                )
            } else {
                note(L("Agents and the Orchestrator call it \(workflow.toolName)."))
            }
            let pinned = workflow.template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pinned.isEmpty, pinned != workflow.name, pinned != trimmed {
                HStack(spacing: theme.space.s6) {
                    note(L("Version \(workflow.templateVersion) is named “\(pinned)”"))
                    SettingsButton(.tertiary, L("Use “\(pinned)”"), size: .compact, verbatim: true) { name = pinned }
                }
            }
            let callers = Self.callers(of: workflow, in: store)
            if !callers.isEmpty {
                note(
                    L(
                        "\(WorkflowSummary.list(callers.map(\.name))) run this as a step. Those steps keep working under the old name."
                    )
                )
            }
        }
        .padding(.top, theme.space.s4)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Other installed workflows with a step that runs `workflow`.
    @MainActor
    static func callers(of workflow: InstalledWorkflow, in store: InstalledWorkflowStore) -> [InstalledWorkflow] {
        store.workflows.filter { other in
            other.id != workflow.id
                && other.definition.subworkflowNames.contains { store.workflow(named: $0)?.id == workflow.id }
        }
    }

    private func rename() {
        do {
            let renamed = try store.rename(id: workflowID, to: trimmed)
            _ = ToastManager.shared.success(L("Renamed to \(renamed.name)"))
            onDone()
        } catch {
            errorMessage = WorkflowErrorText.text(error)
        }
    }
}
