//
//  DiscoveryTests.swift
//  osaurusTests
//
//  The discovery catalog, its daily limit, and the walkthrough a card opens.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Discovery catalog")
@MainActor
struct DiscoveryCatalogTests {
    @Test
    func eachItem_followsItsShownAndRetiredRule() {
        let fresh = DiscoverySnapshot()
        #expect(DiscoveryCatalog.status(.history, in: fresh) == .open)
        #expect(DiscoveryCatalog.status(.turnOnWorkflow, in: fresh) == .hidden)
        #expect(DiscoveryCatalog.status(.keeperFolders, in: fresh) == .hidden)
        #expect(DiscoveryCatalog.status(.keeperRedaction, in: fresh) == .hidden)
        #expect(DiscoveryCatalog.status(.privacyAI, in: fresh) == .hidden)
        #expect(DiscoveryCatalog.status(.messages, in: fresh) == .hidden)

        var s = fresh
        s.ranWithoutAutomation = [OnboardingPaths.morningBriefId]
        s.keeperExists = true
        s.providerConnected = true
        s.courierExists = true
        #expect(DiscoveryCatalog.status(.turnOnWorkflow, in: s) == .open)
        #expect(DiscoveryCatalog.status(.keeperFolders, in: s) == .open)
        #expect(DiscoveryCatalog.status(.keeperRedaction, in: s) == .open)
        #expect(DiscoveryCatalog.status(.privacyAI, in: s) == .open)
        #expect(DiscoveryCatalog.status(.messages, in: s) == .open)

        s.defaultAutomationExists = true
        s.otherFolderAttached = true
        s.keeperRedactionOn = true
        s.enabledApps = [.contacts, .maps, .shortcuts, .music, .messages]
        s.courierHasMessages = true
        s.fullDiskAccess = true
        s.builderExists = true
        s.customAgentExists = true
        s.privacyAIOn = true
        s.searchProviderSet = true
        s.storeInstalled = true
        s.phonePaired = true
        s.encryptionOn = true
        s.voiceSetUp = true
        s.defaultWorkflowSucceeded = true
        s.memoryReviewed = true
        s.toolServerAdded = true
        s.channelConfigured = true
        s.skillOrPluginAdded = true
        s.orchestratorHasFolder = true
        s.computerOrBrowserOn = true
        let notDone = DiscoveryItem.allCases.filter { DiscoveryCatalog.status($0, in: s) != .done }
        // History retires through the import's notification, not a snapshot field.
        #expect(notDone == [.history])
    }

    @Test
    func tryAWorkflow_offersANeverRunDefault_theFirstTeammatesFirst() {
        var s = DiscoverySnapshot()
        #expect(DiscoveryCatalog.status(.tryWorkflow, in: s) == .hidden)
        s.neverRun = [OnboardingPaths.mailTriageId, OnboardingPaths.endOfDayId, TeamSeeder.repoDigestTemplateID]
        #expect(DiscoveryCatalog.status(.tryWorkflow, in: s) == .open)
        #expect(
            DiscoveryCatalog.workflowsToTry(s, startedWith: nil)
                == [OnboardingPaths.mailTriageId, OnboardingPaths.endOfDayId])
        #expect(DiscoveryCatalog.workflowsToTry(s, startedWith: .planner).first == OnboardingPaths.endOfDayId)
        #expect(DiscoveryCatalog.workflowsToTry(s, startedWith: .builder).first == OnboardingPaths.mailTriageId)
        s.builderHasFolder = true
        #expect(DiscoveryCatalog.workflowsToTry(s, startedWith: .builder).first == TeamSeeder.repoDigestTemplateID)

