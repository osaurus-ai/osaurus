//
//  OnboardingAgentTests.swift
//  osaurusTests
//
//  The walkthrough's turns: step words, the Configurator, the handover to
//  the Orchestrator, the Onboarding agent's one generation and its 3,000
//  token context, and Skip setup.
//

import Foundation
import Testing

@testable import OsaurusCore

private let team: [OnboardingOpening.Member] = [
    .init(teammate: .planner, name: "Planner"), .init(teammate: .courier, name: "Courier"),
    .init(teammate: .keeper, name: "Keeper"), .init(teammate: .scout, name: "Scout"),
]

private func plan(at step: String) -> OnboardingPlan {
    var plan = OnboardingPlan(sessionId: UUID())
    switch step {
    case OnboardingSteps.firstTask:
        plan.select(pathId: "planner")
    default:
        break
    }
    plan.advance(OnboardingAppSnapshot(plan: plan, brain: .local(comfortable: true)))
    return plan
}

@Suite("Onboarding turn router")
struct OnboardingTurnRouterTests {
    @Test
    func stepWords_moveThePlan_forTheStepItIsOn() {
        let choice = plan(at: OnboardingSteps.choice)
        #expect(OnboardingTurnRouter.stepAction("Skip", plan: choice, team: team) == .dismissSetup)
        #expect(OnboardingTurnRouter.stepAction("next", plan: choice, team: team) == nil, "next is not skip setup")
        #expect(OnboardingTurnRouter.stepAction("planner!", plan: choice, team: team) == .selectPath("planner"))
        #expect(OnboardingTurnRouter.stepAction("your mail", plan: choice, team: team) == .selectPath("courier"))
        #expect(OnboardingTurnRouter.stepAction("start with Scout", plan: choice, team: team) == .selectPath("scout"))
        #expect(OnboardingTurnRouter.stepAction("Osaurus", plan: choice, team: team) == .selectPath("osaurus"))
        #expect(
            OnboardingTurnRouter.stepAction("Builder", plan: choice, team: team) == nil,
            "no card for a teammate this Mac does not have"
        )
        #expect(OnboardingTurnRouter.stepAction("back", plan: choice, team: team) == nil)

        let firstTask = plan(at: OnboardingSteps.firstTask)
        #expect(OnboardingTurnRouter.stepAction("Go back", plan: firstTask, team: team) == .back)
        #expect(OnboardingTurnRouter.stepAction("later", plan: firstTask, team: team) == .dismissSetup)
        #expect(OnboardingTurnRouter.stepAction("Planner", plan: firstTask, team: team) == nil)
    }

    @Test
    func skipWords_endSetup_onEveryStep_andNothingAfterIt() {
        var brain = OnboardingPlan(sessionId: UUID())
        brain.advance(OnboardingAppSnapshot(plan: brain, brain: .none))
        #expect(brain.current?.id == OnboardingSteps.brain)
        for open in [brain, plan(at: OnboardingSteps.choice), plan(at: OnboardingSteps.firstTask)] {
            for word in ["skip setup", "Skip.", "not now", "no thanks"] {
                #expect(OnboardingTurnRouter.stepAction(word, plan: open, team: team) == .dismissSetup, "\(word)")
            }
        }
        var finished = plan(at: OnboardingSteps.firstTask)
        finished.finish(.firstTask)
        finished.advance(OnboardingAppSnapshot(plan: finished, brain: .local(comfortable: true)))
        #expect(OnboardingTurnRouter.stepAction("skip", plan: finished, team: team) == nil)
    }

    @Test
    func aTypedJob_picksItsCard_andATaskStillHandsOver() {
        let choice = plan(at: OnboardingSteps.choice)
        func step(_ text: String) -> OnboardingAction? {
            OnboardingTurnRouter.stepAction(text, plan: choice, team: team)
        }
        #expect(step("Help with my mail") == .selectPath("courier"))
        #expect(step("I need help with my calendar.") == .selectPath("planner"))
        #expect(step("my downloads") == .selectPath("keeper"))
        #expect(step("research") == .selectPath("scout"))
        #expect(step("help me with my code") == nil, "no card for a teammate this Mac does not have")
        #expect(step("Help with my email to Sam about Friday") == nil, "a task, not a job")
        #expect(step("What is on my calendar today") == nil)
    }

    @Test
    func walkthroughTalk_isAReply_andEverythingElseHandsOver() {
        func route(_ text: String) -> OnboardingTurnRoute { OnboardingTurnRouter.route(text, team: team) }
        #expect(route("How do I change the default model?") == .task)
        #expect(route("Turn off follow-up suggestions") == .task)
        #expect(route("What is on my calendar today") == .task)
        #expect(route("Write me a poem about autumn") == .task)
        #expect(route("What is the capital of France") == .task)
        #expect(route("hi") == .reply)
        #expect(route("Who should I pick?") == .reply)
        #expect(route("What does Keeper do?") == .reply)
        #expect(route("ok") == .reply)
    }

    @Test
    func aPersonalTask_isAPersonalAsksLabel() {
        #expect(OnboardingTurnRouter.readsPersonalData("what is on my calendar today?"))
        #expect(!OnboardingTurnRouter.readsPersonalData("Research tide pools"))
        #expect(!OnboardingTurnRouter.readsPersonalData("Write me a poem about autumn"))
    }
}

