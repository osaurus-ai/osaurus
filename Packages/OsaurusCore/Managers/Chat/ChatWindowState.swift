//
//  ChatWindowState.swift
//  osaurus
//
//  Per-window state container that isolates each ChatView window from shared singletons.
//  Pre-computes values needed for view rendering so view body is read-only.
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// Lifecycle of a Mode 2 remote-agent connection, surfaced in chat so the user
/// sees progress/errors and the composer can gate the first send.
public enum RemoteAgentConnectionPhase: Equatable, Sendable {
    /// Not in remote-agent mode (or fully torn down).
    case idle
    /// Connect + effective-model pin in flight; send is gated.
    case connecting
    /// Provider connected and model pinned; send is allowed.
    case connected
    /// Connect or secure-channel handshake failed; carries a user-facing reason.
    case failed(String)
}

/// The display identity (name + avatar) of whoever currently "owns" the chat
/// thread: the local agent in Mode 1, or the paired/discovered remote agent in
/// Mode 2. Lets message bubbles, the empty state, and the toolbar pill render a
/// single coherent identity instead of always showing the local agent.
public struct ChatThreadIdentity: Equatable, Sendable {
    public let name: String
    /// Mascot avatar id (e.g. "green") or nil for the name-initial monogram.
    public let mascotId: String?
    /// Absolute path to a user-supplied avatar image (local agents only;
    /// remote agents never transfer custom images, so this is nil for them).
    public let customAvatarPath: String?
    /// True when this identity is a remote agent (Mode 2).
    public let isRemote: Bool
}

/// One browser-style tab in a chat window. Identity is the tab's own id —
/// the session it holds is replaceable (in-tab chat switches swap it, just
/// like the window's single session used to be swapped).
struct ChatTab: Identifiable, Equatable {
    let id: UUID
    var session: ChatSession
    /// LRU stamp: when this tab last became the active tab. Drives which
    /// idle tabs get hibernated when the window holds too many.
    var lastActivatedAt: Date = Date()
    /// A hibernated tab keeps only a metadata-level session (title, agent,
    /// ids; no turns, no warm-up) so the chip still renders; the transcript
    /// reloads from disk when the tab is selected again.
    var isHibernated: Bool = false

    static func == (lhs: ChatTab, rhs: ChatTab) -> Bool {
        lhs.id == rhs.id && lhs.session === rhs.session
    }
}

/// Per-window state container for ChatView - each window creates its own instance
@MainActor
final class ChatWindowState: ObservableObject {
    // MARK: - Identity & Session

    let windowId: UUID
    /// The session this window currently displays. Replaceable: switching
    /// chats while a run is in flight detaches the running session into the
    /// `BackgroundTaskManager` registry (execution continues) and installs a
    /// different `ChatSession` here. `@Published` so the window root view can
    /// rebuild `ChatView` around the new instance. Always mirrors the active
    /// tab's session — the didSet keeps the tab entry in sync when in-tab
    /// navigation replaces the instance.
    @Published private(set) var session: ChatSession {
        didSet { syncActiveTabSession() }
    }
    let foundationModelAvailable: Bool

    // MARK: - Tabs

    /// Browser-style tabs, each holding its own live `ChatSession`. Inactive
    /// tabs keep their sessions alive in memory (streams keep running); only
    /// closing a tab tears its session down or hands it to the background
    /// registry.
    @Published private(set) var tabs: [ChatTab] = []
    @Published private(set) var activeTabId: UUID = UUID()

    // MARK: - View State

    /// Session sidebar starts open so a fresh window surfaces chat history
    /// immediately; the toolbar toggle still collapses it per window.
    @Published var showSidebar: Bool = true

    /// The project whose detail page currently covers the chat surface, or
    /// nil while the chat is showing. Owned here (not as `ChatView` state)
    /// so window-level actions like ⌘N can both read it and dismiss it.
    @Published var openProjectId: UUID?

    /// True while the content area shows a project detail page instead of
    /// the chat surface. Read by the toolbar item views so chat-specific
    /// chrome (agent pill, window pin) hides with it.
    var isProjectPageVisible: Bool { openProjectId != nil }

    /// True when the current chat was entered FROM its project's detail page
    /// (as opposed to the sidebar's Chats tab). The toolbar's back-to-project
    /// button uses this only to pick its icon: a back chevron when returning
    /// retraces the user's path, a folder when the project page would be new
    /// navigation. Set alongside `loadSession`/`startNewChat` by `ChatView`.
    @Published var enteredChatFromProjectPage: Bool = false

    /// Drives the "a local model is already running in another window" alert
    /// raised when the user tries to start a second local generation. Only one
    /// local generation can run at a time across windows; the alert is
    /// dismissed by its OK button in `ChatView`.
    @Published var showLocalModelBusyAlert: Bool = false

    /// Imperative hook set by `ChatView` while the inline message editor
    /// is active (and cleared on save/cancel). The window-level Esc
    /// monitor invokes it so Esc cancels the edit even when the editor's
    /// text view has lost keyboard focus (e.g. the user clicked the
    /// thread background mid-edit) — without it Esc would fall through
    /// to closing the whole window. Not `@Published`: purely imperative,
    /// no view re-renders.
    var cancelInlineEdit: (() -> Void)?

    /// Float-on-top state, driven by the toolbar overflow menu's Pin Window
    /// item (was local state inside the old PinButton).
    @Published var isWindowPinned: Bool = false

    /// Drives the in-conversation find bar (Cmd+F). Set by the window-level
    /// key monitor (which cannot touch `ChatView`'s `@State`) and cleared by
    /// the bar's close button or the Esc dismissal chain.
    @Published var isFindBarVisible: Bool = false

    /// Bumped on every Cmd+F so the find bar re-focuses its text field even
    /// when the bar is already visible (e.g. focus wandered back to the
    /// composer). Monotonic counter; the value itself is meaningless.
    @Published var findBarFocusRequestID: Int = 0

    // MARK: - Agent State

    @Published var agentId: UUID
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var discoveredAgents: [DiscoveredAgent] = []
    @Published var selectedDiscoveredAgent: DiscoveredAgent?
    @Published var selectedDiscoveredAgentProviderId: UUID?
    @Published private(set) var pairedRelayAgents: [PairedRelayAgent] = []
    @Published var selectedRelayAgent: PairedRelayAgent?
    /// Mode 2 only: the *unprefixed* live effective model id of the selected
    /// remote agent (e.g. `mlx-community/Qwen3-4B-...`), resolved from
    /// `GET /agents/{address}` on connect. Used to pin the model chip to the
    /// agent's own model. `nil` until resolved (or when it can't be resolved),
    /// in which case the picker falls back to the provider's first chat-capable
    /// model. Cleared whenever the window leaves remote-agent mode.
    @Published var pinnedRemoteAgentEffectiveModel: String?

