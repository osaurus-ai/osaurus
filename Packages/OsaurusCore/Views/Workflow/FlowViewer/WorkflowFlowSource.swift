//
//  WorkflowFlowSource.swift
//  osaurus
//
//  What the full view shows: an Architect draft (with its latest test), a
//  saved workflow, or one run of either. Read fresh from the stores on
//  every redraw, so the view follows the Architect's edits and a running
//  run as they happen.
//

import Foundation

enum WorkflowFlowSource: Hashable {
    case draft(UUID)
    case workflow(UUID)
    case run(runID: UUID, workflowID: UUID)
}

/// One source as the full view draws it.
struct WorkflowFlowSnapshot {
    let title: String
    let definition: WorkflowDefinition
    /// The run whose progress colors the graph: the run shown, or a
    /// draft's latest test.
    let run: WorkflowRun?
    /// Steps the Architect's latest edit touched.
    let highlighted: Set<String>
    let draft: WorkflowDraft?
    let installed: InstalledWorkflow?

    @MainActor
    static func resolve(_ source: WorkflowFlowSource) -> WorkflowFlowSnapshot? {
        let drafts = WorkflowDraftStore.shared
        let runs = WorkflowRunStore.shared
        let workflows = InstalledWorkflowStore.shared
        switch source {
        case .draft(let id):
            guard let draft = drafts.draft(id: id) else { return nil }
            return WorkflowFlowSnapshot(
                title: title(draft), definition: draft.definition,
                run: draft.testRunIDs.last.flatMap { runs.run(id: $0) },
                highlighted: Set(draft.lastPatchedNodeIDs), draft: draft, installed: nil)
        case .workflow(let id):
            guard let workflow = workflows.workflow(id: id) else { return nil }
            return WorkflowFlowSnapshot(
                title: workflow.name, definition: workflow.definition, run: nil, highlighted: [], draft: nil,
                installed: workflow)
        case .run(let runID, let workflowID):
            guard let run = runs.run(id: runID) else { return nil }
            if run.workflowID == workflowID, let workflow = workflows.workflow(id: workflowID) {
                return WorkflowFlowSnapshot(
                    title: workflow.name, definition: workflow.definition, run: run, highlighted: [], draft: nil,
                    installed: workflow)
            }
            // A test run's workflow id is its draft's.
            if let draft = drafts.draft(id: run.workflowID) {
                return WorkflowFlowSnapshot(
                    title: title(draft), definition: draft.definition, run: run, highlighted: [], draft: draft,
                    installed: nil)
            }
            return nil
        }
    }

    private static func title(_ draft: WorkflowDraft) -> String {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? L("Untitled Workflow") : name
    }

    var thumbnails: [String: String] { run.map(WorkflowMediaGalleryModel.thumbnails) ?? [:] }

    func record(_ id: String) -> NodeRun? { run?.node(id) }

    /// Each step's badges, with the draft's or the workflow's bindings.
    @MainActor
    func badges() -> [String: [WorkflowStepBadge]] {
        let catalog = ConfigModelReference.liveCatalog()
        var out: [String: [WorkflowStepBadge]] = [:]
        for node in definition.nodes {
            if let draft {
                out[node.id] = WorkflowStepRisk.badges(for: node, in: draft, catalog: catalog)
            } else if let installed {
                out[node.id] = WorkflowStepRisk.badges(for: node, in: installed, catalog: catalog)
            }
        }
        return out
    }

    /// "Qwen 3 (this Mac)" for a model step: the model the run used, else
    /// the one its slot is bound to or prefers.
    @MainActor
    func model(for node: WorkflowNode) -> String? {
        guard case .inference(let spec) = node.kind else { return nil }
        if let used = record(node.id)?.model, !used.isEmpty { return WorkflowModelChoices.runsOn(used) }
        let slot = spec.modelSlot
        let chosen: String?
        if let draft {
            chosen = draft.bindings.models[slot]
                ?? draft.template().requirements.models.first { $0.slot == slot }?.preferred
        } else if let installed {
            chosen = installed.bindings.models[slot]
                ?? installed.template.requirements.models.first { $0.slot == slot }?.preferred
        } else {
            chosen = nil
        }
        return chosen.flatMap { $0.isEmpty ? nil : WorkflowModelChoices.runsOn($0) }
    }

    /// The installed workflow a `workflow` step runs, when this Mac has it.
    @MainActor
    func nestedWorkflow(_ node: WorkflowNode) -> InstalledWorkflow? {
        guard case .workflow(let spec) = node.kind else { return nil }
        return InstalledWorkflowStore.shared.workflow(named: spec.workflow)
    }

    /// Where opening a `workflow` step goes: the run it started within
    /// this run, else the workflow itself.
    @MainActor
    func nestedSource(_ node: WorkflowNode) -> WorkflowFlowSource? {
        guard let child = nestedWorkflow(node) else { return nil }
        if let run,
            let childRun = WorkflowRunStore.shared.runs(workflowID: child.id, limit: 50)
                .first(where: { $0.caller.parentRunID == run.id })
        {
            return .run(runID: childRun.id, workflowID: child.id)
        }
        return .workflow(child.id)
    }
}
