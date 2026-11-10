//
//  WorkflowStepBadgesView.swift
//  osaurus
//
//  The risk and cost badges on a step card: hosts reached, files written,
//  commands run, cloud or local model, and time and tokens seen in past
//  runs. One row of small capsules; hover for the full list.
//

import SwiftUI

struct WorkflowStepBadgesView: View {
    let badges: [WorkflowStepBadge]

    @Environment(\.theme) private var theme

    var body: some View {
        if !badges.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(badges) { badge in
                    StatusChip(badge.label, tint: color(badge.tone), icon: badge.systemImage)
                    .help(badge.detail ?? badge.label)
                }
            }
            .settingsLandingAnchor("workflows.stepBadges")
        }
    }

    private func color(_ tone: WorkflowStepBadge.Tone) -> Color {
        switch tone {
        case .neutral: return theme.text.secondary
        case .caution: return theme.status.warning.foreground
        case .risky: return theme.status.error.foreground
        }
    }
}

extension WorkflowStepRisk {
    /// Badges for a draft's step, with the slot bindings the draft tests
    /// with and the draft's own test runs as history.
    @MainActor
    static func badges(for node: WorkflowNode, in draft: WorkflowDraft, catalog: ConfigModelReference.Catalog)
        -> [WorkflowStepBadge]
    {
        let bindings = draft.bindings
        let runs = draft.testRunIDs.suffix(20).compactMap { WorkflowRunStore.shared.run(id: $0) }
        let history = history(from: runs)[node.id]
        return badges(
            for: node, in: draft.definition,
            locality: { slot in
                if let bound = locality(slot: slot, bindings: bindings, catalog: catalog) as WorkflowModelLocality?,
                    bound != .unbound
                {
                    return bound
                }
                // Unbound in the draft: the slot's preferred model decides.
                if let preferred = draft.definition.modelSlots.first(where: { $0.slot == slot })?.preferred,
                    !preferred.isEmpty
                {
                    return SetupChecker.isLocalModel(preferred, catalog: catalog) ? .local : .cloud
                }
                return .unbound
            }, history: history)
    }

    /// Badges for an installed workflow's step, with its real bindings and
    /// recent runs.
    @MainActor
    static func badges(for node: WorkflowNode, in workflow: InstalledWorkflow, catalog: ConfigModelReference.Catalog)
        -> [WorkflowStepBadge]
    {
        // Cost badges describe real runs; eval runs across candidate models
        // would skew the averages toward models the workflow does not use.
        let runs = WorkflowRunStore.shared.runs(workflowID: workflow.id, limit: 20, includeTests: false)
        let history = history(from: runs)[node.id]
        return badges(
            for: node, in: workflow.definition,
            locality: { locality(slot: $0, bindings: workflow.bindings, catalog: catalog) }, history: history)
    }
}
