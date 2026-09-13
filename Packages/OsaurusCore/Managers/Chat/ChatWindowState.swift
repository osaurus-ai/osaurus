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

/// Why the composer refuses input right now. nil = the user can type and
/// send. Rendered by `ChatView` as a notice above the (disabled) composer;
/// the card keeps its shape so the layout doesn't jump.
public enum ComposerLock: Equatable, Sendable {
    /// The teammate's Osaurus that hosts this shared agent isn't reachable.
    /// History stays readable; new messages wait for the host to come back.
    case agentOffline(agentName: String, ownerName: String?, lastSeen: Date?)
    /// The shared agent hasn't been paired on this device yet (auto-connect
    /// failed or hasn't run); carries the last failure reason, if any.
    case agentNotConnected(agentName: String, reason: String?)
    /// The Mode 2 connect + model pin is in flight.
    case connecting(agentName: String)
    /// This is a remote caller's conversation that this instance served for
    /// them (host side) — a workspace teammate (`isWorkspace`) or an
    /// invite-link peer. Read-only: replying here would inject into their
    /// chat. While the run is live the notice shows its step and a Stop.
    case teammateConversation(callerName: String?, agentName: String, isWorkspace: Bool)
    /// The agent is no longer reachable through the workspace at all: its
    /// owner unshared it, or the user is no longer a member. History stays
    /// readable; there is nothing to retry.
    case agentUnavailable(agentName: String, reason: String)

    /// Whether the user may retry a connection from the notice.
    public var offersRetry: Bool {
        switch self {
        case .agentOffline, .agentNotConnected: return true
        case .connecting, .teammateConversation, .agentUnavailable: return false
        }
    }
}

/// A Mode 2 connect the window state asked the view layer to perform. The
/// connect flow (provider update → connect → effective-model pin) lives in
/// `ChatView` because it drives the session's picker; the window state only
/// records the intent so a freshly mounted `ChatView` (tab remount) can pick
/// it up on appear instead of racing a notification.
struct PendingRelayConnect: Equatable {
    let id: UUID
    let relay: PairedRelayAgent
    /// Keep the current transcript (reopening history) instead of resetting
    /// the session for a fresh chat.
    let preserveSession: Bool

    init(relay: PairedRelayAgent, preserveSession: Bool) {
        self.id = UUID()
        self.relay = relay
        self.preserveSession = preserveSession
    }
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

/// Which agent a tab belongs to. The tab strip is scoped to the window's
/// active agent: only tabs in the same scope are visible, and the sidebar's
/// agent rows switch between scopes. A local agent's chats (including the
/// host-side read-only copies of a teammate's chats with a shared local
/// agent) scope by agent id; a chat with a teammate's shared agent scopes
/// by that agent's workspace address.
enum ChatTabScope: Hashable {
    case local(UUID)
    case workspace(String, workspaceId: String = "")

