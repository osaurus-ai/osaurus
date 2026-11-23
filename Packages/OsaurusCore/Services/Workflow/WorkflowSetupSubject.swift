//
//  WorkflowSetupSubject.swift
//  osaurus
//
//  A workflow being installed, set up, updated, or readied for a test run,
//  with the bindings collected so far. The setup wizard edits one; the
//  install coordinator finishes one in the background.
//

import Foundation

struct WorkflowSetupSubject: Identifiable {
    enum Mode: Codable, Equatable {
        case install
        case setup(UUID)
        case update(UUID)
        case draft(UUID)
    }

    let id = UUID()
    var mode: Mode
    var template: Template
    var bindings: InstallBindings
    var name: String
    /// `InstalledWorkflow.agentStepsAllowed`, saved with the bindings.
    var agentStepsAllowed = false
    /// The registry listing an install or update came from.
    var source: InstalledWorkflow.Source?

    /// Adding a template. A template already installed here opens as setup on
    /// that install: one installed workflow per template per Mac.
    @MainActor
    static func install(_ template: Template) -> WorkflowSetupSubject {
        if let existing = InstalledWorkflowStore.shared.workflow(templateID: template.id) {
            if existing.templateVersion < template.version { return update(existing, to: template) }
            return setup(existing)
        }
        return WorkflowSetupSubject(mode: .install, template: template, bindings: InstallBindings(), name: template.name)
    }

    static func setup(_ workflow: InstalledWorkflow) -> WorkflowSetupSubject {
        WorkflowSetupSubject(
            mode: .setup(workflow.id), template: workflow.template, bindings: workflow.bindings, name: workflow.name,
            agentStepsAllowed: workflow.agentStepsAllowed)
    }

    /// A version that asks a new agent is asked about again.
    static func update(_ workflow: InstalledWorkflow, to template: Template) -> WorkflowSetupSubject {
        let newAgents = TemplateDiff.newRequirements(from: workflow.template.requirements, to: template.requirements).agents
        return WorkflowSetupSubject(
            mode: .update(workflow.id), template: template, bindings: workflow.bindings, name: workflow.name,
            agentStepsAllowed: newAgents.isEmpty && workflow.agentStepsAllowed)
    }

    @MainActor
    static func draft(_ draft: WorkflowDraft) -> WorkflowSetupSubject {
        WorkflowSetupSubject(
            mode: .draft(draft.id), template: draft.template(),
            bindings: WorkflowDraftStore.shared.testBindings(draft.id), name: draft.name)
    }

    var installedID: UUID? {
        switch mode {
        case .install, .draft: return nil
        case .setup(let id), .update(let id): return id
        }
    }

    var isDraft: Bool {
        if case .draft = mode { return true }
        return false
    }

    /// The id setup checks and parked state key on.
    var subjectID: UUID {
        switch mode {
        case .draft(let id): return id
        default: return installedID ?? template.id
        }
    }
}

extension WorkflowSetupSubject {
    /// Installs, saves, or updates the subject. Nil for a draft (nothing
    /// installs) or an install that disappeared meanwhile.
    @MainActor
    func commit() throws -> InstalledWorkflow? {
        let working = self
        let store = InstalledWorkflowStore.shared
        switch working.mode {
        case .draft:
            return nil
        case .install:
            var installed = try store.install(working.template, bindings: working.bindings, name: working.name)
            // Secrets entered before the install existed sat under the
            // template id; move them to the install they now belong to.
            installed.bindings.secrets = WorkflowCredentials.rekey(
                working.template.requirements.secrets.map(\.key), from: working.subjectID, to: installed.id,
                keeping: working.bindings.secrets)
            installed.agentStepsAllowed = working.agentStepsAllowed
            if let source = working.source { installed.source = source }
            try store.save(installed)
            return store.workflow(id: installed.id) ?? installed
        case .setup(let id):
            guard var installed = store.workflow(id: id) else { return nil }
            installed.bindings = working.bindings
            installed.agentStepsAllowed = working.agentStepsAllowed
            installed.needsSetup = false
            try store.save(installed, reviewed: true)
            return store.workflow(id: id) ?? installed
        case .update(let id):
            guard let current = store.workflow(id: id) else { return nil }
            let name = working.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var installed = try store.install(
                working.template, bindings: working.bindings, name: name == current.name ? nil : name)
            if installed.agentStepsAllowed != working.agentStepsAllowed
                || (working.source != nil && installed.source != working.source)
            {
                installed.agentStepsAllowed = working.agentStepsAllowed
                if let source = working.source { installed.source = source }
                try store.save(installed)
            }
            if let def = working.template.workflow {
                SavedAnswersStore.shared.migrate(workflowID: installed.id, to: def)
            }
            return installed
        }
    }
}