    /// Mode 2 only: the selected remote agent's mascot avatar id (e.g. "green"),
    /// resolved from `GET /agents/{address}` on connect so the chat surfaces the
    /// remote agent's own avatar instead of a generic icon. `nil` falls back to
    /// the remote name's initial monogram. Cleared when leaving remote-agent mode.
    @Published var pinnedRemoteAgentAvatar: String?

    /// Mode 2 only: the selected remote agent's custom Action Bar (chat quick
    /// actions), resolved from `GET /agents/{address}` on connect so the empty
    /// state offers the remote agent's own prompt shortcuts. `nil` falls back to
    /// the neutral chat defaults. Cleared when leaving remote-agent mode.
    @Published var pinnedRemoteAgentQuickActions: [AgentQuickAction]?

    /// Mode 2 only: lifecycle of the selected remote agent's connection so the
    /// chat can show "connecting"/error and gate the first send until the
    /// provider is connected and its model is pinned (otherwise the first
    /// message races the async connect and fails with a misleading "model not
    /// found"). Driven by `pinRemoteAgentModelAfterConnect` and kept in sync
    /// with later disconnects via the `.remoteProviderStatusChanged` observer.
    @Published var remoteAgentConnectionPhase: RemoteAgentConnectionPhase = .idle

    /// The window's content width, pushed by `ChatWindowDelegate` on every
    /// resize. The tab strip sizes itself from this — it must come through
    /// the window state because the strip's own toolbar item (and any AppKit
    /// observer owned by its views) is REMOVED from the window when AppKit
    /// folds an oversized item into the toolbar overflow menu, which would
    /// freeze a view-owned measurement exactly when it's needed most.
    @Published private(set) var windowContentWidth: CGFloat?

    func updateWindowContentWidth(_ width: CGFloat) {
        guard abs((windowContentWidth ?? -1) - width) > 0.5 else { return }
        windowContentWidth = width
    }

    /// True while the window is in native full screen. AppKit draws the
    /// full-screen toolbar with an opaque system backdrop that clashes with
    /// custom themes, so the NSToolbar is hidden in full screen and the
    /// content renders its own themed header row instead.
    @Published var isFullScreen: Bool = false

    // MARK: - Sandbox Changes State

    /// Drives the session-scoped "Changes" sheet (sandbox file changes +
    /// undo). Presented from `ChatView`, toggled by the toolbar button.
    @Published var isChangesSheetPresented: Bool = false

    /// Number of outstanding sandbox workspace changes tracked for the
    /// current chat session. Zero hides the toolbar entrypoint.
    @Published private(set) var sandboxChangesCount: Int = 0

    /// True while a background job spawned by the current session may still
    /// be mutating the workspace (undo is disabled meanwhile).
    @Published private(set) var sandboxChangesHaveActiveJob: Bool = false

    // MARK: - Theme State

    @Published private(set) var theme: ThemeProtocol
    @Published private(set) var cachedBackgroundImage: NSImage?

    // MARK: - Pre-computed View Values

    @Published private(set) var filteredSessions: [ChatSessionData] = []
    @Published private(set) var cachedSystemPrompt: String = ""
    @Published private(set) var cachedActiveAgent: Agent = .default
    @Published private(set) var cachedAgentDisplayName: String = L("Assistant")

    // MARK: - Private

    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    private var sessionRefreshWorkItem: DispatchWorkItem?
    private var bonjourCancellable: AnyCancellable?
    private var agentsCancellable: AnyCancellable?
    private var sessionsCancellable: AnyCancellable?

    // MARK: - Initialization

    init(windowId: UUID, agentId: UUID, sessionData: ChatSessionData? = nil) {
        self.windowId = windowId
        self.agentId = agentId
        self.session = ChatSession()
        self.foundationModelAvailable = AppConfiguration.shared.foundationModelAvailable
        self.theme = Self.loadTheme(for: agentId)

        // Load initial data.
        let allAgents = AgentManager.shared.agents
        self.agents = allAgents
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)

