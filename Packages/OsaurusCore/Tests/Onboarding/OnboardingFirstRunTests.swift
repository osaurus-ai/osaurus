//
//  OnboardingFirstRunTests.swift
//  OsaurusCoreTests
//
//  The scripted first run: the Mac profile, the brain state, the authored
//  opening, the plan, the panel each step shows, the prepared asks and the
//  call an ask makes, the run-location label, and the persisted turn fields.
//

import Foundation
import Testing

@testable import OsaurusCore

private let team: [OnboardingOpening.Member] = [
    .init(teammate: .planner, name: "Planner"), .init(teammate: .courier, name: "Courier"),
    .init(teammate: .keeper, name: "Keeper"),
    .init(teammate: .scout, name: "Scout", avatar: Teammate.scout.avatar.rawValue),
]
private let profile = MacProfile(modelName: "MacBook Air", chip: "M4", memoryGB: 16)

@Suite("Mac profile")
struct MacProfileTests {
    @Test
    func marketingName_andChip_readTheSystemsStrings() {
        #expect(MacProfile.marketingName(productName: "MacBook Air (15-inch, M4, 2025)") == "MacBook Air")
        #expect(MacProfile.marketingName(productName: nil) == nil)
        #expect(MacProfile.chipName(brandString: "Apple M4 Pro") == "M4 Pro")
        #expect(MacProfile.chipName(brandString: "Intel(R) Core(TM) i7") == nil)
    }
}

@Suite("Onboarding brain state")
struct OnboardingBrainStateTests {
    private func resolve(_ source: OnboardingBrainState.Inputs.Source, pending: Bool = false, fits: Bool = true)
        -> OnboardingBrainState
    {
        OnboardingBrainState.resolve(.init(pendingLocalDownload: pending, source: source, isCompatible: { _ in fits }))
    }

    @Test
    func eachRowOfTheBrainTable_resolves_andSaysWhereItRuns() {
        #expect(resolve(.local(modelName: "m")) == .local(comfortable: true))
        #expect(resolve(.local(modelName: "m"), fits: false) == .local(comfortable: false))
        #expect(resolve(.remote(providerName: "Osaurus", isOsaurusRouter: true), pending: true) == .bridged)
        #expect(resolve(.local(modelName: "m"), pending: true) == .downloadingLocked)
        #expect(resolve(.remote(providerName: "Osaurus", isOsaurusRouter: true)) == .provider("Osaurus Cloud"))
        #expect(resolve(.remote(providerName: "Anthropic", isOsaurusRouter: false)) == .provider("Anthropic"))
        #expect(resolve(.none) == .none)
        #expect(
            OnboardingBrainState.resolve(.init(pendingLocalDownload: false, source: .none, cloudPending: true) { _ in true })
                == .cloudConnecting)
        #expect(
            OnboardingBrainState.resolve(
                .init(
                    pendingLocalDownload: false, source: .remote(providerName: "Osaurus", isOsaurusRouter: true),
                    cloudPending: true
                ) { _ in true }) == .provider("Osaurus Cloud"), "a model in the picker wins")
        #expect(!OnboardingBrainState.cloudConnecting.canAnswer)
        #expect(OnboardingBrainState.cloudConnecting.holdsPersonalAsks)

        #expect(OnboardingBrainState.bridged.holdsPersonalAsks)
        #expect(!OnboardingBrainState.provider("Anthropic").holdsPersonalAsks)
        #expect(OnboardingBrainState.provider("Anthropic").disclosedProvider == "Anthropic")
        #expect(OnboardingBrainState.local(comfortable: true).disclosedProvider == nil)
        #expect(!OnboardingBrainState.downloadingLocked.canAnswer)
    }

    @Test
    func runLocationLabel_matchesTheSource_andReadsOfflineWhenTheNetworkIsDown() {
        let local = OnboardingBrainState.local(comfortable: true)
        #expect(local.runLocation(offline: false) == .thisMac)
        #expect(local.runLocation(offline: true) == .thisMacOffline)
        #expect(OnboardingBrainState.bridged.runLocation(offline: false) == .provider("Osaurus Cloud"))
        #expect(OnboardingBrainState.none.runLocation(offline: false) == nil)
        #expect(ChatRunLocation.thisMac.label(tokensPerSecond: 41.6) == "On this Mac · 42 tok/s")
        #expect(ChatRunLocation.thisMac.label(tokensPerSecond: nil) == "On this Mac")
        #expect(ChatRunLocation.thisMacOffline.label(tokensPerSecond: 30) == "On this Mac, offline")
        #expect(ChatRunLocation.provider("Anthropic").label(tokensPerSecond: 90) == "Anthropic")
    }
}