@Suite("Onboarding agent prompt")
struct OnboardingAgentPromptTests {
    private func history(_ count: Int, length: Int = 40) -> [ChatTurn] {
        (0 ..< count).flatMap { index in
            [
                ChatTurn(role: .user, content: "question \(index) " + String(repeating: "x", count: length)),
                ChatTurn(role: .assistant, content: "answer \(index) " + String(repeating: "y", count: length)),
            ]
        }
    }

    @Test
    func thePrompt_holdsTheRulesPlanAndStep_andOnlyTheLastTwoExchanges() {
        let context = OnboardingSystemPromptBuilder.Context(
            plan: plan(at: OnboardingSteps.choice),
            location: .thisMac,
            team: team,
            history: history(5),
            message: "Who should I pick?"
        )
        let (system, prompt) = OnboardingSystemPromptBuilder.build(context)
        for rule in OnboardingSystemPromptBuilder.replyRules { #expect(system.contains(rule)) }
        #expect(system.contains("- choice: active"))
        #expect(system.contains("Current step: choice. " + OnboardingSteps.ChoiceStep().card))
        #expect(system.contains("Where this chat runs: On this Mac."))
        #expect(system.contains("Your team is ready: Planner for your day"))
        #expect(prompt.contains("question 3") && prompt.contains("answer 4"))
        #expect(!prompt.contains("question 2") && !prompt.contains("answer 2"))
        #expect(prompt.contains("Person: Who should I pick?"))
        for name in ["run_workflow", "configurator_handoff", "Orchestrator", "Configurator"] {
            #expect(!(system + prompt).contains(name), "\(name) is not named")
        }
    }

    @Test
    func thePrompt_staysUnderBudget_acrossTwentyLongTurns() {
        var turns: [ChatTurn] = []
        var walkthrough = plan(at: OnboardingSteps.firstTask)
        for turn in 0 ..< 20 {
            let message = "turn \(turn) " + String(repeating: "word ", count: 2000)
            let (system, prompt) = OnboardingSystemPromptBuilder.build(
                .init(
                    plan: walkthrough,
                    location: .provider("Osaurus Cloud"),
                    team: team,
                    history: turns,
                    message: message
                )
            )
            let total = OnboardingSystemPromptBuilder.tokens(system) + OnboardingSystemPromptBuilder.tokens(prompt)
            #expect(total <= OnboardingSystemPromptBuilder.tokenBudget, "turn \(turn): \(total) tokens")
            turns.append(ChatTurn(role: .user, content: message))
            turns.append(ChatTurn(role: .assistant, content: String(repeating: "reply ", count: 400)))
            if turn == 10 { walkthrough.requestOutcome = .denied }
        }
    }
}

@Suite("Onboarding handover")
@MainActor
struct OnboardingHandoverTests {
    @Test
    func handoverFacts_sayWhereItRuns_whoWasChosen_andWhatWasSkipped() {
        var chosen = plan(at: OnboardingSteps.firstTask)
        chosen.requestOutcome = .denied
        chosen.finish(.firstTask)
        let facts = OnboardingFirstRun.handoverFacts(plan: chosen, location: .thisMacOffline, team: team)
        #expect(facts.contains("This chat runs: On this Mac, offline."))
        #expect(facts.contains("In setup the user started with Planner, for your day."))
        #expect(facts.contains { $0.contains("macOS did not allow Planner's access") })

        var dismissed = plan(at: OnboardingSteps.choice)
        dismissed.dismiss()
        dismissed.advance(OnboardingAppSnapshot(plan: dismissed, brain: .local(comfortable: true)))
        let skipped = OnboardingFirstRun.handoverFacts(plan: dismissed, location: nil, team: team)
        #expect(skipped.contains("In setup the user skipped choosing a teammate."))
        #expect(skipped.contains("The user dismissed setup before a first task."))
        #expect(skipped.contains("Setup steps skipped: choice, first_task."))
        #expect(!skipped.contains { $0.hasPrefix("This chat runs") })
        for fact in facts + skipped { #expect(fact.count <= SessionState.maxItemCharacters) }
    }

    @Test
    func eachScheduledDefault_isAnAutomationTheSchedulerCanRun() throws {
        let scheduled: [(UUID, String)] = [
            (OnboardingPaths.morningBriefId, "Morning Brief"), (OnboardingPaths.meetingPrepId, "Meeting Prep"),
            (OnboardingPaths.mailTriageId, "Mail Triage"), (OnboardingPaths.newDownloadId, "New Download"),
            (OnboardingPaths.endOfDayId, "End of Day"), (TeamSeeder.repoDigestTemplateID, "Repo Digest"),
        ]
        for (id, name) in scheduled {
            let automation = try #require(OnboardingKeep.automation(workflowId: id, name: name), "\(name)")
            #expect(automation.entry.workflow == id.uuidString)
            #expect(automation.entry.name == name)
            let source = try #require(automation.entry.source)
            if source.kind == "schedule" {
                let parsed = ConfigScheduleFrequency.parse(
                    frequency: source.frequency ?? "",
                    value: source.frequencyValue,
                    timeOfDay: nil
                )
                guard case .success = parsed else {
                    Issue.record("\(name): \(source.frequencyValue ?? "")")
                    continue
                }
            } else {
                #expect(source.kind == "folder" && source.path?.hasSuffix("/Downloads") == true, "\(name)")
            }
        }
        #expect(OnboardingKeep.automation(workflowId: OnboardingPaths.researchBriefId, name: "Research Brief") == nil)
    }

    @Test
    func theDefaultWorkflows_areReachedThroughTheirInstalledCopies() throws {
        let wanted = [OnboardingPaths.morningBriefId, OnboardingPaths.researchBriefId]
        let installed = try TeamSeeder.bundledDefaultWorkflows().filter { wanted.contains($0.id) }.map {
            try InstalledWorkflowStore.shared.install($0, bindings: InstallBindings())
        }
        defer { for workflow in installed { InstalledWorkflowStore.shared.delete(id: workflow.id) } }
        let brief = try #require(installed.first { $0.templateID == OnboardingPaths.morningBriefId })
        let research = try #require(installed.first { $0.templateID == OnboardingPaths.researchBriefId })
        #expect(brief.id != OnboardingPaths.morningBriefId, "an install has an id of its own")

        let automation = OnboardingKeep.automation(workflowId: OnboardingPaths.morningBriefId, name: brief.name)
        let entry = try #require(automation?.entry)
        #expect(entry.workflow == brief.id.uuidString)
        #expect(ConfigEvents.liveWorkflowResolver(entry.workflow ?? "") == brief.id)
        #expect(OnboardingKeep.permissions(forWorkflow: OnboardingPaths.morningBriefId).contains(.calendar))

        let call = try #require(OnboardingFirstRun.dispatch(for: OnboardingPaths.topicAsk("tide pools")))
        let args = JSONValue.parse(call.jsonArguments)?.objectValue
        #expect(args?["workflow"]?.stringValue == research.id.uuidString)
    }

    @Test
    func theSaveNoteWrite_isOneNotesCreate_underKeeper() throws {
        let template = try #require(PreparedAskCatalog.template(id: OnboardingKeep.saveNoteId))
        let def = try #require(template.workflow)
        let refs = def.nodes.flatMap(\.calledTools)
        #expect(refs.map(\.name) == ["notes_create"])
        #expect(refs.first?.agent == Teammate.keeper.templateID.uuidString)
        #expect(def.modelSlots.isEmpty, "the note is saved as written")
        let required = def.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(Set(required) == ["title", "body"])
        #expect(PreparedAskCatalog.installed(id: OnboardingKeep.saveNoteId)?.orchestratorVisible == false)
    }

    @Test
    func thePickedTeammate_staysOnThePanels_afterThePick() throws {
        let first = try #require(
            OnboardingPanel.make(
                plan: plan(at: OnboardingSteps.firstTask), brain: .local(comfortable: true), team: team,
                sessionId: UUID())
        )
        #expect(first.step == .firstTask)
        #expect(first.teammate == .init(pathId: "planner", name: "Planner", mascotId: nil))

        let choice = try #require(
            OnboardingPanel.make(
                plan: plan(at: OnboardingSteps.choice), brain: .local(comfortable: true), team: team,
                sessionId: UUID())
        )
        #expect(choice.step == .team)
        #expect(choice.teammate == nil)
    }