        s.defaultWorkflowSucceeded = true
        #expect(DiscoveryCatalog.status(.tryWorkflow, in: s) == .done)
        for teammate in Teammate.allCases {
            for id in DiscoveryCatalog.workflows(of: teammate) {
                #expect(DiscoveryCenter.schedulableWorkflows.contains(id), "\(teammate)")
            }
        }
    }

    @Test
    func memory_offersTurningOn_orReviewingOnceThereIsSomething() {
        var s = DiscoverySnapshot()
        #expect(DiscoveryCatalog.status(.memory, in: s) == .hidden)
        s.memoryHasEntries = true
        #expect(DiscoveryCatalog.status(.memory, in: s) == .open)
        #expect(DiscoveryCenter.step(.memory, snapshot: s, offer: nil)?.title == "Review Memory")
        s.memoryReviewed = true
        #expect(DiscoveryCatalog.status(.memory, in: s) == .done)
        s.memoryEnabled = false
        #expect(DiscoveryCatalog.status(.memory, in: s) == .open)
        #expect(DiscoveryCenter.step(.memory, snapshot: s, offer: nil)?.title == "Turn On Memory")
    }

    @Test
    func channels_waitForTheirCredentials_beforeOffering() {
        var s = DiscoverySnapshot()
        #expect(DiscoveryCatalog.status(.channels, in: s) == .hidden)
        s.channelConfigured = false
        #expect(DiscoveryCatalog.status(.channels, in: s) == .open)
        s.channelConfigured = true
        #expect(DiscoveryCatalog.status(.channels, in: s) == .done)
    }

    @Test
    func messagesOnSomeAgent_hidesTheCard_untilCourierHasItWithFullDiskAccess() {
        var s = DiscoverySnapshot()
        s.courierExists = true
        s.enabledApps = [.messages]
        #expect(DiscoveryCatalog.status(.messages, in: s) == .hidden)
        s.courierHasMessages = true
        #expect(DiscoveryCatalog.status(.messages, in: s) == .hidden)
        s.fullDiskAccess = true
        #expect(DiscoveryCatalog.status(.messages, in: s) == .done)
    }

    @Test
    func order_putsTheFirstChoicesItemsFirst_andKeepsEveryItemOnce() {
        #expect(DiscoveryCatalog.order(startedWith: nil) == DiscoveryCatalog.defaultOrder)
        #expect(Set(DiscoveryCatalog.defaultOrder) == Set(DiscoveryItem.allCases))
        #expect(DiscoveryCatalog.defaultOrder.count == DiscoveryItem.allCases.count)
        for teammate in Teammate.allCases {
            let order = DiscoveryCatalog.order(startedWith: teammate)
            #expect(order.count == DiscoveryItem.allCases.count && Set(order) == Set(DiscoveryItem.allCases))
        }
        #expect(DiscoveryCatalog.order(startedWith: .courier).first == .messages)
        #expect(DiscoveryCatalog.order(startedWith: .keeper).prefix(2) == [.keeperFolders, .keeperRedaction])
        #expect(DiscoveryCatalog.order(startedWith: .scout).first == .search)
    }

    @Test
    func titles_useTheTeammatesCurrentNames() {
        let names: [Teammate: String] = [.keeper: "Archie", .courier: "Postie", .scout: "Finder"]
        #expect(DiscoveryCatalog.title(.keeperFolders, names: names) == "Give Archie Your Documents and Desktop")
        #expect(DiscoveryCatalog.title(.messages, names: names) == "Connect Your Texts to Postie")
        #expect(DiscoveryCatalog.title(.search, names: names) == "Better Search for Finder")
        #expect(DiscoveryCatalog.line(.keeperRedaction, names: names).hasPrefix("Archie "))
        for item in DiscoveryItem.allCases {
            #expect(!DiscoveryCatalog.title(item, names: [:]).isEmpty)
            #expect(!DiscoveryCatalog.line(item, names: [:]).isEmpty)
            #expect(!DiscoveryCatalog.icon(item).isEmpty)
        }
    }

    @Test
    func builderAndMessages_haveTwoSteps_fromAppState() {
        var s = DiscoverySnapshot()
        #expect(DiscoveryCenter.step(.builder, snapshot: s, offer: nil)?.title == "Add Builder")
        s.builderExists = true
        #expect(DiscoveryCenter.step(.builder, snapshot: s, offer: nil)?.title == "Choose Project Folder")
        s.builderHasFolder = true
        #expect(DiscoveryCenter.step(.builder, snapshot: s, offer: nil) == nil)

        #expect(DiscoveryCenter.step(.messages, snapshot: s, offer: nil)?.title == "Open System Settings")
        s.fullDiskAccess = true
        #expect(DiscoveryCenter.step(.messages, snapshot: s, offer: nil)?.title == "Connect Messages")

        #expect(DiscoveryCenter.step(.turnOnWorkflow, snapshot: s, offer: nil) == nil)
        let offer = (id: OnboardingPaths.morningBriefId, name: "Morning Brief", when: "on weekday mornings")
        #expect(DiscoveryCenter.step(.turnOnWorkflow, snapshot: s, offer: offer)?.title == "Turn On Morning Brief")
        #expect(DiscoveryCenter.step(.tryWorkflow, snapshot: s, offer: nil) == nil)
        let trial = (id: OnboardingPaths.endOfDayId, name: "End of Day")
        #expect(DiscoveryCenter.step(.tryWorkflow, snapshot: s, offer: nil, trial: trial)?.title == "Run End of Day")
        for item in DiscoveryItem.allCases where item != .builder {
            #expect(
                DiscoveryCenter.step(item, snapshot: DiscoverySnapshot(), offer: offer, trial: trial) != nil,
                "\(item)")
        }
    }

    @Test
    func anItemThatAddsAnApp_asksForANewTeammate() {
        for item in [DiscoveryItem.people, .navigator, .shortcuts, .music] {
            let request = DiscoveryCenter.teammateRequest(item) ?? ""
            #expect(request.hasPrefix("Create a new agent named "), "\(item)")
            #expect(request.contains("with only the "), "\(item)")
            for teammate in ["Planner", "Courier", "Keeper", "Scout", "Builder"] {
                #expect(!request.contains(teammate), "\(item) names \(teammate)")
            }
        }
        #expect(DiscoveryCenter.teammateRequest(.messages) == nil)
        let folder = DiscoveryCenter.folderTeammateRequest(path: "/Users/me/Documents", folderName: "Documents")
        #expect(folder.hasPrefix("Create a new agent named "))
        #expect(folder.contains("/Users/me/Documents, read only"))
        #expect(!folder.contains("Keeper"))
    }

    @Test
    func endOfDayAndRepoDigest_haveSchedules() throws {
        let endOfDay = try #require(
            OnboardingKeep.automation(workflowId: OnboardingPaths.endOfDayId, name: "End of Day")
        )
        #expect(endOfDay.entry.source?.frequencyValue == "0 18 * * 1-5")
        let digest = try #require(
            OnboardingKeep.automation(workflowId: TeamSeeder.repoDigestTemplateID, name: "Repo Digest")
        )
        #expect(digest.entry.source?.frequencyValue == "0 16 * * 5")
        #expect(digest.entry.workflow == TeamSeeder.repoDigestTemplateID.uuidString)
        for id in DiscoveryCenter.schedulableWorkflows {
            #expect(OnboardingKeep.automation(workflowId: id, name: "x") != nil)
        }
    }
}

