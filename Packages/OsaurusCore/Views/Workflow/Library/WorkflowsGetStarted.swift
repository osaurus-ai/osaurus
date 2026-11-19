//
//  WorkflowsGetStarted.swift
//  osaurus
//
//  Home's Get Started card: four steps from a fresh setup to workflows
//  that work for you, each with the one button that does it. A step checks
//  itself off when it happens, wherever it happens; the card says
//  "You're all set" when the last one does, and Hide puts it away.
//

import SwiftUI

struct WorkflowsGetStarted: View {
    typealias Step = WorkflowsGetStartedModel.Step

    @Environment(\.theme) private var theme
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var overview: WorkflowsOverviewModel
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    @ObservedObject private var drafts = WorkflowDraftStore.shared

    @AppStorage(WorkflowsGetStartedStore.dismissedKey) private var dismissed = false
    @AppStorage(WorkflowsGetStartedStore.doneKey(.tryOne)) private var triedOne = false
    @AppStorage(WorkflowsGetStartedStore.doneKey(.automate)) private var automated = false
    @AppStorage(WorkflowsGetStartedStore.doneKey(.create)) private var created = false
    @AppStorage(WorkflowsGetStartedStore.doneKey(.store)) private var visitedStore = false

    let onRun: (InstalledWorkflow) -> Void

    private var remembered: Set<Step> {
        var steps: Set<Step> = []
        if triedOne { steps.insert(.tryOne) }
        if automated { steps.insert(.automate) }
        if created { steps.insert(.create) }
        if visitedStore { steps.insert(.store) }
        return steps
    }

    private var model: WorkflowsGetStartedModel {
        WorkflowsGetStartedModel.make(
            workflows: installed.workflows, lastRunAt: overview.lastRunAt,
            hasAutomation: overview.automationFacts.values.contains { $0.contains(where: \.event.isEnabled) },
            hasDraft: !drafts.libraryDrafts.isEmpty,
            remembered: remembered, dismissed: dismissed, sawIncomplete: WorkflowsGetStartedStore.sawIncomplete,
            isBuiltIn: WorkflowShareService.isBuiltInTemplate, runsAlone: runsAlone)
    }

    private func runsAlone(_ workflow: InstalledWorkflow) -> Bool {
        guard let preset = suggestedPreset(workflow) else { return false }
        switch preset.kind {
        case .schedule, .pickDayAndTime: return AutomationDefaults.startsOn(workflow, kind: .schedule)
        case .folder: return AutomationDefaults.startsOn(workflow, kind: .folder)
        }
    }

    var body: some View {
        let model = model
        Group {
            if model.isShown { card(model) }
        }
        .animation(theme.motion.standard, value: model.isShown)
        .onAppear { note(model) }
        .onChange(of: model) { _, model in note(model) }
    }

    /// Remembers steps that just happened, and that the card was seen with
    /// one still open.
    private func note(_ model: WorkflowsGetStartedModel) {
        if model.isShown, !model.isComplete { WorkflowsGetStartedStore.sawIncomplete = true }
        for step in model.newlyDone {
            switch step {
            case .tryOne: triedOne = true
            case .automate: automated = true
            case .create: created = true
            case .store: visitedStore = true
            }
        }
    }

    // MARK: Card

