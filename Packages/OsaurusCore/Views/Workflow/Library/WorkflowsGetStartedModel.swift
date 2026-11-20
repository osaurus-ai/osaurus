//
//  WorkflowsGetStartedModel.swift
//  osaurus
//
//  Home's Get Started card, from plain values so it is testable: four
//  steps a new person takes (try a workflow, let one run on its own,
//  describe their own, look in the Store), each checked off by what
//  actually happened rather than by a click on the card. A step once done
//  stays done (`WorkflowsGetStartedStore`), so a pruned run history never
//  takes a check back.
//

import Foundation

struct WorkflowsGetStartedModel: Equatable {
    enum Step: String, CaseIterable, Identifiable, Sendable {
        case tryOne, automate, create, store
        var id: String { rawValue }
    }

    /// Steps done, live or remembered.
    var done: Set<Step> = []
    /// Done now and not remembered yet.
    var newlyDone: Set<Step> = []
    /// The workflow Try a Workflow runs.
    var tryWorkflowID: UUID?
    /// The workflow Let One Run on Its Own automates: of those that can run
    /// without anyone filling in an input, the one run last, else the first
    /// default; else the one to try.
    var automateWorkflowID: UUID?
    var isShown = false

    var doneCount: Int { done.count }
    var isComplete: Bool { done.count == Step.allCases.count }
    /// The first step not done yet; it carries the card's primary button.
    var next: Step? { Step.allCases.first { !done.contains($0) } }

    /// Template ids of the default workflows, best first try first: no
    /// input and a result on the first run.
    static let tryOrder: [UUID] = [201, 206, 205, 202, 203, 204, 207].compactMap {
        UUID(uuidString: "0f5c1a4e-6b7d-4c1a-9a01-000000000\($0)")
    }

    /// `lastRunAt` is when each workflow last started a run by someone
    /// (tests don't count). `hasAutomation` counts only automations that
    /// are on. `isBuiltIn` says whether a template id is one Osaurus ships.
    /// `runsAlone` says whether a workflow's suggested automation would
    /// start on. `sawIncomplete` is whether the card was on screen
    /// with a step still open this session: a card completed then says
    /// "You're all set" until the app quits; one already complete when the
    /// session began stays away.
    static func make(
        workflows: [InstalledWorkflow],
        lastRunAt: [UUID: Date],
        hasAutomation: Bool,
        hasDraft: Bool,
        remembered: Set<Step>,
        dismissed: Bool,
        sawIncomplete: Bool,
        isBuiltIn: (UUID) -> Bool = { _ in false },
        runsAlone: (InstalledWorkflow) -> Bool = { _ in true }
    ) -> WorkflowsGetStartedModel {
        var live: Set<Step> = []
        if !lastRunAt.isEmpty { live.insert(.tryOne) }
        if hasAutomation { live.insert(.automate) }
        let madeOwn = workflows.contains { workflow in
            workflow.source == nil && !TeamSeeder.defaultWorkflowTemplateIDs.contains(workflow.templateID)
                && !isBuiltIn(workflow.templateID)
        }
        if hasDraft || madeOwn { live.insert(.create) }
        if workflows.contains(where: { $0.source != nil }) { live.insert(.store) }

        var model = WorkflowsGetStartedModel()
        model.done = live.union(remembered)
        model.newlyDone = live.subtracting(remembered)
        model.tryWorkflowID = suggestedToTry(workflows)?.id
        let canAutomate = workflows.filter { !$0.needsSetup && runsAlone($0) }
        let lastRun = canAutomate.compactMap { workflow in lastRunAt[workflow.id].map { (workflow.id, $0) } }
            .max { $0.1 < $1.1 }?.0
        model.automateWorkflowID = lastRun ?? suggestedToTry(canAutomate)?.id ?? model.tryWorkflowID
        model.isShown = !workflows.isEmpty && !dismissed && (!model.isComplete || sawIncomplete)
        return model
    }

    /// A default workflow that can run now, in `tryOrder`; else any that
    /// can, by name; else the first by name, which opens its setup.
    static func suggestedToTry(_ workflows: [InstalledWorkflow]) -> InstalledWorkflow? {
        let byName = workflows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let ready = byName.filter { !$0.needsSetup }
        for templateID in tryOrder {
            if let match = ready.first(where: { $0.templateID == templateID }) { return match }
        }
        return ready.first ?? byName.first
    }
}

/// What the Get Started card remembers on this Mac.
enum WorkflowsGetStartedStore {
    static let dismissedKey = "workflowsGetStarted.dismissed"
    static func doneKey(_ step: WorkflowsGetStartedModel.Step) -> String { "workflowsGetStarted.done.\(step.rawValue)" }

    /// Whether the card was on screen with a step open since launch.
    @MainActor static var sawIncomplete = false

    static func remembered(_ defaults: UserDefaults = .standard) -> Set<WorkflowsGetStartedModel.Step> {
        Set(WorkflowsGetStartedModel.Step.allCases.filter { defaults.bool(forKey: doneKey($0)) })
    }

    static func remember(_ steps: Set<WorkflowsGetStartedModel.Step>, _ defaults: UserDefaults = .standard) {
        for step in steps { defaults.set(true, forKey: doneKey(step)) }
    }

    /// The person opened the Osaurus Store, from anywhere in Workflows.
    static func noteStoreVisited(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: doneKey(.store))
    }
}