@Suite("Discovery store")
struct DiscoveryStoreTests {
    private let order: [DiscoveryItem] = [.voice, .history, .people]

    @Test
    func oneNewCardPerDay_aSeenCardMayRepeat() {
        var state = DiscoveryState()
        let first = DiscoveryStore.pick(order: order, isOpen: { _ in true }, state: &state, today: "2026-11-04")
        #expect(first == .voice)
        let again = DiscoveryStore.pick(order: order, isOpen: { _ in true }, state: &state, today: "2026-11-04")
        #expect(again == .voice)
        #expect(state.seen == [.voice])

        state.retired.insert(.voice)
        let sameDay = DiscoveryStore.pick(order: order, isOpen: { _ in true }, state: &state, today: "2026-11-04")
        #expect(sameDay == nil)

        let nextDay = DiscoveryStore.pick(order: order, isOpen: { _ in true }, state: &state, today: "2026-11-05")
        #expect(nextDay == .history)
        #expect(state.lastNewDay == "2026-11-05")
    }

    @Test
    func aNewDay_withNothingNew_repeatsASeenCard_andLeavesTheDayUnused() {
        var state = DiscoveryState(seen: [.people], lastNewDay: "2026-11-01")
        let picked = DiscoveryStore.pick(
            order: order,
            isOpen: { $0 == .people },
            state: &state,
            today: "2026-11-04"
        )
        #expect(picked == .people)
        #expect(state.lastNewDay == "2026-11-01")
    }