    @Test
    func aConfiguratorQuestion_carriesTheExactWords() throws {
        let words = "how do I make the text bigger?? "
        let call = OnboardingFirstRun.configuratorDispatch(words)
        #expect(call.toolName == ConfiguratorHandoffTool.toolName)
        let args = try #require(JSONValue.parse(call.jsonArguments)?.objectValue)
        #expect(args["user_message"]?.stringValue == words)
    }
}

// MARK: - Turns in a live chat

private actor CapturingEngine: ChatEngineProtocol {
    private(set) var requests: [ChatCompletionRequest] = []

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield("Here is the answer.")
            continuation.finish()
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "OnboardingAgentTests", code: 1)
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "OnboardingAgentTests", code: 2)
}

/// Records what the controller would have done, in place of the real
/// model, automation apply, and permission prompts.
@MainActor
private final class Recorder {
    var generations: [(system: String, prompt: String)] = []
    var orchestrator: [String] = []
    var reply = "Planner is a good place to start."
}

@MainActor
private func walkthrough(
    _ engine: CapturingEngine,
    configure: (inout OnboardingPlan) -> Void
) -> (ChatSession, OnboardingFirstRun, Recorder) {
    let run = OnboardingFirstRun.shared
    let store = OnboardingPlanStore(
        fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
            "onboarding-agent-\(UUID().uuidString).json"
        )
    )
    let defaults = UserDefaults(suiteName: "onboarding-agent-\(UUID().uuidString)")!
    run.resetForTesting(store: store, defaults: defaults)
    let session = ChatSession()
    session.forceChatEngineRouteForTests = true
    session.toolsDisabledForTestingOverride = true
    session.chatEngineFactory = { _ in engine }
    let opening = ChatTurn(role: .assistant, content: "Hi, I am Osaurus. Who do you want to start with?")
    opening.origin = .authored
    opening.modelContextExcluded = true
    session.appendAuthoredTurn(opening)
    var plan = OnboardingPlan(sessionId: session.sessionId)
    configure(&plan)
    plan.advance(OnboardingAppSnapshot(plan: plan, brain: .local(comfortable: true)))
    store.save(plan)
    run.resetForTesting(store: store, defaults: defaults)
    run.brainOverride = .local(comfortable: true)

    let recorder = Recorder()
    run.generateReply = { system, prompt, _ in
        await MainActor.run {
            recorder.generations.append((system, prompt))
            return recorder.reply
        }
    }
    run.sendToOrchestrator = { _, text, _ in recorder.orchestrator.append(text) }
    run.requestPermission = { _ in false }
    run.isPermissionGranted = { _ in false }
    run.readDownloads = { false }
    return (session, run, recorder)
}