@Suite("Onboarding opening")
struct OnboardingOpeningTests {
    @Test
    func theOpening_greets_saysWhereItRuns_andAsksOneQuestion() {
        let text = OnboardingOpening.text(profile: profile, brain: .local(comfortable: true))
        #expect(
            text == "Hi, I am Osaurus, your personal AI agent. I am running right here, on this Mac.\n\n"
                + "Ask me a question or give me a job. I can change Osaurus settings when you ask, and when a job "
                + "needs your calendar, email, or files, I pass it to a teammate who knows that one thing well. "
                + "Who do you want to start with?")
        #expect(text.filter { $0 == "?" }.count == 1)
    }

    @Test
    @MainActor
    func aTypedOutLine_pausesLongerAtCommas_sentences_andParagraphs() {
        let word = ChatSession.authoredPause(after: "o", before: " ")
        let comma = ChatSession.authoredPause(after: ",", before: " ")
        let sentence = ChatSession.authoredPause(after: ".", before: " ")
        let paragraph = ChatSession.authoredPause(after: ".", before: "\n")
        #expect(word < comma && comma < sentence && sentence < paragraph)
    }

    @Test
    func theOpening_saysWhatOsaurusDoes_inEveryState() {
        for brain: OnboardingBrainState in [
            .local(comfortable: true), .bridged, .downloadingLocked, .provider("Anthropic"), .cloudConnecting, .none,
        ] {
            #expect(OnboardingOpening.text(profile: profile, brain: brain).contains(OnboardingOpening.introLine), "\(brain)")
        }
    }

    @Test
    func theOpening_leavesTheMacAndTheTeam_toTheCards() {
        for brain: OnboardingBrainState in [
            .local(comfortable: true), .local(comfortable: false), .bridged, .downloadingLocked,
            .provider("Anthropic"), .none,
        ] {
            let text = OnboardingOpening.text(profile: profile, brain: brain)
            #expect(!text.contains("MacBook Air") && !text.contains("16 GB"), "\(brain)")
            #expect(!team.contains { text.contains($0.name) }, "\(brain)")
        }
    }

    @Test
    func eachBrainState_hasItsOwnWhereLine() {
        let lines = [
            OnboardingBrainState.local(comfortable: true), .bridged, .downloadingLocked, .provider("Anthropic"),
            .cloudConnecting, .none,
        ].map(OnboardingOpening.whereLine)
        #expect(Set(lines).count == lines.count)
        #expect(OnboardingOpening.whereLine(.bridged).contains("Osaurus Cloud"))
        #expect(OnboardingOpening.whereLine(.provider("Anthropic")) == "I am running on Anthropic.")
        let none = OnboardingOpening.text(profile: profile, brain: .none)
        #expect(none.hasSuffix(OnboardingSteps.BrainStep().fallbackLine))
        let connecting = OnboardingOpening.text(profile: profile, brain: .cloudConnecting)
        #expect(connecting.contains("Osaurus Cloud is still connecting"))
        #expect(connecting.hasSuffix("You can wait a moment, or choose another model."))
    }

    @Test
    func theOpening_neverGreetsByName() {
        for brain: OnboardingBrainState in [.local(comfortable: true), .bridged, .provider("Anthropic"), .none] {
            #expect(
                OnboardingOpening.text(profile: profile, brain: brain).hasPrefix("Hi, I am Osaurus, your personal AI agent. "),
                "\(brain)")
        }
    }
}