    @Test
    func persists_andDefaultsOn() {
        let defaults = UserDefaults(suiteName: "discovery-\(UUID().uuidString)")!
        let store = DiscoveryStore(defaults: defaults)
        #expect(store.isEnabled)
        #expect(store.load() == DiscoveryState())
        store.save(DiscoveryState(retired: [.phone], seen: [.phone, .voice], lastNewDay: "2026-11-04"))
        #expect(DiscoveryStore(defaults: defaults).load().retired == [.phone])
        store.isEnabled = false
        #expect(!DiscoveryStore(defaults: defaults).isEnabled)
    }

    @Test
    func aRemovedItem_inSavedState_leavesTheRestIntact() {
        let defaults = UserDefaults(suiteName: "discovery-\(UUID().uuidString)")!
        let saved = #"{"retired":["working_folder","phone"],"seen":["working_folder","voice"],"lastNewDay":"2026-11-04"}"#
        defaults.set(Data(saved.utf8), forKey: DiscoveryStore.stateKey)
        #expect(
            DiscoveryStore(defaults: defaults).load()
                == DiscoveryState(retired: [.phone], seen: [.voice], lastNewDay: "2026-11-04"))
    }

    @Test
    func day_isTheLocalCalendarDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = Date(timeIntervalSince1970: 1_793_779_200)  // 2026-11-04 08:00 UTC
        #expect(DiscoveryStore.day(date, calendar: calendar) == "2026-11-04")
    }
}

// MARK: - The card and its walkthrough

@MainActor
private final class DiscoveryRecorder {
    var asks: [(label: String, call: ServiceToolInvocation?)] = []
    var automations: [EventEntry] = []
    var settings: [String] = []
    var skipUndo: (@MainActor () -> Void)?
}

@MainActor
private func discovery(
    _ snapshot: DiscoverySnapshot = DiscoverySnapshot(),
    firstRunInProgress: Bool = false
) -> (DiscoveryCenter, DiscoveryRecorder) {
    let center = DiscoveryCenter.shared
    center.resetForTesting(store: DiscoveryStore(defaults: UserDefaults(suiteName: "discovery-\(UUID().uuidString)")!))
    let recorder = DiscoveryRecorder()
    center.snapshot = { snapshot }
    center.now = { Date(timeIntervalSince1970: 1_793_779_200) }
    center.sendAsk = { _, label, call in
        recorder.asks.append((label, call))
        return true
    }
    center.turnOnAutomation = { entry in
        await MainActor.run { recorder.automations.append(entry) }
        return .turnedOn
    }
    center.openSetting = { recorder.settings.append($0) }
    center.pickFolder = { _, _ in nil }
    center.createTeammate = { _ in }
    center.isPermissionGranted = { _ in true }
    center.firstRun = { (firstRunInProgress, nil) }
    center.showSkipNotice = { recorder.skipUndo = $0 }
    return (center, recorder)
}

@MainActor
private func restoreDiscovery(_ center: DiscoveryCenter) {
    center.snapshot = { DiscoveryCenter.liveSnapshot() }
    center.now = { Date() }
    center.sendAsk = { $0.sendPreparedAsk(label: $1, dispatch: $2) }
    center.turnOnAutomation = { await OnboardingKeep.turnOn($0) }
    center.openSetting = { SettingsLanding.open(id: $0) }
    center.createTeammate = { _ = await TeamSeeder.create([$0]) }
    center.isPermissionGranted = { SystemPermissionService.shared.isGranted($0) }
    center.firstRun = { DiscoveryCenter.liveFirstRun() }
    center.workflowName = { OnboardingPaths.installed($0)?.name }
    center.showSkipNotice = { DiscoveryCenter.showSkipToast(undo: $0) }
    center.resetForTesting(store: DiscoveryStore())
}

/// One serialized suite: every test swaps `DiscoveryCenter.shared`'s seams.
@Suite("Discovery cards and walkthrough", .serialized)
@MainActor
struct DiscoveryInChatTests {
    @Test
    func aNewChat_drawsOneCard_once() async throws {
        let (center, _) = discovery()
        defer { restoreDiscovery(center) }
        let session = ChatSession()
        center.draw(for: session)
        #expect(session.discoveryCard?.item == .history)
        session.discoveryCard = nil
        center.draw(for: session)
        #expect(session.discoveryCard == nil)

        // The same day, the next new chat repeats the seen card.
        let next = ChatSession()
        center.draw(for: next)
        #expect(next.discoveryCard?.item == .history)

        next.reset()
        #expect(!next.discoveryDrawn && next.discoveryCard == nil)
    }

