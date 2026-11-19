//
//  WorkflowsGetStartedModelTests.swift
//  osaurusTests
//
//  Home's Get Started card: each step checks itself off from what
//  happened, a step once done stays done, the workflow it offers to try,
//  and when the card shows.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowsGetStartedModelTests {
    private static func defaultID(_ n: Int) -> UUID { UUID(uuidString: "0f5c1a4e-6b7d-4c1a-9a01-000000000\(n)")! }

    private static func workflow(
        _ name: String, templateID: UUID = UUID(), needsSetup: Bool = false, fromStore: Bool = false
    ) -> InstalledWorkflow {
        let template = Template(id: templateID, name: name, summary: "Test", payload: .workflow(WF.intake()))
        var w = InstalledWorkflow(template: template, bindings: InstallBindings(), needsSetup: needsSetup)
        if fromStore { w.source = .init(registryID: "listing") }
        return w
    }

    private static let defaults = [
        workflow("Mail Triage", templateID: defaultID(203)),
        workflow("Morning Brief", templateID: defaultID(201)),
        workflow("Research Brief", templateID: defaultID(206)),
    ]

    private static func make(
        workflows: [InstalledWorkflow] = defaults, lastRunAt: [UUID: Date] = [:], hasAutomation: Bool = false,
        hasDraft: Bool = false, remembered: Set<WorkflowsGetStartedModel.Step> = [], dismissed: Bool = false,
        sawIncomplete: Bool = false, isBuiltIn: (UUID) -> Bool = { _ in false },
        runsAlone: (InstalledWorkflow) -> Bool = { _ in true }
    ) -> WorkflowsGetStartedModel {
        WorkflowsGetStartedModel.make(
            workflows: workflows, lastRunAt: lastRunAt, hasAutomation: hasAutomation, hasDraft: hasDraft,
            remembered: remembered, dismissed: dismissed, sawIncomplete: sawIncomplete, isBuiltIn: isBuiltIn,
            runsAlone: runsAlone)
    }

    @Test func aFreshSetupHasNothingDoneAndOffersMorningBrief() {
        let model = Self.make()
        #expect(model.done.isEmpty)
        #expect(model.next == .tryOne)
        #expect(model.isShown)
        #expect(model.tryWorkflowID == Self.defaults[1].id)
        #expect(model.automateWorkflowID == Self.defaults[1].id)
    }

    @Test func eachStepChecksItselfOffFromWhatHappened() {
        let ran = Self.make(lastRunAt: [Self.defaults[0].id: Date()])
        #expect(ran.done == [.tryOne])
        #expect(ran.newlyDone == [.tryOne])
        #expect(ran.next == .automate)
        #expect(ran.automateWorkflowID == Self.defaults[0].id)

        #expect(Self.make(hasAutomation: true).done == [.automate])
        #expect(Self.make(hasDraft: true).done == [.create])
        #expect(Self.make(workflows: Self.defaults + [Self.workflow("Mine")]).done == [.create])
        #expect(Self.make(workflows: Self.defaults + [Self.workflow("Listing", fromStore: true)]).done == [.store])
    }

    @Test func theWorkflowToAutomateCanRunWithoutAnInput() {
        let research = Self.defaults[2]
        let needsInput: (InstalledWorkflow) -> Bool = { $0.id != research.id }
        let ranResearch = Self.make(lastRunAt: [research.id: Date()], runsAlone: needsInput)
        #expect(ranResearch.automateWorkflowID == Self.defaults[1].id)
        let ranBoth = Self.make(
            lastRunAt: [research.id: Date(), Self.defaults[0].id: Date().addingTimeInterval(-60)], runsAlone: needsInput)
        #expect(ranBoth.automateWorkflowID == Self.defaults[0].id)
        let noneCan = Self.make(runsAlone: { _ in false })
        #expect(noneCan.automateWorkflowID == noneCan.tryWorkflowID)
    }

    @Test @MainActor func onlyResearchBriefNeedsAnInputToRunAlone() {
        let needInput = TeamSeeder.bundledDefaultWorkflows()
            .map { InstalledWorkflow(template: $0, bindings: InstallBindings(), needsSetup: false) }
            .filter { !AutomationDefaults.startsOn($0, kind: .schedule) }
            .map(\.name)
        #expect(needInput == ["Research Brief"])
    }

    @Test func defaultsBuiltInsAndStoreWorkflowsAreNotYourOwn() {
        let builtIn = Self.workflow("Email Reply")
        let model = Self.make(
            workflows: Self.defaults + [builtIn, Self.workflow("Listing", fromStore: true)],
            isBuiltIn: { $0 == builtIn.templateID })
        #expect(!model.done.contains(.create))
    }

    @Test func aRememberedStepStaysDone() {
        let model = Self.make(remembered: [.tryOne, .store])
        #expect(model.done == [.tryOne, .store])
        #expect(model.newlyDone.isEmpty)
        #expect(model.next == .automate)
        #expect(model.doneCount == 2)
    }

    @Test func theWorkflowToTryCanRunNow() {
        let blocked = [
            Self.workflow("Morning Brief", templateID: Self.defaultID(201), needsSetup: true),
            Self.workflow("End of Day", templateID: Self.defaultID(205)),
            Self.workflow("Research Brief", templateID: Self.defaultID(206)),
        ]
        #expect(WorkflowsGetStartedModel.suggestedToTry(blocked)?.name == "Research Brief")
        let mine = [Self.workflow("Zebra"), Self.workflow("Alpha", needsSetup: true), Self.workflow("Beta")]
        #expect(WorkflowsGetStartedModel.suggestedToTry(mine)?.name == "Beta")
        let allBlocked = [Self.workflow("Zebra", needsSetup: true), Self.workflow("Alpha", needsSetup: true)]
        #expect(WorkflowsGetStartedModel.suggestedToTry(allBlocked)?.name == "Alpha")
        #expect(WorkflowsGetStartedModel.suggestedToTry([]) == nil)
    }

    @Test func whenTheCardShows() {
        let all: Set<WorkflowsGetStartedModel.Step> = Set(WorkflowsGetStartedModel.Step.allCases)
        #expect(!Self.make(dismissed: true).isShown)
        #expect(!Self.make(workflows: []).isShown)
        let complete = Self.make(remembered: all)
        #expect(complete.isComplete)
        #expect(!complete.isShown)
        #expect(Self.make(remembered: all, sawIncomplete: true).isShown)
        #expect(!Self.make(remembered: all, dismissed: true, sawIncomplete: true).isShown)
    }

    @Test @MainActor func defaultTemplateIDsMatchTheBundledWorkflows() {
        #expect(Set(TeamSeeder.bundledDefaultWorkflows().map(\.id)) == TeamSeeder.defaultWorkflowTemplateIDs)
        #expect(Set(WorkflowsGetStartedModel.tryOrder) == TeamSeeder.defaultWorkflowTemplateIDs)
    }
}
