//
//  DiscoveryCenter.swift
//  osaurus
//
//  Discovery in the app: draws one card for each new chat, runs the small
//  walkthrough a card opens (an authored line and a panel of one or two
//  steps), and lists what is left for Set Up Osaurus. A step that changes
//  configuration goes to the Configurator through the approval card, in
//  the Orchestrator's chat, so the Orchestrator has the chat afterwards.
//  A typed message during a walkthrough goes straight to the Orchestrator.
//

import AppKit
import Foundation

/// The card under the greeting.
struct DiscoveryCard: Equatable, Sendable {
    let item: DiscoveryItem
    let title: String
    let icon: String
}

@MainActor
final class DiscoveryCenter {
    static let shared = DiscoveryCenter()

    var store = DiscoveryStore()

    // Test seams.
    var snapshot: () -> DiscoverySnapshot = { DiscoveryCenter.liveSnapshot() }
    var now: () -> Date = { Date() }
    var turnOnAutomation: (EventEntry) async -> OnboardingKeep.Outcome = { await OnboardingKeep.turnOn($0) }
    var pickFolder: @MainActor (_ message: String, _ directory: URL?) async -> URL? = {
        await DiscoveryCenter.runFolderPanel(message: $0, directory: $1)
    }
    var openSetting: @MainActor (String) -> Void = { SettingsLanding.open(id: $0) }
    var sendAsk: (ChatSession, String, ServiceToolInvocation?) -> Bool = {
        $0.sendPreparedAsk(label: $1, dispatch: $2)
    }
    var createTeammate: (Teammate) async -> Void = { _ = await TeamSeeder.create([$0]) }
    /// An installed default workflow's name, by template id.
    var workflowName: (UUID) -> String? = { OnboardingPaths.installed($0)?.name }
    var isPermissionGranted: (SystemPermission) -> Bool = { SystemPermissionService.shared.isGranted($0) }
    /// Whether the first run is still going, and who it started with.
    var firstRun: () -> (inProgress: Bool, startedWith: Teammate?) = { DiscoveryCenter.liveFirstRun() }
    /// Says setup suggestions are off, with Undo.
    var showSkipNotice: @MainActor (_ undo: @escaping @MainActor () -> Void) -> Void = {
        DiscoveryCenter.showSkipToast(undo: $0)
    }

    private enum Overlay: Equatable {
        case item(DiscoveryItem)
        case setUp
    }

    /// The open walkthrough in each chat and the authored line it sits under.
    private var overlays: [UUID: (overlay: Overlay, turnId: UUID)] = [:]
    /// The default workflow a Try card ran in each chat, by template id,
    /// until that run ends.
    private var trials: [UUID: UUID] = [:]
    /// The last Try card run that completed, offered first to turn on.
    private var recentTrial: UUID?
    private var inFlight = false
    private var observers: [NSObjectProtocol] = []
    /// Whether any channel is set up. Nil until its credentials are read.
    private var channelConfigured: Bool?
    private var channelRefreshInFlight = false