    @Test
    func noCard_whenDisabled_orDuringTheFirstRun_orForAnotherAgent() async throws {
        let (center, _) = discovery()
        defer { restoreDiscovery(center) }
        center.store.isEnabled = false
        let disabled = ChatSession()
        center.draw(for: disabled)
        #expect(disabled.discoveryCard == nil)
        center.store.isEnabled = true

        let other = ChatSession()
        other.agentId = UUID()
        center.draw(for: other)
        #expect(other.discoveryCard == nil)

        _ = discovery(firstRunInProgress: true)
        let duringSetup = ChatSession()
        center.draw(for: duringSetup)
        #expect(duringSetup.discoveryCard == nil)
    }

    @Test
    func skipSetUp_turnsDiscoveryOff_untilUndo() async throws {
        let (center, recorder) = discovery()
        defer { restoreDiscovery(center) }
        center.skipSetUp()
        #expect(!center.store.isEnabled)
        let skipped = ChatSession()
        center.draw(for: skipped)
        #expect(skipped.discoveryCard == nil && skipped.setUpLeft == 0)

        let undo = try #require(recorder.skipUndo)
        undo()
        #expect(center.store.isEnabled)
        let back = ChatSession()
        center.draw(for: back)
        #expect(back.discoveryCard != nil && back.setUpLeft > 0)
        #expect(center.remaining().contains(.history), "Set Up Osaurus keeps its list either way")
    }

    @Test
    func dismissing_retiresTheItemForGood() async throws {
        let (center, _) = discovery()
        defer { restoreDiscovery(center) }
        let session = ChatSession()
        center.draw(for: session)
        center.dismiss(.history, in: session)
        #expect(session.discoveryCard == nil)
        #expect(center.store.load().retired.contains(.history))
        #expect(!center.remaining().isEmpty)

        // Nothing new until tomorrow, and the dismissed card never returns.
        let next = ChatSession()
        center.draw(for: next)
        #expect(next.discoveryCard == nil)
    }

    @Test
    func doingTheThing_retiresTheCard() async throws {
        var done = DiscoverySnapshot()
        done.importPromptSeen = true
        done.enabledApps = [.contacts]
        let (center, _) = discovery(done)
        defer { restoreDiscovery(center) }
        let session = ChatSession()
        center.draw(for: session)
        #expect(session.discoveryCard?.item == .navigator)
        #expect(center.store.load().retired.contains(.people))
    }

    // MARK: Walkthrough
    @Test
    func opening_showsAnAuthoredLine_andOneStep_andNotNowEndsIt() async throws {
        try await ChatHistoryTestStorage.run {
            let (center, _) = discovery()
            defer { restoreDiscovery(center) }
            let session = ChatSession()
            center.draw(for: session)
            center.open(.people, in: session)
            let line = try #require(session.turns.last)
            #expect(line.content == DiscoveryCatalog.line(.people, names: [:]))
            #expect(line.origin == .authored && line.modelContextExcluded)
            #expect(session.discoveryCard == nil)

            let (turnId, panel) = try #require(center.panel(for: session))
            #expect(turnId == line.id && panel.isDiscovery)
            #expect(panel.buttons.map { $0.action } == [.discover, .skip])
            #expect(panel.buttons.first?.title == "Add People")

            center.perform(.skip, in: session)
            #expect(center.panel(for: session) == nil)
            #expect(session.turns.last?.origin == .authored)
            #expect(session.turns.allSatisfy { $0.modelContextExcluded })
        }
    }

    @Test
    func addingATeammate_goesToTheConfigurator_withTheRequest() async throws {
        try await ChatHistoryTestStorage.run {
            let (center, recorder) = discovery()
            defer { restoreDiscovery(center) }
            let session = ChatSession()
            center.open(.navigator, in: session)
            center.perform(.discover, in: session)
            await center.waitForStep()
            let ask = try #require(recorder.asks.first)
            #expect(ask.label == DiscoveryCenter.teammateRequest(.navigator))
            #expect(ask.call?.toolName == ConfiguratorHandoffTool.toolName)
            #expect(ask.call?.jsonArguments.contains("Navigator") == true)
            #expect(center.panel(for: session) == nil)
        }
    }

