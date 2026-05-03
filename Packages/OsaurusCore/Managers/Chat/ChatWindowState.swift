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

/// Per-window state container for ChatView - each window creates its own instance
@MainActor
final class ChatWindowState: ObservableObject {
    // MARK: - Identity & Session

    let windowId: UUID
    let session: ChatSession
    let foundationModelAvailable: Bool

    // MARK: - View State

    @Published var showSidebar: Bool = false

    // MARK: - Agent State

    @Published var agentId: UUID
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var discoveredAgents: [DiscoveredAgent] = []
    @Published var selectedDiscoveredAgent: DiscoveredAgent?
    @Published var selectedDiscoveredAgentProviderId: UUID?
    @Published private(set) var pairedRelayAgents: [PairedRelayAgent] = []
    @Published var selectedRelayAgent: PairedRelayAgent?

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

        setupNotificationObservers()
        observeBonjourBrowser()
        observeAgentManager()
        refreshPairedRelayAgents()
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

        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }

        setupNotificationObservers()
        observeBonjourBrowser()
        observeAgentManager()
        refreshPairedRelayAgents()
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
        session.reset(for: newAgentId)
        refreshSessions()
    }

    func startNewChat() {
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        flushCurrentSession()
        session.reset(for: agentId)
        refreshSessions()
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

        session.load(from: resolvedData)
        refreshSessions()
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
        // Skip only if the full config is identical (not just the ID)
        guard oldConfig != newConfig else { return }

        theme = newTheme

        // Only re-decode background image when the theme itself changes (different ID)
        if oldConfig?.metadata.id != newConfig?.metadata.id {
            decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)
        }
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
                self?.discoveredAgents = agents
                if let selected = self?.selectedDiscoveredAgent,
                    !agents.contains(where: { $0.id == selected.id })
                {
                    self?.removeEphemeralProviderIfNeeded()
                    self?.selectedDiscoveredAgent = nil
                    self?.selectedDiscoveredAgentProviderId = nil
                }
                self?.refreshPairedRelayAgents(discoveredAgents: agents)
            }
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
                providerId: provider.id
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

    /// Built-in (Default) agent always renders as the localized "Assistant"
    /// label so the chat header doesn't expose the internal `"Default"` name;
    /// custom agents render their stored name verbatim.
    private static func displayName(for agent: Agent) -> String {
        agent.isBuiltIn ? L("Assistant") : agent.name
    }

    private func decodeBackgroundImageAsync(themeConfig: CustomTheme?) {
        Task { [weak self] in
            let decoded = themeConfig?.background.decodedImage()
            self?.cachedBackgroundImage = decoded
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
        // Note: .chatOverlayActivated intentionally not observed here
        // State is loaded in init(), refreshAll() would cause excessive re-renders
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .appConfigurationChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshAgentConfig() } }
        )
        // Refresh theme when global theme changes (only if agent uses global theme)
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .globalThemeChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    if self?.themeId == nil { self?.refreshTheme() }
                }
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
                    let providerExists = RemoteProviderManager.shared.configuration.providers
                        .contains(where: { $0.id == providerId })
                    guard !providerExists else { return }
                    self.selectedDiscoveredAgent = nil
                    self.selectedRelayAgent = nil
                    self.selectedDiscoveredAgentProviderId = nil
                    self.refreshPairedRelayAgents()
                }
            }
        )
    }
}