@Suite("Onboarding plan")
struct OnboardingPlanTests {
    private func advanced(_ plan: OnboardingPlan, _ brain: OnboardingBrainState) -> OnboardingPlan {
        var plan = plan
        plan.advance(OnboardingAppSnapshot(plan: plan, brain: brain))
        return plan
    }

    @Test
    func planFromState_hidesTheBrainStep_whenAModelIsCommitted() {
        let local = advanced(OnboardingPlan(sessionId: UUID()), .local(comfortable: true))
        #expect(local.status(of: OnboardingSteps.brain) == .done)
        #expect(local.current?.id == OnboardingSteps.choice)

        let locked = advanced(OnboardingPlan(sessionId: UUID()), .downloadingLocked)
        #expect(locked.current?.id == OnboardingSteps.choice, "cards still work while the model downloads")

        let none = advanced(OnboardingPlan(sessionId: UUID()), .none)
        #expect(none.current?.id == OnboardingSteps.brain)
        #expect(none.status(of: OnboardingSteps.choice) == .pending)
        #expect(advanced(none, .provider("Anthropic")).current?.id == OnboardingSteps.choice)

        let connecting = advanced(OnboardingPlan(sessionId: UUID()), .cloudConnecting)
        #expect(connecting.current?.id == OnboardingSteps.brain, "Choose a Model stays offered while Cloud connects")
        #expect(advanced(connecting, .provider("Osaurus Cloud")).current?.id == OnboardingSteps.choice)
    }

    @Test
    func zeroModelRun_reachesTheFirstTask_throughButtonsAlone() {
        var plan = advanced(OnboardingPlan(sessionId: UUID()), .downloadingLocked)
        plan.select(pathId: "planner")
        plan = advanced(plan, .downloadingLocked)
        #expect(plan.current?.id == OnboardingSteps.firstTask)
        #expect(plan.status(of: OnboardingSteps.choice) == .done)
    }

    @Test
    func back_returnsToTheCards() {
        var plan = advanced(OnboardingPlan(sessionId: UUID()), .local(comfortable: true))
        plan.select(pathId: "courier")
        plan = advanced(plan, .local(comfortable: true))
        #expect(plan.current?.id == OnboardingSteps.firstTask)

        plan.back()
        plan = advanced(plan, .local(comfortable: true))
        #expect(plan.pathId == nil)
        #expect(plan.current?.id == OnboardingSteps.choice)
    }

    @Test
    func skipSetup_endsSetup_fromEveryStep() {
        var onCards = advanced(OnboardingPlan(sessionId: UUID()), .local(comfortable: true))
        onCards.select(pathId: "courier")
        let starts: [(String, OnboardingPlan, OnboardingBrainState)] = [
            ("brain", advanced(OnboardingPlan(sessionId: UUID()), .none), .none),
            ("cards", advanced(OnboardingPlan(sessionId: UUID()), .local(comfortable: true)), .local(comfortable: true)),
            ("first task", advanced(onCards, .local(comfortable: true)), .local(comfortable: true)),
        ]
        for (name, start, brain) in starts {
            #expect(start.current != nil, "\(name)")
            var plan = start
            plan.dismiss()
            plan = advanced(plan, brain)
            #expect(plan.finishReason == .dismissed, "\(name)")
            #expect(plan.current == nil && plan.isComplete, "\(name)")
        }

        var finished = OnboardingPlan(sessionId: UUID())
        finished.finish(.firstTask)
        let before = finished
        finished.dismiss()
        #expect(finished == before, "a finished plan stays as it ended")
    }