    @Test
    func turningOnAWorkflow_createsItsAutomation() async throws {
        try await ChatHistoryTestStorage.run {
            var s = DiscoverySnapshot()
            s.ranWithoutAutomation = [OnboardingPaths.endOfDayId]
            let (center, recorder) = discovery(s)
            defer { restoreDiscovery(center) }
            let session = ChatSession()
            center.open(.turnOnWorkflow, in: session)
            center.perform(.discover, in: session)
            await center.waitForStep()
            let entry = try #require(recorder.automations.first)
            #expect(entry.workflow == OnboardingPaths.endOfDayId.uuidString)
            #expect(entry.source?.frequencyValue == "0 18 * * 1-5")
            #expect(session.turns.last?.origin == .authored)
            #expect(center.panel(for: session) == nil)
        }
    }

    @Test
    func aSettingsItem_opensItsCatalogRow() async throws {
        try await ChatHistoryTestStorage.run {
            let (center, recorder) = discovery()
            defer { restoreDiscovery(center) }
            for (item, id) in [
                (DiscoveryItem.search, "search.providers"), (.phone, "settings.connect.pairing"),
                (.encryption, "storage.encryption"), (.voice, "voice.stt.model"), (.privacyAI, "privacy.models"),
                (.toolServer, "tools.directory"), (.channels, "agentChannels.overview"),
                (.skills, "skills.overview"), (.computerUse, "computerUse.enable"),
            ] {
                let session = ChatSession()
                center.open(item, in: session)
                center.perform(.discover, in: session)
                await center.waitForStep()
                #expect(recorder.settings.last == id)
                #expect(SettingsSearchIndex.entries.contains { $0.id == id }, "\(id)")
            }
        }
    }

    @Test
    func memory_opensItsSwitch_orItsList_andReviewingRetiresIt() async throws {
        try await ChatHistoryTestStorage.run {
            var off = DiscoverySnapshot()
            off.memoryEnabled = false
            let (center, recorder) = discovery(off)
            defer { restoreDiscovery(center) }
            let first = ChatSession()
            center.open(.memory, in: first)
            center.perform(.discover, in: first)
            await center.waitForStep()
            #expect(recorder.settings.last == "memory.settings.enabled")
            #expect(!center.store.load().taken.contains(.memory))

            var on = DiscoverySnapshot()
            on.memoryHasEntries = true
            center.snapshot = { on }
            let second = ChatSession()
            center.open(.memory, in: second)
            center.perform(.discover, in: second)
            await center.waitForStep()
            #expect(recorder.settings.last == "memory.settings")
            let state = center.store.load()
            #expect(state.taken.contains(.memory) && state.retired.contains(.memory))
            for id in ["memory.settings", "memory.settings.enabled"] {
                #expect(SettingsSearchIndex.entries.contains { $0.id == id }, "\(id)")
            }
        }
    }

