//
//  OnboardingFirstRun.swift
//  osaurus
//
//  The scripted first run. When the first chat window comes forward after
//  the onboarding window on a fresh install, an authored opening is on
//  screen at once, the local model starts loading, and the plan begins.
//  Cards, requests, and asks are buttons the runtime handles; an ask sends
//  its label and the host makes the ask's `run_workflow` call by id, so the
//  first task needs no generation to decide anything. A typed message goes
//  through `OnboardingTurnRouter`; only talk about the walkthrough itself
//  reaches the Onboarding agent's one generation.
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class OnboardingFirstRun {
    static let shared = OnboardingFirstRun()

    /// Armed by the onboarding window, consumed by the first chat shown.
    static let openingPendingKey = "onboardingOpeningPending"

    var store: OnboardingPlanStore = .shared
    var defaults: UserDefaults = .standard

    // Test seams.
    var profile: () -> MacProfile = { MacProfile.current() }
    var requestPermission: (SystemPermission) async -> Bool = {
        await SystemPermissionService.shared.requestPermissionAndWait($0)
    }
    var isPermissionGranted: (SystemPermission) -> Bool = { SystemPermissionService.shared.isGranted($0) }
    /// `@MainActor` in the type, not just the default: a nonisolated async
    /// closure runs on the global executor, and its synchronous TeamSeeder
    /// call then trips the main-actor isolation check.
    var readDownloads: @MainActor () async -> Bool = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let readable = await Task.detached {
            (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) != nil
        }.value
        if readable { await TeamSeeder.bookmarkWaitingFolders(at: downloads) }
        return readable
    }
    var pickProjectFolder: @MainActor () async -> URL? = { await OnboardingFirstRun.runProjectPanel() }
    /// Off in tests, which read the panel the moment a line lands.
    var typesOutLines = !RuntimeEnvironment.isUnderTests
    var isOffline: () -> Bool = { RemoteProviderManager.shared.isOffline }
    /// One generation on the chat's model: (system, prompt, model) -> text.
    var generateReply: (String, String, String?) async throws -> String = { system, prompt, model in
        try await OnboardingFirstRun.generate(system: system, prompt: prompt, model: model)
    }
    var sendToOrchestrator: (ChatSession, String, [Attachment]) -> Void = {
        $0.sendBypassingOnboarding($1, attachments: $2)
    }
    /// In place of the chat's picker.
    var brainOverride: OnboardingBrainState?

    nonisolated static func generate(system: String, prompt: String, model: String?) async throws -> String {
        try await CoreModelService.shared.generate(
            prompt: prompt,
            systemPrompt: system,
            maxTokens: 1024,
            timeout: 60,
            intent: .interactive,
            modelOverride: model,
            purpose: "onboarding"
        )
    }

    private var cachedPlan: OnboardingPlan??
    private var preloadTask: Task<Void, Never>?
    private var brainObservation: AnyCancellable?
    private var lastBrain: OnboardingBrainState?
    private var requestInFlight = false
    private var routingTask: Task<Void, Never>?
    /// The window whose sidebar setup closed, so it comes back when setup
    /// ends. Closed once per launch: reopening it during setup sticks.
    private var focusedWindowId: UUID?
    private var didFocusWindow = false

    var plan: OnboardingPlan? {
        if let cachedPlan { return cachedPlan }
        let loaded = store.load()
        cachedPlan = .some(loaded)
        return loaded
    }

    static func armOpening(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: openingPendingKey)
    }

    /// The chat that holds the walkthrough.
    func ownsSession(_ session: ChatSession) -> Bool {
        guard let id = session.sessionId, let plan else { return false }
        return plan.sessionId == id
    }

    // MARK: - Window hooks

    func windowShown(_ session: ChatSession) {
        if ownsSession(session) {
            attach(session)
            return
        }
        guard defaults.bool(forKey: Self.openingPendingKey) else {
            resumeIfNeeded(in: session)
            return
        }
        defaults.removeObject(forKey: Self.openingPendingKey)
        guard session.turns.isEmpty, (session.agentId ?? Agent.defaultId) == Agent.defaultId else { return }
        Task { await start(session) }
    }

    /// A close cancels a first load still running for this chat.
    func windowClosing(_ session: ChatSession) {
        guard ownsSession(session) else { return }
        preloadTask?.cancel()
        preloadTask = nil
        brainObservation = nil
    }

    // MARK: - Opening

    func start(_ session: ChatSession) async {
        // The picker resolves models asynchronously; on the local-download
        // path the temporary Cloud model is connected first, so the opening
        // says where the chat really runs.
        for _ in 0 ..< 5 where session.selectedModel == nil && session.pendingLocalSetupModelId == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if session.pendingLocalSetupModelId != nil, !session.isOsaurusRouterSession {
            await session.adoptOsaurusRouterModelWhileLocalSetupPending(maxConnectAttempts: 2)
        }
        guard session.turns.isEmpty else { return }
        let brain = brainState(of: session)
        let text = OnboardingOpening.text(profile: profile(), brain: brain)
        appendAuthored(.assistant, text, to: session)
        OnboardingTelemetry.agentOpeningShown(brain: brain)
        var plan = OnboardingPlan(sessionId: session.sessionId)
        plan.advance(OnboardingAppSnapshot(plan: plan, brain: brain))
        commit(plan, session: session)
        attach(session)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    /// A relaunch during setup reopens the walkthrough's chat.
    private func resumeIfNeeded(in session: ChatSession) {
        guard let plan, !plan.isFinished, let id = plan.sessionId, session.turns.isEmpty,
            session.sessionId == nil, ChatWindowManager.shared.session(forSessionId: id) == nil,
            ChatSessionsManager.shared.session(for: id) != nil,
            let data = ChatSessionStore.load(id: id)
        else { return }
        session.load(from: data)
        attach(session)
    }

    private func attach(_ session: ChatSession) {
        focusWindow(on: session)
        lastBrain = brainState(of: session)
        startPreload(session)
        brainObservation = session.$selectedModel.combineLatest(session.$pickerItems)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self, weak session] _ in
                guard let self, let session else { return }
                self.brainMayHaveChanged(session)
            }
        session.rebuildVisibleBlocks()
    }

    /// Setup keeps the person on the conversation: the sidebar stays
    /// closed until the walkthrough ends.
    private func focusWindow(on session: ChatSession) {
        guard !didFocusWindow, let plan, !plan.isFinished,
            let window = ChatWindowManager.shared.windowState(holding: session)
        else { return }
        didFocusWindow = true
        guard window.showSidebar else { return }
        window.showSidebar = false
        focusedWindowId = window.windowId
    }

    private func restoreSidebar() {
        guard let id = focusedWindowId else { return }
        focusedWindowId = nil
        guard let window = ChatWindowManager.shared.windowState(id: id), !window.showSidebar else { return }
        withAnimation(window.theme.motion.quick) { window.showSidebar = true }
    }

    /// Starts loading the local model the chat will answer with, through
    /// the ordinary load path. Cancelled when the window closes.
    private func startPreload(_ session: ChatSession) {
        guard case .local = brainState(of: session), let model = session.selectedModel,
            ModelManager.findInstalledMLXModelFromCache(named: model) != nil
        else { return }
        preloadTask?.cancel()
        preloadTask = Task { try? await ModelRuntime.shared.preload(name: model) }
    }

    /// The bridge handing over to the local model, or a model arriving,
    /// is the runtime's notice to make, not the model's.
    private func brainMayHaveChanged(_ session: ChatSession) {
        guard ownsSession(session), let sessionId = session.sessionId else { return }
        let brain = brainState(of: session)
        let previous = lastBrain
        lastBrain = brain
        guard brain != previous else { return }
        if let notice = Self.notice(from: previous, to: brain) {
            ConversationEventLog.shared.record(
                sessionId: sessionId,
                text: notice.text,
                icon: notice.icon,
                key: notice.key
            )
        }
        if case .local = brain { startPreload(session) }
        if var plan, !plan.isComplete {
            let wasChoosingBrain = plan.current?.id == OnboardingSteps.brain
            plan.advance(OnboardingAppSnapshot(plan: plan, brain: brain))
            commit(plan, session: session)
            if wasChoosingBrain, plan.current?.id == OnboardingSteps.choice {
                appendAuthored(.assistant, OnboardingSteps.ChoiceStep().fallbackLine, to: session)
            }
        }
        session.rebuildVisibleBlocks()
    }

    static func notice(from previous: OnboardingBrainState?, to brain: OnboardingBrainState)
        -> (text: String, icon: String, key: String)?
    {
        switch (previous, brain) {
        case (.bridged?, .local), (.downloadingLocked?, .local):
            return (
                L("Your private model is ready. I am running on this Mac now."), "desktopcomputer",
                "onboarding.local-ready"
            )
        case (.cloudConnecting?, .provider(OnboardingBrainState.osaurusCloudName)):
            return (L("Osaurus Cloud is connected. I can answer now."), "cloud", "onboarding.cloud-ready")
        case (.downloadingLocked?, .bridged):
            return (
                L("Osaurus Cloud is connected, so I can answer while your private model downloads."), "cloud",
                "onboarding.bridge-ready"
            )
        default:
            return nil
        }
    }

    // MARK: - Display

    /// The panel and the turn it sits under: the latest line, when it is
    /// an authored one and no run is open.
    func panel(for session: ChatSession) -> (turnId: UUID, panel: OnboardingPanel)? {
        guard ownsSession(session), let plan, let sessionId = session.sessionId, !session.isStreaming,
            !session.isTypingOutAuthoredLine,
            let last = Self.lastLine(of: session), last.role == .assistant
        else { return nil }
        if plan.canExplore, plan.browse == nil {
            guard plan.offerTurnId == last.id else { return nil }
            return (last.id, OnboardingPanel.exploreOffer(sessionId: sessionId))
        }
        guard last.origin == .authored,
            let panel = OnboardingPanel.make(
                plan: plan,
                brain: brainState(of: session),
                team: teamMembers(),
                osaurus: orchestrator(),
                sessionId: sessionId
            )
        else { return nil }
        return (last.id, panel)
    }

    /// The latest line in the chat. A run can end on a tool's result,
    /// which shows on its call's reply rather than as a line of its own.
    static func lastLine(of session: ChatSession) -> ChatTurn? {
        session.turns.last { $0.role != .tool }
    }

    /// The label for a reply this chat just generated.
    func runLocation(for session: ChatSession) -> ChatRunLocation? {
        guard ownsSession(session) else { return nil }
        return brainState(of: session).runLocation(offline: isOffline())
    }

    // MARK: - Actions

    func perform(_ action: OnboardingAction, sessionId: UUID) {
        guard let session = ChatWindowManager.shared.session(forSessionId: sessionId) else { return }
        perform(action, in: session, echo: true)
    }

    /// `echo` shows a tapped card as the person's line; a typed one is
    /// already on screen.
    func perform(_ action: OnboardingAction, in session: ChatSession, echo: Bool) {
        guard ownsSession(session), var plan else { return }
        if plan.isFinished {
            guard plan.canExplore else { return }
            explore(action, plan: &plan, in: session, echo: echo)
            return
        }
        let brain = brainState(of: session)
        switch action {
        case .selectPath(let id):
            guard plan.current?.id == OnboardingSteps.choice, let path = OnboardingPaths.path(id: id) else { return }
            if echo { appendAuthored(.user, cardName(path), to: session) }
            plan.select(pathId: id)
            OnboardingTelemetry.agentPathSelected(id)
            if case .permission(let permission) = path.request, isPermissionGranted(permission) {
                plan.requestOutcome = .granted
            }
            appendAuthored(.assistant, path.introLine, to: session)
        case .back:
            plan.back()
            appendAuthored(.assistant, OnboardingSteps.ChoiceStep().fallbackLine, to: session)
        case .skip, .dismissSetup:
            plan.dismiss()
            guard plan.finishReason == .dismissed else { return }
            seedHandover(plan, in: session)
            appendAuthored(.assistant, L("Setup is done. Ask me anything."), to: session)
        case .discover, .openDiscovery:
            return
        case .request:
            Task { await runRequest(session) }
            return
        case .openSettings(let permission):
            SystemPermissionService.shared.openSystemSettings(for: permission)
            return
        case .openFilesAndFolders:
            openFilesAndFolders()
            return
        case .ask(let id):
            guard let ask = OnboardingPaths.ask(id: id) else { return }
            runAsk(ask, plan: &plan, brain: brain, session: session)
        case .topic(let topic):
            let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            runAsk(OnboardingPaths.topicAsk(trimmed), plan: &plan, brain: brain, session: session)
        case .chooseBrain:
            presentBrainChooser(for: session)
            return
        case .exploreTeam, .doneExploring:
            return
        }
        plan.advance(OnboardingAppSnapshot(plan: plan, brain: brain))
        commit(plan, session: session)
    }

    private func presentBrainChooser(for session: ChatSession) {
        let windows = ChatWindowManager.shared
        BrainChooserSheet.present(
            over: windows.windowState(holding: session).flatMap { windows.getNSWindow(id: $0.windowId) })
    }

    // MARK: - Exploring after the first task

    /// The offer under a task's reply, and the team it opens: the same
    /// cards, requests, and asks, recorded apart from the first task.
    private func explore(_ action: OnboardingAction, plan: inout OnboardingPlan, in session: ChatSession, echo: Bool) {
        let brain = brainState(of: session)
        switch action {
        case .exploreTeam:
            guard plan.browse == nil else { return }
            if echo { appendAuthored(.user, L("Meet Another Teammate"), to: session) }
            plan.exploreTeam()
            appendAuthored(.assistant, Self.exploreLine, to: session)
        case .selectPath(let id):
            guard plan.browse?.pathId == nil, let path = OnboardingPaths.path(id: id) else { return }
            if echo { appendAuthored(.user, cardName(path), to: session) }
            plan.browseSelect(pathId: id)
            if id == plan.pathId, plan.requestOutcome == .granted {
                plan.browse?.requestOutcome = .granted
            } else if case .permission(let permission) = path.request, isPermissionGranted(permission) {
                plan.browse?.requestOutcome = .granted
            }
            appendAuthored(.assistant, path.introLine, to: session)
        case .back:
            guard plan.browse?.pathId != nil else { return }
            plan.browseBack()
            appendAuthored(.assistant, Self.exploreLine, to: session)
        case .doneExploring, .dismissSetup, .skip:
            plan.endExploring()
            appendAuthored(.assistant, L("Setup is done. Ask me anything."), to: session)
        case .request:
            Task { await runRequest(session) }
            return
        case .openSettings(let permission):
            SystemPermissionService.shared.openSystemSettings(for: permission)
            return
        case .openFilesAndFolders:
            openFilesAndFolders()
            return
        case .chooseBrain:
            presentBrainChooser(for: session)
            return
        case .ask(let id):
            guard let ask = OnboardingPaths.ask(id: id) else { return }
            sendBrowsedAsk(ask, plan: &plan, brain: brain, session: session)
            return
        case .topic(let topic):
            let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            sendBrowsedAsk(OnboardingPaths.topicAsk(trimmed), plan: &plan, brain: brain, session: session)
            return
        case .discover, .openDiscovery:
            return
        }
        commit(plan, session: session)
    }

    static var exploreLine: String { L("Who do you want to try next?") }

    /// Committed before the send, so the run's end finds the offer pending.
    private func sendBrowsedAsk(
        _ ask: OnboardingAsk,
        plan: inout OnboardingPlan,
        brain: OnboardingBrainState,
        session: ChatSession
    ) {
        guard brain.canAnswer, !(ask.readsPersonalData && brain.holdsPersonalAsks), !session.isStreaming
        else { return }
        let browsing = plan
        plan.browseSent()
        commit(plan, session: session)
        guard session.sendPreparedAsk(label: ask.label, dispatch: Self.dispatch(for: ask)) else {
            plan = browsing
            commit(plan, session: session)
            return
        }
    }

    private func openFilesAndFolders() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    private func runAsk(
        _ ask: OnboardingAsk,
        plan: inout OnboardingPlan,
        brain: OnboardingBrainState,
        session: ChatSession
    ) {
        guard brain.canAnswer, !(ask.readsPersonalData && brain.holdsPersonalAsks), !session.isStreaming
        else { return }
        var finished = plan
        finished.finish(.firstTask, askId: ask.id)
        seedHandover(finished, in: session)
        guard session.sendPreparedAsk(label: ask.label, dispatch: Self.dispatch(for: ask)) else { return }
        plan = finished
    }

    // MARK: - Typed messages

    /// A typed message in the walkthrough comes here instead of going
    /// straight to the Orchestrator.
    func routesTypedMessage(in session: ChatSession) -> Bool {
        guard ownsSession(session), let plan else { return false }
        if plan.canExplore {
            return plan.browse != nil || (plan.offerTurnId != nil && plan.offerTurnId == Self.lastLine(of: session)?.id)
        }
        return plan.current != nil && !plan.isFinished
    }

    /// Handled in order, so a second message waits for the first.
    func routeTyped(_ text: String, attachments: [Attachment], in session: ChatSession) {
        let previous = routingTask
        routingTask = Task { [weak self, weak session] in
            await previous?.value
            guard let self, let session else { return }
            await self.route(text, attachments: attachments, in: session)
        }
    }

    func waitForRouting() async {
        await routingTask?.value
    }

    private func route(_ text: String, attachments: [Attachment], in session: ChatSession) async {
        guard routesTypedMessage(in: session), var plan else {
            sendToOrchestrator(session, text, attachments)
            return
        }
        // Exploring: their own message is the end of setup.
        if plan.canExplore {
            plan.endExploring()
            commit(plan, session: session)
            sendToOrchestrator(session, text, attachments)
            return
        }
        let team = teamMembers()
        if attachments.isEmpty, let action = OnboardingTurnRouter.stepAction(text, plan: plan, team: team) {
            appendAuthored(.user, text, to: session)
            perform(action, in: session, echo: false)
            return
        }
        guard attachments.isEmpty else {
            graduate(text, attachments: attachments, in: session)
            return
        }
        switch OnboardingTurnRouter.route(text, team: team) {
        case .task, .step:
            if brainState(of: session).holdsPersonalAsks, OnboardingTurnRouter.readsPersonalData(text) {
                appendAuthored(.user, text, to: session)
                appendAuthored(
                    .assistant, L("That reads your own data, so it waits for the private model on this Mac."),
                    to: session)
                return
            }
            graduate(text, attachments: attachments, in: session)
        case .reply: await reply(to: text, in: session)
        }
    }

    /// `configurator_handoff` with the person's words as they typed them.
    static func configuratorDispatch(_ text: String) -> ServiceToolInvocation {
        ServiceToolInvocation(
            toolName: ConfiguratorHandoffTool.toolName,
            jsonArguments: JSONValue.object(["brief": .string(""), "user_message": .string(text)]).compactJSONString,
            toolCallId: nil)
    }

    /// Setup ends; the Orchestrator receives the message verbatim, with
    /// the seeded state and none of the walkthrough.
    private func graduate(_ text: String, attachments: [Attachment], in session: ChatSession) {
        guard var plan else { return }
        plan.finish(.firstTask)
        plan.advance(OnboardingAppSnapshot(plan: plan, brain: brainState(of: session)))
        commit(plan, session: session)
        seedHandover(plan, in: session)
        sendToOrchestrator(session, text, attachments)
    }

    /// The Onboarding agent's reply, generated on the chat's model, or the
    /// step's authored line when no model can answer.
    private func reply(to text: String, in session: ChatSession) async {
        let history = session.turns
        appendAuthored(.user, text, to: session)
        guard let plan, let current = plan.current, let step = OnboardingSteps.definition(id: current.id) else {
            return
        }
        let brain = brainState(of: session)
        let location = brain.runLocation(offline: isOffline())
        var line = step.fallbackLine
        var generatedAt: ChatRunLocation?
        if brain.canAnswer {
            let (system, prompt) = OnboardingSystemPromptBuilder.build(
                .init(plan: plan, location: location, team: teamMembers(), history: history, message: text)
            )
            if let generated = try? await generateReply(system, prompt, session.selectedModel)
                .trimmingCharacters(in: .whitespacesAndNewlines), !generated.isEmpty
            {
                line = generated
                generatedAt = location
            }
        }
        guard routesTypedMessage(in: session) else { return }
        appendAuthored(.assistant, line, to: session, runLocation: generatedAt)
    }

    // MARK: - Handover

    /// What the Orchestrator knows of setup: where the chat runs, the
    /// teammate chosen, and what was skipped. Written by the runtime.
    static func handoverFacts(plan: OnboardingPlan, location: ChatRunLocation?, team: [OnboardingOpening.Member])
        -> [String]
    {
        var facts: [String] = []
        if let location { facts.append("This chat runs: \(location.label(tokensPerSecond: nil)).") }
        if let path = plan.path, let teammate = path.teammate {
            let name = team.first { $0.teammate == teammate }?.name ?? teammate.rawValue.capitalized
            facts.append("In setup the user started with \(name), for \(path.job.lowercased()).")
            if plan.requestOutcome == .denied {
                facts.append("macOS did not allow \(name)'s access; its asks that need it were not offered.")
            }
        } else if plan.path != nil {
            facts.append("In setup the user started with you, the Orchestrator, rather than a teammate.")
        } else if plan.finishReason == .dismissed {
            facts.append("In setup the user skipped choosing a teammate.")
        }
        if plan.finishReason == .dismissed { facts.append("The user dismissed setup before a first task.") }
        let skipped = plan.steps.filter { $0.status == .skipped }.map(\.id)
        if !skipped.isEmpty { facts.append("Setup steps skipped: \(skipped.joined(separator: ", ")).") }
        return facts
    }

    private func seedHandover(_ plan: OnboardingPlan, in session: ChatSession) {
        let facts = Self.handoverFacts(
            plan: plan,
            location: brainState(of: session).runLocation(offline: isOffline()),
            team: teamMembers()
        )
        var state = session.sessionState ?? .empty
        state.facts = Array((state.facts + facts).suffix(SessionState.maxItemsPerList))
        session.seedSessionState(state)
    }

    /// The `run_workflow` call an ask makes, by workflow id: a prepared
    /// ask's, or the installed copy of a default workflow.
    static func dispatch(for ask: OnboardingAsk) -> ServiceToolInvocation? {
        guard let id = ask.workflowId else { return nil }
        let target = OnboardingPaths.installed(id)?.id ?? id
        let object: [String: Any] = ["workflow": target.uuidString, "input": ask.input]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return ServiceToolInvocation(toolName: RunWorkflowTool.toolName, jsonArguments: json, toolCallId: nil)
    }

    private func runRequest(_ session: ChatSession) async {
        let browsing = plan?.canExplore == true
        guard !requestInFlight, let path = browsing ? plan?.browse?.path : plan?.path, let request = path.request
        else { return }
        requestInFlight = true
        defer { requestInFlight = false }
        let granted: Bool
        switch request {
        case .permission(let permission):
            granted = await requestPermission(permission)
            for companion in Self.companionPermissions(permission) where !isPermissionGranted(companion) {
                _ = await requestPermission(companion)
            }
        case .downloadsFolder: granted = await readDownloads()
        case .projectFolder: granted = await pickProjectFolder().map(setBuilderFolder) ?? false
        case .topic: return
        }
        guard var plan else { return }
        if browsing {
            guard plan.canExplore, plan.browse?.pathId == path.id else { return }
            plan.browse?.requestOutcome = granted ? .granted : .denied
        } else {
            guard plan.pathId == path.id, !plan.isFinished else { return }
            plan.requestOutcome = granted ? .granted : .denied
        }
        appendAuthored(
            .assistant,
            granted
                ? OnboardingSteps.FirstTaskStep().fallbackLine
                : L("That was not allowed. You can still pick another teammate."),
            to: session
        )
        plan.advance(OnboardingAppSnapshot(plan: plan, brain: brainState(of: session)))
        commit(plan, session: session)
    }

    /// Asked with a path's permission, so a later ask on the same card does
    /// not raise a second dialog: Planner's week and overdue asks read
    /// Reminders.
    static func companionPermissions(_ permission: SystemPermission) -> [SystemPermission] {
        permission == .calendar ? [.reminders] : []
    }

    private static func runProjectPanel() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        panel.message = L("Choose the project Builder works in.")
        return await panel.beginModal() == .OK ? panel.url : nil
    }

    private func setBuilderFolder(_ url: URL) -> Bool {
        guard
            let builder = AgentManager.shared.agents.first(where: { $0.sourceTemplateID == Teammate.builder.templateID }
            )
        else { return false }
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        AgentManager.shared.updateWorkingFolder(for: builder.id, bookmark: bookmark, path: url.path)
        return true
    }

    // MARK: - Run end

    /// Settles the first task once its run ends: a typed task counts as
    /// the first task too.
    /// A walkthrough task's reply gets the offer to meet another teammate;
    /// any other run means the person moved on.
    func runEnded(in session: ChatSession) {
        guard ownsSession(session), var plan else { return }
        let before = plan
        if plan.finishReason == nil {
            guard
                session.turns.contains(where: {
                    $0.role == .user && $0.origin != .authored && !$0.modelContextExcluded
                })
            else { return }
            plan.finish(.firstTask)
        }
        guard plan.finishReason == .firstTask else { return }
        if plan.firstTaskSucceeded == nil {
            plan.firstTaskSucceeded = Self.firstTaskSucceeded(session.turns)
        }
        if plan.offerPending == true {
            plan.offerPending = nil
            if plan.canExplore, let last = Self.lastLine(of: session), last.role == .assistant {
                plan.offerTurnId = last.id
            }
        } else if plan.canExplore, plan.offerTurnId != nil || plan.browse != nil {
            plan.endExploring()
        }
        guard plan != before else { return }
        plan.advance(OnboardingAppSnapshot(plan: plan, brain: brainState(of: session)))
        commit(plan, session: session)
    }

    /// The last task answered, and every workflow it ran completed.
    static func firstTaskSucceeded(_ turns: [ChatTurn]) -> Bool {
        guard let lastUser = turns.lastIndex(where: { $0.role == .user }) else { return false }
        let after = turns[(lastUser + 1)...].filter { $0.role == .assistant }
        for turn in after {
            for call in turn.toolCalls ?? [] where call.function.name == RunWorkflowTool.toolName {
                guard let result = turn.toolResults[call.id], ToolEnvelope.isSuccess(result) else { return false }
            }
        }
        return after.contains { !$0.contentIsBlank }
    }

    // MARK: - State

    func brainState(of session: ChatSession) -> OnboardingBrainState {
        if let brainOverride { return brainOverride }
        let source: OnboardingBrainState.Inputs.Source
        switch session.selectedPickerItem?.source {
        case .local: source = .local(modelName: session.selectedModel ?? "")
        case .foundation: source = .foundation
        case .remote(let name, let providerId):
            source = .remote(
                providerName: name,
                isOsaurusRouter: providerId == RemoteProviderManager.osaurusRouterProviderId
            )
        case .imageGeneration, nil: source = .none
        }
        let memory = SystemMonitorService.shared.totalMemoryGB
        return OnboardingBrainState.resolve(
            .init(
                pendingLocalDownload: session.pendingLocalSetupModelId != nil,
                source: source,
                cloudPending: OnboardingBrainPin.cloudPending,
                isCompatible: { name in
                    ModelManager.findInstalledMLXModelFromCache(named: name)?.compatibility(totalMemoryGB: memory)
                        == .compatible
                }
            )
        )
    }

    func teamMembers() -> [OnboardingOpening.Member] {
        let agents = AgentManager.shared.agents
        return Teammate.allCases.compactMap { teammate in
            agents.first { $0.sourceTemplateID == teammate.templateID }
                .map { OnboardingOpening.Member(teammate: teammate, name: $0.name, avatar: $0.avatar) }
        }
    }

    /// The Orchestrator as the sidebar shows it: its name and avatar.
    func orchestrator() -> OnboardingPanel.Orchestrator {
        guard let agent = AgentManager.shared.agent(for: Agent.defaultId) else { return .init() }
        return .init(name: agent.displayName, mascotId: agent.avatar, imageURL: agent.customAvatarURL)
    }

    private func cardName(_ path: OnboardingPath) -> String {
        guard let teammate = path.teammate else { return orchestrator().name }
        return teamMembers().first { $0.teammate == teammate }?.name ?? path.job
    }

    /// Authored lines are shown, never sent to a model. The assistant's
    /// arrive the way a reply does: a beat of typing, then the words.
    private func appendAuthored(
        _ role: MessageRole,
        _ text: String,
        to session: ChatSession,
        runLocation: ChatRunLocation? = nil
    ) {
        let turn = ChatTurn(role: role, content: text)
        turn.origin = .authored
        turn.modelContextExcluded = true
        turn.runLocation = runLocation
        if role == .assistant, typesOutLines {
            session.appendAuthoredTurnTypingOut(turn)
        } else {
            session.appendAuthoredTurn(turn)
        }
    }

    private func commit(_ plan: OnboardingPlan, session: ChatSession) {
        let previous = cachedPlan ?? nil
        if let reason = plan.finishReason, previous?.finishReason == nil {
            OnboardingTelemetry.agentFinished(
                reason: reason,
                step: previous?.current?.id,
                ask: plan.firstAskId != nil
            )
        }
        if plan.isClosed, previous?.isClosed != true { restoreSidebar() }
        cachedPlan = .some(plan)
        store.save(plan)
        session.rebuildVisibleBlocks()
    }

    func resetForTesting(store: OnboardingPlanStore, defaults: UserDefaults) {
        self.store = store
        self.defaults = defaults
        cachedPlan = nil
        preloadTask?.cancel()
        preloadTask = nil
        brainObservation = nil
        lastBrain = nil
        routingTask = nil
        brainOverride = nil
        focusedWindowId = nil
        didFocusWindow = false
    }
}