    private func card(_ model: WorkflowsGetStartedModel) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack(alignment: .center, spacing: theme.space.s8) {
                    Text(verbatim: model.isComplete ? L("You're all set") : L("Get Started"))
                        .font(SettingsFont.sectionTitle)
                        .foregroundStyle(theme.text.primary)
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: L("\(model.doneCount) of \(Step.allCases.count) done"))
                        .font(SettingsFont.footnote.monospacedDigit())
                        .foregroundStyle(theme.text.tertiary)
                    SettingsIconButton("xmark", help: "Hide", size: .extraSmall, role: .tertiary) {
                        withAnimation(theme.motion.standard) { dismissed = true }
                    }
                    .accessibilityLabel(Text("Hide Get Started", bundle: .module))
                }
                Text(
                    verbatim: model.isComplete
                        ? L("Your workflows are ready. Run one any time, or let Osaurus run it for you.")
                        : L("A few small steps to get your first workflows working for you.")
                )
                .font(SettingsFont.rowDescription)
                .foregroundStyle(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            // Rows carry s10 vertical padding, so these pair with it to make
            // s16 above the first step and s20 below the last.
            SettingsProgressBar(
                value: Double(model.doneCount) / Double(Step.allCases.count), tint: theme.statusInk(.success))
                .padding(.top, theme.space.s16)
                .padding(.bottom, theme.space.s6)
            VStack(spacing: theme.space.s0) {
                ForEach(Array(Step.allCases.enumerated()), id: \.element) { index, step in
                    if index > 0 { ThemeHairlineDivider(color: theme.border.subtle) }
                    row(step, model: model)
                }
            }
        }
        .padding(.horizontal, theme.space.s20)
        .padding(.top, theme.space.s20)
        .padding(.bottom, theme.space.s10)
        .settingsChrome(.card)
        .settingsLandingAnchor("workflows.getStarted")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Steps

    private func row(_ step: Step, model: WorkflowsGetStartedModel) -> some View {
        let isDone = model.done.contains(step)
        let isNext = model.next == step
        return HStack(alignment: .center, spacing: theme.space.s12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .glyphSize(.body, weight: .semibold)
                .foregroundStyle(isDone ? theme.statusInk(.success) : isNext ? theme.text.secondary : theme.text.tertiary)
                .frame(width: theme.space.s20)
                .accessibilityLabel(Text(isDone ? "Done" : "Not done yet", bundle: .module))
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: title(step))
                    .textStyle(.body, weight: isDone ? 400 : 500)
                    .foregroundStyle(isDone ? theme.text.secondary : theme.text.primary)
                if !isDone, let detail = detail(step, model: model) {
                    Text(verbatim: detail)
                        .font(SettingsFont.footnote)
                        .foregroundStyle(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isDone { action(step, model: model, isNext: isNext) }
        }
        .padding(.vertical, theme.space.s10)
        .accessibilityElement(children: .contain)
    }

    private func title(_ step: Step) -> String {
        switch step {
        case .tryOne: return L("Try a workflow")
        case .automate: return L("Let one run on its own")
        case .create: return L("Describe your own")
        case .store: return L("Find more in the Store")
        }
    }

    private func detail(_ step: Step, model: WorkflowsGetStartedModel) -> String? {
        switch step {
        case .tryOne:
            guard let workflow = model.tryWorkflowID.flatMap(installed.workflow(id:)) else {
                return L("Run one and see what it makes for you.")
            }
            return workflow.summary ?? L("Run \(workflow.name) and see what it makes for you.")
        case .automate:
            guard let workflow = model.automateWorkflowID.flatMap(installed.workflow(id:)),
                let preset = suggestedPreset(workflow)
            else { return L("Pick a moment and Osaurus runs it for you.") }
            return L("\(workflow.name) could run \(phrase(preset.kind)), without you asking.")
        case .create:
            return L("Say what you want done in your own words. Osaurus builds it and tries it with you.")
        case .store:
            return L("Workflows other people made, ready to add in one click.")
        }
    }

    @ViewBuilder
    private func action(_ step: Step, model: WorkflowsGetStartedModel, isNext: Bool) -> some View {
        let role: SettingsButtonRole = isNext ? .primary : .secondary
        switch step {
        case .tryOne:
            if let workflow = model.tryWorkflowID.flatMap(installed.workflow(id:)) {
                SettingsButton(
                    role, workflow.needsSetup ? L("Set Up \(workflow.name)") : L("Run \(workflow.name)"),
                    icon: workflow.needsSetup ? nil : "play.fill", size: .small, verbatim: true
                ) { onRun(workflow) }
            }
        case .automate:
            if let workflow = model.automateWorkflowID.flatMap(installed.workflow(id:)),
                let preset = suggestedPreset(workflow)
            {
                SettingsButton(role, "Turn it on", icon: "bolt", size: .small) {
                    WorkflowAutomationPresetAction.perform(
                        preset.kind, for: workflow, onClose: {},
                        onOpenPage: { intent in windowState.showWorkflowAutomation(workflowID: workflow.id, intent: intent) })
                }
            }
        case .create:
            SettingsButton(role, "New Workflow", icon: "plus", size: .small) {
                withAnimation(theme.motion.quick) { windowState.showNewWorkflow() }
            }
        case .store:
            SettingsButton(role, "Browse the Store", icon: "arrow.up.right", size: .small) {
                WorkflowsSidebar.openStore()
            }
        }
    }

    private func suggestedPreset(_ workflow: InstalledWorkflow) -> AutomationPresets.Preset? {
        AutomationPresets.presets(name: workflow.name, summary: workflow.summary).first
    }

    /// "every weekday at 8:00 AM", "when a file shows up in Downloads".
    private func phrase(_ kind: AutomationPresets.Kind) -> String {
        switch kind {
        case .schedule(let frequency): return AutomationPresets.schedulePhrase(frequency)
        case .folder, .pickDayAndTime:
            let title = AutomationPresets.title(kind)
            guard let first = title.first else { return title }
            return String(first).lowercased() + title.dropFirst()
        }
    }
}