    @Test
    func setup_endsWithTheFirstTask() {
        var plan = advanced(OnboardingPlan(sessionId: UUID()), .local(comfortable: true))
        plan.select(pathId: "planner")
        plan.requestOutcome = .granted
        plan = advanced(plan, .local(comfortable: true))
        plan.finish(.firstTask, askId: "planner.today")
        plan.firstTaskSucceeded = true
        plan = advanced(plan, .local(comfortable: true))
        #expect(plan.isComplete && plan.current == nil)
        #expect(OnboardingSteps.all.map(\.id) == [OnboardingSteps.brain, OnboardingSteps.choice, OnboardingSteps.firstTask])
    }

    @Test
    func store_roundTrips_andAMissingFileIsNoPlan() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        await MainActor.run {
            let store = OnboardingPlanStore(fileURL: url)
            #expect(store.load() == nil)
            var plan = OnboardingPlan(sessionId: UUID())
            plan.select(pathId: "keeper")
            plan.requestOutcome = .denied
            store.save(plan)
            #expect(store.load() == plan)
            store.clear()
            #expect(store.load() == nil)
        }
    }

    @Test
    func aStoredPlan_fromBeforeTheKeepStepWasRetired_loadsWithoutIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var plan = advanced(OnboardingPlan(sessionId: UUID()), .local(comfortable: true))
        plan.select(pathId: "planner")
        plan.finish(.firstTask, askId: "planner.today")
        plan.firstTaskSucceeded = true
        var stored = plan
        stored.steps.append(.init(id: "keep", status: .active))
        let saved = stored
        let loaded = await MainActor.run {
            let store = OnboardingPlanStore(fileURL: url)
            store.save(saved)
            return store.load()
        }
        #expect(loaded?.steps.map(\.id) == plan.steps.map(\.id))
        #expect(loaded.map { advanced($0, .local(comfortable: true)).isComplete } == true)
    }
}

@Suite("Onboarding panel")
struct OnboardingPanelTests {
    private let sessionId = UUID()

    private func plan(_ pathId: String?, outcome: OnboardingPlan.RequestOutcome? = nil) -> OnboardingPlan {
        var plan = OnboardingPlan(sessionId: sessionId)
        if let pathId { plan.select(pathId: pathId) }
        plan.requestOutcome = outcome
        plan.advance(OnboardingAppSnapshot(plan: plan, brain: .local(comfortable: true)))
        return plan
    }

    private func panel(_ plan: OnboardingPlan, _ brain: OnboardingBrainState = .local(comfortable: true))
        -> OnboardingPanel?
    {
        OnboardingPanel.make(plan: plan, brain: brain, team: team, sessionId: sessionId)
    }

    private func asks(_ panel: OnboardingPanel?) -> [String] {
        panel?.buttons.compactMap { if case .ask(let id) = $0.action { return id } else { return nil } } ?? []
    }

    @Test
    func cards_followTheTeam() throws {
        let cards = try #require(panel(plan(nil))).cards
        #expect(cards.map(\.id) == ["planner", "courier", "keeper", "scout", "osaurus"])
        #expect(cards.map(\.access) == ["Calendar", "Mail", "Downloads", "Web", nil])
        #expect(cards.first { $0.id == "scout" }?.note == "Searches the web")
    }

