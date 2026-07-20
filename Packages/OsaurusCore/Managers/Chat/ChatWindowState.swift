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

/// Per-window state container for ChatView - each window creates its own instance
@MainActor
final class ChatWindowState: ObservableObject {
    // MARK: - Identity & Session

    let windowId: UUID
    /// The session this window currently displays. Replaceable: switching
    /// chats while a run is in flight detaches the running session into the
    /// `BackgroundTaskManager` registry (execution continues) and installs a
    /// different `ChatSession` here. `@Published` so the window root view can
    /// rebuild `ChatView` around the new instance.
    @Published private(set) var session: ChatSession
    let foundationModelAvailable: Bool

    // MARK: - View State

    @Published var showSidebar: Bool = false

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

        // Load initial data
        self.agents = AgentManager.shared.agents
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)

        // Pre-compute view values
        self.cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        self.cachedActiveAgent = agents.first { $0.id == agentId } ?? .default
        self.cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
        decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)

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

        self.agents = AgentManager.shared.agents
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: context.agentId)
        self.cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: context.agentId)
        self.cachedActiveAgent = agents.first { $0.id == context.agentId } ?? .default
        self.cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
        decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)

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

    func switchAgent(to newAgentId: UUID) {
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        adoptAgent(newAgentId)
        if detachRunningSessionIfNeeded() {
            installFreshSession(agentId: newAgentId)
        } else {
            session.reset(for: newAgentId)
        }
        refreshSessions()
        refreshSandboxChanges()
    }

    func startNewChat() {
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        flushCurrentSession()
        if detachRunningSessionIfNeeded() {
            installFreshSession(agentId: agentId)
        } else {
            session.reset(for: agentId)
        }
        refreshSessions()
        refreshSandboxChanges()
        // KPI: user started a new chat conversation. Count only.
        FeatureTelemetry.chatSessionStarted()
    }

    func loadSession(_ sessionData: ChatSessionData) {
        guard sessionData.id != session.sessionId else { return }
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
            detachRunningSessionIfNeeded()
            attachSession(liveSession, registryTaskId: liveTask.id)
        } else if detachRunningSessionIfNeeded() {
            // The chat we're leaving keeps running in the background; the
            // target loads into a brand-new session so the two never share
            // transcript state.
            installFreshSession(agentId: targetAgentId, loading: resolvedData)
        } else {
            session.load(from: resolvedData)
        }
        refreshSessions()
        refreshSandboxChanges()
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

    /// Install a brand-new `ChatSession` for this window (optionally loading
    /// persisted turns), used after the previous one was detached to the
    /// registry.
    private func installFreshSession(agentId: UUID, loading data: ChatSessionData? = nil) {
        let fresh = ChatSession()
        fresh.windowState = self
        fresh.agentId = agentId
        fresh.applyInitialModelSelection()
        if let data { fresh.load(from: data) }
        fresh.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }
        session = fresh
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
        agents = AgentManager.shared.agents
        cachedActiveAgent = agents.first { $0.id == agentId } ?? .default
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

    func refreshTheme() {
        let newTheme = Self.loadTheme(for: agentId)
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
        session.invalidateTokenCache()
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
                self?.refreshSessions()
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
        session.invalidateTokenCache()

        if newActive.themeId != oldActive.themeId {
            refreshTheme()
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

    private static func loadTheme(for agentId: UUID) -> ThemeProtocol {
        if let themeId = AgentManager.shared.themeId(for: agentId),
            let custom = ThemeManager.shared.installedThemes.first(where: { $0.metadata.id == themeId })
        {
            return CustomizableTheme(config: custom)
        }
        return ThemeManager.shared.currentTheme
    }

    /// Built-in default agent renders as the localized "Osaurus" brand
    /// label so the chat header carries the product name instead of the
    /// internal `"Default"` id; custom agents render their stored name
    /// verbatim.
    private static func displayName(for agent: Agent) -> String {
        agent.isBuiltIn ? L("Osaurus") : agent.name
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