        // Pre-compute view values
        self.cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        self.cachedActiveAgent = allAgents.first { $0.id == agentId } ?? .default
        self.cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
        decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)

        let initialTab = ChatTab(id: UUID(), session: self.session)
        self.tabs = [initialTab]
        self.activeTabId = initialTab.id

        // Configure session
        self.session.windowState = self
        self.session.agentId = agentId
        self.session.applyInitialModelSelection()
        if let data = sessionData {
            self.session.load(from: data)
        }
        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }

        // One-time legacy migration: pre-per-chat-isolation builds persisted a
        // single process-wide folder bookmark. The first eligible chat opened
        // after the update adopts it as ITS folder (then the global key is
        // deleted); it is never used as a default for any other chat. The
        // Default agent is folder-less by policy, and a session that already
        // carries its own bookmark must not be overridden.
        if agentId != Agent.defaultId, sessionData?.folderBookmark == nil {
            self.session.folderState.adoptLegacyGlobalBookmarkIfNeeded()
        }

        setupNotificationObservers()
        observeBonjourBrowser()
        observeAgentManager()
        observeSessionsManager()
        refreshPairedRelayAgents()
        refreshSandboxChanges()
    }

    /// Wrap an existing `ExecutionContext`, reusing its sessions without duplication.
    /// Used for lazy window creation when a user clicks "View" on a toast.
    init(windowId: UUID, executionContext context: ExecutionContext) {
        self.windowId = windowId
        self.agentId = context.agentId
        self.session = context.chatSession
        self.foundationModelAvailable = AppConfiguration.shared.foundationModelAvailable
        self.theme = Self.loadTheme(for: context.agentId)

        let allAgents = AgentManager.shared.agents
        self.agents = allAgents
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: context.agentId)
        self.cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: context.agentId)
        self.cachedActiveAgent = allAgents.first { $0.id == context.agentId } ?? .default
        self.cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
        decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)

        let initialTab = ChatTab(id: UUID(), session: self.session)
        self.tabs = [initialTab]
        self.activeTabId = initialTab.id

        // Re-link the adopted session to this window so busy alerts and
        // Mode 2 routing reach the view that now displays it.
        self.session.windowState = self
        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }

        setupNotificationObservers()
        observeBonjourBrowser()
        observeAgentManager()
        observeSessionsManager()
        refreshPairedRelayAgents()
        refreshSandboxChanges()
    }

    deinit {
        print("[ChatWindowState] deinit – windowId: \(windowId)")
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Stops any running execution and breaks reference chains — call when window is closing.
    func cleanup() {
        removeEphemeralProviderIfNeeded()
        selectedDiscoveredAgent = nil
        selectedDiscoveredAgentProviderId = nil
        selectedRelayAgent = nil
        // Inactive tabs first: each of their sessions is saved and stopped
        // (or handed to the background registry / unlinked when shared) —
        // the single-session logic below only covers the active tab.
        teardownInactiveTabSessions()
        // A registry-shared session is co-owned by its registering owner:
        // this window closing must only unlink, never shut down the shared
        // instance's warm-up controller or stop its run.
        if LiveChatSessionRegistry.shared.isShared(session) {
            if !session.turns.isEmpty { session.save() }
            releaseSharedSessionIfNeeded()
            return
        }
        // Persist BEFORE stop(), exactly like switchAgent/startNewChat do:
        // stop() on a mid-prepare cancel takes the draft-restore rollback,
        // which REMOVES the just-sent user turn to put its text back in the
        // composer — but this window is being destroyed, so the restored
        // draft dies with it and the close callback's later save() finds
        // empty turns and bails. Verified live: closing during model load
        // silently lost the user's message with no persisted trace. Saving
        // first keeps the message; for a mid-stream close the post-cleanup
        // save then overwrites this snapshot with the cancel-stamped turns.
        if !session.turns.isEmpty { session.save() }
        // Shut the warm-up controller BEFORE stop(): stop() on an idle session
        // runs completeRunCleanup(), whose run-completed hook would otherwise
        // schedule a fresh warm-up for a session that is being torn down.
        session.warmupController.shutdown()
        session.stop()
        session.onSessionChanged = nil
    }

    // MARK: - API

    var activeAgent: Agent { cachedActiveAgent }

    var themeId: UUID? {
        AgentManager.shared.themeId(for: agentId)
    }

    /// Pick another agent. Browser-style: the current tab is only reused
    /// when it is a blank chat; otherwise the conversation stays put in its
    /// tab and the new agent opens in its own tab (or an existing blank tab
    /// of that agent is focused). The fresh chat does NOT inherit the
    /// outgoing chat's project: it is a different agent's new conversation,
    /// so the project pill only shows for chats that belong to a project.
    func switchAgent(to newAgentId: UUID) {
        TTSService.shared.stop()
        if isBlank(session) {
            adoptAgent(newAgentId)
            if releaseSharedSessionIfNeeded() || detachRunningSessionIfNeeded() {
                installFreshSession(agentId: newAgentId)
            } else {
                session.reset(for: newAgentId)
            }
            refreshSessions()
            refreshSandboxChanges()
            return
        }
        if let blank = tabs.first(where: {
            $0.id != activeTabId && !$0.isHibernated && isBlank($0.session)
                && ($0.session.agentId ?? Agent.defaultId) == newAgentId
        }) {
            selectTab(id: blank.id)
            return
        }
        newTab(agentId: newAgentId)
    }

    /// An untouched chat: nothing sent, nothing running, nothing pending.
    private func isBlank(_ s: ChatSession) -> Bool {
        s.turns.isEmpty && !s.isStreaming && s.awaitingClarify == nil
    }

    /// Start a new chat that stays in the user's current project context:
    /// the open project page when one is showing, otherwise the current
    /// chat's project. Bound to ⌘N so running out of context mid-project
    /// doesn't silently drop the project's instructions, knowledge, and
    /// folder. Falls back to a plain new chat outside any project.
    func startNewChatInCurrentProject() {
        let projectId = openProjectId ?? session.projectId
        guard let project = ProjectManager.shared.project(for: projectId) else {
            openProjectId = nil
            enteredChatFromProjectPage = false
            startNewChat()
            return
        }
        startNewChat(in: project)
    }

    /// Start a fresh chat inside `project`: closes the project page if it is
    /// showing, honors the project's default agent when set and still
    /// existing, stamps membership (persisted with the first turn's save),
    /// and opens the project's working folder when the chat has none.
    func startNewChat(in project: Project) {
        openProjectId = nil
        enteredChatFromProjectPage = true
        // `switchAgent` already installs a fresh session for the target
        // agent, so the two branches differ only in the agent change.
        if let defaultAgentId = project.defaultAgentId,
            defaultAgentId != agentId,
            agents.contains(where: { $0.id == defaultAgentId })
        {
            switchAgent(to: defaultAgentId)
        } else {
            startNewChat()
        }
        // `reset`/`installFreshSession` clear membership; re-stamp it.
        session.projectId = project.id
        // A default, not a lock: never overrides a folder the chat picks
        // itself. Restoring the security-scoped bookmark is the same path
        // a persisted chat folder takes on reopen.
        if project.folderBookmark != nil, !session.folderState.hasActiveFolder {
            session.folderState.restore(bookmark: project.folderBookmark, path: project.folderPath)
        }
    }

    /// ⌘N: ALWAYS open a new tab (like ⌘T), staying in the current project
    /// context: the current chat's project, if any, is stamped on the new
    /// tab along with the project folder, the same way `startNewChat(in:)`
    /// does. Unlike `startNewChat`, a blank active tab is not reused.
    func newTabInCurrentProject() {
        let project = ProjectManager.shared.project(for: openProjectId ?? session.projectId)
        openProjectId = nil
        enteredChatFromProjectPage = project != nil
        newTab()
        guard let project else { return }
        session.projectId = project.id
        if project.folderBookmark != nil, !session.folderState.hasActiveFolder {
            session.folderState.restore(bookmark: project.folderBookmark, path: project.folderPath)
        }
    }

    /// Start a new chat. Browser-style: a blank active tab is reused in
    /// place; otherwise the current conversation keeps its tab (a running
    /// reply keeps streaming there) and the new chat opens in a new tab.
    /// Callers that stamp project membership afterwards (`startNewChat(in:)`)
    /// act on `session`, which is then the new tab's session.
    func startNewChat() {
        guard isBlank(session) else {
            newTab()
            return
        }
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        flushCurrentSession()
        if releaseSharedSessionIfNeeded() || detachRunningSessionIfNeeded() {
            installFreshSession(agentId: agentId)
        } else {
            session.reset(for: agentId)
        }
        refreshSessions()
        refreshSandboxChanges()
        // KPI: user started a new chat conversation. Count only.
        FeatureTelemetry.chatSessionStarted()
    }

    /// The sidebar is about to delete conversation `id`. If this window is
    /// attached to it, move the window off it first. A registry-shared
    /// (co-owned) instance must never be `reset()` in place — that
    /// would wipe the co-owner's engagement; the owning surface stops and
    /// unregisters it. Ordinary
    /// sessions keep the old behavior: reset stops the run and clears the
    /// view (never a background-registry handoff — the row is going away,
    /// and an adopted run's completion save would resurrect it).
    func prepareForSessionDeletion(id: UUID) {
        // An INACTIVE tab showing the doomed conversation just closes; its
        // session must not be saved on the way out (the row is being
        // deleted, a save would resurrect it).
        if let tab = tabs.first(where: {
            $0.id != activeTabId && $0.session.sessionId == id
        }) {
            tabs.removeAll { $0.id == tab.id }
            let doomed = tab.session
            if LiveChatSessionRegistry.shared.isShared(doomed) {
                doomed.windowState = nil
                doomed.onSessionChanged = nil
            } else {
                doomed.warmupController.shutdown()
                doomed.stop()
                doomed.onSessionChanged = nil
                doomed.windowState = nil
            }
            return
        }
        guard session.sessionId == id else { return }
        if releaseSharedSessionIfNeeded() {
            installFreshSession(agentId: agentId)
        } else {
            session.reset()
        }
    }

    func loadSession(_ sessionData: ChatSessionData) {
        guard sessionData.id != session.sessionId else { return }
        // Browser-style dedupe: if another tab already shows this
        // conversation, switch to it instead of loading a second copy of
        // the same transcript into this tab (two live instances of one row
        // race each other's saves).
        if let existing = tabs.first(where: {
            $0.id != activeTabId && $0.session.sessionId == sessionData.id
        }) {
            selectTab(id: existing.id)
            return
        }
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        flushCurrentSession()

        let resolvedData = ChatSessionStore.load(id: sessionData.id) ?? sessionData
        let targetAgentId = resolvedData.agentId ?? Agent.defaultId

        // Sync the window's active agent with the loaded session so the
        // chat header, theme, dropdown, sidebar filter, and downstream
        // save()/reset() calls all reflect the conversation's true agent
        // (#1005). Without this, clicking "New Chat" afterwards silently
        // re-tags the conversation to the previously-selected agent.
        if targetAgentId != agentId {
            adoptAgent(targetAgentId)
        }

        // Reopening a chat the registry is still running: attach the live
        // in-memory session instead of hydrating a stale copy from disk —
        // the stream keeps rendering into the reopened view, and disk state
        // lags behind the in-flight turns.
        if let liveTask = BackgroundTaskManager.shared.liveTask(forSessionId: sessionData.id),
            let liveSession = liveTask.chatSession
        {
            releaseSharedSessionIfNeeded()
            detachRunningSessionIfNeeded()
            attachSession(liveSession, registryTaskId: liveTask.id)
        } else if let sharedSession = LiveChatSessionRegistry.shared.liveSession(
            for: sessionData.id
        ) {
            // Another surface owns a live
            // instance of this conversation: attach that exact object so
            // both surfaces render one session and never race saves.
            releaseSharedSessionIfNeeded()
            detachRunningSessionIfNeeded()
            attachSharedSession(sharedSession)
        } else if releaseSharedSessionIfNeeded() || detachRunningSessionIfNeeded() {
            // The chat we're leaving is co-owned by another surface, or
            // keeps running in the background; the target loads into a
            // brand-new session so the two never share transcript state.
            installFreshSession(agentId: targetAgentId, loading: resolvedData)
        } else {
            session.load(from: resolvedData)
        }
        refreshSessions()
        refreshSandboxChanges()
    }

    // MARK: - Tabs API

    /// All live sessions this window holds, across every tab. The active
    /// tab's session is `session`; the rest keep streaming/existing in the
    /// background of this window.
    var tabSessions: [ChatSession] {
        tabs.map(\.session)
    }

    /// Open a new tab with a fresh empty chat and make it active. The
    /// outgoing tab keeps its session untouched (no detach — the tab still
    /// owns it).
    func newTab(agentId newAgentId: UUID? = nil) {
        persistActiveSessionForTabSwitch()
        if let newAgentId, newAgentId != agentId {
            adoptAgent(newAgentId)
        }
        let fresh = makeFreshSession(agentId: agentId)
        let tab = ChatTab(id: UUID(), session: fresh)
        // One un-animated update for strip + content: letting SwiftUI's
        // implicit animations interpolate the strip growing while ChatView
        // is simultaneously torn down and remounted (the `.id` swap) reads
        // as a visual glitch.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            tabs.append(tab)
            activeTabId = tab.id
            session = fresh
        }
        refreshSessions()
        refreshSandboxChanges()
        hibernateColdTabsIfNeeded()
        // KPI: a new tab starts a new conversation, same as sidebar New Chat.
        FeatureTelemetry.chatSessionStarted()
    }

    /// Switch the visible chat to another tab. Unlike `loadSession`, the
    /// outgoing session is neither detached nor released — its tab keeps it
    /// live, so an in-flight stream keeps rendering into that tab.
    /// Reorder a tab (drag-to-reorder in the strip). Pure array move; the
    /// active tab and its session are untouched.
    func moveTab(id: UUID, to newIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(newIndex, 0), tabs.count - 1)
        guard from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    func selectTab(id: UUID) {
        guard id != activeTabId, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        persistActiveSessionForTabSwitch()
        tabs[idx].lastActivatedAt = Date()
        if tabs[idx].isHibernated {
            wake(tabAt: idx)
        }
        activeTabId = id
        adoptTabSession(tabs[idx].session)
        hibernateColdTabsIfNeeded()
    }

    /// Cycle to the next (+1) or previous (-1) tab, wrapping around.
    func selectAdjacentTab(offset: Int) {
        guard tabs.count > 1,
            let idx = tabs.firstIndex(where: { $0.id == activeTabId })
        else { return }
        let next = ((idx + offset) % tabs.count + tabs.count) % tabs.count
        selectTab(id: tabs[next].id)
    }

    /// Close a tab. The last remaining tab never closes here — the caller
    /// (⌘W / close button) falls through to closing the window instead.
    /// A closing tab's session follows the window-close rules: shared →
    /// unlink only; mid-run → detach to the background registry; idle →
    /// save and stop.
    func closeTab(id: UUID) {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[idx]
        rememberClosedTab(closing, at: idx)
        // The removal itself animates (the strip keys a layout animation on
        // the tab ids, so neighbors slide over); the session swap below is
        // wrapped un-animated so ChatView's remount doesn't interpolate.
        tabs.remove(at: idx)
        if activeTabId == id {
            let neighbor = tabs[min(idx, tabs.count - 1)]
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                activeTabId = neighbor.id
                adoptTabSession(neighbor.session)
            }
        }
        teardownTabSession(closing.session)
    }

    /// Open a persisted conversation in a new tab (or focus the tab that
    /// already shows it).
    func openSessionInNewTab(_ sessionData: ChatSessionData) {
        if let existing = tabs.first(where: { $0.session.sessionId == sessionData.id }) {
            selectTab(id: existing.id)
            return
        }
        // Chrome-style: an untouched empty tab is reused rather than left
        // behind as a blank tab next to the one we just opened.
        let activeIsBlank = session.turns.isEmpty && !session.isStreaming
        if !activeIsBlank {
            newTab()
        }
        loadSession(sessionData)
    }

    /// Tear down every tab except the active one. `cleanup()` calls this on
    /// window close; `ChatWindowManager` also calls it when the ACTIVE
    /// session was detached to the background (that path skips `cleanup()`
    /// entirely, which would otherwise strand inactive tabs unsaved).
    func teardownInactiveTabSessions() {
        let inactive = tabs.filter { $0.id != activeTabId }
        tabs.removeAll { $0.id != activeTabId }
        for tab in inactive {
            teardownTabSession(tab.session)
        }
    }

    /// Make an incoming tab's session the visible one, syncing the window's
    /// per-agent chrome (theme, pills, dropdown, sidebar filter) the same
    /// way `loadSession` does for in-tab switches.
    private func adoptTabSession(_ target: ChatSession) {
        let targetAgentId = target.agentId ?? Agent.defaultId
        if targetAgentId != agentId {
            adoptAgent(targetAgentId)
        }
        session = target
        refreshSessions()
        refreshSandboxChanges()
    }

    /// Save the active session and flush memory before another tab takes
    /// over the visible surface. Deliberately does NOT detach/release — the
    /// outgoing tab still owns its session.
    private func persistActiveSessionForTabSwitch() {
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        flushCurrentSession()
    }

    /// Dispose of a session whose tab was closed, mirroring `cleanup()`'s
    /// per-session rules (see the comments there for why save precedes
    /// stop and shared instances are only unlinked).
    private func teardownTabSession(_ closingSession: ChatSession) {
        if LiveChatSessionRegistry.shared.isShared(closingSession) {
            if !closingSession.turns.isEmpty { closingSession.save() }
            closingSession.windowState = nil
            closingSession.onSessionChanged = nil
            return
        }
        // A mid-run (or clarify-paused) session survives its tab closing the
        // same way it survives its window closing: adopted into the
        // background registry, execution untouched.
        if closingSession.isStreaming || closingSession.awaitingClarify != nil,
            BackgroundTaskManager.shared.adoptSession(closingSession) != nil
        {
            closingSession.windowState = nil
            closingSession.onSessionChanged = nil
            return
        }
        if !closingSession.turns.isEmpty { closingSession.save() }
        closingSession.warmupController.shutdown()
        closingSession.stop()
        closingSession.onSessionChanged = nil
        closingSession.windowState = nil
    }

    // MARK: Recently closed tabs (⇧⌘T)

    private struct ClosedTab {
        let sessionId: UUID
        let index: Int
    }

    /// Most recent last. Only persisted conversations are remembered: a
    /// blank tab has nothing to reopen.
    private var recentlyClosedTabs: [ClosedTab] = []
    private static let recentlyClosedLimit = 10

    private func rememberClosedTab(_ tab: ChatTab, at index: Int) {
        guard let sessionId = tab.session.sessionId,
            tab.isHibernated || !tab.session.turns.isEmpty
        else { return }
        recentlyClosedTabs.removeAll { $0.sessionId == sessionId }
        recentlyClosedTabs.append(ClosedTab(sessionId: sessionId, index: index))
        if recentlyClosedTabs.count > Self.recentlyClosedLimit {
            recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - Self.recentlyClosedLimit)
        }
    }

    /// Reopen the most recently closed tab at its old position (browser
    /// ⇧⌘T). Conversations deleted since, or already open in another tab,
    /// are skipped / focused respectively.
    func reopenLastClosedTab() {
        while let closed = recentlyClosedTabs.popLast() {
            let sessionId = closed.sessionId
            if let open = tabs.first(where: { $0.session.sessionId == sessionId }) {
                selectTab(id: open.id)
                return
            }
            guard let data = ChatSessionStore.load(id: sessionId) else { continue }
            // Always its own tab (a blank active tab is left alone), like a
            // browser restoring a closed tab.
            newTab(agentId: data.agentId ?? Agent.defaultId)
            loadSession(data)
            moveTab(id: activeTabId, to: min(closed.index, tabs.count - 1))
            return
        }
    }

    // MARK: Tab hibernation (LRU)

    /// How many tabs keep a fully hydrated session (transcript, warm-up
    /// controller, KV-cache prefix) at once. Beyond this the least recently
    /// activated idle tabs are hibernated to a metadata-only session.
    private static let warmTabLimit = 5

    /// Hibernate the coldest idle tabs once more than `warmTabLimit` are
    /// hydrated. Streaming, clarify-paused, registry-shared and unsaved
    /// (blank) tabs are never hibernated: their state lives only in memory.
    private func hibernateColdTabsIfNeeded() {
        let warm = tabs.enumerated()
            .filter { $0.element.id != activeTabId && !$0.element.isHibernated }
            .sorted { $0.element.lastActivatedAt < $1.element.lastActivatedAt }
        var excess = warm.count - (Self.warmTabLimit - 1)
        for (idx, tab) in warm where excess > 0 {
            guard canHibernate(tab.session) else { continue }
            hibernate(tabAt: idx)
            excess -= 1
        }
    }

    private func canHibernate(_ s: ChatSession) -> Bool {
        s.sessionId != nil && !s.turns.isEmpty && !s.isStreaming && s.awaitingClarify == nil
            && !LiveChatSessionRegistry.shared.isShared(s)
    }

    /// Save the tab's session, then swap it for a metadata-only stand-in
    /// (same ids/title/agent/project, no turns) and release the hydrated
    /// instance's warm-up state.
    private func hibernate(tabAt idx: Int) {
        let live = tabs[idx].session
        live.save()
        var snapshot = live.toSessionData()
        snapshot.turns = []
        let cold = makeFreshSession(agentId: live.agentId ?? Agent.defaultId, loading: snapshot)
        live.warmupController.shutdown()
        live.stop()
        live.onSessionChanged = nil
        live.windowState = nil
        tabs[idx].session = cold
        tabs[idx].isHibernated = true
    }

    /// Reload a hibernated tab's transcript from disk in place.
    private func wake(tabAt idx: Int) {
        let cold = tabs[idx].session
        if let sid = cold.sessionId, let full = ChatSessionStore.load(id: sid) {
            cold.load(from: full)
        }
        tabs[idx].isHibernated = false
    }

    /// Sessions that are actually hydrated in this window (excludes
    /// hibernated stand-ins, which have ids but no transcript).
    var liveTabSessions: [ChatSession] {
        tabs.filter { !$0.isHibernated }.map(\.session)
    }

    /// Keep the active tab's entry pointing at the window's current session
    /// after in-tab navigation replaces the instance (loadSession /
    /// startNewChat / switchAgent / attach paths).
    private func syncActiveTabSession() {
        guard let idx = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        if tabs[idx].session !== session {
            tabs[idx].session = session
        }
    }

    /// Build a fresh, window-linked `ChatSession` (shared by `newTab` and
    /// `installFreshSession`).
    private func makeFreshSession(agentId: UUID, loading data: ChatSessionData? = nil) -> ChatSession {
        let fresh = ChatSession()
        fresh.windowState = self
        fresh.agentId = agentId
        fresh.applyInitialModelSelection()
        if let data { fresh.load(from: data) }
        fresh.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }
        return fresh
    }

    // MARK: - Sandbox Changes

    /// Re-query the tracker for the current session's outstanding sandbox
    /// change count + active-job flag. Cheap (actor cache hit) and safe to
    /// call on every chat switch / tracker notification.
    func refreshSandboxChanges() {
        // Remote-agent chats never mutate the local sandbox; a new chat has
        // no session id until the first send.
        guard selectedDiscoveredAgentProviderId == nil,
            let sessionId = session.sessionId?.uuidString
        else {
            sandboxChangesCount = 0
            sandboxChangesHaveActiveJob = false
            return
        }
        Task { [weak self] in
            let count = await SandboxWorkspaceChangeTracker.shared.changeCount(for: sessionId)
            let hasJob = await SandboxWorkspaceChangeTracker.shared.hasActiveBackgroundJobs(
                sessionId: sessionId)
            await MainActor.run {
                guard let self, self.session.sessionId?.uuidString == sessionId else { return }
                self.sandboxChangesCount = count
                self.sandboxChangesHaveActiveJob = hasJob
            }
        }
    }

    // MARK: - Detach / Attach

    /// Hand a mid-run session over to the `BackgroundTaskManager` registry so
    /// its execution lifecycle survives this window moving to another chat
    /// (or closing). Returns true when a handoff happened — the caller must
    /// then install a replacement session rather than reuse (and thereby
    /// stop) the detached one.
    @discardableResult
    private func detachRunningSessionIfNeeded() -> Bool {
        guard session.isStreaming || session.awaitingClarify != nil else { return false }
        // Registry-shared sessions are co-owned by their registering
        // owner, which keeps an in-flight run alive after this window
        // stops viewing it; adopting one into the background-task registry
        // would create a second owner. `releaseSharedSessionIfNeeded` is the
        // hand-off path for them.
        guard !LiveChatSessionRegistry.shared.isShared(session) else { return false }
        guard BackgroundTaskManager.shared.adoptSession(session) != nil else { return false }
        // The detached run no longer belongs to this window: break the weak
        // window link so it can't push alerts into a view showing a
        // different conversation, and stop routing its saves into this
        // window's sidebar refresh.
        session.windowState = nil
        session.onSessionChanged = nil
        BackgroundTaskManager.shared.unbindWindow(windowId)
        return true
    }

    /// Unlink this window from a registry-shared session (co-owned by
    /// another surface) WITHOUT resetting, reloading, or
    /// stopping it — the other surface keeps it live. Returns true when the
    /// current session was shared and the caller must install a replacement
    /// rather than mutate the released one.
    @discardableResult
    private func releaseSharedSessionIfNeeded() -> Bool {
        guard LiveChatSessionRegistry.shared.isShared(session) else { return false }
        session.windowState = nil
        session.onSessionChanged = nil
        BackgroundTaskManager.shared.unbindWindow(windowId)
        return true
    }

    /// Attach a registry-shared live session so this window
    /// renders the exact instance the other surface owns. Unlike
    /// `attachSession` there is no background-task binding — the co-owner
    /// governs the execution lifecycle.
    private func attachSharedSession(_ sharedSession: ChatSession) {
        sharedSession.windowState = self
        sharedSession.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }
        session = sharedSession
    }

    /// Install a brand-new `ChatSession` for this window (optionally loading
    /// persisted turns), used after the previous one was detached to the
    /// registry.
    private func installFreshSession(agentId: UUID, loading data: ChatSessionData? = nil) {
        session = makeFreshSession(agentId: agentId, loading: data)
    }

    /// Attach an existing (registry-owned) live session to this window so
    /// the user sees the in-flight stream. Execution ownership stays with
    /// the registry; the window is only a view. The window→task binding
    /// makes close/switch detach instead of stop, and suppresses the
    /// duplicate notch/toast surface while the chat is visible.
    private func attachSession(_ liveSession: ChatSession, registryTaskId: UUID) {
        liveSession.windowState = self
        liveSession.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }
        session = liveSession
        BackgroundTaskManager.shared.bindWindow(windowId, toTask: registryTaskId)
    }

    /// Switch every per-agent piece of window state (`agentId`,
    /// discovered/relay-agent pills, theme, system-prompt cache, global
    /// active-agent pointer) to `newAgentId` WITHOUT touching the
    /// session's content. `switchAgent` calls this before resetting the
    /// session for a brand-new chat; `loadSession` calls it before
    /// loading turns from disk.
    private func adoptAgent(_ newAgentId: UUID) {
        removeEphemeralProviderIfNeeded()
        selectedDiscoveredAgent = nil
        selectedDiscoveredAgentProviderId = nil
        selectedRelayAgent = nil
        pinnedRemoteAgentEffectiveModel = nil
        pinnedRemoteAgentAvatar = nil
        pinnedRemoteAgentQuickActions = nil
        remoteAgentConnectionPhase = .idle
        agentId = newAgentId
        refreshTheme()
        refreshAgentConfig()
        AgentManager.shared.setActiveAgent(newAgentId)
    }

    private func flushCurrentSession() {
        guard let sid = session.sessionId else { return }
        let agentStr = (session.agentId ?? Agent.defaultId).uuidString
        let convStr = sid.uuidString
        Task {
            await MemoryService.shared.flushSession(agentId: agentStr, conversationId: convStr)
        }
    }

    // MARK: - Refresh Methods

    func refreshAgents() {
        let allAgents = AgentManager.shared.agents
        agents = allAgents
        cachedActiveAgent = allAgents.first { $0.id == agentId } ?? .default
        cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
    }

    func refreshSessions() {
        filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)
    }

    /// Coalesces rapid `refreshSessions()` calls (e.g. during streaming saves).
    func refreshSessionsDebounced() {
        sessionRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshSessions()
            }
        }
        sessionRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    /// `freshAgent` lets callers that already hold the up-to-date agent (e.g.
    /// the `applyAgentsUpdate` sink, which runs during `@Published`'s `willSet`
    /// while `AgentManager.shared.agents` still holds the OLD array) resolve the
    /// theme from that fresh value instead of re-reading the stale singleton —
    /// otherwise the window's theme trails a per-agent theme change by one.
    func refreshTheme(freshAgent: Agent? = nil) {
        let newTheme = Self.loadTheme(for: agentId, freshAgent: freshAgent)
        let oldConfig = theme.customThemeConfig
        let newConfig = newTheme.customThemeConfig
        // Skip only if the full config is identical (not just the ID) and the
        // global font zoom is unchanged — the zoom lives on the theme instance,
        // not in the config, so it must be compared separately.
        let oldScale = (theme as? CustomizableTheme)?.fontScale
        let newScale = (newTheme as? CustomizableTheme)?.fontScale
        guard oldConfig != newConfig || oldScale != newScale else { return }
        let shouldRedecodeBackgroundImage = Self.needsBackgroundImageRedecode(
            oldConfig: oldConfig,
            newConfig: newConfig
        )

        theme = newTheme

        if shouldRedecodeBackgroundImage {
            decodeBackgroundImageAsync(themeConfig: newConfig)
        }
    }

    nonisolated static func needsBackgroundImageRedecode(oldConfig: CustomTheme?, newConfig: CustomTheme?) -> Bool {
        BackgroundImageDecodeKey(config: oldConfig) != BackgroundImageDecodeKey(config: newConfig)
    }

    func refreshAgentConfig() {
        cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        cachedActiveAgent = agents.first { $0.id == agentId } ?? .default
        cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
        // `.appConfigurationChanged` also feeds ChatSession's prompt-shape
        // detector. Keep its old preview bytes until that detector compares
        // them with the newly persisted Default-agent configuration. Clearing
        // the preview here allowed the intervening SwiftUI redraw to cache
        // the new bytes first, hiding the change and leaving a stale green
        // warm-prefix claim for the next send.
        session.invalidateTokenCache(preservingPromptShapeBaseline: true)
    }

    func refreshAll() async {
        refreshAgents()
        refreshSessions()
        refreshTheme()
        refreshAgentConfig()
        await session.refreshPickerItems()
    }

    // MARK: - Private

    private func observeBonjourBrowser() {
        bonjourCancellable = BonjourBrowser.shared.$discoveredAgents
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                guard let self else { return }
                self.discoveredAgents = agents
                if let selected = self.selectedDiscoveredAgent {
                    if let refreshed = agents.first(where: { $0.id == selected.id }) {
                        // Agent survived (or re-appeared within the browser's
                        // removal grace period). If it came back on a new
                        // host/port — sleep/wake, DHCP change — repoint the
                        // provider and reconnect so the chat keeps working.
                        if refreshed.host != selected.host || refreshed.port != selected.port {
                            self.selectedDiscoveredAgent = refreshed
                            self.reconnectSelectedDiscoveredAgent(to: refreshed)
                        }
                    } else {
                        // Browser already debounces flaps; an actual removal
                        // here means the agent has been gone for the full
                        // grace period.
                        self.removeEphemeralProviderIfNeeded()
                        self.selectedDiscoveredAgent = nil
                        self.selectedDiscoveredAgentProviderId = nil
                    }
                }
                self.refreshPairedRelayAgents(discoveredAgents: agents)
            }
    }

    /// Repoint the selected agent's provider at a refreshed host/port and
    /// reconnect. Used when a discovered agent re-resolves to a new endpoint
    /// after a network change.
    private func reconnectSelectedDiscoveredAgent(to agent: DiscoveredAgent) {
        guard let providerId = selectedDiscoveredAgentProviderId else { return }
        let manager = RemoteProviderManager.shared
        guard var provider = manager.configuration.providers.first(where: { $0.id == providerId })
        else { return }
        let rawHost = agent.host ?? ""
        guard !rawHost.isEmpty else { return }
        provider.host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        provider.port = agent.port
        manager.updateProvider(provider, apiKey: nil)
        Task { try? await manager.connect(providerId: providerId) }
    }

    /// Mirror `AgentManager.shared.$agents` into this window so the picker,
    /// `cachedActiveAgent`, and `cachedAgentDisplayName` stay live across
    /// mutations from anywhere (AgentsView, onboarding, plugins, other
    /// windows). The publisher is already `@MainActor`-bound, so we skip
    /// `.receive(on:)` to avoid an unnecessary RunLoop hop.
    ///
    /// `@Published` replays its current value on subscribe; since the
    /// initializers populate the cached fields with the same source-of-
    /// truth values just before calling this, that first replay no-ops in
    /// the `oldActive == newActive` gate of `applyAgentsUpdate`.
    private func observeAgentManager() {
        agentsCancellable = AgentManager.shared.$agents
            .sink { [weak self] latest in
                self?.applyAgentsUpdate(latest)
            }
    }

    private func observeSessionsManager() {
        sessionsCancellable = ChatSessionsManager.shared.$sessions
            .dropFirst()
            .sink { [weak self] _ in
                // `@Published` emits in willSet (see the warning on
                // `applyAgentsUpdate`): during this callback the manager's
                // storage still holds the OLD array, and `refreshSessions()`
                // re-reads that storage. Refreshing synchronously here
                // captured mid-mutation state — after `upsertInMemory`'s
                // remove+insert pair, the LAST emission observed the list
                // with the session removed but not yet re-inserted, so the
                // sidebar latched onto a snapshot missing a live chat until
                // some later refresh happened to run (never, for the quiet
                // auto-title rename). Hop one main-actor turn so the read
                // sees the post-mutation array.
                Task { @MainActor [weak self] in
                    self?.refreshSessions()
                }
            }
    }

    /// Reconcile our snapshot with a fresh emission from `AgentManager.$agents`.
    ///
    /// - Active agent missing → fall back to Default via `switchAgent`.
    /// - Otherwise always update the dropdown-facing snapshot (cheap path
    ///   that handles non-active mutations).
    /// - Only when the active agent's `Agent` value changed do we touch the
    ///   token cache, system-prompt cache, and theme — same gating the
    ///   removed `.agentUpdated` observer used to do, now driven by the
    ///   source-of-truth array's `Equatable` diff.
    ///
    /// IMPORTANT: do not read from `AgentManager.shared.agents` (or
    /// `effectiveSystemPrompt`, which routes through it) inside this
    /// method. Combine's `@Published` emits in `willSet`, so during the
    /// sink callback the singleton's storage still holds the OLD array;
    /// only `latest` and the resolved `newActive` are guaranteed fresh.
    private func applyAgentsUpdate(_ latest: [Agent]) {
        let oldActive = cachedActiveAgent
        agents = latest

        guard let newActive = latest.first(where: { $0.id == agentId }) else {
            // `switchAgent` updates theme/sessions/config and persists the
            // selection. `agents` was just swapped above, so any re-read
            // inside `switchAgent` sees the fresh list.
            switchAgent(to: Agent.defaultId)
            return
        }

        cachedActiveAgent = newActive
        cachedAgentDisplayName = Self.displayName(for: newActive)

        guard newActive != oldActive else { return }

        // The Default agent's mutable settings live in `ChatConfiguration`
        // and are kept fresh by the `.appConfigurationChanged` observer;
        // here we only refresh the cache for the custom-agent case (using
        // the fresh `newActive`, not the stale singleton).
        if !newActive.isBuiltIn {
            cachedSystemPrompt = newActive.systemPrompt
        }
        // The matching `.agentUpdated` / prompt-shape signal must compare the
        // old preview against this newly published agent. Preserve that
        // baseline across the immediate window-state refresh; otherwise a
        // view redraw can consume the new shape before the detector runs.
        session.invalidateTokenCache(preservingPromptShapeBaseline: true)

        if newActive.themeId != oldActive.themeId {
            // Resolve from `newActive`: the singleton's `agents` is still the old
            // array during this `willSet` sink, so re-reading it would apply the
            // previous theme (a one-change lag).
            refreshTheme(freshAgent: newActive)
        }
    }

    func refreshPairedRelayAgents(discoveredAgents: [DiscoveredAgent]? = nil) {
        let knownAgents = discoveredAgents ?? self.discoveredAgents
        let discoveredIds = Set(knownAgents.map(\.id))
        let manager = RemoteProviderManager.shared
        pairedRelayAgents = manager.configuration.providers.compactMap { provider in
            guard provider.providerType == .osaurus,
                !manager.isEphemeral(id: provider.id),
                let agentId = provider.remoteAgentId,
                let relayAddress = provider.remoteAgentAddress,
                !discoveredIds.contains(agentId)
            else { return nil }
            return PairedRelayAgent(
                id: agentId,
                name: provider.name,
                remoteAgentAddress: relayAddress,
                providerId: provider.id,
                avatar: RemoteAgentManager.shared.remoteAgent(forProviderId: provider.id)?.avatar
            )
        }
    }

    private func removeEphemeralProviderIfNeeded() {
        guard let providerId = selectedDiscoveredAgentProviderId,
            RemoteProviderManager.shared.isEphemeral(id: providerId)
        else { return }
        RemoteProviderManager.shared.removeProvider(id: providerId)
    }

    private static func loadTheme(for agentId: UUID, freshAgent: Agent? = nil) -> ThemeProtocol {
        // Prefer an explicitly-supplied fresh agent over the singleton, which can
        // still be mid-update (see `refreshTheme(freshAgent:)`). The Default agent
        // always uses the global theme, matching `AgentManager.themeId(for:)`.
        let agent = freshAgent ?? AgentManager.shared.agent(for: agentId)
        if let agent, agent.id != Agent.defaultId,
            let themeId = agent.themeId,
            let custom = ThemeManager.shared.installedThemes.first(where: { $0.metadata.id == themeId })
        {
            return CustomizableTheme(config: custom)
        }
        return ThemeManager.shared.currentTheme
    }

    /// Built-in default agent renders its localized display name (the
    /// "Osaurus" brand label, or the user's custom Orchestrator name from
    /// Settings → Orchestrator) so the chat header carries the product
    /// name instead of the internal `"Default"` id; custom agents render
    /// their stored name verbatim.
    private static func displayName(for agent: Agent) -> String {
        agent.displayName
    }

    /// The identity that should head the chat thread / empty state right now.
    /// In Mode 2 (a discovered/relay agent is selected) this is the *remote*
    /// agent's name + fetched mascot; otherwise it's the local active agent.
    /// Drives message-bubble headers so a remote conversation isn't mislabeled
    /// "Osaurus" with the local avatar.
    var effectiveChatIdentity: ChatThreadIdentity {
        if selectedDiscoveredAgentProviderId != nil {
            let remoteName =
                selectedDiscoveredAgent?.name
                ?? selectedRelayAgent?.name
                ?? L("Remote Agent")
            return ChatThreadIdentity(
                name: remoteName,
                mascotId: pinnedRemoteAgentAvatar,
                customAvatarPath: nil,
                isRemote: true
            )
        }
        return ChatThreadIdentity(
            name: cachedAgentDisplayName,
            mascotId: cachedActiveAgent.avatar,
            customAvatarPath: cachedActiveAgent.customAvatarURL?.path,
            isRemote: false
        )
    }

    private func decodeBackgroundImageAsync(themeConfig: CustomTheme?) {
        Task { [weak self] in
            let decoded = themeConfig?.background.decodedImage()
            self?.cachedBackgroundImage = decoded
        }
    }

    private struct BackgroundImageDecodeKey: Equatable {
        let themeId: UUID?
        let backgroundType: ThemeBackground.BackgroundType?
        let imageData: String?

        init(config: CustomTheme?) {
            self.themeId = config?.metadata.id
            self.backgroundType = config?.background.type
            self.imageData = config?.background.imageData
        }
    }

    private func setupNotificationObservers() {
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .activeAgentChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshAgents() } }
        )
        // Conversation import saves sessions from outside any window;
        // refresh so the new rows appear in every open sidebar.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .chatSessionsImported,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshSessions() } }
        )
        // Sandbox change tracking: refresh the toolbar count when the
        // tracker records/undoes changes for the session this window shows.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .sandboxWorkspaceChangesDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let changed = notification.userInfo?["sessionId"] as? String
                Task { @MainActor in
                    guard let self else { return }
                    guard let current = self.session.sessionId?.uuidString,
                        changed == nil || changed == current
                    else { return }
                    self.refreshSandboxChanges()
                }
            }
        )
        // Note: .chatOverlayActivated intentionally not observed here
        // State is loaded in init(), refreshAll() would cause excessive re-renders
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .appConfigurationChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshAgentConfig() } }
        )
        // refresh theme when any theme on disk changes. refreshTheme()
        // re-resolves from `installedThemes`/`currentTheme` and no ops via its
        // config equality guard if this window's effective theme is unchanged,
        // so windows pinned to an agent specific theme also pick up live edits
        // to that theme without waiting for a reopen
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .globalThemeChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshTheme() }
            }
        )
        // Note: `.agentUpdated` is intentionally not observed here.
        // `observeAgentManager()` covers active-custom-agent updates by
        // diffing the published `agents` array, and the
        // `.appConfigurationChanged` observer above covers Default-agent
        // updates (whose settings live in `ChatConfiguration`).

        // Clear the selected paired/relay agent pill when its provider is
        // removed from settings.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .remoteProviderStatusChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                        let providerId = self.selectedDiscoveredAgentProviderId
                    else { return }
                    let manager = RemoteProviderManager.shared
                    let providerExists = manager.configuration.providers
                        .contains(where: { $0.id == providerId })
                    guard providerExists else {
                        // Provider was removed from settings — leave remote-agent mode.
                        self.selectedDiscoveredAgent = nil
                        self.selectedRelayAgent = nil
                        self.selectedDiscoveredAgentProviderId = nil
                        self.pinnedRemoteAgentEffectiveModel = nil
                        self.pinnedRemoteAgentAvatar = nil
                        self.pinnedRemoteAgentQuickActions = nil
                        self.remoteAgentConnectionPhase = .idle
                        self.refreshPairedRelayAgents()
                        return
                    }
                    // Provider still selected: mirror later connect/disconnect/
                    // error transitions (e.g. the peer drops or reconnects) so
                    // chat keeps showing an accurate status without overwriting
                    // the optimistic `.connecting`/`.connected` set by the
                    // connect flow before the manager publishes its first state.
                    if let state = manager.providerStates[providerId] {
                        if let lastError = state.lastError, !lastError.isEmpty,
                            !state.isConnected, !state.isConnecting
                        {
                            self.remoteAgentConnectionPhase = .failed(lastError)
                        } else if state.isConnected {
                            // Don't pre-empt the in-flight connect+pin: while
                            // we're still `.connecting`, the pin flow owns the
                            // final `.connected` transition (it flips only once
                            // the model pin resolves, so the gated send releases
                            // with the right model). Only reflect a *later*
                            // reconnect (phase was `.failed`/`.connected`) here.
                            if self.remoteAgentConnectionPhase != .connecting {
                                self.remoteAgentConnectionPhase = .connected
                            }
                        } else if state.isConnecting,
                            self.remoteAgentConnectionPhase != .connected
                        {
                            self.remoteAgentConnectionPhase = .connecting
                        }
                    }
                }
            }
        )
    }
}