    @Test
    func osaurusComesLast_byName_sayingWhatItDoes() throws {
        let osaurus = try #require(panel(plan(nil))?.cards.last)
        #expect(osaurus.id == "osaurus")
        #expect(osaurus.name == "Osaurus")
        #expect(osaurus.mascotId == Agent.defaultAgentStockAvatar, "the sidebar's dino, not a monogram")
        #expect(osaurus.pitch.contains("setting") && osaurus.pitch.contains("teammate"))
        let firstTask = try #require(panel(plan("osaurus")))
        #expect(
            firstTask.teammate == .init(pathId: "osaurus", name: "Osaurus", mascotId: Agent.defaultAgentStockAvatar))
        #expect(asks(firstTask) == ["osaurus.help", "osaurus.theme", "osaurus.team"])
        #expect(firstTask.buttons.first?.action != .request, "Osaurus needs no access first")
    }

    @Test
    func everyCard_speaksPlainly_inItsOwnVoice() throws {
        let cards = try #require(panel(plan(nil))).cards
        #expect(cards.first { $0.id == "planner" }?.pitch == "Work with me to plan out your day.")
        for card in cards {
            #expect(card.pitch.hasSuffix("."), "\(card.id)")
            #expect(card.pitch.split(separator: " ").count >= 6, "\(card.id): a sentence, not a label")
        }
    }

    @Test
    func eachCard_wearsItsAgentsSidebarAvatar() throws {
        let cards = try #require(panel(plan(nil))).cards
        #expect(cards.first { $0.id == "scout" }?.mascotId == Teammate.scout.avatar.rawValue)
        #expect(cards.first { $0.id == "planner" }?.mascotId == nil, "no avatar falls back to the monogram")
    }

    @Test
    func everyShippedTeammate_saysWhatItWorksWith() {
        let paths = OnboardingPaths.available(teammates: Set(Teammate.allCases)).filter { $0.teammate != nil }
        #expect(paths.count == Teammate.allCases.count)
        for path in paths {
            #expect(path.request.flatMap(OnboardingPanel.accessLabel) != nil, "\(path.id)")
        }
    }

    @Test
    func theFirstTaskHeader_namesThePickedTeammate_withItsAvatar() throws {
        let firstTask = try #require(panel(plan("scout")))
        #expect(
            firstTask.teammate == .init(pathId: "scout", name: "Scout", mascotId: Teammate.scout.avatar.rawValue))
    }

    @Test
    func aPath_firstMakesItsRequest_thenOffersItsAsks() throws {
        let request = try #require(panel(plan("planner")))
        #expect(request.buttons.first?.action == .request)
        #expect(asks(request).isEmpty)
        let granted = try #require(panel(plan("planner", outcome: .granted)))
        #expect(asks(granted) == ["planner.today", "planner.week", "planner.overdue"])
        #expect(granted.buttons.contains { $0.action == .back })
    }

    @Test
    func aDenial_showsTheSettingsLink_andLeavesTheOtherAsksUsable() throws {
        let denied = try #require(panel(plan("planner", outcome: .denied)))
        #expect(asks(denied) == ["planner.week", "planner.overdue"])
        #expect(denied.buttons.contains { $0.action == .openSettings(.calendar) })
        let keeper = try #require(panel(plan("keeper", outcome: .denied)))
        #expect(asks(keeper) == ["keeper.note"])
    }

    @Test
    func heldOnTheBridge_personalAsksWait_forThePrivateModel() throws {
        let bridged = try #require(panel(plan("planner", outcome: .granted), .bridged))
        #expect(asks(bridged).isEmpty)
        #expect(bridged.note?.contains("private model") == true)
        let scout = try #require(panel(plan("scout"), .bridged))
        #expect(asks(scout).count == 2, "web asks read nothing personal")
        let locked = try #require(panel(plan("scout"), .downloadingLocked))
        #expect(asks(locked).isEmpty, "nothing can answer yet")
    }

    @Test
    func onAProvider_theRequestSaysWhereTheDataGoes_first() throws {
        let request = try #require(panel(plan("courier"), .provider("Anthropic")))
        #expect(request.note?.contains("Anthropic") == true)
        #expect(request.buttons.first?.action == .request)
        #expect(panel(plan("courier"))?.note == nil)
    }

    @Test
    func scout_takesATopic_andShowsExamples() throws {
        let scout = try #require(panel(plan("scout")))
        #expect(scout.topicField)
        #expect(asks(scout) == ["scout.example1", "scout.example2"])
    }

    @Test
    func theFirstTask_offersBack_andNoSkipButton() throws {
        let granted = try #require(panel(plan("planner", outcome: .granted)))
        let controls = granted.buttons.filter { $0.style != .ask }.map(\.action)
        #expect(controls == [.back])
        #expect(OnboardingKeep.schedule(workflowId: OnboardingPaths.meetingPrepId)?.source.frequencyValue == "30 7 * * 1-5")
    }

    @Test
    func aFinishedPlan_showsNothing() {
        var finished = plan("planner", outcome: .granted)
        finished.finish(.firstTask, askId: "planner.today")
        #expect(panel(finished) == nil)
    }
}

