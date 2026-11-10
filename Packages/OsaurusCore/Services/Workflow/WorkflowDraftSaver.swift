//
//  WorkflowDraftSaver.swift
//  osaurus
//
//  Turns an Architect draft into a template version and installs it on
//  this Mac with the draft's bindings, so the workflow is callable the
//  moment the user clicks Save. Answers given in test runs stay with the
//  draft and never become the installed workflow's saved answers. Only
//  user actions call this; the Architect can only propose.
//

import Foundation

@MainActor
enum WorkflowDraftSaver {
    enum SaveError: LocalizedError, Equatable {
        case missingDraft
        case invalid([WorkflowIssue])
        /// A change to the steps has no passing test behind it.
        case untested(String)

        var errorDescription: String? {
            switch self {
            case .missingDraft: return L("The draft is gone.")
            case .invalid(let issues):
                return L("Fix these first: \(issues.map(\.message).joined(separator: "; "))")
            case .untested(let reason): return reason
            }
        }
    }

    /// Saves the draft as a template version and installs it. A change to
    /// the steps, schemas, or output needs a passing test since the change
    /// (`WorkflowTestEvidence`); the save card and `workflow_propose_save`
    /// show the same gate, and this is where it holds whatever the caller.
    /// `requireEvidence: false` is for the person's explicit choice to save
    /// an untested change anyway; the Architect never gets that path.
    @discardableResult
    static func save(draftID: UUID, changelog: String, requireEvidence: Bool = true) throws -> InstalledWorkflow {
        let drafts = WorkflowDraftStore.shared
        guard let draft = drafts.draft(id: draftID) else { throw SaveError.missingDraft }
        let issues = WorkflowValidator.validate(draft.definition, allowPlaceholders: false)
        guard issues.isEmpty else { throw SaveError.invalid(issues) }
        if requireEvidence, let blocker = drafts.testEvidence(draftID).blocker {
            throw SaveError.untested(blocker)
        }

        // Only what the user chose on the draft is installed. Test-run
        // fallbacks (`testBindings`) are per run; an unbound slot goes
        // through the setup wizard like any other install.
        let saved = try TemplateStore.shared.save(draft.template(), changelog: changelog)
        // Agent steps built here ask the agent they name; that is the
        // person's choice, recorded so setup doesn't ask for it again.
        var bindings = draft.bindings
        for req in saved.requirements.agents where bindings.agents[req.id] == nil {
            bindings.agents[req.id] = InstallBindings.agentByName
        }
        // The draft's name is the person's: a rename in the Architect
        // renames the installed workflow too (the save card says so).
        var installed = try InstalledWorkflowStore.shared.install(saved, bindings: bindings, name: saved.name)
        // Secrets entered for the draft are copied into the install's own
        // accounts; the draft keeps its copies for further test runs.
        let copied = WorkflowCredentials.rekey(
            saved.requirements.secrets.map(\.key), from: draftID, to: installed.id, removingSource: false,
            keeping: draft.bindings.secrets)
        if installed.bindings.secrets != copied {
            installed.bindings.secrets = copied
            try InstalledWorkflowStore.shared.save(installed)
        }
        SavedAnswersStore.shared.migrate(workflowID: installed.id, to: saved.workflow ?? draft.definition)
        InstalledWorkflowStore.shared.setNeedsSetup(SetupChecker.check(installed, secrets: .install, attended: true).hasBlockers, id: installed.id)
        drafts.markSaved(draftID, template: saved)
        drafts.notePending(draftID, "The user saved the workflow as \"\(saved.name)\" version \(saved.version).")
        return InstalledWorkflowStore.shared.workflow(id: installed.id) ?? installed
    }

    /// What saving does to the installed workflow's name when it changes
    /// it, for both save surfaces. Nil when the name stays.
    static func renameNotice(for draft: WorkflowDraft) -> String? {
        let store = InstalledWorkflowStore.shared
        guard let templateID = draft.templateID, let installed = store.workflow(templateID: templateID),
            let next = store.renamedName(for: draft.name, id: installed.id), next != installed.name
        else { return nil }
        return L(
            "Also renames the workflow from “\(installed.name)” to “\(next)”. Agents and the Orchestrator will call it \(InstalledWorkflow.toolName(for: next)).")
    }
}