@MainActor
private func restoreSeams(_ run: OnboardingFirstRun) {
    run.generateReply = { try await OnboardingFirstRun.generate(system: $0, prompt: $1, model: $2) }
    run.sendToOrchestrator = { $0.sendBypassingOnboarding($1, attachments: $2) }
    run.requestPermission = { await SystemPermissionService.shared.requestPermissionAndWait($0) }
    run.isPermissionGranted = { SystemPermissionService.shared.isGranted($0) }
    run.resetForTesting(store: .shared, defaults: .standard)
}

@Suite("Onboarding agent turns", .serialized)
@MainActor
struct OnboardingAgentTurnTests {
    @Test
    func skipSetup_endsTheWalkthrough_fromTheCards_andTheFirstTask() async throws {
        for pathId in [nil, "planner"] as [String?] {
            try await ChatHistoryTestStorage.run {
                let engine = CapturingEngine()
                let (session, run, recorder) = walkthrough(engine) { plan in
                    if let pathId { plan.select(pathId: pathId) }
                }
                defer { restoreSeams(run) }
                #expect(run.panel(for: session) != nil)
                run.perform(.dismissSetup, in: session, echo: false)
                #expect(run.plan?.finishReason == .dismissed)
                #expect(run.plan?.isComplete == true)
                #expect(run.panel(for: session) == nil, "the panel goes with the walkthrough")
                #expect(session.turns.last?.content == "Setup is done. Ask me anything.")
                #expect(session.sessionState?.facts.contains("The user dismissed setup before a first task.") == true)
                #expect(!run.routesTypedMessage(in: session), "the next message is the Orchestrator's")
                #expect(recorder.generations.isEmpty && recorder.orchestrator.isEmpty)
                #expect(await engine.requests.isEmpty)
            }
        }
    }