@Suite("Prepared asks")
@MainActor
struct PreparedAskTests {
    @Test
    func everyPreparedAsk_parses_readsOnce_underATeammate_andWritesLocally() throws {
        let all = PreparedAskCatalog.templates()
        #expect(all.count == PreparedAskCatalog.resourceNames.count + PreparedAskCatalog.writeResourceNames.count)
        let templates = all.filter { $0.id != OnboardingKeep.saveNoteId }
        #expect(templates.count == PreparedAskCatalog.resourceNames.count)
        let teammateIDs = Set(Teammate.allCases.map(\.templateID.uuidString))
        for template in templates {
            let def = try #require(template.workflow, "\(template.name)")
            let refs = def.nodes.flatMap(\.calledTools)
            #expect(!refs.isEmpty, "\(template.name)")
            for ref in refs {
                let agent = try #require(ref.agent, "\(template.name): \(ref.name)")
                #expect(teammateIDs.contains(agent), "\(template.name)")
                #expect(
                    BundledTeamTests.readOnlyTools.union(["notes_list"]).contains(ref.name),
                    "\(template.name) calls \(ref.name)")
            }
            #expect(def.modelSlots.map(\.locality) == [.localOnly], "\(template.name)")
            let required = def.inputSchema.objectValue?["required"]?.arrayValue ?? []
            #expect(required.isEmpty, "\(template.name) needs no typed input")
        }
    }

    @Test
    func everyAskButton_pointsAtAPreparedAsk_orAnInstalledDefault() {
        let prepared = Set(PreparedAskCatalog.templates().map(\.id))
        let defaults = Set(TeamSeeder.bundledDefaultWorkflows().map(\.id))
        #expect(
            OnboardingPaths.osaurus.asks.allSatisfy { $0.workflowId == nil && !$0.readsPersonalData },
            "Osaurus's asks go to it as ordinary messages")
        for path in OnboardingPaths.all where path.teammate != nil {
            for ask in path.asks {
                guard let id = ask.workflowId else {
                    Issue.record("\(ask.id) runs no workflow")
                    continue
                }
                #expect(prepared.contains(id) || defaults.contains(id), "\(ask.id)")
                #expect(PreparedAskCatalog.installed(id: id)?.orchestratorVisible != true, "\(ask.id) stays hidden")
            }
        }
        #expect(PreparedAskCatalog.templates().allSatisfy { !defaults.contains($0.id) })
    }

    @Test
    func anAsk_dispatchesRunWorkflow_byWorkflowId_withItsInput() throws {
        let ask = OnboardingPaths.topicAsk("tide pools")
        let call = try #require(OnboardingFirstRun.dispatch(for: ask))
        #expect(call.toolName == RunWorkflowTool.toolName)
        let args = try #require(JSONValue.parse(call.jsonArguments)?.objectValue)
        #expect(args["workflow"]?.stringValue == OnboardingPaths.researchBriefId.uuidString)
        #expect(args["input"]?.objectValue?["topic"]?.stringValue == "tide pools")
    }

    @Test
    func theFirstTask_succeeds_onlyWhenEveryWorkflowRunCompleted_andTheReplyHasText() {
        func turns(result: String?, reply: String) -> [ChatTurn] {
            let user = ChatTurn(role: .user, content: "What is on my calendar today")
            let call = ChatTurn(role: .assistant, content: "")
            call.toolCalls = [
                ToolCall(id: "c1", type: "function", function: ToolCallFunction(name: "run_workflow", arguments: "{}"))
            ]
            if let result { call.toolResults["c1"] = result }
            return [user, call, ChatTurn(role: .assistant, content: reply)]
        }
        let ok = ToolEnvelope.success(tool: "run_workflow", result: ["answer": "Two meetings"])
        let failed = ToolEnvelope.failure(kind: .executionError, message: "failed", tool: "run_workflow")
        #expect(OnboardingFirstRun.firstTaskSucceeded(turns(result: ok, reply: "You have two meetings.")))
        #expect(!OnboardingFirstRun.firstTaskSucceeded(turns(result: failed, reply: "It failed.")))
        #expect(!OnboardingFirstRun.firstTaskSucceeded(turns(result: nil, reply: "Hm.")))
        #expect(!OnboardingFirstRun.firstTaskSucceeded(turns(result: ok, reply: "")))
    }

    @Test
    func runtimeNotices_coverTheBridgeHandover_only() {
        #expect(OnboardingFirstRun.notice(from: .bridged, to: .local(comfortable: true))?.key == "onboarding.local-ready")
        #expect(OnboardingFirstRun.notice(from: .downloadingLocked, to: .bridged)?.key == "onboarding.bridge-ready")
        #expect(OnboardingFirstRun.notice(from: nil, to: .local(comfortable: true)) == nil)
        #expect(
            OnboardingFirstRun.notice(from: .cloudConnecting, to: .provider("Osaurus Cloud"))?.key
                == "onboarding.cloud-ready")
        #expect(OnboardingFirstRun.notice(from: .provider("A"), to: .provider("B")) == nil)
    }
}