    private init() {
        observers.append(
            NotificationCenter.default.addObserver(forName: .chatSessionsImported, object: nil, queue: .main) {
                _ in
                MainActor.assumeIsolated { DiscoveryCenter.shared.retireDone(.history) }
            }
        )
        // A step can wait on System Settings; coming back shows the next one.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { DiscoveryCenter.shared.refreshOpenPanels() }
            }
        )
    }

    /// Discovery is a setting.
    var isActive: Bool { store.isEnabled }

    // MARK: - The card

    /// Draws this chat's card once, when its empty state first shows.
    func draw(for session: ChatSession) {
        guard !session.discoveryDrawn else { return }
        session.discoveryDrawn = true
        guard isActive, session.turns.isEmpty, (session.agentId ?? Agent.defaultId) == Agent.defaultId,
            !firstRun().inProgress
        else { return }
        session.discoveryCard = card()
        session.setUpLeft = remaining().count
    }

    private func card() -> DiscoveryCard? {
        let snapshot = snapshot()
        var state = store.load()
        retireDone(in: snapshot, state: &state)
        let order = DiscoveryCatalog.order(startedWith: firstRun().startedWith)
        let seenBefore = state.seen
        let picked = DiscoveryStore.pick(
            order: order,
            isOpen: { DiscoveryCatalog.status($0, in: snapshot) == .open },
            state: &state,
            today: DiscoveryStore.day(now())
        )
        store.save(state)
        guard let picked else { return nil }
        OnboardingTelemetry.discoveryShown(picked, new: !seenBefore.contains(picked))
        let names = teammateNames()
        return DiscoveryCard(
            item: picked,
            title: DiscoveryCatalog.title(picked, names: names),
            icon: DiscoveryCatalog.icon(picked)
        )
    }

    /// Never during the first run, including before its opening lands.
    static func liveFirstRun() -> (inProgress: Bool, startedWith: Teammate?) {
        let run = OnboardingFirstRun.shared
        let plan = run.plan
        let pending = run.defaults.bool(forKey: OnboardingFirstRun.openingPendingKey)
        return (pending || plan.map { !$0.isFinished } == true, plan?.path?.teammate)
    }

    /// Skip setup under a new chat's greeting: the same switch as Settings →
    /// Chat → Show Discovery Cards, so the card and the link leave every
    /// new chat at once. Set Up Osaurus stays in the menu and in Settings.
    func skipSetUp() {
        guard store.isEnabled else { return }
        store.isEnabled = false
        FeatureTelemetry.discoveryToggled(enabled: false, source: "greeting")
        showSkipNotice { [store] in
            store.isEnabled = true
            FeatureTelemetry.discoveryToggled(enabled: true, source: "undo")
        }
    }

    private static let undoSkipActionId = "discovery.undoSkipSetUp"

    static func showSkipToast(undo: @escaping @MainActor () -> Void) {
        ToastManager.shared.registerActionHandler(for: undoSkipActionId) { _ in
            MainActor.assumeIsolated { undo() }
        }
        ToastManager.shared.show(
            Toast(
                type: .info,
                title: L("Setup suggestions are off"),
                message: L("Turn them back on in Settings → Chat → Show Discovery Cards."),
                timeout: 8,
                actionTitle: L("Undo"),
                actionId: undoSkipActionId
            )
        )
    }

    /// The dismiss control: retired for good.
    func dismiss(_ item: DiscoveryItem, in session: ChatSession) {
        var state = store.load()
        state.retired.insert(item)
        store.save(state)
        OnboardingTelemetry.discoveryDeclined(item, via: "dismiss")
        session.discoveryCard = nil
    }

    /// The card was tapped: the walkthrough starts in this chat.
    func open(_ item: DiscoveryItem, in session: ChatSession) {
        session.discoveryCard = nil
        OnboardingTelemetry.discoveryOpened(item, from: "card")
        start(item, in: session)
    }

    private func retireDone(in snapshot: DiscoverySnapshot, state: inout DiscoveryState) {
        for item in DiscoveryItem.allCases
        where !state.retired.contains(item) && DiscoveryCatalog.status(item, in: snapshot) == .done {
            state.retired.insert(item)
            if state.seen.contains(item) { OnboardingTelemetry.discoveryCompleted(item) }
        }
    }

    private func retireDone(_ item: DiscoveryItem) {
        var state = store.load()
        guard !state.retired.contains(item) else { return }
        state.retired.insert(item)
        store.save(state)
        if state.seen.contains(item) { OnboardingTelemetry.discoveryCompleted(item) }
    }

    // MARK: - Set Up Osaurus

    enum SetUpSource: String {
        case menu
        case settings
        /// The link under a new chat's greeting.
        case greeting
    }

    /// What is left, in order: every open item, dismissed ones included,
    /// because the person asked.
    func remaining() -> [DiscoveryItem] {
        let snapshot = snapshot()
        return DiscoveryCatalog.order(startedWith: firstRun().startedWith)
            .filter { DiscoveryCatalog.status($0, in: snapshot) == .open }
    }

    /// Opens a new chat that lists what is left to set up.
    func openSetUp(from source: SetUpSource) {
        let windowId = ChatWindowManager.shared.createWindow(agentId: Agent.defaultId)
        guard let session = ChatWindowManager.shared.windowState(id: windowId)?.session else { return }
        showSetUp(in: session, source: source)
    }

    func showSetUp(in session: ChatSession, source: SetUpSource) {
        let items = remaining()
        FeatureTelemetry.setUpOsaurusOpened(source: source.rawValue, remaining: items.count)
        session.discoveryDrawn = true
        session.discoveryCard = nil
        session.setUpLeft = 0
        guard !items.isEmpty else {
            appendAuthored(L("Everything is set up. Ask me anything."), to: session)
            return
        }
        let turn = appendAuthored(L("Here is what is left to set up. Pick one, or ask me anything."), to: session)
        if let sessionId = session.sessionId { overlays[sessionId] = (.setUp, turn.id) }
        session.rebuildVisibleBlocks()
    }

    // MARK: - The walkthrough

    private func start(_ item: DiscoveryItem, in session: ChatSession) {
        let turn = appendAuthored(line(for: item), to: session)
        if let sessionId = session.sessionId { overlays[sessionId] = (.item(item), turn.id) }
        session.rebuildVisibleBlocks()
    }

    private func line(for item: DiscoveryItem) -> String {
        if item == .turnOnWorkflow, let offer = workflowOffer(snapshot()) {
            return String(format: L("%@ can run on its own %@. You approve it first."), offer.name, offer.when)
        }
        if item == .tryWorkflow, let trial = trialOffer(snapshot()) {
            return String(
                format: L("%@ came with Osaurus. Run it once here to see what it gives you. If you like it, it can run on its own later."),
                trial.name
            )
        }
        return DiscoveryCatalog.line(item, names: teammateNames())
    }

    /// The panel under the open walkthrough's line, while it is the latest.
    func panel(for session: ChatSession) -> (turnId: UUID, panel: OnboardingPanel)? {
        guard let sessionId = session.sessionId, let open = overlays[sessionId], !session.isStreaming,
            session.turns.last?.id == open.turnId
        else { return nil }
        let snapshot = snapshot()
        var panel = OnboardingPanel(sessionId: sessionId)
        panel.isDiscovery = true
        switch open.overlay {
        case .setUp:
            let names = teammateNames()
            panel.buttons = remaining().map {
                .init(
                    action: .openDiscovery($0),
                    title: DiscoveryCatalog.title($0, names: names),
                    icon: nil,
                    style: .ask
                )
            }
        case .item(let item):
            guard
                let step = Self.step(
                    item,
                    snapshot: snapshot,
                    offer: workflowOffer(snapshot),
                    trial: trialOffer(snapshot)
                )
            else { return nil }
            panel.note = step.note
            panel.buttons = [
                .init(action: .discover, title: step.title, icon: DiscoveryCatalog.icon(item), style: .primary),
                .init(action: .skip, title: L("Not Now"), icon: nil, style: .quiet),
            ]
        }
        return panel.buttons.isEmpty ? nil : (open.turnId, panel)
    }

    /// The step an item is on, from app state: most have one; Builder,
    /// Messages, and Memory have two.
    static func step(
        _ item: DiscoveryItem,
        snapshot s: DiscoverySnapshot,
        offer: (id: UUID, name: String, when: String)?,
        trial: (id: UUID, name: String)? = nil
    ) -> (title: String, note: String?)? {
        switch item {
        case .tryWorkflow:
            guard let trial else { return nil }
            return (String(format: L("Run %@"), trial.name), nil)
        case .turnOnWorkflow:
            guard let offer else { return nil }
            return (String(format: L("Turn On %@"), offer.name), nil)
        case .keeperFolders: return (L("Choose Folder"), nil)
        case .keeperRedaction: return (L("Turn On Detection"), L("You approve the change first."))
        case .history: return (L("Bring History"), nil)
        case .people: return (L("Add People"), L("You approve the new teammate first."))
        case .navigator: return (L("Add Navigator"), L("You approve the new teammate first."))
        case .builder:
            if !s.builderExists { return (L("Add Builder"), nil) }
            return s.builderHasFolder ? nil : (L("Choose Project Folder"), L("Builder works in one project folder."))
        case .ownAgent: return (L("Make an Agent"), nil)
        case .privacyAI: return (L("Open Detection Models"), L("The detection model is a 2.8 GB download."))
        case .search: return (L("Open Search Providers"), nil)
        case .shortcuts: return (L("Add Shortcuts Teammate"), L("You approve the new teammate first."))
        case .store: return (L("Open Workflows"), nil)
        case .messages:
            if !s.fullDiskAccess {
                return (
                    L("Open System Settings"),
                    L("Turn on Osaurus under Full Disk Access, then come back here.")
                )
            }
            return (L("Connect Messages"), L("You approve the change first."))
        case .phone: return (L("Pair iPhone"), nil)
        case .encryption: return (L("Open Encryption"), nil)
        case .music: return (L("Add Music Teammate"), L("You approve the new teammate first."))
        case .voice: return (L("Set Up Voice"), nil)
        case .memory: return s.memoryEnabled ? (L("Review Memory"), nil) : (L("Turn On Memory"), nil)
        case .toolServer: return (L("Browse Tool Servers"), nil)
        case .channels: return (L("Open Channels"), nil)
        case .skills: return (L("Open Skills"), nil)
        case .orchestratorFolder: return (L("Choose Folder"), nil)
        case .computerUse: return (L("Open Computer Use"), nil)
        }
    }

    func perform(_ action: OnboardingAction, sessionId: UUID) {
        guard let session = ChatWindowManager.shared.session(forSessionId: sessionId) else { return }
        perform(action, in: session)
    }

    func perform(_ action: OnboardingAction, in session: ChatSession) {
        guard let sessionId = session.sessionId, let open = overlays[sessionId] else { return }
        switch (action, open.overlay) {
        case (.openDiscovery(let item), .setUp):
            appendAuthored(DiscoveryCatalog.title(item, names: teammateNames()), role: .user, to: session)
            OnboardingTelemetry.discoveryOpened(item, from: "set_up")
            start(item, in: session)
        case (.skip, .item(let item)):
            overlays[sessionId] = nil
            OnboardingTelemetry.discoveryDeclined(item, via: "not_now")
            appendAuthored(L("Okay. It is in Set Up Osaurus whenever you want it."), to: session)
        case (.discover, .item(let item)):
            guard !inFlight else { return }
            inFlight = true
            Task {
                defer { inFlight = false }
                await take(item, in: session)
            }
        default:
            break
        }
    }

    /// Waits for a step started by `perform` to finish.
    func waitForStep() async {
        while inFlight { await Task.yield() }
    }

    private func take(_ item: DiscoveryItem, in session: ChatSession) async {
        guard let sessionId = session.sessionId else { return }
        OnboardingTelemetry.discoveryTaken(item)
        let snapshot = snapshot()
        let names = teammateNames()
        func end(_ line: String? = nil) {
            overlays[sessionId] = nil
            if let line { appendAuthored(line, to: session) } else { session.rebuildVisibleBlocks() }
        }
        func configure(_ request: String) {
            overlays[sessionId] = nil
            if !sendAsk(session, request, OnboardingFirstRun.configuratorDispatch(request)) {
                appendAuthored(L("I can do that once a model is ready."), to: session)
            }
        }
        switch item {
        case .tryWorkflow:
            guard let trial = trialOffer(snapshot) else { return end() }
            overlays[sessionId] = nil
            let ask = OnboardingAsk(
                id: "discovery-try",
                label: String(format: L("Run %@"), trial.name),
                workflowId: trial.id,
                readsPersonalData: true,
                dependsOnRequest: false
            )
            if sendAsk(session, ask.label, OnboardingFirstRun.dispatch(for: ask)) {
                trials[sessionId] = trial.id
            } else {
                appendAuthored(L("I can do that once a model is ready."), to: session)
            }
        case .turnOnWorkflow:
            guard let offer = workflowOffer(snapshot),
                let automation = OnboardingKeep.automation(workflowId: offer.id, name: offer.name)
            else { return end() }
            let outcome = await turnOnAutomation(automation.entry)
            OnboardingTelemetry.keepResolved(offer: "turn_on", outcome: outcome)
            if outcome == .turnedOn {
                await OnboardingKeep.requestGrants(
                    forWorkflow: offer.id,
                    isGranted: isPermissionGranted,
                    request: { await SystemPermissionService.shared.requestPermissionAndWait($0) },
                    readDownloads: { await OnboardingFirstRun.shared.readDownloads() }
                )
            }
            switch outcome {
            case .turnedOn: end(String(format: L("%@ is on. It runs %@."), offer.name, automation.when))
            case .declined: end(L("Okay, it stays off. You can turn it on any time in Automations."))
            case .failed(let reason): end(String(format: L("I could not turn it on: %@"), reason))
            }
        case .keeperFolders:
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            guard let url = await pickFolder(L("Choose a folder for the new teammate to read."), documents) else {
                return
            }
            configure(Self.folderTeammateRequest(path: url.path, folderName: url.lastPathComponent))
        case .keeperRedaction:
            configure(String(format: "Turn on the redaction tools for the agent named %@.", names[.keeper] ?? "Keeper"))
        case .history:
            ImportHistoryPromptGate.shared.markSeen()
            end()
            ChatSessionImportCoordinator.run(agentId: nil, source: .discovery)
        case .people, .navigator, .shortcuts, .music:
            guard let request = Self.teammateRequest(item) else { return end() }
            configure(request)
        case .builder:
            if !snapshot.builderExists {
                await createTeammate(.builder)
                let name = teammateNames()[.builder] ?? "Builder"
                appendAuthored(
                    String(format: L("%@ is on your team. Choose the project it works in."), name),
                    to: session
                )
                if let last = session.turns.last { overlays[sessionId] = (.item(.builder), last.id) }
                session.rebuildVisibleBlocks()
                return
            }
            guard let url = await pickFolder(L("Choose the project Builder works in."), nil),
                let builder = AgentManager.shared.agents.first(where: { $0.teammate == .builder })
            else { return }
            AgentManager.shared.updateWorkingFolder(for: builder.id, bookmark: Self.bookmark(url), path: url.path)
            end(String(format: L("%@ works in %@ now."), builder.name, url.lastPathComponent))
        case .ownAgent:
            end()
            AgentCreatorLauncher.open(source: .discovery)
        case .privacyAI:
            end()
            openSetting("privacy.models")
        case .search:
            end()
            openSetting("search.providers")
        case .store:
            end()
            ChatWindowManager.shared.showWorkflowsSurface()
        case .messages:
            if !snapshot.fullDiskAccess {
                SystemPermissionService.shared.openSystemSettings(for: .disk)
                return
            }
            configure(
                String(
                    format:
                        "Turn on the Messages app for the agent named %@, and set its description to: Email in Mail and texts in Messages. Use for reading, finding, sorting, and drafting replies. Not for posting to Slack, Discord, or another channel.",
                    names[.courier] ?? "Courier"))
        case .phone:
            end()
            openSetting("settings.connect.pairing")
        case .encryption:
            end()
            openSetting("storage.encryption")
        case .voice:
            end()
            openSetting("voice.stt.model")
        case .memory:
            end()
            if snapshot.memoryEnabled {
                var state = store.load()
                state.taken.insert(.memory)
                store.save(state)
                retireDone(.memory)
                openSetting("memory.settings")
            } else {
                openSetting("memory.settings.enabled")
            }
        case .toolServer:
            end()
            openSetting("tools.directory")
        case .channels:
            end()
            openSetting("agentChannels.overview")
        case .skills:
            end()
            openSetting("skills.overview")
        case .orchestratorFolder:
            guard let url = await pickFolder(L("Choose a folder for the Orchestrator to work in."), nil) else { return }
            AgentManager.shared.updateWorkingFolder(for: Agent.defaultId, bookmark: Self.bookmark(url), path: url.path)
            end(String(format: L("The Orchestrator works in %@ now."), url.lastPathComponent))
        case .computerUse:
            end()
            openSetting("computerUse.enable")
        }
    }

    // MARK: - Run end

    /// A Try card's run ended: when it completed, the turn-on step follows
    /// in the same chat.
    func runEnded(in session: ChatSession) {
        guard let sessionId = session.sessionId, let templateID = trials.removeValue(forKey: sessionId),
            OnboardingFirstRun.firstTaskSucceeded(session.turns)
        else { return }
        recentTrial = templateID
        guard workflowOffer(snapshot())?.id == templateID else { return }
        start(.turnOnWorkflow, in: session)
    }

    // MARK: - Requests

    /// What the Configurator is asked for an item that adds a teammate. A
    /// new teammate, never an app added to an existing one.
    static func teammateRequest(_ item: DiscoveryItem) -> String? {
        switch item {
        case .people:
            return
                "Create a new agent named People with only the Contacts app turned on. Its description: Contacts. Use for looking up people, phone numbers, email addresses, and birthdays. Not for mail, messages, or the calendar."
        case .navigator:
            return
                "Create a new agent named Navigator with only the Maps app turned on. Its description: Places and travel. Use for finding places, directions, and travel time. Not for the calendar."
        case .shortcuts:
            return
                "Create a new agent named Shortcuts with only the Shortcuts app turned on. Its description: The user's shortcuts. Use for running a shortcut the user already has."
        case .music:
            return
                "Create a new agent named Music with only the Music app turned on. Its description: Music. Use for playing, finding, and queueing music."
        default:
            return nil
        }
    }

    static func folderTeammateRequest(path: String, folderName: String) -> String {
        "Create a new agent named Archivist with the working folder \(path), read only, and no apps. Its description: Files in \(folderName). Use for finding, reading, and summarizing documents there. Not for writing, editing, or moving files."
    }

    // MARK: - State

    private func refreshOpenPanels() {
        for sessionId in overlays.keys {
            ChatWindowManager.shared.session(forSessionId: sessionId)?.rebuildVisibleBlocks()
        }
    }

    /// The default workflow a card offers to turn on: the one a Try card
    /// just ran, if it can.
    private func workflowOffer(_ snapshot: DiscoverySnapshot) -> (id: UUID, name: String, when: String)? {
        let ids = snapshot.ranWithoutAutomation
        let ordered = recentTrial.map { recent in ids.filter { $0 == recent } + ids.filter { $0 != recent } } ?? ids
        for id in ordered {
            let name = workflowName(id) ?? ""
            if let automation = OnboardingKeep.automation(workflowId: id, name: name) {
                return (id, name, automation.when)
            }
        }
        return nil
    }

    /// The default workflow the Try card runs.
    private func trialOffer(_ snapshot: DiscoverySnapshot) -> (id: UUID, name: String)? {
        for id in DiscoveryCatalog.workflowsToTry(snapshot, startedWith: firstRun().startedWith) {
            if let name = workflowName(id) { return (id, name) }
        }
        return nil
    }

    private func teammateNames() -> [Teammate: String] {
        Dictionary(
            OnboardingFirstRun.shared.teamMembers().map { ($0.teammate, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The default workflows that can run on their own, in default order,
    /// by template id.
    static let schedulableWorkflows: [UUID] = [
        OnboardingPaths.morningBriefId, OnboardingPaths.meetingPrepId, OnboardingPaths.mailTriageId,
        OnboardingPaths.newDownloadId, OnboardingPaths.endOfDayId, TeamSeeder.repoDigestTemplateID,
    ]

    static func liveSnapshot() -> DiscoverySnapshot {
        var s = DiscoverySnapshot()
        let manager = AgentManager.shared
        let automated = Set(EventManager.shared.events.compactMap { $0.action.workflow?.workflowID })
        let installed = schedulableWorkflows.compactMap { id in OnboardingPaths.installed(id).map { (id, $0.id) } }
        s.defaultAutomationExists = installed.contains { automated.contains($0.1) }
        let runs = Dictionary(
            uniqueKeysWithValues: installed.map { id, installedID in
                (id, WorkflowRunStore.shared.runs(workflowID: installedID, limit: 20, includeTests: false))
            }
        )
        let completed = installed.filter { id, _ in runs[id]?.contains { $0.status == .completed } == true }
        s.defaultWorkflowSucceeded = !completed.isEmpty
        s.ranWithoutAutomation = completed.filter { !automated.contains($0.1) }.map(\.0)
        s.neverRun = installed.filter { id, installedID in
            !automated.contains(installedID) && runs[id]?.isEmpty != false
        }.map(\.0)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .standardizedFileURL.path
        for agent in manager.agents where agent.id != Agent.defaultId {
            let capabilities = manager.effectiveCapabilities(for: agent.id)
            s.enabledApps.formUnion(capabilities.enabledAppleApps)
            let folder = manager.workingFolder(for: agent)?.path
            switch agent.teammate {
            case .keeper:
                s.keeperExists = true
                s.keeperRedactionOn = capabilities.redactionToolsEnabled
            case .courier:
                s.courierExists = true
                s.courierHasMessages = capabilities.enabledAppleApps.contains(.messages)
            case .builder:
                s.builderExists = true
                s.builderHasFolder = folder != nil
            case nil:
                if !agent.isBuiltIn { s.customAgentExists = true }
            default:
                break
            }
            if agent.teammate != .builder, let folder,
                URL(fileURLWithPath: folder).standardizedFileURL.path != downloads
            {
                s.otherFolderAttached = true
            }
        }
        s.importPromptSeen = ImportHistoryPromptGate.shared.hasSeen
        s.fullDiskAccess = SystemPermissionService.shared.isGranted(.disk)
        s.privacyAIOn = PrivacyFilterStore.load()?.aiDetectionEnabled ?? false
        s.providerConnected = RemoteProviderManager.shared.providerStates.values.contains { $0.isConnected }
        s.searchProviderSet = SearchProviderManager.shared.hasConfiguredAPIProvider
        s.storeInstalled = InstalledWorkflowStore.shared.workflows.contains { $0.source != nil }
        s.phonePaired = MobilePairingService.shared.pairedDevice != nil
        s.encryptionOn = StorageEncryptionPolicy.shared.isEncryptionEnabled
        let speech = SpeechModelManager.shared
        s.voiceSetUp = speech.downloadedModelsCount > 0 && speech.selectedModel != nil
        s.memoryEnabled = MemoryConfigurationStore.load().enabled
        let memory = MemoryDatabase.shared
        s.memoryHasEntries = ((try? memory.pinnedFactCount()) ?? 0) + ((try? memory.episodeCount()) ?? 0) > 0
        let center = DiscoveryCenter.shared
        s.memoryReviewed = center.store.load().taken.contains(.memory)
        s.toolServerAdded = !MCPProviderManager.shared.configuration.providers.isEmpty
        center.refreshChannels()
        s.channelConfigured = center.channelConfigured
        s.skillOrPluginAdded =
            SkillManager.shared.skills.contains { !$0.isBuiltIn && !$0.isFromPlugin }
            || !PluginManager.shared.plugins.isEmpty
        s.orchestratorHasFolder = manager.workingFolder(for: Agent.defaultId) != nil
        s.computerOrBrowserOn = ([Agent.defaultId] + manager.agents.map(\.id)).contains { id in
            let capabilities = manager.effectiveCapabilities(for: id)
            return capabilities.computerUseEnabled || capabilities.browserUseEnabled
        }
        return s
    }

    /// Reads whether a channel is set up, off the main thread; the next
    /// snapshot sees it.
    private func refreshChannels() {
        guard !channelRefreshInFlight else { return }
        channelRefreshInFlight = true
        Task {
            let configured = await AgentChannelConnectionManager.shared.anyChannelConfigured()
            channelConfigured = configured
            channelRefreshInFlight = false
        }
    }

    private static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func runFolderPanel(message: String, directory: URL?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        panel.message = message
        panel.directoryURL = directory
        return await panel.beginModal() == .OK ? panel.url : nil
    }

    /// Authored lines are shown, never sent to a model.
    @discardableResult
    private func appendAuthored(_ text: String, role: MessageRole = .assistant, to session: ChatSession) -> ChatTurn {
        let turn = ChatTurn(role: role, content: text)
        turn.origin = .authored
        turn.modelContextExcluded = true
        session.appendAuthoredTurn(turn)
        return turn
    }

    func resetForTesting(store: DiscoveryStore) {
        self.store = store
        overlays = [:]
        trials = [:]
        recentTrial = nil
        inFlight = false
    }
}

/// The Set Up Osaurus command, for the app menu.
@MainActor
public enum SetUpOsaurusCommand {
    public static func run() {
        DiscoveryCenter.shared.openSetUp(from: .menu)
    }
}