    @Test
    func aStepWord_movesThePlan_withNoGeneration() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingEngine()
            let (session, run, recorder) = walkthrough(engine) { $0.select(pathId: "planner") }
            defer { restoreSeams(run) }
            session.send("go back")
            await run.waitForRouting()
            #expect(run.plan?.pathId == nil)
            #expect(run.plan?.current?.id == OnboardingSteps.choice)
            let last = session.turns.suffix(2)
            #expect(last.map(\.content) == ["go back", OnboardingSteps.ChoiceStep().fallbackLine])
            #expect(last.allSatisfy { $0.origin == .authored && $0.modelContextExcluded })

            session.send("skip setup")
            await run.waitForRouting()
            #expect(run.plan?.finishReason == .dismissed)
            #expect(session.turns.last?.content == "Setup is done. Ask me anything.")
            #expect(recorder.generations.isEmpty && recorder.orchestrator.isEmpty)
            #expect(await engine.requests.isEmpty)
        }
    }

    @Test
    func talk_getsOneGeneratedReply_thatTheOrchestratorNeverSees() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingEngine()
            let (session, run, recorder) = walkthrough(engine) { _ in }
            defer { restoreSeams(run) }
            session.send("Who should I pick?")
            await run.waitForRouting()
            #expect(recorder.generations.count == 1)
            #expect(recorder.generations.first?.system.contains("Current step: choice.") == true)
            let reply = try #require(session.turns.last)
            #expect(reply.content == recorder.reply && reply.runLocation == .thisMac)
            #expect(session.turns.suffix(2).allSatisfy { $0.origin == .authored && $0.modelContextExcluded })
            #expect(run.plan?.current?.id == OnboardingSteps.choice, "the step is unchanged")
            #expect(run.panel(for: session)?.turnId == reply.id, "the cards come back under the reply")
            #expect(recorder.orchestrator.isEmpty)
            #expect(await engine.requests.isEmpty)
        }
    }

    @Test
    func talk_withNoModel_getsTheStepsAuthoredLine() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingEngine()
            let (session, run, recorder) = walkthrough(engine) { _ in }
            defer { restoreSeams(run) }
            run.brainOverride = .downloadingLocked
            session.send("hello")
            await run.waitForRouting()
            #expect(recorder.generations.isEmpty)
            #expect(session.turns.last?.content == OnboardingSteps.ChoiceStep().fallbackLine)
            #expect(session.turns.last?.runLocation == nil)
        }
    }

    @Test
    func aTask_graduates_verbatim_withTheSeededState() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingEngine()
            let (session, run, recorder) = walkthrough(engine) { $0.select(pathId: "planner") }
            defer { restoreSeams(run) }
            let before = session.turns.count
            let task = "  Draft a packing list for a weekend in Lisbon  "
            session.send(task)
            await run.waitForRouting()
            #expect(recorder.orchestrator == [task.trimmingCharacters(in: .whitespaces)])
            #expect(recorder.generations.isEmpty, "no onboarding reply sits in between")
            #expect(session.turns.count == before)
            #expect(run.plan?.finishReason == .firstTask)
            let facts = session.sessionState?.facts ?? []
            #expect(facts.contains("In setup the user started with Planner, for your day."))
            #expect(facts.contains("This chat runs: On this Mac."))
            #expect(!run.routesTypedMessage(in: session), "the next message is the Orchestrator's")
        }
    }

    @Test
    func aTypedPersonalTask_waitsOnTheBridge_andAnOrdinaryTaskStillGraduates() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingEngine()
            let (session, run, recorder) = walkthrough(engine) { $0.select(pathId: "planner") }
            defer { restoreSeams(run) }
            run.brainOverride = .bridged
            session.send("What is on my calendar today")
            await run.waitForRouting()
            #expect(recorder.orchestrator.isEmpty, "nothing reads the calendar on the bridge")
            #expect(session.turns.last?.content.contains("private model") == true)
            #expect(run.plan?.finishReason == nil, "the walkthrough stays")

            session.send("Draft a packing list for a weekend in Lisbon")
            await run.waitForRouting()
            #expect(recorder.orchestrator == ["Draft a packing list for a weekend in Lisbon"])
            #expect(run.plan?.finishReason == .firstTask)
        }
    }

    @Test
    func aTypedPersonalTask_graduates_onTheLocalModel() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingEngine()
            let (session, run, recorder) = walkthrough(engine) { $0.select(pathId: "planner") }
            defer { restoreSeams(run) }
            session.send("What is on my calendar today")
            await run.waitForRouting()
            #expect(recorder.orchestrator == ["What is on my calendar today"])
        }
    }

    @Test
    func aSettingsQuestion_graduatesToTheOrchestrator() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingEngine()
            let (session, run, recorder) = walkthrough(engine) { _ in }
            defer { restoreSeams(run) }
            session.send("How do I change the default model?")
            await run.waitForRouting()
            #expect(recorder.orchestrator == ["How do I change the default model?"])
            #expect(recorder.generations.isEmpty)
            #expect(run.plan?.finishReason == .firstTask)
        }
    }

    @Test
    func theFirstResult_endsSetup_withNothingOfferedAfterIt() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingEngine()
            let (session, run, recorder) = walkthrough(engine) {
                $0.select(pathId: "planner")
                $0.finish(.firstTask)
                $0.firstTaskSucceeded = true
            }
            defer { restoreSeams(run) }
            let result = ChatTurn(role: .assistant, content: "You have two meetings today.")
            session.appendAuthoredTurn(result)
            #expect(run.plan?.isComplete == true)
            #expect(run.panel(for: session) == nil)
            #expect(!run.routesTypedMessage(in: session))
            #expect(session.turns.last?.id == result.id, "nothing is appended under the result")
            #expect(recorder.orchestrator.isEmpty)
        }
    }

    @Test
    func plannersRequest_asksForRemindersWithTheCalendar() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingEngine()
            let (session, run, _) = walkthrough(engine) { $0.select(pathId: "planner") }
            defer { restoreSeams(run) }
            final class Asked { var permissions: [SystemPermission] = [] }
            let asked = Asked()
            run.requestPermission = { permission in
                await MainActor.run { asked.permissions.append(permission) }
                return true
            }
            run.perform(.request, in: session, echo: false)
            try await waitUntil { run.plan?.requestOutcome == .granted }
            #expect(asked.permissions == [.calendar, .reminders])
        }
    }

    @Test
    func aDownloadsDenial_offersTryAgainAndSettings_andARetryCanSucceed() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingEngine()
            let (session, run, _) = walkthrough(engine) { $0.select(pathId: "keeper") }
            defer { restoreSeams(run) }
            run.perform(.request, in: session, echo: false)
            try await waitUntil { run.plan?.requestOutcome == .denied }
            let denied = try #require(run.panel(for: session)?.panel)
            #expect(denied.buttons.contains { $0.action == .request })
            #expect(denied.buttons.contains { $0.action == .openFilesAndFolders })
            #expect(denied.note?.contains("Files & Folders") == true)

            run.readDownloads = { true }
            run.perform(.request, in: session, echo: false)
            try await waitUntil { run.plan?.requestOutcome == .granted }
            let granted = try #require(run.panel(for: session)?.panel)
            #expect(granted.buttons.contains { $0.action == .ask("keeper.week") })
        }
    }

    @Test
    func theOrchestratorsPrompt_holdsTheSeededState_andNoneOfTheWalkthrough() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = CapturingEngine()
            let session = ChatSession()
            session.forceChatEngineRouteForTests = true
            session.toolsDisabledForTestingOverride = true
            session.chatEngineFactory = { _ in engine }
            for (role, text) in [
                (MessageRole.assistant, "Hi, I am Osaurus. Who do you want to start with?"),
                (.user, "Planner"), (.assistant, "Planner reads your calendar and reminders."),
            ] {
                let turn = ChatTurn(role: role, content: text)
                turn.origin = .authored
                turn.modelContextExcluded = true
                session.appendAuthoredTurn(turn)
            }
            session.seedSessionState(SessionState(facts: ["In setup the user started with Planner, for your day."]))
            session.send("Draft a packing list for Lisbon")
            try await waitUntil { !session.isStreaming && session.turns.last?.role == .assistant }
            if let task = session.currentSendTaskForTesting { await task.value }
            let request = try #require(await engine.requests.first)
            let text = request.messages.compactMap(\.content).joined(separator: "\n")
            #expect(!text.contains("Who do you want to start with"))
            #expect(!text.contains("Planner reads your calendar"))
            #expect(text.contains("In setup the user started with Planner"))
            #expect(
                request.messages.last { $0.role == "user" }?.content?.contains("Draft a packing list for Lisbon")
                    == true
            )
        }
    }
}