@Suite("Authored turn fields")
@MainActor
struct AuthoredTurnFieldTests {
    @Test
    func originAndRunLocation_roundTrip_andOldRowsDecodeWithout() throws {
        let turn = ChatTurn(role: .assistant, content: "Hi Alex")
        turn.origin = .authored
        turn.runLocation = .provider("Osaurus Cloud")
        let data = try JSONEncoder().encode(ChatTurnData(from: turn))
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: data)
        #expect(decoded.origin == .authored)
        #expect(decoded.runLocation == .provider("Osaurus Cloud"))
        let back = ChatTurn(from: decoded)
        #expect(back.origin == .authored && back.runLocation == .provider("Osaurus Cloud"))

        let plain = try JSONEncoder().encode(ChatTurnData(from: ChatTurn(role: .user, content: "hi")))
        let legacy = try JSONDecoder().decode(ChatTurnData.self, from: plain)
        #expect(legacy.origin == nil && legacy.runLocation == nil)
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("origin"))
    }
}

@Suite("Recent-first listing")
struct RecentFirstListingTests {
    @Test
    func recentFirst_listsTheNewestFilesFirst_withTheirDates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        for (index, name) in ["a-old.pdf", "b-new.pdf", "c-mid.pdf"].enumerated() {
            let url = root.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            let age: TimeInterval = [3, 1, 2][index] * 86_400
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let tool = FileTreeTool(rootPath: root)
        let recent = tool.entries(for: root, maxDepth: 1, recentFirst: true).entries
        #expect(recent.compactMap { $0["name"] as? String } == ["b-new.pdf", "c-mid.pdf", "a-old.pdf", "folder"])
        #expect(recent.first?["modified"] is String)
        let byName = tool.entries(for: root, maxDepth: 1).entries.compactMap { $0["name"] as? String }
        #expect(byName.first == "folder", "the default listing is unchanged")
    }
}

@Suite("Onboarding progress")
struct OnboardingProgressTests {
    @Test
    func theChapter_followsTheWalkthroughStep() {
        #expect(OnboardingChapter.of(nil) == .team)
        #expect(OnboardingChapter.of(.brain) == .model)
        #expect(OnboardingChapter.of(.team) == .team)
        #expect(OnboardingChapter.of(.firstTask) == .team)
        #expect(OnboardingChapter.allCases == [.welcome, .model, .team])
    }
}
