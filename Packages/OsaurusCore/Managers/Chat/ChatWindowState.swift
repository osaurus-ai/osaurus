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
/// thread: the local agent in Mode 1, or the paired remote agent in
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
    /// The user's other Mac that runs this chat's agent isn't connected.
    /// Sending waits for it to be awake and online.
    case hostOffline(hostName: String)

    /// Whether the user may retry a connection from the notice.
    public var offersRetry: Bool {
        switch self {
        case .agentOffline, .agentNotConnected: return true
        case .connecting, .teammateConversation, .agentUnavailable, .hostOffline: return false
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
    /// What the tab shows. Workflow tabs keep a blank session only for
    /// their agent scope; they are never hibernated or saved to History.
    var kind: ChatTabKind = .chat
    /// LRU stamp: when this tab last became the active tab. Drives which
    /// idle tabs get hibernated when the window holds too many.
    var lastActivatedAt: Date = Date()
    /// A hibernated tab keeps only a metadata-level session (title, agent,
    /// ids; no turns, no warm-up) so the chip still renders; the transcript
    /// reloads from disk when the tab is selected again.
    var isHibernated: Bool = false

    static func == (lhs: ChatTab, rhs: ChatTab) -> Bool {
        lhs.id == rhs.id && lhs.session === rhs.session && lhs.kind == rhs.kind
    }

    var workflowID: UUID? {
        if case .workflowRun(let id, _) = kind { return id }
        return nil
    }
}

enum ChatTabKind: Equatable, Codable {
    case chat
    /// A workflow's input form, one of its runs, and the result.
    case workflowRun(workflowID: UUID, runID: UUID?)
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
    /// An agent another of the user's Macs runs (`device`), by its id there.
    case hosted(device: String, agentId: UUID)

    var isHosted: Bool {
        if case .hosted = self { return true }
        return false
    }

    @MainActor
    static func of(_ session: ChatSession) -> ChatTabScope {
        if let device = session.hostDeviceElsewhere ?? session.servedElsewhere, let agentId = session.agentId {
            return .hosted(device: device, agentId: agentId)
        }
        if let context = session.workspaceContext, !context.isServedForTeammate {
            return .workspace(context.agentAddress.lowercased(), workspaceId: context.workspaceId)
        }
        return .local(session.agentId ?? Agent.defaultId)
    }
}

/// The panes of the chat window's right-hand inspector, all about the tab
/// on screen.
enum ChatInspectorPane: Hashable {
    /// This chat's file history: timeline, per-file net state, revert.
    case fileChanges
    /// The workflows this chat's agent can run, and the starters. In The
    /// Architect's chats: every workflow on this Mac, to pick one to edit.
    case workflows
    /// The Architect's draft for this chat. Only the Architect's chats
    /// have it, in place of File Changes.
    case draft

    /// `self`, or the lens that stands in for it in a chat that lacks it.
    func resolved(isArchitect: Bool) -> ChatInspectorPane {
        switch self {
        case .fileChanges where isArchitect: return .draft
        case .draft where !isArchitect: return .workflows
        default: return self
        }
    }
}

/// The two halves of the inspector's History lens.
enum ChatHistoryTab: Hashable {
    /// The past chats of this chat's agent.
    case chats
    /// The workflow runs of this chat's agent.
    case runs
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
    @Published private(set) var tabs: [ChatTab] = [] {
        didSet { onTabLayoutChanged?() }
    }
    @Published private(set) var activeTabId: UUID = UUID() {
        didSet { onTabLayoutChanged?() }
    }

    /// Fired whenever the set of tabs or the active tab changes (and on
    /// session refreshes, which is when a blank tab gets its first saved
    /// turn). `ChatWindowManager` uses it to remember the open tabs across
    /// window close and relaunch (`ChatTabLayoutStore`). Not `@Published`:
    /// purely imperative, no view re-renders.
    var onTabLayoutChanged: (() -> Void)?

    /// The agent whose tabs the strip currently shows: the active tab's
    /// agent on another of the user's Macs, else the workspace agent the
    /// window's remote mode is bound to, else the window's local agent.
    /// Both follow the active tab (`adoptTabSession` / `reconcileRemoteMode`).
    var activeScope: ChatTabScope {
        let sessionScope = ChatTabScope.of(session)
        if case .hosted = sessionScope { return sessionScope }
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

    /// True while the sidebar is stepping aside for the open inspector
    /// because the window is too narrow for both (`ChatView` sets it from
    /// its geometry). Separate from `showSidebar` so the user's choice
    /// survives and the sidebar returns when the inspector closes.
    @Published var isSidebarAutoHidden: Bool = false

    /// Width of the right rail actually on screen (the chat inspector or
    /// Project Settings), 0 while closed. `ChatView` sets it from its
    /// geometry, so it already reflects the narrow-window squeeze and a
    /// live resize drag. The tab strip reads it to stop the tabs at the
    /// chat column's trailing edge instead of running under the rail.
    @Published var inspectorColumnWidth: CGFloat = 0

    /// Width of the left rail actually on screen (the Agents | Projects
    /// sidebar), 0 while hidden or stepping aside for the inspector.
    /// `ChatView` sets it from its geometry, LIVE during a resize drag
    /// (the persisted `chatSidebarWidth` default only updates on release),
    /// so the tab strip tracks the rail's edge without lagging it. Mirror
    /// of `inspectorColumnWidth`.
    @Published var sidebarColumnWidth: CGFloat = 0 {
        didSet { if sidebarColumnWidth > 0 { lastDockedSidebarColumnWidth = sidebarColumnWidth } }
    }
    /// The rail's width the last time it was docked, so a toggle can publish
    /// the width it is animating to in its own transaction.
    private var lastDockedSidebarColumnWidth: CGFloat = 0

    /// Width class of the window's content area (`ChatView` sets it from
    /// its geometry through `updateShellBreakpoint`). Compact windows turn
    /// the sidebar into a drawer and the context panel into an overlay.
    @Published private(set) var shellBreakpoint: ChatShellBreakpoint = .regular

    /// Whether the sidebar drawer is open over the content of a compact
    /// window. Separate from `showSidebar` so narrowing the window never
    /// rewrites the docked choice, and so the drawer always starts closed.
    @Published var isCompactSidebarPresented: Bool = false

    /// Record the window's breakpoint. Crossing into or out of compact
    /// closes the overlays: a drawer or context overlay left open from a
    /// wide layout would otherwise cover the conversation the moment the
    /// window narrows. The docked sidebar choice is untouched, and a
    /// docked context panel comes back when the window widens again.
    func updateShellBreakpoint(_ breakpoint: ChatShellBreakpoint) {
        guard breakpoint != shellBreakpoint else { return }
        let crossesCompact = (breakpoint == .compact) != (shellBreakpoint == .compact)
        shellBreakpoint = breakpoint
        guard crossesCompact else { return }
        isCompactSidebarPresented = false
        if breakpoint == .compact {
            contextPanelWantedBeforeCompact = inspectorPane != nil
            inspectorPane = nil
            settingsSidebarCollapsedBeforeCompact = isSettingsSidebarCollapsed
            isSettingsSidebarCollapsed = true
        } else {
            if contextPanelWantedBeforeCompact { inspectorPane = lastInspectorPane }
            if let before = settingsSidebarCollapsedBeforeCompact {
                isSettingsSidebarCollapsed = before
                settingsSidebarCollapsedBeforeCompact = nil
            }
        }
    }

    /// The Settings destination's sidebar shows icons only. A compact
    /// window collapses it; widening again restores the person's choice.
    @Published var isSettingsSidebarCollapsed = false
    private var settingsSidebarCollapsedBeforeCompact: Bool?

    /// Whether the docked context panel was wanted when the window
    /// narrowed into compact, so widening brings it back.
    private var contextPanelWantedBeforeCompact = false

    /// Esc while a compact overlay is open: closes the drawer first, then
    /// the context overlay. Returns whether anything closed, so the key
    /// handler only swallows Esc when it did something.
    @discardableResult
    func dismissShellOverlay() -> Bool {
        guard shellBreakpoint == .compact else { return false }
        if isCompactSidebarPresented {
            isCompactSidebarPresented = false
            return true
        }
        if inspectorPane != nil {
            inspectorPane = nil
            return true
        }
        return false
    }

    /// Whether the sidebar is on screen. The toolbar toggle and the tab
    /// strip inset read this, not `showSidebar`, so the chrome never claims
    /// a sidebar that the inspector has pushed aside.
    var isSidebarVisible: Bool {
        if shellBreakpoint == .compact { return isCompactSidebarPresented }
        return showSidebar && !isSidebarAutoHidden
    }

    /// Toolbar button / ⌘B. When the sidebar is stepping aside for the
    /// inspector, the user asking for it wins: the inspector closes and the
    /// sidebar (still "shown") comes back — a plain flip would hide nothing
    /// visible and leave the button looking broken. In a compact window it
    /// opens or closes the drawer, which replaces any open context overlay.
    func toggleSidebar() {
        if shellBreakpoint == .compact {
            isCompactSidebarPresented.toggle()
            if isCompactSidebarPresented { inspectorPane = nil }
            return
        }
        if showSidebar && isSidebarAutoHidden {
            inspectorPane = nil
            return
        }
        showSidebar.toggle()
        // ChatView republishes the laid-out width afterwards; setting it here
        // moves the tab strip in the same animation as the rail instead of
        // one render pass later.
        if !isSidebarAutoHidden, mainSurface == .chat {
            if !showSidebar {
                sidebarColumnWidth = 0
            } else if lastDockedSidebarColumnWidth > 0 {
                sidebarColumnWidth = lastDockedSidebarColumnWidth
            }
        }
    }

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

    /// Cancels a title rename before the window-level Escape shortcut closes chat.
    var cancelHistoryRename: (() -> Void)?

    /// Float-on-top state, driven by the toolbar overflow menu's Pin Window
    /// item (was local state inside the old PinButton).
    @Published var isWindowPinned: Bool = false

    /// Drives the in-conversation find bar (Cmd+F). Set by the window-level
    /// key monitor (which cannot touch `ChatView`'s `@State`) and cleared by
    /// the bar's close button or the Esc dismissal chain.
    @Published var isFindBarVisible: Bool = false

    /// Main navigation is independent of the live chat/session lifecycle.
    /// `newAgent` is the New Agent creator: no rail entry, reached from New
    /// Agent buttons, with the way back in the title bar.
    enum MainSurface: String { case chat, workflows, insights, help, newAgent, settings }
    @Published var mainSurface: MainSurface = .chat {
        willSet { recordSurfaceReturn(to: newValue) }
    }
    /// Insights, Help, New Agent and Settings are full-window pages over the
    /// window's chat: Cmd+F and Esc belong to the page, not that chat.
    var showsPageSurface: Bool {
        mainSurface == .insights || mainSurface == .help || mainSurface == .newAgent || mainSurface == .settings
    }
    @Published var showsWorkflowLibrary = true
    /// Retain the unsent workflow brief when switching between main destinations.
    /// This is the same chat-session model used by the shared composer, and is
    /// separate from the user's active conversation until they explicitly send.
    lazy var workflowCreationSession: ChatSession = {
        let draft = ChatSession()
        draft.agentId = Agent.architectId
        return draft
    }()

    /// A page pushed over the Workflows window's home.
    enum WorkflowsPage: Equatable, Hashable {
        /// One workflow: its runs, what it does, and who can start it.
        case workflow(UUID)
        /// One run as it happens, or the form for a new one (`runID` nil).
        /// `agentId` is the agent a new run there runs as.
        case run(workflowID: UUID, runID: UUID?, agentId: UUID)
        /// New Workflow: describe a task to the Architect, or add a
        /// ready-made workflow.
        case create

        var workflowID: UUID? {
            switch self {
            case .workflow(let id): return id
            case .run(let id, _, _): return id
            case .create: return nil
            }
        }
    }

    /// The Workflows home's tabs over its one list: every installed
    /// workflow, unfinished drafts, and what this Mac has published.
    enum WorkflowsTab: String, CaseIterable { case all, drafts, published, workspaces }

    static let workflowsTabDefaultsKey = "WorkflowsWindow.tab"

    /// The tab last chosen; nil until one is. See `workflowsTab(chosen:hasDrafts:hasPublished:)`.
    @Published var workflowsTab: WorkflowsTab? =
        WorkflowsTab(rawValue: UserDefaults.standard.string(forKey: workflowsTabDefaultsKey) ?? "")
    {
        didSet { UserDefaults.standard.set(workflowsTab?.rawValue, forKey: Self.workflowsTabDefaultsKey) }
    }

    /// The tab the home shows: the one last chosen while it has anything,
    /// else All. With drafts and nothing installed, Drafts. Workspaces is
    /// offered while this Mac belongs to one.
    static func workflowsTab(
        chosen: WorkflowsTab?, hasInstalled: Bool, hasDrafts: Bool, hasPublished: Bool, hasWorkspaces: Bool = false
    ) -> WorkflowsTab {
        switch chosen {
        case .drafts? where hasDrafts: return .drafts
        case .published? where hasPublished: return .published
        case .workspaces? where hasWorkspaces: return .workspaces
        default: return !hasInstalled && hasDrafts ? .drafts : .all
        }
    }

    /// Pages pushed over the home, oldest first; empty shows the home.
    @Published var workflowsPath: [WorkflowsPage] = []
    /// The workspace the Workspaces tab scrolls to, once.
    @Published var workflowsWorkspaceFocus: String?
    /// The run the Workflows home last started, so its row opens to show it.
    @Published var workflowsSpotlightRunID: UUID?

    /// Set by New Workflow until the Architect composer on screen takes
    /// focus; the composer may appear only after it is set.
    @Published private(set) var newWorkflowComposerWantsFocus = false

    /// True once per New Workflow request.
    func consumeNewWorkflowComposerFocus() -> Bool {
        guard newWorkflowComposerWantsFocus else { return false }
        newWorkflowComposerWantsFocus = false
        return true
    }

    /// Where a Settings search row's `subTab` lands in the Workflows window:
    /// `workflows` or `workflows.<tab>` for the home on a tab,
    /// `workflows.workspaces.<id>` for one workspace's section, `new` for
    /// the New Workflow page.
    enum WorkflowsDestination: Equatable {
        case home(WorkflowsTab?)
        case workspace(String)
        case newWorkflow

        init?(subTab: String) {
            if subTab == "new" {
                self = .newWorkflow
                return
            }
            let parts = subTab.split(separator: ".", maxSplits: 2).map(String.init)
            guard parts.first == "workflows" else { return nil }
            guard parts.count >= 2 else {
                self = .home(nil)
                return
            }
            guard let tab = WorkflowsTab(rawValue: parts[1]) else { return nil }
            if parts.count == 3 {
                guard tab == .workspaces, !parts[2].isEmpty else { return nil }
                self = .workspace(parts[2])
                return
            }
            self = .home(tab)
        }

        /// `osaurus://workflows[/<tab>[/<workspace id>]]`.
        init?(url: URL) {
            guard url.scheme == "osaurus", url.host == "workflows" else { return nil }
            let path = url.pathComponents.filter { $0 != "/" }
            self.init(subTab: (["workflows"] + path).joined(separator: "."))
        }
    }

    /// Fires before any of what the Workflows window reads from this state
    /// changes: its tab, its pages, the run it spotlights, the workspace
    /// it scrolls to, and the window's agent. This state publishes on every chat change; the
    /// Workflows window listens to this instead.
    var workflowsRouteWillChange: AnyPublisher<Void, Never> {
        Publishers.Merge(
            Publishers.Merge4(
                $workflowsTab.removeDuplicates().dropFirst().map { _ in () },
                $workflowsPath.removeDuplicates().dropFirst().map { _ in () },
                $workflowsSpotlightRunID.removeDuplicates().dropFirst().map { _ in () },
                $agentId.removeDuplicates().dropFirst().map { _ in () }),
            $workflowsWorkspaceFocus.removeDuplicates().dropFirst().map { _ in () })
            .eraseToAnyPublisher()
    }

    /// The Workflows home (on `tab` when given), with nothing pushed.
    func showWorkflowsHome(tab: WorkflowsTab? = nil) {
        if let tab { workflowsTab = tab }
        workflowsPath = []
        showMainSurface(.workflows)
    }

    /// New Workflow (⌘N): its page over the home, its composer focused.
    /// With no workflows and no drafts the home already is that page, so
    /// nothing is pushed.
    func showNewWorkflow() {
        if WorkflowsView.isFirstRun(installed: .shared, drafts: .shared) {
            workflowsPath = []
        } else if workflowsPath != [.create] {
            workflowsPath = [.create]
        }
        newWorkflowComposerWantsFocus = true
        showMainSurface(.workflows)
    }

    /// Where a Settings search result for Workflows lands.
    func showWorkflows(_ destination: WorkflowsDestination?) {
        switch destination {
        case .newWorkflow?: showNewWorkflow()
        case .home(let tab)?: showWorkflowsHome(tab: tab)
        case .workspace(let id)?:
            workflowsWorkspaceFocus = id
            showWorkflowsHome(tab: .workspaces)
        case nil: showMainSurface(.workflows)
        }
    }

    func pushWorkflowsPage(_ page: WorkflowsPage) {
        if workflowsPath.last != page { workflowsPath.append(page) }
        if mainSurface != .workflows || !showsWorkflowLibrary { showMainSurface(.workflows) }
    }

    func popWorkflowsPage() {
        _ = workflowsPath.popLast()
    }

    /// One level back, as the title bar's back button: to the surface a
    /// link came from, else out of the editor to the Workflows page under
    /// it, else the top pushed page. False at the top of the window (Chat,
    /// or the Workflows home), where there is nothing to go back to. On
    /// Settings and Insights, Esc belongs to the page, so never here.
    @discardableResult
    func goBack() -> Bool {
        if !showsPageSurface, surfaceBack != nil { return returnToPreviousSurface() }
        guard mainSurface == .workflows else { return false }
        if !showsWorkflowLibrary {
            showMainSurface(.workflows)
            return true
        }
        guard !workflowsPath.isEmpty else { return false }
        popWorkflowsPage()
        return true
    }

    /// Once New Workflow has started a draft, back from the draft returns
    /// to what was under New Workflow, not to its emptied composer.
    func leaveNewWorkflowPage() {
        if workflowsPath.last == .create { workflowsPath.removeLast() }
    }

    /// A workflow's run (or its form when `runID` is nil) in the Workflows
    /// window. From elsewhere in the app the run opens on its own; from the
    /// workflow's page it pushes on top of it.
    func showWorkflowRun(workflowID: UUID, runID: UUID?, agentId: UUID = Agent.defaultId) {
        let page = WorkflowsPage.run(workflowID: workflowID, runID: runID, agentId: agentId)
        let showingLibrary = mainSurface == .workflows && showsWorkflowLibrary
        if showingLibrary, case .run(let shown, _, _)? = workflowsPath.last, shown == workflowID {
            workflowsPath[workflowsPath.count - 1] = page
        } else if showingLibrary {
            workflowsPath.append(page)
        } else {
            workflowsPath = [page]
        }
        showMainSurface(.workflows)
    }

    func showMainSurface(_ surface: MainSurface) {
        if surface == .workflows {
            if mainSurface != .workflows { FeatureTelemetry.workflowsOpened(page: workflowsPageToken) }
            showsWorkflowLibrary = true
        } else if surface == .settings {
            if mainSurface != .settings {
                // Tab switches while Settings is up are counted by
                // `ManagementView.handleTabChange`.
                let tab = ManagementStateManager.shared.selectedTab
                CrashReportingService.recordBreadcrumb(category: "navigation", message: "management.window \(tab.rawValue)")
                FeatureTelemetry.settingsOpened(tab: tab)
            }
        } else if surface == .insights {
            if mainSurface != .insights {
                // Keeps the `insights` token Settings used, so the series
                // stays continuous now that Insights is its own surface.
                CrashReportingService.recordBreadcrumb(category: "navigation", message: "insights.window")
                FeatureTelemetry.settingsOpened(tab: .insights)
            }
        } else if surface == .help {
            if mainSurface != .help {
                CrashReportingService.recordBreadcrumb(category: "navigation", message: "help.window")
            }
        } else if surface == .chat, activeTab?.workflowID != nil || agentId == Agent.architectId {
            if let recent = tabs.filter({ $0.workflowID == nil && $0.session.agentId != Agent.architectId })
                .max(by: { $0.lastActivatedAt < $1.lastActivatedAt }) {
                selectTab(id: recent.id)
            } else {
                startNewChat(with: Agent.defaultId)
            }
        }
        mainSurface = surface
    }

    /// Closed `workflows_opened` page token for the page the surface lands on.
    private var workflowsPageToken: String {
        switch workflowsPath.last {
        case nil: return "home"
        case .workflow?: return "workflow"
        case .run?: return "run"
        case .create?: return "new"
        }
    }

    // MARK: - Back across surfaces

    /// The page a jump to another surface landed on. Workflows compares its
    /// pages too: moving within Workflows hands back to its own back button
    /// until the person is on this page again.
    struct SurfaceLanding: Equatable {
        let surface: MainSurface
        let workflowsPath: [WorkflowsPage]
        let showsWorkflowLibrary: Bool
    }

    /// Where a jump to another surface came from.
    struct SurfaceReturn: Equatable {
        let surface: MainSurface
        let settingsTab: ManagementTab
        let workflowsPath: [WorkflowsPage]
        let showedWorkflowLibrary: Bool
        let tabId: UUID?
        let landed: SurfaceLanding

        @MainActor var title: String {
            switch surface {
            case .chat: L("Chat")
            case .insights: L("Insights")
            case .help: L("Help")
            case .newAgent: L("New Agent")
            case .settings: settingsTab.label
            case .workflows: showedWorkflowLibrary ? WorkflowsView.backTitle(to: workflowsPath.last) : L("Workflows")
            }
        }
    }

    /// Every surface change but the navigation rail (top level, which
    /// clears this) and going back pushes where it came from, so a link
    /// from a page on one surface always offers the way back.
    @Published private(set) var surfaceReturns: [SurfaceReturn] = []
    private var isReturningToSurface = false
    private static let surfaceReturnLimit = 20

    /// The way back, while the page the jump landed on is on screen.
    var surfaceBack: SurfaceReturn? {
        guard let last = surfaceReturns.last, last.landed == landing(on: mainSurface) else { return nil }
        return last
    }

    private func landing(on surface: MainSurface) -> SurfaceLanding {
        surface == .workflows
            ? SurfaceLanding(surface: surface, workflowsPath: workflowsPath, showsWorkflowLibrary: showsWorkflowLibrary)
            : SurfaceLanding(surface: surface, workflowsPath: [], showsWorkflowLibrary: true)
    }

    /// Runs from `mainSurface`'s willSet: Workflows' path and library flag
    /// are already those of the page being opened.
    private func recordSurfaceReturn(to newSurface: MainSurface) {
        guard newSurface != mainSurface, !isReturningToSurface else { return }
        let settingsTab = ManagementStateManager.shared.selectedTab
        surfaceReturns.append(
            SurfaceReturn(
                surface: mainSurface,
                settingsTab: ManagementTab.mainWindowCases.contains(settingsTab) ? .defaultTab : settingsTab,
                workflowsPath: workflowsPath,
                showedWorkflowLibrary: showsWorkflowLibrary,
                tabId: activeTabId,
                landed: landing(on: newSurface)
            ))
        if surfaceReturns.count > Self.surfaceReturnLimit { surfaceReturns.removeFirst() }
    }

    /// The navigation rail: a top-level destination, with no way back.
    func showMainSurfaceFromRail(_ surface: MainSurface) {
        surfaceReturns.removeAll()
        isReturningToSurface = true
        defer { isReturningToSurface = false }
        if surface == .workflows, mainSurface == .workflows, showsWorkflowLibrary {
            showWorkflowsHome()
        } else {
            showMainSurface(surface)
        }
    }

    /// Back to the page the jump on screen came from. False when the
    /// page on screen was not opened by one.
    @discardableResult
    func returnToPreviousSurface() -> Bool {
        guard let back = surfaceBack else { return false }
        surfaceReturns.removeLast()
        isReturningToSurface = true
        defer { isReturningToSurface = false }
        switch back.surface {
        case .settings:
            showSettings(tab: back.settingsTab)
        case .insights, .help, .newAgent:
            showMainSurface(back.surface)
        case .workflows:
            workflowsPath = back.workflowsPath
            if !back.showedWorkflowLibrary, let id = back.tabId, tabs.contains(where: { $0.id == id }) {
                selectTab(id: id)
            } else {
                showMainSurface(.workflows)
            }
        case .chat:
            if let id = back.tabId, tabs.contains(where: { $0.id == id }) {
                selectTab(id: id)
            } else {
                showMainSurface(.chat)
            }
        }
        return true
    }

    /// Leaves New Agent once its draft is gone (created or discarded). Its
    /// way back moves to where `navigate` lands, so back never reopens the
    /// emptied creator.
    func leaveNewAgent(_ navigate: () -> Void) {
        guard mainSurface == .newAgent else { return }
        let origin = surfaceBack
        if origin != nil { surfaceReturns.removeLast() }
        isReturningToSurface = true
        navigate()
        isReturningToSurface = false
        guard let origin, mainSurface != .newAgent, origin.surface != mainSurface else { return }
        let landed = landing(on: mainSurface)
        surfaceReturns.append(
            SurfaceReturn(
                surface: origin.surface,
                settingsTab: origin.settingsTab,
                workflowsPath: origin.workflowsPath,
                showedWorkflowLibrary: origin.showedWorkflowLibrary,
                tabId: origin.tabId,
                landed: landed
            ))
    }

    /// Settings, on `tab` when given. The page on screen is app-wide
    /// (`ManagementStateManager.selectedTab`), so every window agrees.
    func showSettings(tab: ManagementTab? = nil) {
        if let tab { ManagementStateManager.shared.selectedTab = tab }
        showMainSurface(.settings)
    }

    func showWorkflowDetail() {
        if showsWorkflowLibrary { showsWorkflowLibrary = false }
        if mainSurface != .workflows { mainSurface = .workflows }
    }

    /// Bumped on every Cmd+F so the find bar re-focuses its text field even
    /// when the bar is already visible (e.g. focus wandered back to the
    /// composer). Monotonic counter; the value itself is meaningless.
    @Published var findBarFocusRequestID: Int = 0

    // MARK: - Agent State

    @Published var agentId: UUID
    @Published private(set) var agents: [Agent] = []
    @Published var selectedRemoteAgentProviderId: UUID?
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
    /// tab is a local chat (or a relay Mode 2 chat). Drives
    /// the sidebar's selected row and the composer lock; kept in step with
    /// the active tab's `session.workspaceContext` by `reconcileRemoteMode`.
    @Published private(set) var workspaceAgentAddress: String?

    /// A connect the view layer should run (see `PendingRelayConnect`).
    /// `ChatView` consumes and clears it on appear / change.
    @Published var pendingRelayConnect: PendingRelayConnect?
    /// Whether this window holds a `WorkspaceRosterStore` observer (poll
    /// lease); released in `cleanup()`.
    private var isObservingRoster = false

    /// The size the chat layout is designed to fit into at minimum. Below
    /// the compact breakpoint the sidebar and context panel become
    /// overlays, so the floor is set by the compact composer and the
    /// empty-state hero rather than by docked columns (`ChatShellLayout`).
    /// Windows on screens that can show this much use it verbatim; see
    /// `minimumContentSize`.
    static let designMinimumContentSize = ChatShellLayout.minimumWindowSize

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

    // MARK: - Inspector State

    /// Which pane the right-hand inspector asks for, or nil once the user
    /// closed it. On the chat surface any request means "show File Changes
    /// when this chat has some" (`contextPane`), so it starts requested:
    /// the panel appears with a chat's first file change and stays out of
    /// the way until then. Past chats live in the sidebar, not here.
    @Published var inspectorPane: ChatInspectorPane? = .fileChanges {
        didSet { if let inspectorPane { lastInspectorPane = inspectorPane } }
    }

    /// The pane the inspector reopens on.
    @Published private(set) var lastInspectorPane: ChatInspectorPane = .fileChanges

    /// Chats or Runs in the History lens; kept across lens switches.
    @Published var historyTab: ChatHistoryTab = .chats

    /// The Runs tab's search, filters, and scroll spot. Opening a run swaps
    /// this window's session, which rebuilds the inspector, so the tab
    /// keeps them here. Not published: the tab owns the live copy.
    var runHistoryViewState = WorkflowRunHistoryViewState()

    var isInspectorOpen: Bool { inspectorPane != nil }

    /// The pane the inspector resolves to for this chat's agent: the
    /// Architect's chats swap File Changes for the draft.
    nonisolated static func effectiveInspectorPane(
        requested: ChatInspectorPane?,
        isArchitect: Bool = false
    ) -> ChatInspectorPane? {
        requested?.resolved(isArchitect: isArchitect)
    }

    var effectiveInspectorPane: ChatInspectorPane? {
        Self.effectiveInspectorPane(requested: inspectorPane, isArchitect: agentId == Agent.architectId)
    }

    /// Closes the inspector when it is open, otherwise reopens it on the
    /// pane it last showed.
    func toggleInspector() {
        if inspectorPane == nil {
            inspectorPane = lastInspectorPane
            closeCompactDrawerForContext()
        } else {
            inspectorPane = nil
        }
    }

    /// Show `pane` (opening the inspector or switching in place). Deep
    /// links such as "N files changed" rows use this; it never closes.
    func showInspector(_ pane: ChatInspectorPane) {
        inspectorPane = pane
        closeCompactDrawerForContext()
    }

    /// Toolbar context button: closes the context panel when it is on
    /// screen, otherwise opens it on File Changes. Works from what is
    /// drawn, not from `inspectorPane`, so a pane the chat surface does
    /// not show (the Architect's draft) never makes a click a no-op.
    func toggleContextPanel() {
        if isContextPanelOpen {
            inspectorPane = nil
            return
        }
        inspectorPane = .fileChanges
        closeCompactDrawerForContext()
    }

    /// Whether this chat has a context panel at all: File Changes, once it
    /// has recorded a change. The toolbar hides the toggle otherwise.
    var hasContextPanel: Bool {
        Self.contextPane(requested: .fileChanges, fileChangeSetCount: fileChangeSetCount, isArchitect: isArchitect) != nil
    }

    /// The pane the chat surface's context panel draws, if any.
    var contextPane: ChatInspectorPane? {
        Self.contextPane(requested: inspectorPane, fileChangeSetCount: fileChangeSetCount, isArchitect: isArchitect)
    }

    /// Whether the context panel is on screen (docked or as an overlay).
    var isContextPanelOpen: Bool { contextPane != nil }

    private var isArchitect: Bool { agentId == Agent.architectId }

    /// A compact window shows one overlay at a time.
    private func closeCompactDrawerForContext() {
        if shellBreakpoint == .compact { isCompactSidebarPresented = false }
    }

    /// The pane the chat surface's context panel draws: File Changes, and
    /// only while the panel is requested and the chat has recorded a
    /// change. Any request counts, so visiting the Architect (whose draft
    /// lives in the Workflows split, not here) never hides File Changes
    /// for the next chat. The Architect's chats have no context panel.
    nonisolated static func contextPane(
        requested: ChatInspectorPane?,
        fileChangeSetCount: Int,
        isArchitect: Bool
    ) -> ChatInspectorPane? {
        guard requested != nil, fileChangeSetCount > 0, !isArchitect else { return nil }
        return .fileChanges
    }

    func closeInspector() {
        inspectorPane = nil
    }

    /// Moving to the Architect opens the inspector on its draft, only when
    /// the inspector is closed. Nothing else about the inspector follows
    /// the agent: an open rail stays open on the lens the user picked
    /// (File Changes reads as the draft there).
    func openInspectorForArchitect() {
        guard agentId == Agent.architectId, inspectorPane == nil else { return }
        showInspector(.draft)
    }

    /// Count shown on the toolbar's inspector toggle: the files this chat
    /// changed, only while the inspector is closed (open, the lens bar
    /// carries it), only for local chats (remote agents' files live on
    /// another machine), and never zero.
    nonisolated static func inspectorBadgeCount(
        fileChangesCount: Int,
        isInspectorOpen: Bool,
        isRemoteAgentChat: Bool
    ) -> Int? {
        guard fileChangesCount > 0, !isInspectorOpen, !isRemoteAgentChat else { return nil }
        return fileChangesCount
    }

    var inspectorBadgeCount: Int? {
        Self.inspectorBadgeCount(
            fileChangesCount: fileChangesCount,
            isInspectorOpen: isContextPanelOpen,
            isRemoteAgentChat: selectedRemoteAgentProviderId != nil
        )
    }

    // MARK: - File Changes State

    /// Change set the inspector should reveal (from an inline card or chip).
    @Published var changesPanelFocusSetId: UUID?

    /// Files whose current state differs from before this chat touched them.
    @Published private(set) var fileChangesCount: Int = 0

    /// Change sets recorded for the chat (including reverts). Zero hides
    /// the context panel and its toolbar toggle.
    @Published private(set) var fileChangeSetCount: Int = 0

    /// Stand-in for the journal query in `refreshFileChanges()`.
    func setFileChangeCountsForTesting(files: Int, sets: Int) {
        fileChangesCount = files
        fileChangeSetCount = sets
    }

    /// True while a background job spawned by the current session may still
    /// be mutating the workspace (undo is disabled meanwhile).
    @Published private(set) var fileChangesHaveActiveJob: Bool = false

    // MARK: - Theme State

    @Published private(set) var theme: ThemeProtocol

    // MARK: - Pre-computed View Values

    @Published private(set) var filteredSessions: [ChatSessionData] = []
    @Published private(set) var cachedSystemPrompt: String = ""
    @Published private(set) var cachedActiveAgent: Agent = .default
    @Published private(set) var cachedAgentDisplayName: String = L("Assistant")

    // MARK: - Private

    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    private var sessionRefreshWorkItem: DispatchWorkItem?
    private var agentsCancellable: AnyCancellable?
    private var sessionsCancellable: AnyCancellable?
    private var workspaceCancellables: Set<AnyCancellable> = []

    // MARK: - Initialization

    init(windowId: UUID, agentId: UUID, sessionData: ChatSessionData? = nil) {
        self.windowId = windowId
        self.agentId = agentId
        self.session = ChatSession()
        self.foundationModelAvailable = AppConfiguration.shared.foundationModelAvailable
        self.theme = ThemeManager.shared.currentTheme

        // Load initial data.
        let allAgents = AgentManager.shared.agents
        self.agents = allAgents
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)

        // Pre-compute view values
        self.cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        self.cachedActiveAgent = Self.resolvedAgent(agentId, in: allAgents) ?? .default
        self.cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)

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
        // The Architect's chat opens on its draft. Set before the first
        // layout so the window doesn't lay out Chat and then swap surfaces.
        if agentId == Agent.architectId { showWorkflowDetail() }

        setupNotificationObservers()
        observeAgentManager()
        observeSessionsManager()
        observeWorkspaceState()
        refreshPairedRelayAgents()
        refreshFileChanges()
        reconcileRemoteMode()
    }

    /// Wrap an existing `ExecutionContext`, reusing its sessions without duplication.
    /// Used for lazy window creation when a user clicks "View" on a toast.
    init(windowId: UUID, executionContext context: ExecutionContext) {
        self.windowId = windowId
        self.agentId = context.agentId
        self.session = context.chatSession
        self.foundationModelAvailable = AppConfiguration.shared.foundationModelAvailable
        self.theme = ThemeManager.shared.currentTheme

        let allAgents = AgentManager.shared.agents
        self.agents = allAgents
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: context.agentId)
        self.cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: context.agentId)
        self.cachedActiveAgent = Self.resolvedAgent(context.agentId, in: allAgents) ?? .default
        self.cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)

        let initialTab = ChatTab(id: UUID(), session: self.session)
        self.tabs = [initialTab]
        self.activeTabId = initialTab.id

        // Re-link the adopted session to this window so busy alerts and
        // Mode 2 routing reach the view that now displays it.
        self.session.windowState = self
        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }
        if context.agentId == Agent.architectId { showWorkflowDetail() }

        setupNotificationObservers()
        observeAgentManager()
        observeSessionsManager()
        observeWorkspaceState()
        refreshPairedRelayAgents()
        refreshFileChanges()
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
        selectedRemoteAgentProviderId = nil
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
        session.closeHarnessSession()
        session.onSessionChanged = nil
    }

    // MARK: - API

    var activeAgent: Agent { cachedActiveAgent }

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
        let scope = ChatTabScope.local(newAgentId)
        if scope == activeScope, activeTab?.workflowID == nil { return }
        if focusExistingTab(in: scope) { return }
        if isBlank(session) {
            adoptAgent(newAgentId)
            if releaseSharedSessionIfNeeded() || detachRunningSessionIfNeeded() {
                installFreshSession(agentId: newAgentId)
            } else {
                session.reset(for: newAgentId)
                // A blank team-agent or hosted tab repurposed for a local
                // agent drops that identity (reset keeps it for New Chat).
                session.workspaceContext = nil
                session.hostDevice = nil
                session.servedBy = nil
                adoptAgentWorkingFolder()
            }
            reconcileRemoteMode()
            refreshSessions()
            refreshFileChanges()
            return
        }
        newTab(agentId: newAgentId)
    }

    /// Start a fresh chat with `newAgentId` from its sidebar row (hover "+").
    /// Unlike `switchAgent`, this never lands on one of the agent's existing
    /// tabs: if the active tab already belongs to that agent it behaves like
    /// New Chat there (a blank tab is reused), otherwise a new tab opens for
    /// the agent.
    func startNewChat(with newAgentId: UUID) {
        if ChatTabScope.local(newAgentId) == activeScope {
            startNewChat()
            return
        }
        TTSService.shared.stop()
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
        // The user's own agent on one of their sync devices: chat through
        // sync. The relay route (owner redeem) stays for Macs not in sync.
        if let hosted = SyncAgentDirectory.shared.hostedAgent(
            address: address,
            connected: SyncHostedRunMonitor.shared.connectedDevices
        ) {
            switchToHostedAgent(device: hosted.device, agentId: hosted.agentId)
            return
        }
        TTSService.shared.stop()
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
            refreshFileChanges()
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
        let candidates = tabs.filter {
            $0.id != activeTabId && $0.workflowID == nil && ChatTabScope.of($0.session) == scope
        }
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

    /// A New Chat nothing has happened in yet. Leaving one closes it (its
    /// unsent text goes back to the agent's draft), so a window holds at
    /// most one and it never lingers in the sidebar.
    private func isAbandonedOnLeave(_ tab: ChatTab) -> Bool {
        tab.kind == .chat && !tab.isHibernated && tab.session.sessionId == nil && isBlank(tab.session)
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
        case .hosted(let device, let agentId):
            let fresh = makeFreshSession(agentId: Agent.defaultId, restoresDraft: false)
            stampHostedAgent(device: device, agentId: agentId, on: fresh)
            return ChatTab(id: UUID(), session: fresh)
        }
    }

    /// Pick an agent another of the user's Macs runs, from its sidebar
    /// section. Same tab handling as a workspace agent: its existing tabs
    /// are shown, else a blank tab is repurposed, else a new tab opens. The
    /// window stays on the Default agent; the tab's session carries the
    /// host's agent id and device, and that Mac answers its turns.
    func switchToHostedAgent(device: String, agentId hostedAgentId: UUID) {
        TTSService.shared.stop()
        let scope = ChatTabScope.hosted(device: device, agentId: hostedAgentId)
        if scope == activeScope, activeTab?.workflowID == nil { return }
        if focusExistingTab(in: scope) { return }
        if isBlank(session) {
            if agentId != Agent.defaultId { adoptAgent(Agent.defaultId) }
            if releaseSharedSessionIfNeeded() || detachRunningSessionIfNeeded() {
                installFreshSession(agentId: Agent.defaultId, restoresDraft: false)
            } else {
                session.reset(for: Agent.defaultId)
            }
            stampHostedAgent(device: device, agentId: hostedAgentId, on: session)
            reconcileRemoteMode()
            refreshSessions()
            refreshFileChanges()
            return
        }
        newTab(agentId: Agent.defaultId, restoresDraft: false)
        stampHostedAgent(device: device, agentId: hostedAgentId, on: session)
        reconcileRemoteMode()
        refreshSessions()
    }

    /// The agent the window takes on for a chat. A chat another Mac runs or
    /// served keeps the window on the Default agent: its agent id is one of
    /// that Mac's, and only the tab's session carries it.
    private static func windowAgentId(agentId: UUID?, elsewhere: Bool) -> UUID {
        elsewhere ? Agent.defaultId : agentId ?? Agent.defaultId
    }

    private func stampHostedAgent(device: String, agentId hostedAgentId: UUID, on target: ChatSession) {
        target.workspaceContext = nil
        target.servedBy = nil
        target.folderState.clearFolder()
        target.agentId = hostedAgentId
        target.hostDevice = device
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
        refreshFileChanges()
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
            selectedRemoteAgentProviderId == paired?.providerId
        { return }
        workspaceAgentAddress = address
        refreshPairedRelayAgents()
        guard let relay = pairedRelayAgents.first(where: {
            $0.providerId == paired?.providerId
            }) else {
            // Not paired yet: the composer lock explains; auto-connect or
            // Retry will pair it, after which `reconcileRemoteMode` re-runs.
            selectedRelayAgent = nil
            selectedRemoteAgentProviderId = nil
            pinnedRemoteAgentEffectiveModel = nil
            pinnedRemoteAgentAvatar = nil
            pinnedRemoteAgentQuickActions = nil
            remoteAgentConnectionPhase = .idle
            return
        }
        // Route sends to the agent even before the connect resolves; the
        // composer stays locked until the phase reaches `.connected`.
        selectedRelayAgent = relay
        selectedRemoteAgentProviderId = relay.providerId
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
        selectedRemoteAgentProviderId = nil
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
        if let device = session.hostDeviceElsewhere {
            let monitor = SyncHostedRunMonitor.shared
            return monitor.isConnected(device) ? nil : .hostOffline(hostName: monitor.hostName(device))
        }
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
        case .accessRevoked:
            return .agentUnavailable(agentName: agentName, reason: L("its owner revoked your guest link."))
        case .readOnlyTeammate(let callerName):
            // Hosted here for a remote caller: the agent is one of ours. An
            // invite-link row may carry no resolvable address, so fall back
            // to the row's agent id before the identity's short address.
            let resolvedName = identity.name == identity.shortAddress ? nil : identity.name
            let hostedName =
                identity.localAgent?.displayName
                ?? resolvedName
                ?? session.agentId.flatMap { AgentManager.shared.agent(for: $0)?.displayName }
                ?? session.servedElsewhere.flatMap { device in
                    session.agentId.flatMap { SyncAgentDirectory.shared.entry(device: device, agentId: $0)?.name }
                }
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
            isBoundToProvider: selectedRemoteAgentProviderId != nil,
            isPairing: connect.isConnecting(address, workspaceId: context.workspaceId),
            connectFailure: connect.connectFailure(for: address, workspaceId: context.workspaceId),
            hasAttempted: connect.hasAttempted(address, workspaceId: context.workspaceId),
            phase: remoteAgentConnectionPhase,
            accessRevokedAt: context.workspaceId.isEmpty
                ? RemoteAgentManager.shared.remoteAgent(forAddress: address, workspaceId: nil)?.accessRevokedAt
                : nil
        )
    }

    /// An untouched chat: nothing sent, nothing running, nothing pending.
    /// A chat tab nothing has happened in yet, which a new chat may take
    /// over. A workflow tab's session is never blank: the tab shows the
    /// workflow, so a chat loaded into it would stay hidden.
    private func isBlank(_ s: ChatSession) -> Bool {
        s.turns.isEmpty && !s.isStreaming && s.awaitingClarify == nil
            && !tabs.contains { $0.workflowID != nil && $0.session === s }
    }

    /// Start a new chat that stays in the current chat's project, so
    /// running out of context mid-project doesn't silently drop the
    /// project's instructions, knowledge, and folder. Falls back to a plain
    /// new chat outside any project.
    func startNewChatInCurrentProject() {
        guard let project = ProjectManager.shared.project(for: session.projectId) else {
            startNewChat()
            return
        }
        startNewChat(in: project)
    }

    /// Start a fresh chat inside `project` with its default agent, or the
    /// window's agent when none is set or it was deleted; stamps membership
    /// (persisted with the first turn's save) and opens the project's
    /// working folder when the chat has none. Never lands on an existing
    /// tab: that conversation would be pulled into the project.
    func startNewChat(in project: Project) {
        let target = project.defaultAgentId.flatMap { id in
            agents.contains(where: { $0.id == id }) ? id : nil
        } ?? agentId
        startNewChat(with: target)
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
    /// The Orchestrator's folder (Settings → Orchestrator → Working Folder)
    /// is adopted the same way; a chat that already has one (or is
    /// mid-restore) is left alone. Returns the follow-up task (nil when
    /// nothing was applied) so tests can await the sandbox change.
    @discardableResult
    func adoptAgentWorkingFolder(on target: ChatSession? = nil) -> Task<Void, Never>? {
        let target = target ?? session
        let agentId = target.agentId ?? Agent.defaultId
        guard target.workspaceContext == nil,
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
        let adoption = folderState.beginHostFolderAdoption(bookmark: bookmark, path: path)
        let agentId = target.agentId ?? agentId
        return Task { @MainActor in
            defer { folderState.endHostFolderAdoption(adoption) }
            // Only a folder that actually resolved earns the switch: a stale
            // bookmark whose path is gone leaves the agent as it was rather
            // than stranding it with no sandbox AND no folder.
            guard await folderState.contextWaitingForRestore() != nil else {
                target.folderFromAgentDefault = false
                return
            }
            // A harness runs on the host; the sandbox only governs Osaurus's
            // own tools, which a harness agent's chat never uses.
            guard AgentManager.shared.effectiveHarness(for: agentId) == nil else { return }
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
    /// does.
    func newTabInCurrentProject() {
        let project = ProjectManager.shared.project(for: session.projectId)
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
        refreshFileChanges()
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
        let me = SyncService.shared.core?.deviceKey()
        let targetAgentId = Self.windowAgentId(
            agentId: resolvedData.agentId,
            elsewhere: resolvedData.hostDevice.map { !$0.isEmpty && $0 != me } == true
                || resolvedData.servedElsewhere(me: me) != nil
        )

        // Browser-style, like `startNewChat` / `switchAgent`: a run in flight
        // (or paused on a clarify prompt) keeps its own tab, still owned by
        // this window and still visible under its agent; the target loads
        // into a fresh tab instead of pushing the run out of the strip.
        // A workflow tab shows the workflow, not a chat: the chat gets a tab
        // of its own.
        if activeTab?.workflowID != nil
            || ((session.isStreaming || session.awaitingClarify != nil)
                && !LiveChatSessionRegistry.shared.isShared(session))
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
        let isHostedRow = sessionData.source == .workspace
        if let liveTask = BackgroundTaskManager.shared.liveTask(forSessionId: sessionData.id),
            let liveSession = liveTask.chatSession
        {
            if isHostedRow {
                MobileConnectLog.hostedRun(
                    "window opened \(sessionData.id) on the live task \(liveTask.id) "
                        + "(turns=\(liveSession.turns.count), streaming=\(liveSession.isStreaming))"
                )
            }
            releaseSharedSessionIfNeeded()
            detachRunningSessionIfNeeded()
            attachSession(liveSession, registryTaskId: liveTask.id)
        } else if let sharedSession = LiveChatSessionRegistry.shared.liveSession(
            for: sessionData.id
        ) {
            if isHostedRow {
                MobileConnectLog.hostedRun("window opened \(sessionData.id) on another surface's live session")
            }
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
            if isHostedRow {
                MobileConnectLog.hostedRun(
                    "window opened \(sessionData.id) from disk into a fresh session "
                        + "(turns=\(resolvedData.turns.count)); no live task for it"
                )
            }
        } else {
            session.load(from: resolvedData)
            if isHostedRow {
                MobileConnectLog.hostedRun(
                    "window opened \(sessionData.id) from disk (turns=\(resolvedData.turns.count)); "
                        + "no live task for it"
                )
            }
        }
        reconcileRemoteMode()
        refreshSessions()
        refreshFileChanges()
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
        defer {
            if agentId == Agent.architectId { showWorkflowDetail() }
            else { mainSurface = .chat }
        }
        // A blank active tab is replaced, not kept beside the new one.
        // Stashed first so the fresh chat restores its unsent text.
        persistActiveSessionForTabSwitch()
        let abandoned = activeTab.flatMap { isAbandonedOnLeave($0) ? $0 : nil }
        abandoned?.session.stashDraft()
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
        // Likewise a new tab from a hosted tab stays with the other Mac's agent.
        let carriedHost: (device: String, agentId: UUID)? =
            newAgentId == nil
            ? session.hostDeviceElsewhere.flatMap { device in session.agentId.map { (device, $0) } }
            : nil
        if let newAgentId, newAgentId != agentId {
            adoptAgent(newAgentId)
        }
        let fresh = makeFreshSession(
            agentId: agentId,
            restoresDraft: restoresDraft && carriedWorkspace == nil && carriedHost == nil
        )
        fresh.workspaceContext = carriedWorkspace
        if let carriedHost {
            stampHostedAgent(device: carriedHost.device, agentId: carriedHost.agentId, on: fresh)
        } else if carriedWorkspace == nil {
            // Local tabs only: a new tab that stays with a team agent must not
            // inherit the hosting local agent's working folder.
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
            if let abandoned { dropTab(abandoned) }
        }
        reconcileRemoteMode()
        refreshSessions()
        refreshFileChanges()
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
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[idx].workflowID != nil || tabs[idx].session.agentId == Agent.architectId {
            showWorkflowDetail()
        } else {
            mainSurface = .chat
        }
        guard id != activeTabId else { return }
        persistActiveSessionForTabSwitch()
        let abandoned = activeTab.flatMap { isAbandonedOnLeave($0) ? $0 : nil }
        abandoned?.session.stashDraft()
        tabs[idx].lastActivatedAt = Date()
        if tabs[idx].isHibernated {
            wake(tabAt: idx)
        }
        activeTabId = id
        adoptTabSession(tabs[idx].session)
        if let abandoned { dropTab(abandoned) }
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
        if id == activeTabId, siblings.isEmpty, !closing.isHibernated, closing.kind == .chat, isBlank(closing.session) {
            return
        }

        rememberClosedTab(closing, at: scopedIdx)
        AgentCreatorLauncher.noteClosed(closing.session)
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

    /// ⌘W: close the active tab when there is something to close — another
    /// tab of the same agent, or a conversation in the lone tab (which is
    /// then replaced by a blank chat so the window stays up; the closed
    /// chat is still in History and ⇧⌘T). Returns false for a lone blank
    /// tab, the only case where ⌘W falls through to closing the window.
    @discardableResult
    func closeActiveTabIfPossible() -> Bool {
        guard let active = tabs.first(where: { $0.id == activeTabId }) else { return false }
        let hasSiblings = scopedTabs.count > 1
        guard hasSiblings || active.isHibernated || active.kind != .chat || !isBlank(active.session) else { return false }
        closeTab(id: activeTabId)
        return true
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

    // MARK: Remembered tabs (relaunch / window reopen)

    /// The persisted conversations this window has open, for
    /// `ChatTabLayoutStore`. Blank tabs are skipped (nothing to reopen);
    /// so are registry-owned runs and registry-shared sessions, which the
    /// `BackgroundTaskManager` retains and re-attaches on its own.
    func tabLayoutSnapshot() -> ChatTabLayoutRecord {
        let entries = tabs.compactMap { tab -> ChatTabLayoutRecord.Tab? in
            if case .workflowRun(let workflowID, let runID) = tab.kind {
                return ChatTabLayoutRecord.Tab(
                    sessionId: nil, lastActivatedAt: tab.lastActivatedAt, workflowID: workflowID, runID: runID,
                    agentId: tab.session.agentId)
            }
            guard let sessionId = tab.session.sessionId,
                tab.isHibernated || !tab.session.turns.isEmpty,
                !LiveChatSessionRegistry.shared.isShared(tab.session),
                BackgroundTaskManager.shared.task(owning: tab.session) == nil
            else { return nil }
            return ChatTabLayoutRecord.Tab(sessionId: sessionId, lastActivatedAt: tab.lastActivatedAt)
        }
        let activeSessionId = tabs.first { $0.id == activeTabId }?.session.sessionId
        return ChatTabLayoutRecord(
            tabs: entries,
            activeSessionId: entries.contains { $0.sessionId == activeSessionId } ? activeSessionId : nil,
            savedAt: Date()
        )
    }

    /// Bring remembered tabs back as hibernated tabs (metadata only; the
    /// transcript loads when a tab is selected). Conversations deleted
    /// since, already open here, or now owned by a registry run are
    /// skipped. When `record.activeSessionId` came back and this window is
    /// still on its initial blank tab, that tab is selected and the blank
    /// dropped, so the window reopens on the chat the user was reading.
    /// Returns how many tabs were restored.
    @discardableResult
    func restoreTabs(from record: ChatTabLayoutRecord) -> Int {
        var restored = 0
        let chatIds = record.tabs.compactMap(\.sessionId).filter { sessionId in
            !tabs.contains(where: { $0.session.sessionId == sessionId })
                && BackgroundTaskManager.shared.taskState(for: sessionId) == nil
        }
        let stubs = transcriptStubs(for: chatIds)
        for entry in record.tabs {
            // Workflows and their runs open in the Workflows window, not
            // as tabs; a layout saved by an earlier version may list them.
            if entry.workflowID != nil { continue }
            guard let sessionId = entry.sessionId, chatIds.contains(sessionId),
                let snapshot = stubs[sessionId]
            else { continue }
            let cold = makeFreshSession(agentId: snapshot.agentId ?? agentId, loading: snapshot)
            var tab = ChatTab(id: UUID(), session: cold)
            tab.isHibernated = true
            tab.lastActivatedAt = entry.lastActivatedAt
            tabs.append(tab)
            restored += 1
        }
        guard restored > 0 else { return 0 }
        if let activeSessionId = record.activeSessionId,
            let target = tabs.first(where: { $0.session.sessionId == activeSessionId }),
            let initial = tabs.first(where: { $0.id == activeTabId }),
            !initial.isHibernated, initial.kind == .chat, isBlank(initial.session),
            initial.session.unsentComposerText.isEmpty
        {
            selectTab(id: target.id)
            dropTab(initial)
        }
        return restored
    }

    // MARK: Workflow tabs

    /// Show a workflow's run, or its form when `runID` is nil, in this
    /// window's Workflows view. `agentId` is the agent a new run there runs
    /// as (the Orchestrator for runs started outside a chat).
    func openWorkflowTab(workflowID: UUID, runID: UUID? = nil, agentId tabAgentId: UUID = Agent.defaultId) {
        showWorkflowRun(workflowID: workflowID, runID: runID, agentId: tabAgentId)
    }

    /// The run a workflow tab shows (Run Again, picking from its history).
    func setWorkflowTabRun(tabId: UUID, runID: UUID?) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }), let workflowID = tabs[idx].workflowID else { return }
        tabs[idx].kind = .workflowRun(workflowID: workflowID, runID: runID)
    }

    var activeTab: ChatTab? { tabs.first { $0.id == activeTabId } }

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
        guard let snapshot = transcriptStubs(for: [task.id])[task.id] else { return false }
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
        let targetAgentId = Self.windowAgentId(agentId: target.agentId, elsewhere: ChatTabScope.of(target).isHosted)
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
        refreshFileChanges()
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
        closingSession.closeHarnessSession()
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
        // Share (not copy) the saved scroll position: the tab's table may
        // unmount and save after this swap, and the write must still land.
        cold.scrollPositionStore = live.scrollPositionStore
        live.warmupController.shutdown()
        live.stop()
        live.onSessionChanged = nil
        live.windowState = nil
        tabs[idx].session = cold
        tabs[idx].isHibernated = true
    }

    /// Metadata-only session snapshots (turns empty) for hibernated tab
    /// stand-ins. The sessions manager already holds every chat's row for
    /// the sidebar, so most ids cost no disk read at all; the rest come
    /// from one batched metadata query. Never a full transcript load: with
    /// dozens of remembered tabs those reads, on the main thread at window
    /// creation, were the dominant cost of opening a window.
    private func transcriptStubs(for ids: [UUID]) -> [UUID: ChatSessionData] {
        var stubs: [UUID: ChatSessionData] = [:]
        var missing: [UUID] = []
        for id in ids {
            if var cached = ChatSessionsManager.shared.session(for: id) {
                cached.turns = []
                stubs[id] = cached
            } else {
                missing.append(id)
            }
        }
        for var row in ChatSessionStore.loadMetadata(ids: missing) {
            row.turns = []
            stubs[row.id] = row
        }
        return stubs
    }

    /// Reload a hibernated tab's transcript in place, off the main thread.
    /// The tab stays `isHibernated` (title from the stand-in, no transcript)
    /// and its session reports `isHydratingTranscript` so the chat surface
    /// shows a loading state rather than the empty-chat greeting; both clear
    /// when the transcript lands. The completion is dropped if the tab was
    /// closed or its session replaced meanwhile (the stand-in is no longer
    /// in `tabs`), and a second select while a load is in flight does not
    /// start another.
    private func wake(tabAt idx: Int) {
        let cold = tabs[idx].session
        guard let sid = cold.sessionId else {
            tabs[idx].isHibernated = false
            return
        }
        guard !cold.isHydratingTranscript else { return }
        cold.isHydratingTranscript = true
        let task = Task { @MainActor [weak self] in
            let full = await ChatSessionStore.loadAsync(id: sid)
            guard let self else { return }
            defer { self.hydrationTasks.removeValue(forKey: ObjectIdentifier(cold)) }
            cold.isHydratingTranscript = false
            guard let liveIdx = self.tabs.firstIndex(where: { $0.session === cold && $0.isHibernated }),
                cold.sessionId == sid
            else { return }
            if let full {
                cold.load(from: full)
            }
            self.tabs[liveIdx].isHibernated = false
        }
        hydrationTasks[ObjectIdentifier(cold)] = task
    }

    /// In-flight transcript loads keyed by the stand-in session, so tests
    /// (and any caller that needs a hydrated transcript) can wait for them.
    private var hydrationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Wait for every in-flight tab wake to finish.
    func awaitTranscriptHydration() async {
        while let task = hydrationTasks.values.first {
            await task.value
        }
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

    // MARK: - File Changes

    /// Show the File Changes inspector, optionally revealing one change set.
    private var pendingChangesPanelRequest: (sessionId: String, setId: UUID?, at: Date)?

    func openChangesPanel(focusing setId: UUID? = nil) {
        changesPanelFocusSetId = setId
        showInspector(.fileChanges)
    }

    /// Re-query the journal for the current session's outstanding file
    /// count, set count, and active-job flag. Cheap (actor cache hit) and
    /// safe to call on every chat switch / journal notification.
    func refreshFileChanges() {
        // Remote-agent chats never mutate local files; a new chat has no
        // session id until the first send.
        if let pending = pendingChangesPanelRequest {
            if Date().timeIntervalSince(pending.at) > 3 {
                pendingChangesPanelRequest = nil
            } else if pending.sessionId == session.sessionId?.uuidString {
                pendingChangesPanelRequest = nil
                openChangesPanel(focusing: pending.setId)
            }
        }
        guard selectedRemoteAgentProviderId == nil,
            let sessionId = session.sessionId?.uuidString
        else {
            fileChangesCount = 0
            fileChangeSetCount = 0
            fileChangesHaveActiveJob = false
            return
        }
        Task { [weak self] in
            let journal = FileChangeJournal.shared
            let count = await journal.outstandingCount(for: sessionId)
            let setCount = await journal.changeSets(for: sessionId).count
            let hasJob = await journal.hasActiveBackgroundJobs(sessionId: sessionId)
            await MainActor.run {
                guard let self, self.session.sessionId?.uuidString == sessionId else { return }
                self.fileChangesCount = count
                self.fileChangeSetCount = setCount
                self.fileChangesHaveActiveJob = hasJob
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
    /// relay-agent pills, theme, system-prompt cache, global
    /// active-agent pointer) to `newAgentId` WITHOUT touching the
    /// session's content. `switchAgent` calls this before resetting the
    /// session for a brand-new chat; `loadSession` calls it before
    /// loading turns from disk.
    private func adoptAgent(_ newAgentId: UUID) {
        // Leaving remote mode wholesale; `reconcileRemoteMode` re-binds a
        // team-agent tab afterwards from its session's workspace context.
        workspaceAgentAddress = nil
        pendingRelayConnect = nil
        selectedRemoteAgentProviderId = nil
        selectedRelayAgent = nil
        pinnedRemoteAgentEffectiveModel = nil
        pinnedRemoteAgentAvatar = nil
        pinnedRemoteAgentQuickActions = nil
        remoteAgentConnectionPhase = .idle
        agentId = newAgentId
        refreshTheme()
        refreshAgentConfig()
        // A New Agent chat is not an agent the user picked: the selection
        // stays on the agent they came from.
        guard newAgentId != Agent.configuratorId else { return }
        AgentManager.shared.setActiveAgent(newAgentId)
        // First-run readiness: a freshly created agent (any path) is checked
        // the first time a window shows it. Clean agents clear silently.
        AgentSetupPromptCoordinator.shared.agentShown(newAgentId, windowId: windowId)
    }

    /// The window's agent by id. The Configurator is never in the agent
    /// list but owns New Agent chats.
    static func resolvedAgent(_ id: UUID, in agents: [Agent]) -> Agent? {
        if id == Agent.configuratorId { return .configurator }
        return agents.first { $0.id == id }
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
        cachedActiveAgent = Self.resolvedAgent(agentId, in: allAgents) ?? .default
        cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
    }

    func refreshSessions() {
        onTabLayoutChanged?()
        // A team-agent tab lists that agent's history (keyed by address);
        // everything else lists the local agent's.
        let next: [ChatSessionData]
        if case .hosted(let device, let hostedAgentId) = ChatTabScope.of(session) {
            next = ChatSessionsManager.shared.sessions(forHost: device, agentId: hostedAgentId)
        } else if let context = session.workspaceContext, !context.isServedForTeammate {
            next = ChatSessionsManager.shared.sessions(
                forRemoteAgentAddress: context.agentAddress).filter { $0.workspace?.workspaceId == context.workspaceId }
        } else {
            next = ChatSessionsManager.shared.sessions(for: agentId)
        }
        // Publishing re-renders the whole chat shell; a save to another
        // agent's chat leaves this list unchanged.
        guard !ChatSessionData.sameListRows(filteredSessions, next) else { return }
        filteredSessions = next
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

    func refreshTheme() {
        let newTheme = ThemeManager.shared.currentTheme
        let oldConfig = theme.customThemeConfig
        let newConfig = newTheme.customThemeConfig
        // Skip only if the full config is identical (not just the ID) and the
        // global font zoom is unchanged — the zoom lives on the theme instance,
        // not in the config, so it must be compared separately.
        let oldScale = (theme as? CustomizableTheme)?.fontScale
        let newScale = (newTheme as? CustomizableTheme)?.fontScale
        guard oldConfig != newConfig || oldScale != newScale else { return }

        theme = newTheme
    }

    func refreshAgentConfig() {
        cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        cachedActiveAgent = Self.resolvedAgent(agentId, in: agents) ?? .default
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
                        self.selectedRemoteAgentProviderId == nil
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

        guard let newActive = Self.resolvedAgent(agentId, in: latest) else {
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
    }

    func refreshPairedRelayAgents() {
        let manager = RemoteProviderManager.shared
        pairedRelayAgents = manager.configuration.providers.compactMap { provider in
            guard provider.providerType == .osaurus,
                !manager.isEphemeral(id: provider.id),
                let agentId = provider.remoteAgentId,
                let relayAddress = provider.remoteAgentAddress
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

    /// Built-in default agent renders its localized display name (the
    /// "Osaurus" brand label, or the user's custom Orchestrator name from
    /// Settings → Orchestrator) so the chat header carries the product
    /// name instead of the internal `"Default"` id; custom agents render
    /// their stored name verbatim.
    private static func displayName(for agent: Agent) -> String {
        agent.displayName
    }

    /// The identity that should head the chat thread / empty state right now.
    /// In a hosted chat it's the agent on the other Mac, from its directory;
    /// in Mode 2 (a relay agent is selected) the *remote* agent's
    /// name + fetched mascot; otherwise it's the local active agent.
    /// Drives message-bubble headers so a remote conversation isn't mislabeled
    /// "Osaurus" with the local avatar.
    var effectiveChatIdentity: ChatThreadIdentity {
        if let host = session.hostDeviceElsewhere, let hostedAgentId = session.agentId {
            let entry = SyncAgentDirectory.shared.entry(device: host, agentId: hostedAgentId)
            return ChatThreadIdentity(
                name: entry?.name ?? L("Agent"),
                mascotId: entry?.avatar,
                customAvatarPath: nil,
                isRemote: true
            )
        }
        if selectedRemoteAgentProviderId != nil {
            let remoteName = selectedRelayAgent?.name ?? L("Remote Agent")
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
        // Inline cards / chips ask the window showing their chat to open
        // the File Changes inspector on a specific change set.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .fileChangesOpenPanel,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let target = notification.userInfo?["sessionId"] as? String
                let setId = notification.userInfo?["setId"] as? UUID
                Task { @MainActor in
                    guard let self, let target else { return }
                    if self.session.sessionId?.uuidString == target {
                        self.openChangesPanel(focusing: setId)
                    } else {
                        // The sidebar badge selects the chat first; the switch
                        // can land after this (e.g. a pending rename commits).
                        self.pendingChangesPanelRequest = (target, setId, Date())
                    }
                }
            }
        )
                // File history: refresh the toolbar count when the journal
        // records/reverts changes for the session this window shows.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .fileChangesDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let changed = notification.userInfo?["sessionId"] as? String
                Task { @MainActor in
                    guard let self else { return }
                    guard let current = self.session.sessionId?.uuidString,
                        changed == nil || changed == current
                    else { return }
                    self.refreshFileChanges()
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
        // Follow appearance and zoom changes. refreshTheme() no-ops via its
        // config equality guard when this window's theme is unchanged.
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
                        let providerId = self.selectedRemoteAgentProviderId
                    else { return }
                    let manager = RemoteProviderManager.shared
                    let providerExists = manager.configuration.providers
                        .contains(where: { $0.id == providerId })
                    guard providerExists else {
                        // Provider was removed from settings — leave remote-agent mode.
                        self.selectedRelayAgent = nil
                        self.selectedRemoteAgentProviderId = nil
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