    @MainActor
    static func of(_ session: ChatSession) -> ChatTabScope {
        if let context = session.workspaceContext, !context.isServedForTeammate {
            return .workspace(context.agentAddress.lowercased(), workspaceId: context.workspaceId)
        }
        return .local(session.agentId ?? Agent.defaultId)
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

    /// The agent whose tabs the strip currently shows: the workspace agent
    /// the window's remote mode is bound to, else the window's local agent.
    /// Both follow the active tab (`adoptTabSession` / `reconcileRemoteMode`).
    var activeScope: ChatTabScope {
        if let address = workspaceAgentAddress { return .workspace(address.lowercased(), workspaceId: session.workspaceContext?.workspaceId ?? "") }
        return .local(agentId)
    }

    /// The tabs visible in the strip: those belonging to the active agent,
    /// in global order. The active tab is always included so the strip can
    /// never show a selection it doesn't contain.
    var scopedTabs: [ChatTab] {
        let scope = activeScope
        return tabs.filter { $0.id == activeTabId || ChatTabScope.of($0.session) == scope }
    }

    /// Tabs in `scope` (any agent), in global order.
    func tabs(in scope: ChatTabScope) -> [ChatTab] {
        tabs.filter { ChatTabScope.of($0.session) == scope }
    }

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
    @Published var remoteAgentConnectionPhase: RemoteAgentConnectionPhase = .idle {
        didSet { mirrorPhaseToConnectService() }
    }

    /// Keep `WorkspaceAgentConnectService.connectFailures` — the one failure
    /// map every list row reads — in step with THIS window's relay connect
    /// for a workspace agent. Without this the sidebar/Workspaces rows show a
    /// paired agent as ready (green dot, "owner · model") while the composer
    /// says the connect was rejected: two surfaces, two verdicts.
    private func mirrorPhaseToConnectService() {
        guard let address = workspaceAgentAddress else { return }
        let connect = WorkspaceAgentConnectService.shared
        switch remoteAgentConnectionPhase {
        case .failed(let message):
            connect.recordFailure(message, for: address, workspaceId: session.workspaceContext?.workspaceId)
        case .connected:
            connect.clearFailure(for: address, workspaceId: session.workspaceContext?.workspaceId)
            // A later key expiry may be repaired again.
            pairingRepairAttemptedFor = nil
        case .connecting:
            // A fresh attempt supersedes the previous verdict; a failure
            // re-records above if it comes back.
            connect.clearFailure(for: address, workspaceId: session.workspaceContext?.workspaceId)
        case .idle:
            break
        }
    }

    // MARK: - Workspace (team) agent state

    /// Lowercased address of the workspace teammate's shared agent the
    /// window's remote mode is currently bound to, or nil when the active
    /// tab is a local chat (or a legacy Bonjour/relay Mode 2 chat). Drives
    /// the sidebar's selected row and the composer lock; kept in step with
    /// the active tab's `session.workspaceContext` by `reconcileRemoteMode`.
    @Published private(set) var workspaceAgentAddress: String?

    /// A connect the view layer should run (see `PendingRelayConnect`).
    /// `ChatView` consumes and clears it on appear / change.
    @Published var pendingRelayConnect: PendingRelayConnect?
    /// Whether this window holds a `WorkspaceRosterStore` observer (poll
    /// lease); released in `cleanup()`.
    private var isObservingRoster = false

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

    /// The size the chat layout is designed to fit into at minimum: with the
    /// sidebar open (260pt) plus the tab strip, anything narrower squished
    /// the chat column, and anything shorter left the composer and the
    /// empty-state hero fighting for room. Windows on screens that can show
    /// this much use it verbatim; see `minimumContentSize`.
    static let designMinimumContentSize = CGSize(width: 800, height: 620)

    /// The effective minimum content size for THIS window: the design
    /// minimum, clamped to what its screen can actually show. The root view
    /// applies it as `.frame(minWidth:minHeight:)`, which the hosting
    /// controller mirrors into the window's `contentMinSize`. Without the
    /// clamp, a screen whose visible area is smaller than the design minimum
    /// (e.g. a 14" MacBook Pro at "Larger Text", 1024x665) gets a window
    /// AppKit cannot shrink to fit, so it hangs off the bottom of the screen
    /// with the composer cut off (#2728). Pushed by `ChatWindowManager` on
    /// creation and whenever the window changes screen.
    @Published private(set) var minimumContentSize: CGSize = ChatWindowState.designMinimumContentSize

    /// Clamp the design minimum to `availableContentSize`, the largest
    /// content area the window's screen can show (visible frame minus the
    /// window's own titlebar/toolbar chrome). An axis at or below zero means
    /// "no screen known" and keeps the design value, so a transient
    /// measurement can't collapse the floor.
    func updateMinimumContentSize(availableContentSize available: CGSize) {
        let design = Self.designMinimumContentSize
        var next = design
        if available.width > 0 { next.width = min(design.width, floor(available.width)) }
        if available.height > 0 { next.height = min(design.height, floor(available.height)) }
        guard next != minimumContentSize else { return }
        minimumContentSize = next
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
    private var workspaceCancellables: Set<AnyCancellable> = []

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
            // The sidebar and the history panel hold METADATA rows
            // (`ChatSessionStore.loadAll` → `loadAllMetadata`, turns: []).
            // "Open in New Window" handed that row straight here, so the
            // new window showed an empty transcript, the next send went to
            // the model with no history, and the incremental save then
            // deleted every stored turn the window never had (2026-09-06:
            // a 50-turn research session reopened from History became 2
            // turns). Hydrate from disk exactly as the in-place open does
            // (`loadSession(_:)` below); fall back to the given data only
            // when the row is not on disk (a brand-new, unsaved session).
            let resolved = data.turns.isEmpty ? (ChatSessionStore.load(id: data.id) ?? data) : data
            self.session.load(from: resolved)
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
        // A brand-new window chat (no session handed in) starts in the
        // agent's sticky working folder, like every other fresh chat. A
        // reopened session keeps its own persisted folder.
        if sessionData == nil {
            adoptAgentWorkingFolder()
        }

        setupNotificationObservers()
        observeBonjourBrowser()
        observeAgentManager()
        observeSessionsManager()
        observeWorkspaceState()
        refreshPairedRelayAgents()
        refreshSandboxChanges()
        reconcileRemoteMode()
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
        observeWorkspaceState()
        refreshPairedRelayAgents()
        refreshSandboxChanges()
        reconcileRemoteMode()
    }

    deinit {
        print("[ChatWindowState] deinit – windowId: \(windowId)")
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Stops any running execution and breaks reference chains — call when window is closing.
    func cleanup() {
        if isObservingRoster {
            isObservingRoster = false
            WorkspaceRosterStore.shared.endObserving()
        }
        pendingRelayConnect = nil
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
        // Same for a registry-owned run on screen: the registry keeps
        // executing (and finalizing) it; this window only stops viewing.
        if BackgroundTaskManager.shared.task(owning: session) != nil {
            if !session.turns.isEmpty { session.save() }
            session.windowState = nil
            session.onSessionChanged = nil
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

    /// Pick another agent: show that agent's tabs. When the agent already
    /// has tabs in this window, the one that needs input (else the most
    /// recently used) is focused and a blank tab left behind in the outgoing
    /// agent's scope is dropped. Otherwise a blank active tab is repurposed,
    /// else the conversation stays put in its tab and the new agent opens in
    /// a fresh tab. The fresh chat does NOT inherit the outgoing chat's
    /// project: it is a different agent's new conversation, so the project
    /// pill only shows for chats that belong to a project.
    func switchAgent(to newAgentId: UUID) {
        TTSService.shared.stop()
        // Picking an agent means "show me this agent's chats": dismiss the
        // project page even when the agent is already active, otherwise the
        // early returns below leave the page covering the chat (#2709).
        openProjectId = nil
        enteredChatFromProjectPage = false
        let scope = ChatTabScope.local(newAgentId)
        if scope == activeScope { return }
        if focusExistingTab(in: scope) { return }
        if isBlank(session) {
            adoptAgent(newAgentId)
            if releaseSharedSessionIfNeeded() || detachRunningSessionIfNeeded() {
                installFreshSession(agentId: newAgentId)
            } else {
                session.reset(for: newAgentId)
                // A blank team-agent tab repurposed for a local agent drops
                // its workspace identity (reset keeps it for New Chat).
                session.workspaceContext = nil
                adoptAgentWorkingFolder()
            }
            reconcileRemoteMode()
            refreshSessions()
            refreshSandboxChanges()
            return
        }
        newTab(agentId: newAgentId)
    }

    /// Pick a workspace teammate's shared agent from the sidebar, exactly
    /// like picking a local agent: the agent's existing tabs are shown when
    /// it has any; otherwise a blank active tab is repurposed, else a new
    /// tab opens. The tab's session is stamped with the agent's
    /// `WorkspaceSessionContext` (so its history lives under that agent) and
    /// the window's remote mode is bound to the agent's paired provider.
    /// Offline / unpaired agents still open — history stays browsable and
    /// the composer explains why sending is locked.
    ///
    /// Also the path for agents shared directly through an invite link (on
    /// no workspace roster): the stamped context then carries an empty
    /// workspace id, which the composer lock and pool chip treat as "no
    /// workspace" rather than "workspace lost".
    func switchToWorkspaceAgent(address rawAddress: String, workspaceId requestedWorkspaceId: String? = nil) {
        let address = rawAddress.lowercased()
        TTSService.shared.stop()
        openProjectId = nil
        enteredChatFromProjectPage = false
        let matches = WorkspaceRosterStore.shared.workspacesSharing(agentAddress: address)
        let workspaceId = requestedWorkspaceId ?? (matches.count == 1 ? matches.first?.id : nil) ?? ""
        let scope = ChatTabScope.workspace(address, workspaceId: workspaceId)
        if scope == activeScope { return }
        if focusExistingTab(in: scope) { return }
        if isBlank(session) {
            if agentId != Agent.defaultId { adoptAgent(Agent.defaultId) }
            if releaseSharedSessionIfNeeded() || detachRunningSessionIfNeeded() {
                installFreshSession(agentId: Agent.defaultId, restoresDraft: false)
            } else {
                session.reset(for: Agent.defaultId)
            }
            stampWorkspaceContext(address: address, workspaceId: workspaceId, on: session)
            reconcileRemoteMode()
            refreshSessions()
            refreshSandboxChanges()
            return
        }
        // The tab is stamped as the team agent's right below; the hosting
        // local agent's own New Chat draft must not land in it.
        newTab(agentId: Agent.defaultId, restoresDraft: false)
        stampWorkspaceContext(address: address, workspaceId: workspaceId, on: session)
        reconcileRemoteMode()
        refreshSessions()
    }

    /// Show an agent's existing tabs: focus the one waiting for input, else
    /// the most recently activated one. A blank tab left behind in the
    /// outgoing scope is dropped so switching back and forth never litters
    /// the strip with empty chats. Returns false when the scope has no tabs
    /// (the caller then opens one).
    private func focusExistingTab(in scope: ChatTabScope) -> Bool {
        let candidates = tabs.filter { $0.id != activeTabId && ChatTabScope.of($0.session) == scope }
        guard !candidates.isEmpty else { return false }
        let target =
            candidates.first { !$0.isHibernated && $0.session.awaitingClarify != nil }
            ?? candidates.max { $0.lastActivatedAt < $1.lastActivatedAt }
        guard let target else { return false }
        let outgoing = tabs.first { $0.id == activeTabId }
        selectTab(id: target.id)
        if let outgoing, !outgoing.isHibernated, isBlank(outgoing.session),
            ChatTabScope.of(outgoing.session) != scope
        {
            // The blank tab goes away, but whatever the user had typed in
            // it comes back the next time this agent gets a New Chat.
            outgoing.session.stashDraft()
            dropTab(outgoing)
        }
        return true
    }

    /// Remove an INACTIVE tab from the strip and dispose of its session.
    private func dropTab(_ tab: ChatTab) {
        guard tab.id != activeTabId, tabs.contains(where: { $0.id == tab.id }) else { return }
        tabs.removeAll { $0.id == tab.id }
        teardownTabSession(tab.session)
    }

    /// A fresh blank tab for `scope` (not yet inserted): a local agent's
    /// chat, or a chat stamped with a workspace agent's context.
    private func makeBlankTab(in scope: ChatTabScope) -> ChatTab {
        switch scope {
        case .local(let id):
            let fresh = makeFreshSession(agentId: id)
            adoptAgentWorkingFolder(on: fresh)
            return ChatTab(id: UUID(), session: fresh)
        case .workspace(let address, let workspaceId):
            let fresh = makeFreshSession(agentId: Agent.defaultId, restoresDraft: false)
            stampWorkspaceContext(address: address, workspaceId: workspaceId, on: fresh)
            return ChatTab(id: UUID(), session: fresh)
        }
    }

    /// Re-run the Mode 2 connect for the active team-agent tab (Retry on
    /// the composer lock notice). Refreshes presence first so a host that
    /// came back is picked up without waiting for the poll.
    func retryWorkspaceAgentConnection() {
        guard let context = session.workspaceContext else { return }
        let address = context.agentAddress
        let originalSession = session
        Task { @MainActor [weak self] in
            await WorkspaceRosterStore.shared.refresh(reason: .manual)
            guard let self, self.session === originalSession,
                self.session.workspaceContext == context else { return }
            // A manual Retry re-runs the workspace handshake even for an
            // agent that is already paired: the usual reason a paired agent
            // fails is a stale attested key (the host refuses it), and
            // reconnecting the same provider with the same key can never
            // recover from that. Direct shares (no workspace) have no
            // handshake to re-run and just reconnect.
            if let workspaceId = self.workspaceId(forRetry: address) {
                let roster = WorkspaceRosterStore.shared.agent(forAddress: address, workspaceId: workspaceId)
                await WorkspaceAgentConnectService.shared.connect(
                    workspaceId: workspaceId,
                    agentAddress: roster?.agentAddress ?? address,
                    displayName: roster?.displayName
                )
                guard self.session === originalSession, self.session.workspaceContext == context else { return }
                self.refreshPairedRelayAgents()
            }
            self.pairingRepairAttemptedFor = nil
            self.bindRemoteMode(toWorkspaceAgent: address, preserveSession: true, force: true)
        }
    }

    /// The workspace to handshake against for `address`: the roster that
    /// lists it, else the id stamped on the tab. nil for direct shares.
    private func workspaceId(forRetry address: String) -> String? {
        guard let context = session.workspaceContext, context.agentAddress == address,
            !context.workspaceId.isEmpty
        else { return nil }
        return context.workspaceId
    }

    /// Address for which an automatic pairing repair already ran during the
    /// current bind, so a host that keeps refusing us gets one silent repair
    /// and then a visible failure — never a connect/repair loop.
    private var pairingRepairAttemptedFor: String?

    /// The host answered but refused our credentials. For a workspace pairing
    /// that means the attested key expired or was revoked (the refresh loop
    /// only re-arms after a connect in this process, so a key can silently
    /// die across a relaunch). Re-run the handshake to mint a fresh key and
    /// provider, then rebind so the connect runs again. Returns false when
    /// there is nothing to repair or a repair already ran for this bind —
    /// the caller then surfaces the failure.
    func repairWorkspacePairingAfterRejection() async -> Bool {
        guard let address = workspaceAgentAddress, pairingRepairAttemptedFor != address else { return false }
        let context = session.workspaceContext
        let originalSession = session
        pairingRepairAttemptedFor = address
        guard let workspaceId = workspaceId(forRetry: address) else { return false }
        let roster = WorkspaceRosterStore.shared.agent(forAddress: address, workspaceId: workspaceId)
        let repaired = await WorkspaceAgentConnectService.shared.connect(
            workspaceId: workspaceId,
            agentAddress: roster?.agentAddress ?? address,
            displayName: roster?.displayName
        )
        guard repaired != nil, session === originalSession, session.workspaceContext == context else { return false }
        refreshPairedRelayAgents()
        bindRemoteMode(toWorkspaceAgent: address, preserveSession: true, force: true)
        return true
    }

    private func stampWorkspaceContext(address: String, workspaceId: String, on target: ChatSession) {
        target.workspaceContext = WorkspaceSessionContext(workspaceId: workspaceId, agentAddress: address)
    }

    /// Keep the window's remote mode in step with the ACTIVE session's
    /// workspace identity. A team-agent tab binds remote mode to that agent's
    /// paired provider (and asks the view to connect); a local tab that
    /// follows a team-agent tab clears it, so a send can never route to the
    /// wrong agent after a tab switch. Legacy (non-workspace) Mode 2
    /// selections are left alone — they carry no per-session marker.
    func reconcileRemoteMode() {
        if let context = session.workspaceContext, !context.isServedForTeammate {
            bindRemoteMode(toWorkspaceAgent: context.agentAddress, preserveSession: !session.turns.isEmpty)
        } else if workspaceAgentAddress != nil {
            clearRemoteMode()
        }
        refreshSandboxChanges()
    }

    /// Bind remote mode to a workspace agent's paired provider. No-op when
    /// already bound to the same address unless `force`.
    private func bindRemoteMode(toWorkspaceAgent address: String, preserveSession: Bool, force: Bool = false) {
        let workspaceId = session.workspaceContext?.workspaceId
        let paired = RemoteAgentManager.shared.remoteAgent(
            forAddress: address,
            workspaceId: workspaceId?.isEmpty == false ? workspaceId : nil
        )
        if !force, workspaceAgentAddress == address,
            selectedDiscoveredAgentProviderId == paired?.providerId
        { return }
        workspaceAgentAddress = address
        removeEphemeralProviderIfNeeded()
        selectedDiscoveredAgent = nil
        refreshPairedRelayAgents()
        guard let relay = pairedRelayAgents.first(where: {
            $0.providerId == paired?.providerId
            }) else {
            // Not paired yet: the composer lock explains; auto-connect or
            // Retry will pair it, after which `reconcileRemoteMode` re-runs.
            selectedRelayAgent = nil
            selectedDiscoveredAgentProviderId = nil
            pinnedRemoteAgentEffectiveModel = nil
            pinnedRemoteAgentAvatar = nil
            pinnedRemoteAgentQuickActions = nil
            remoteAgentConnectionPhase = .idle
            return
        }
        // Route sends to the agent even before the connect resolves; the
        // composer stays locked until the phase reaches `.connected`.
        selectedRelayAgent = relay
        selectedDiscoveredAgentProviderId = relay.providerId
        if WorkspaceRosterStore.shared.presence(forAddress: address, workspaceId: workspaceId).isOffline {
            // Don't hammer a host the router says is down; Retry / the
            // presence poll flipping online re-issues the connect.
            remoteAgentConnectionPhase = .idle
            return
        }
        pendingRelayConnect = PendingRelayConnect(relay: relay, preserveSession: preserveSession)
    }

    /// Leave remote mode (the same fields `adoptAgent` clears).
    private func clearRemoteMode() {
        workspaceAgentAddress = nil
        pendingRelayConnect = nil
        removeEphemeralProviderIfNeeded()
        selectedDiscoveredAgent = nil
        selectedDiscoveredAgentProviderId = nil
        selectedRelayAgent = nil
        pinnedRemoteAgentEffectiveModel = nil
        pinnedRemoteAgentAvatar = nil
        pinnedRemoteAgentQuickActions = nil
        remoteAgentConnectionPhase = .idle
    }

    /// Why the composer is locked for the active tab, or nil when the user
    /// can send. Evaluated by the view on every relevant publisher change
    /// (roster presence, pairing, connection phase, session swap).
    var composerLock: ComposerLock? {
        guard let context = session.workspaceContext, let status = sharedAgentStatus else { return nil }
        let identity = sharedAgentIdentity ?? SharedAgentIdentity.resolve(address: context.agentAddress)
        let agentName = identity.name
        switch status {
        case .ready:
            return nil
        case .checking, .connecting:
            return .connecting(agentName: agentName)
        case .offline(let lastSeen):
            return .agentOffline(agentName: agentName, ownerName: identity.ownerName, lastSeen: lastSeen)
        case .notConnected(let reason, _):
            return .agentNotConnected(agentName: agentName, reason: reason)
        case .unavailable(let reason, _):
            return .agentUnavailable(agentName: agentName, reason: reason)
        case .readOnlyTeammate(let callerName):
            // Hosted here for a remote caller: the agent is one of ours. An
            // invite-link row may carry no resolvable address, so fall back
            // to the row's agent id before the identity's short address.
            let resolvedName = identity.name == identity.shortAddress ? nil : identity.name
            let hostedName =
                identity.localAgent?.displayName
                ?? resolvedName
                ?? session.agentId.flatMap { AgentManager.shared.agent(for: $0)?.displayName }
                ?? agentName
            return .teammateConversation(
                callerName: callerName,
                agentName: hostedName,
                isWorkspace: !context.isDirectShare
            )
        }
    }

    /// Identity of the shared agent the ACTIVE tab talks to, or nil for a
    /// local tab. Resolved live (cheap) so a rename/re-pair shows at once.
    var sharedAgentIdentity: SharedAgentIdentity? {
        guard let context = session.workspaceContext else { return nil }
        return SharedAgentIdentity.resolve(
            address: context.agentAddress,
            workspaceId: context.workspaceId,
            liveEffectiveModel: remoteAgentConnectionPhase == .connected ? pinnedRemoteAgentEffectiveModel : nil
        )
    }

    /// Connection status of the shared agent the ACTIVE tab talks to, or
    /// nil for a local tab. The single derivation every surface renders
    /// (composer lock notice, empty-state badge, sidebar row); the pure
    /// `SharedAgentStatus.derive` carries the precedence rules.
    var sharedAgentStatus: SharedAgentStatus? {
        guard let context = session.workspaceContext else { return nil }
        let roster = WorkspaceRosterStore.shared
        let connect = WorkspaceAgentConnectService.shared
        let address = context.agentAddress
        return SharedAgentStatus.derive(
            isServedForTeammate: context.isServedForTeammate,
            callerLabel: context.callerLabel,
            workspaceId: context.workspaceId,
            rosterLists: roster.agent(forAddress: address, workspaceId: context.workspaceId) != nil,
            rosterHasLoaded: roster.lastRefreshedAt != nil,
            routerEnabled: OsaurusRouter.isEnabled,
            workspaceName: roster.rosters.first(where: { $0.id == context.workspaceId })?.workspace.name,
            presence: roster.presence(forAddress: address, workspaceId: context.workspaceId),
            isPaired: RemoteAgentManager.shared.remoteAgent(forAddress: address,
                workspaceId: context.workspaceId.isEmpty ? nil : context.workspaceId
            ) != nil,
            isBoundToProvider: selectedDiscoveredAgentProviderId != nil,
            isPairing: connect.isConnecting(address, workspaceId: context.workspaceId),
            connectFailure: connect.connectFailure(for: address, workspaceId: context.workspaceId),
            hasAttempted: connect.hasAttempted(address, workspaceId: context.workspaceId),
            phase: remoteAgentConnectionPhase
        )
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
        adoptProjectFolder(project)
    }

    /// Apply the project's working folder to the current (fresh) session.
    /// A default, not a lock: never overrides a folder the chat picks
    /// itself. Restoring the security-scoped bookmark is the same path a
    /// persisted chat folder takes on reopen.
    ///
    /// Once the folder resolves, the agent's sandbox is turned off, exactly
    /// as the composer's folder chip does on selection. The sandbox wins
    /// over a folder in `resolveExecutionMode`, and it is on by default for
    /// every custom agent with no in-chat toggle, so without this the chat
    /// showed the project folder while the model was jailed to its
    /// `/workspace/agents/<id>/` home and reported the folder unreachable.
    /// Returns the follow-up task (nil when no folder was applied) so
    /// callers and tests can await the sandbox change.
    @discardableResult
    func adoptProjectFolder(_ project: Project) -> Task<Void, Never>? {
        let hasFolder = project.folderBookmark != nil || project.folderPath?.isEmpty == false
        // A project folder replaces an agent-default seed (the project is the
        // more specific context) but never a folder this chat picked itself.
        guard hasFolder, !session.folderState.hasActiveFolder || session.folderFromAgentDefault
        else { return nil }
        session.folderFromAgentDefault = false
        return adoptDefaultFolder(
            bookmark: project.folderBookmark,
            path: project.folderPath,
            on: session,
            origin: "project folder"
        )
    }

    /// Seed a fresh, folder-less chat with its agent's sticky working folder
    /// (`Agent.workingFolderBookmark`, remembered from the composer chip or
    /// the agent editor). A default, not a lock: a project's folder applied
    /// afterwards (`adoptProjectFolder`) or a pick in the chat replaces it,
    /// and a session restored from history keeps its own persisted folder.
    /// The Default agent never carries a folder, and a chat that already
    /// has one (or is mid-restore) is left alone. Returns the follow-up
    /// task (nil when nothing was applied) so tests can await the sandbox
    /// change.
    @discardableResult
    func adoptAgentWorkingFolder(on target: ChatSession? = nil) -> Task<Void, Never>? {
        let target = target ?? session
        guard let agentId = target.agentId, agentId != Agent.defaultId,
            target.workspaceContext == nil,
            let folder = AgentManager.shared.workingFolder(for: agentId),
            !target.folderState.hasActiveFolder,
            target.folderState.pendingRestore == nil,
            target.folderState.persistedBookmark == nil,
            target.folderState.persistedPath == nil
        else { return nil }
        target.folderFromAgentDefault = true
        return adoptDefaultFolder(
            bookmark: folder.bookmark,
            path: folder.path,
            on: target,
            origin: "agent working folder"
        )
    }

    /// Shared body for the project-folder and agent-folder defaults: restore
    /// the bookmark (the same path a persisted chat folder takes on reopen)
    /// and, once it resolves, turn the agent's sandbox off exactly as the
    /// composer's folder chip does on selection. The sandbox wins over a
    /// folder in `resolveExecutionMode`, and it is on by default for every
    /// custom agent with no in-chat toggle, so without this the chat showed
    /// the folder while the model was jailed to its `/workspace/agents/<id>/`
    /// home and reported the folder unreachable.
    private func adoptDefaultFolder(
        bookmark: Data?,
        path: String?,
        on target: ChatSession,
        origin: String
    ) -> Task<Void, Never> {
        let folderState = target.folderState
        folderState.restore(bookmark: bookmark, path: path)
        let agentId = target.agentId ?? agentId
        return Task { @MainActor in
            // Only a folder that actually resolved earns the switch: a stale
            // bookmark whose path is gone leaves the agent as it was rather
            // than stranding it with no sandbox AND no folder.
            guard await folderState.contextWaitingForRestore() != nil else {
                target.folderFromAgentDefault = false
                return
            }
            do {
                try await AgentManager.shared.disableSandboxForHostFolder(agentId: agentId)
            } catch {
                // Fail closed, same as the composer chip: never show a folder
                // as active while the VM boundary is still authoritative.
                folderState.clearFolder()
                target.folderFromAgentDefault = false
                debugLog(
                    "[Workspace] Could not disable sandbox after applying \(origin): "
                        + error.localizedDescription
                )
            }
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
        adoptProjectFolder(project)
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
        // A new chat inside a team-agent tab stays with that agent ("as if
        // local"); a host-side read-only copy of a teammate's chat does not
        // carry over — New Chat there is a plain chat with the local agent.
        let carriedWorkspace = session.workspaceContext.flatMap { $0.isServedForTeammate ? nil : $0 }
        if releaseSharedSessionIfNeeded() || detachRunningSessionIfNeeded() {
            installFreshSession(agentId: agentId)
        } else {
            session.reset(for: agentId)
        }
        session.workspaceContext = carriedWorkspace
        // Seed the agent's sticky working folder AFTER the workspace context
        // is settled: a team-agent tab never gets the local agent's folder.
        adoptAgentWorkingFolder()
        reconcileRemoteMode()
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
            adoptAgentWorkingFolder()
        }
    }

    func loadSession(_ sessionData: ChatSessionData) {
        guard sessionData.id != session.sessionId else { return }
        // Match same-window tab deduplication across windows. Do this before
        // saving/detaching the current session: choosing an already-open chat
        // must not mutate either transcript or create a competing writer.
        if ChatWindowManager.shared.revealOpenSession(
            sessionData.id, excludingWindowId: windowId
        ) != nil { return }
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

        // Browser-style, like `startNewChat` / `switchAgent`: a run in flight
        // (or paused on a clarify prompt) keeps its own tab, still owned by
        // this window and still visible under its agent; the target loads
        // into a fresh tab instead of pushing the run out of the strip.
        if session.isStreaming || session.awaitingClarify != nil,
            !LiveChatSessionRegistry.shared.isShared(session)
        {
            newTab(agentId: targetAgentId, startsConversation: false)
        }

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
        reconcileRemoteMode()
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
    func newTab(agentId newAgentId: UUID? = nil, startsConversation: Bool = true, restoresDraft: Bool = true) {
        persistActiveSessionForTabSwitch()
        // A new tab from a team-agent tab stays with that agent, same as
        // sidebar New Chat (`startNewChat`). Without the carried context the
        // fresh session scopes as a local tab, so the strip switches scope
        // and the user lands in an unrelated local chat. A host-side
        // read-only copy of a teammate's chat does not carry over, and an
        // explicit agent pick means a local tab for that agent.
        let carriedWorkspace =
            newAgentId == nil
            ? session.workspaceContext.flatMap { $0.isServedForTeammate ? nil : $0 }
            : nil
        if let newAgentId, newAgentId != agentId {
            adoptAgent(newAgentId)
        }
        let fresh = makeFreshSession(
            agentId: agentId,
            restoresDraft: restoresDraft && carriedWorkspace == nil
        )
        fresh.workspaceContext = carriedWorkspace
        // Local tabs only: a new tab that stays with a team agent must not
        // inherit the hosting local agent's working folder.
        if carriedWorkspace == nil {
            adoptAgentWorkingFolder(on: fresh)
        }
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
        reconcileRemoteMode()
        refreshSessions()
        refreshSandboxChanges()
        hibernateColdTabsIfNeeded()
        // KPI: a new tab starts a new conversation, same as sidebar New Chat
        // (not counted when the tab is about to load an existing chat).
        if startsConversation {
            FeatureTelemetry.chatSessionStarted()
        }
    }

    /// Reorder a tab (drag-to-reorder in the strip). `newIndex` is the
    /// target slot within the tab's OWN scope (the strip only shows one
    /// agent's tabs); tabs of other agents keep their relative positions.
    /// Pure array move; the active tab and its session are untouched.
    func moveTab(id: UUID, to newIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let scopedIds = tabs(in: ChatTabScope.of(tabs[from].session)).map(\.id)
        guard let fromScoped = scopedIds.firstIndex(of: id) else { return }
        let toScoped = min(max(newIndex, 0), scopedIds.count - 1)
        guard fromScoped != toScoped,
            let to = tabs.firstIndex(where: { $0.id == scopedIds[toScoped] })
        else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    /// Switch the visible chat to another tab. Unlike `loadSession`, the
    /// outgoing session is neither detached nor released — its tab keeps it
    /// live, so an in-flight stream keeps rendering into that tab.
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

    /// Cycle to the next (+1) or previous (-1) tab of the active agent,
    /// wrapping around.
    func selectAdjacentTab(offset: Int) {
        let scoped = scopedTabs
        guard scoped.count > 1,
            let idx = scoped.firstIndex(where: { $0.id == activeTabId })
        else { return }
        let next = ((idx + offset) % scoped.count + scoped.count) % scoped.count
        selectTab(id: scoped[next].id)
    }

    /// Close a tab. Closing stays within the tab's agent: the neighbor that
    /// takes over is the next tab of the same agent, and closing an agent's
    /// last tab replaces it with a blank chat for that agent (so the agent
    /// stays selected) — unless that tab is already blank, in which case
    /// nothing happens and the caller (⌘W) falls through to closing the
    /// window. A closing tab's session follows the window-close rules:
    /// shared / registry-owned → unlink only; mid-run → detach to the
    /// background registry; idle → save and stop.
    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[idx]
        let scope = ChatTabScope.of(closing.session)
        let scoped = tabs(in: scope)
        let scopedIdx = scoped.firstIndex(where: { $0.id == id }) ?? 0
        let siblings = scoped.filter { $0.id != id }
        // A lone blank tab has nothing to close.
        if id == activeTabId, siblings.isEmpty, !closing.isHibernated, isBlank(closing.session) { return }

        rememberClosedTab(closing, at: scopedIdx)
        if id != activeTabId {
            tabs.remove(at: idx)
            teardownTabSession(closing.session)
            return
        }

        // The removal itself animates (the strip keys a layout animation on
        // the tab ids, so neighbors slide over); the session swap below is
        // wrapped un-animated so ChatView's remount doesn't interpolate.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        if siblings.isEmpty {
            let replacement = makeBlankTab(in: scope)
            withTransaction(transaction) {
                tabs[idx] = replacement
                activeTabId = replacement.id
                adoptTabSession(replacement.session)
            }
        } else {
            tabs.remove(at: idx)
            let neighborId = siblings[min(scopedIdx, siblings.count - 1)].id
            guard let neighborIdx = tabs.firstIndex(where: { $0.id == neighborId }) else { return }
            if tabs[neighborIdx].isHibernated { wake(tabAt: neighborIdx) }
            tabs[neighborIdx].lastActivatedAt = Date()
            let neighbor = tabs[neighborIdx]
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
        if ChatWindowManager.shared.revealOpenSession(
            sessionData.id, excludingWindowId: windowId
        ) != nil { return }
        // Chrome-style: an untouched empty tab is reused rather than left
        // behind as a blank tab next to the one we just opened.
        let activeIsBlank = session.turns.isEmpty && !session.isStreaming
        if !activeIsBlank {
            newTab(startsConversation: false)
        }
        loadSession(sessionData)
    }

    // MARK: Background runs as tabs

    /// Surface a registry-owned run (scheduled / API / channel / delegated /
    /// detached) as a tab of its agent WITHOUT taking focus: the live
    /// `ChatSession` is linked to this window the way `attachSession` does
    /// and appended as an inactive tab, so the run shows up under its agent
    /// in the strip while the user keeps working. Execution ownership stays
    /// with the registry. No-op for mirrors, for runs without a session, and
    /// when the session already has a tab here. Returns whether a tab was
    /// added.
    @discardableResult
    func attachBackgroundTab(for task: BackgroundTaskState) -> Bool {
        guard !task.isSubagentMirror, let live = task.chatSession else { return false }
        let alreadyShown = tabs.contains {
            $0.session === live || ($0.session.sessionId != nil && $0.session.sessionId == live.sessionId)
        }
        guard !alreadyShown else { return false }
        live.windowState = self
        live.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }
        tabs.append(ChatTab(id: UUID(), session: live))
        refreshSessions()
        return true
    }

    /// Surface a finished run the registry retained across relaunch (no
    /// live session any more) as a hibernated tab of its agent, so a run
    /// that completed while the app was closed is still there to review.
    /// The transcript loads from disk when the tab is selected; closing the
    /// tab dismisses the retained task. Returns whether a tab was added.
    @discardableResult
    func attachRetainedTab(for task: BackgroundTaskState) -> Bool {
        guard !task.isSubagentMirror, task.chatSession == nil, !task.status.isActive else { return false }
        guard !tabs.contains(where: { $0.session.sessionId == task.id }) else { return false }
        guard var snapshot = ChatSessionStore.load(id: task.id) else { return false }
        snapshot.turns = []
        let cold = makeFreshSession(agentId: snapshot.agentId ?? task.agentId, loading: snapshot)
        var tab = ChatTab(id: UUID(), session: cold)
        tab.isHibernated = true
        tab.lastActivatedAt = task.createdAt
        tabs.append(tab)
        return true
    }

    /// Bring a registry run's tab to the front (waking it if hibernated).
    /// Returns false when no tab here shows that run.
    @discardableResult
    func focusTab(forSessionId sessionId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.session.sessionId == sessionId }) else { return false }
        selectTab(id: tab.id)
        return true
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
        // The composer remounts for the incoming tab and rehydrates from
        // `input`; surface the tab's unsent keystrokes there first (#2708).
        target.promoteComposerDraft()
        session = target
        // Window→task binding follows the visible session: a registry-owned
        // run on screen makes closing this window detach (not stop) it.
        if let task = BackgroundTaskManager.shared.task(owning: target), task.status.isActive {
            BackgroundTaskManager.shared.bindWindow(windowId, toTask: task.id)
        } else {
            BackgroundTaskManager.shared.unbindWindow(windowId)
        }
        reconcileRemoteMode()
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
        // A registry-owned run (dispatched / scheduled / previously detached)
        // shown in this tab: execution belongs to the registry, so closing
        // the tab only unlinks the view. Closing the tab of a FINISHED run
        // is how the user dismisses it — the task leaves the registry.
        if let task = BackgroundTaskManager.shared.task(owning: closingSession) {
            closingSession.windowState = nil
            closingSession.onSessionChanged = nil
            if !task.status.isActive {
                if !closingSession.turns.isEmpty { closingSession.save() }
                BackgroundTaskManager.shared.finalizeTask(task.id)
            }
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
        /// Slot within the chat's agent scope at the time it closed.
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
            if ChatWindowManager.shared.revealOpenSession(
                sessionId, excludingWindowId: windowId
            ) != nil { return }
            guard let data = ChatSessionStore.load(id: sessionId) else { continue }
            // Always its own tab (a blank active tab is left alone), like a
            // browser restoring a closed tab.
            newTab(agentId: data.agentId ?? Agent.defaultId, startsConversation: false)
            loadSession(data)
            // `closed.index` is the slot within the chat's agent scope, the
            // same coordinate `moveTab` takes.
            moveTab(id: activeTabId, to: closed.index)
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
        guard let sessionId = s.sessionId, !s.turns.isEmpty, !s.isStreaming, s.awaitingClarify == nil,
            !LiveChatSessionRegistry.shared.isShared(s)
        else { return false }
        // A registry run that hasn't started yet (queued) has no turns to
        // reload; swapping it for a cold stand-in would divorce the tab from
        // the session the run is about to stream into.
        return BackgroundTaskManager.shared.liveTask(forSessionId: sessionId) == nil
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
        // `ChatSessionData` carries no composer text; carry the unsent
        // draft across so hibernating a tab does not eat it (#2708).
        cold.input = live.unsentComposerText
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
    /// `restoresDraft` is false for sessions about to be stamped with a
    /// workspace agent's context: those are keyed by the hosting local
    /// agent until stamped, and must not pick up that agent's own draft.
    private func makeFreshSession(
        agentId: UUID,
        loading data: ChatSessionData? = nil,
        restoresDraft: Bool = true
    ) -> ChatSession {
        let fresh = ChatSession()
        fresh.windowState = self
        fresh.agentId = agentId
        fresh.applyInitialModelSelection()
        if let data {
            fresh.load(from: data)
        } else if restoresDraft {
            // A fresh New Chat for this agent picks up the draft the user
            // left in an earlier New Chat for the same agent (a blank tab
            // repurposed or dropped on the way to another agent), so
            // coming back to the agent reads like switching tabs.
            fresh.restoreDraft()
        }
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
    private func installFreshSession(
        agentId: UUID,
        loading data: ChatSessionData? = nil,
        restoresDraft: Bool = true
    ) {
        session = makeFreshSession(agentId: agentId, loading: data, restoresDraft: restoresDraft)
        // A blank replacement (not a history load) starts in the agent's
        // sticky working folder; a loaded session keeps its own.
        if data == nil {
            adoptAgentWorkingFolder()
        }
    }

    /// Attach an existing (registry-owned) live session to this window so
    /// the user sees the in-flight stream. Execution ownership stays with
    /// the registry; the window is only a view. The window→task binding
    /// makes close/switch detach instead of stop, and suppresses the
    /// duplicate Activity section/toast surface while the chat is visible.
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
        // Leaving remote mode wholesale; `reconcileRemoteMode` re-binds a
        // team-agent tab afterwards from its session's workspace context.
        workspaceAgentAddress = nil
        pendingRelayConnect = nil
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
        // A team-agent tab lists that agent's history (keyed by address);
        // everything else lists the local agent's.
        if let context = session.workspaceContext, !context.isServedForTeammate {
            filteredSessions = ChatSessionsManager.shared.sessions(
                forRemoteAgentAddress: context.agentAddress).filter { $0.workspace?.workspaceId == context.workspaceId }
        } else {
            filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)
        }
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

    /// A team-agent tab opened before its agent was paired (auto-connect
    /// still running) or while its host was offline must come alive on its
    /// own once the pairing lands / presence flips online — without the user
    /// clicking the row again. Both signals re-run the remote-mode binding
    /// for the active tab; `bindRemoteMode` is idempotent for an already
    /// connected tab (`force` only when something actually changed).
    private func observeWorkspaceState() {
        // The roster/presence poll runs while any chat window is open — not
        // only while its sidebar is showing — so a team-agent tab's composer
        // lock tracks presence even with the sidebar collapsed.
        // Skipped under tests: the poll would hit the router (or, with no
        // identity, wipe the fixture rosters suites install on the store).
        if !isObservingRoster, !RuntimeEnvironment.isUnderTests {
            isObservingRoster = true
            WorkspaceRosterStore.shared.beginObserving()
        }
        RemoteAgentManager.shared.$remoteAgents
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let address = self.workspaceAgentAddress,
                        self.selectedDiscoveredAgentProviderId == nil
                    else { return }
                    self.refreshPairedRelayAgents()
                    self.bindRemoteMode(
                        toWorkspaceAgent: address,
                        preserveSession: !self.session.turns.isEmpty,
                        force: true
                    )
                }
            }
            .store(in: &workspaceCancellables)
        // Presence can flip back online two ways: a poll changes the
        // roster, or a poll clears the local force-offline mark while the
        // router's roster is unchanged. Watch both so a parked tab reconnects
        // either way.
        WorkspaceRosterStore.shared.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let address = self.workspaceAgentAddress else { return }
                    // Only a tab that was parked (offline / unpaired → phase
                    // idle) needs a fresh connect when presence returns.
                    self.objectWillChange.send()
                    guard
                        WorkspaceRosterStore.shared.presence(
                            forAddress: address,
                            workspaceId: self.session.workspaceContext?.workspaceId
                        ) == .online
                    else { return }
                    switch self.remoteAgentConnectionPhase {
                    case .idle, .failed: break
                    case .connecting, .connected: return }
                    self.refreshPairedRelayAgents()
                    self.bindRemoteMode(
                        toWorkspaceAgent: address,
                        preserveSession: !self.session.turns.isEmpty,
                        force: true
                    )
                }
            }
            .store(in: &workspaceCancellables)
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
                            self.remoteAgentConnectionPhase = .failed(
                                ChatErrorMessages.remoteConnectFailure(message: lastError)
                            )
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
