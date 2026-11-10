//
//  WorkflowStarterPreviewSheet.swift
//  osaurus
//
//  A starter before it is added: the form you will fill in (with its
//  example), the steps, what you get back, and what it needs. Add to My
//  Workflows installs straight away when nothing needs setting up, and
//  walks through the setup wizard otherwise.
//

import SwiftUI

struct WorkflowStarterPreviewSheet: View {
    let template: Template
    let onClose: () -> Void
    let onAdded: (InstalledWorkflow) -> Void

    @Environment(\.theme) private var theme
    @State private var values: [String: JSONValue] = [:]
    @State private var wizard: WorkflowSetupSubject?
    @State private var failure: String?

    /// What adding would ask for, with the bindings it would start from.
    /// A missing shared key counts: the wizard asks for it even though it
    /// may be skipped there.
    static func blockers(_ template: Template) -> [SetupItem] {
        SetupChecker.check(template, bindings: startingBindings(template), subjectId: template.id, secrets: .caller(nil))
            .blocking
    }

    /// Servers this Mac already has under other names, bound up front.
    static func startingBindings(_ template: Template) -> InstallBindings {
        MCPServerResolution.liveAutoBindings(for: template, bindings: InstallBindings())
    }

    /// Installs without the wizard when nothing blocks; nil means the
    /// wizard has to collect something first.
    static func addDirectly(_ template: Template) throws -> InstalledWorkflow? {
        guard blockers(template).isEmpty else { return nil }
        var subject = WorkflowSetupSubject.install(template)
        subject.bindings = MCPServerResolution.liveAutoBindings(for: template, bindings: subject.bindings)
        return try WorkflowSetupWizardView.commit(subject)
    }

    /// Preferred models that are not here; the slot runs on the default
    /// model until the user gets one.
    static func missingPreferredModels(_ template: Template) -> [(slot: ModelRequirement, plan: WorkflowModelResolution.Plan)] {
        template.requirements.models.compactMap { slot in
            guard slot.strictness != .always else { return nil }
            let plan = WorkflowModelResolution.livePlan(for: WorkflowModelChoices.suggested(slot))
            switch plan {
            case .none, .ready: return nil
            default: return (slot, plan)
            }
        }
    }

    private var def: WorkflowDefinition { template.workflow ?? WorkflowDefinition() }
    private var fields: [DialogField] { WorkflowFormFields.fields(fromInputSchema: def.inputSchema) }

    var body: some View {
        if let wizard {
            WorkflowSetupWizardView(subject: wizard, onClose: onClose, onFinished: onAdded)
        } else {
            preview
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    section(L("You fill in")) {
                        if fields.isEmpty {
                            note(L("Nothing. It runs as is."))
                        } else {
                            WorkflowFormView(
                                fields: fields, values: $values,
                                accessCaptions: WorkflowAccessScope.derive(def).inputCaptions)
                                .disabled(true)
                            if !def.examples.isEmpty {
                                note(L("Filled in with an example. You can change everything before it runs."))
                            }
                        }
                    }
                    section(L("What it does")) {
                        ForEach(Array(WorkflowSummary.steps(def).enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: "\(index + 1).")
                                    .foregroundColor(theme.text.tertiary)
                                    .textStyle(.body)
                                VStack(alignment: .leading, spacing: theme.space.s2) {
                                    Text(verbatim: step.name)
                                        .textStyle(.body)
                                        .foregroundColor(theme.text.primary)
                                    Text(verbatim: step.kind)
                                        .textStyle(.caption)
                                        .foregroundColor(theme.text.secondary)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    let outputs = WorkflowSummary.outputs(def)
                    if !outputs.isEmpty {
                        section(L("You get")) {
                            Text(verbatim: WorkflowSummary.list(outputs))
                                .textStyle(.body)
                                .foregroundColor(theme.text.primary)
                        }
                    }
                    section(L("Your files")) {
                        WorkflowAccessLine(scope: WorkflowAccessScope.derive(def))
                    }
                    section(L("Before it runs")) {
                        let blockers = Self.blockers(template)
                        let missing = Self.missingPreferredModels(template)
                        ForEach(missing, id: \.slot.slot) { entry in
                            Label {
                                Text(verbatim: Self.advisory(entry.plan))
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "info.circle").foregroundColor(theme.status.info.foreground)
                            }
                            .textStyle(.caption)
                            .foregroundColor(theme.text.secondary)
                        }
                        if blockers.isEmpty && missing.isEmpty {
                            note(L("Nothing to set up. It works with what this Mac already has."))
                        } else {
                            ForEach(blockers) { item in
                                Label {
                                    Text(verbatim: item.detail.isEmpty ? item.title : item.detail)
                                        .fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: "exclamationmark.circle").foregroundColor(
                                        theme.status.warning.foreground
                                    )
                                }
                                .textStyle(.caption)
                                .foregroundColor(theme.text.secondary)
                            }
                        }
                    }
                }
                .padding(theme.settingsSheetInset)
            }
            SettingsSheetFooter(
                primary: .init(label: "Add Workflow", handler: add),
                secondary: .init(label: "Cancel", handler: onClose),
                warning: failure
            )
        }
        .fittedSheetFrame(width: 520, height: 600)
        .background(theme.surface.canvas)
        .onAppear {
            values = WorkflowFormFields.initialValues(
                fields, prefill: def.examples.first?.input.objectValue ?? [:])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: template.name)
                .font(SettingsFont.detailTitle)
                .foregroundColor(theme.text.primary)
            if let summary = template.summary, !summary.isEmpty {
                Text(verbatim: summary)
                    .textStyle(.body)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WorkflowRequirementChips(template: template)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .textStyle(.caption, weight: 600)
                .foregroundColor(theme.text.secondary)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .textStyle(.caption)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func advisory(_ plan: WorkflowModelResolution.Plan) -> String {
        switch plan {
        case .download(let repo):
            return L("Suggests \(WorkflowModelChoices.displayName(repo)), which isn't downloaded. Setup can download it; until then it uses your default model.")
        case .connectProvider(let preset, let model):
            return L("Suggests \(model) on \(preset.name), which isn't connected. Setup can connect it; until then it uses your default model.")
        case .unavailable(let id):
            return L("Suggests \(id), which isn't on this Mac. It uses your default model.")
        case .none, .ready:
            return ""
        }
    }

    private func add() {
        do {
            if Self.missingPreferredModels(template).isEmpty, let installed = try Self.addDirectly(template) {
                onAdded(installed)
            } else {
                wizard = .install(template)
            }
        } catch {
            failure = WorkflowErrorText.text(error)
        }
    }
}