    @Test
    func theOrchestratorFolder_isSetFromThePicker() async throws {
        try await ChatHistoryTestStorage.run {
            let (center, _) = discovery()
            defer { restoreDiscovery(center) }
            let saved = DefaultAgentConfigurationStore.load()
            defer { DefaultAgentConfigurationStore.save(saved) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            center.pickFolder = { _, _ in folder }
            let session = ChatSession()
            center.open(.orchestratorFolder, in: session)
            center.perform(.discover, in: session)
            await center.waitForStep()
            #expect(AgentManager.shared.workingFolder(for: Agent.defaultId)?.path == folder.path)
            #expect(session.turns.last?.content == "The Orchestrator works in \(folder.lastPathComponent) now.")
        }
    }

    @Test
    func tryingAWorkflow_runsIt_andACompletedRunOffersToTurnItOn() async throws {
        try await ChatHistoryTestStorage.run {
            var s = DiscoverySnapshot()
            s.neverRun = [OnboardingPaths.mailTriageId, OnboardingPaths.endOfDayId]
            let (center, recorder) = discovery(s)
            defer { restoreDiscovery(center) }
            center.workflowName = { $0 == OnboardingPaths.endOfDayId ? "End of Day" : "Mail Triage" }
            center.firstRun = { (false, .planner) }
            let session = ChatSession()
            center.open(.tryWorkflow, in: session)
            #expect(session.turns.last?.content.hasPrefix("End of Day came with Osaurus.") == true)
            #expect(center.panel(for: session)?.panel.buttons.first?.title == "Run End of Day")
            center.perform(.discover, in: session)
            await center.waitForStep()
            let ask = try #require(recorder.asks.first)
            #expect(ask.label == "Run End of Day")
            #expect(ask.call?.toolName == RunWorkflowTool.toolName)
            #expect(ask.call?.jsonArguments.contains(OnboardingPaths.endOfDayId.uuidString) == true)
            #expect(center.panel(for: session) == nil)

            session.appendAuthoredTurn(ChatTurn(role: .user, content: "Run End of Day"))
            session.appendAuthoredTurn(ChatTurn(role: .assistant, content: "Here is your day."))
            var ran = s
            ran.neverRun = [OnboardingPaths.mailTriageId]
            ran.ranWithoutAutomation = [OnboardingPaths.mailTriageId, OnboardingPaths.endOfDayId]
            ran.defaultWorkflowSucceeded = true
            center.snapshot = { ran }
            center.runEnded(in: session)
            #expect(center.panel(for: session)?.panel.buttons.first?.title == "Turn On End of Day")
            // Only the run the card started.
            let other = ChatSession()
            center.runEnded(in: other)
            #expect(center.panel(for: other) == nil)
        }
    }

    @Test
    func setUpOsaurus_listsWhatIsLeft_andOpensAnItem() async throws {
        try await ChatHistoryTestStorage.run {
            let (center, _) = discovery()
            defer { restoreDiscovery(center) }
            // Asking for the list works with the cards off.
            center.store.isEnabled = false
            let session = ChatSession()
            center.showSetUp(in: session, source: .settings)
            let (_, list) = try #require(center.panel(for: session))
            #expect(list.buttons.map(\.action) == center.remaining().map { .openDiscovery($0) })
            #expect(list.buttons.allSatisfy { $0.style == .ask })

            center.perform(.openDiscovery(.voice), in: session)
            let echoed = session.turns.suffix(2).map { $0.content }
            #expect(
                echoed == [DiscoveryCatalog.title(.voice, names: [:]), DiscoveryCatalog.line(.voice, names: [:])]
            )
            #expect(center.panel(for: session)?.panel.buttons.first?.title == "Set Up Voice")
        }
    }

    @Test
    func aNewChat_linksToWhatIsLeft_butNotDuringTheFirstRun() async throws {
        let (center, _) = discovery()
        defer { restoreDiscovery(center) }
        let session = ChatSession()
        center.draw(for: session)
        #expect(session.setUpLeft == center.remaining().count && session.setUpLeft > 0)

        _ = discovery(firstRunInProgress: true)
        let duringSetup = ChatSession()
        center.draw(for: duringSetup)
        #expect(duringSetup.setUpLeft == 0)
    }

    @Test
    func setUpOsaurus_listsWhatIsLeft() async throws {
        try await ChatHistoryTestStorage.run {
            let (center, _) = discovery()
            defer { restoreDiscovery(center) }
            let session = ChatSession()
            center.showSetUp(in: session, source: .menu)
            let (turnId, list) = try #require(center.panel(for: session))
            #expect(turnId == session.turns.last?.id)
            #expect(list.buttons.map(\.action) == center.remaining().map { .openDiscovery($0) })
        }
    }

    @Test
    func setUpOsaurus_withNothingLeft_saysSo() async throws {
        try await ChatHistoryTestStorage.run {
            var all = DiscoverySnapshot()
            all.defaultAutomationExists = true
            all.importPromptSeen = true
            all.enabledApps = [.contacts, .maps, .shortcuts, .music]
            all.builderExists = true
            all.customAgentExists = true
            all.searchProviderSet = true
            all.storeLive = false
            all.phonePaired = true
            all.encryptionOn = true
            all.voiceSetUp = true
            all.toolServerAdded = true
            all.skillOrPluginAdded = true
            all.orchestratorHasFolder = true
            all.computerOrBrowserOn = true
            let (center, _) = discovery(all)
            defer { restoreDiscovery(center) }
            #expect(center.remaining().isEmpty)
            let session = ChatSession()
            center.showSetUp(in: session, source: .menu)
            #expect(session.turns.last?.content == "Everything is set up. Ask me anything.")
            #expect(center.panel(for: session) == nil)
        }
    }
}
