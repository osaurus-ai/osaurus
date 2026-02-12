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

// MARK: - Close Confirmation

@MainActor
struct AgentCloseConfirmation: Identifiable {
    let id = UUID()
}

/// Per-window state container for ChatView - each window creates its own instance
@MainActor
final class ChatWindowState: ObservableObject {
    // MARK: - Identity & Session

    let windowId: UUID
    let session: ChatSession
    let foundationModelAvailable: Bool

    // MARK: - Mode State

    @Published var mode: ChatMode = .chat
    @Published var showSidebar: Bool = false

    /// When non-nil, ChatView should present a close confirmation for active agent execution.
    @Published var agentCloseConfirmation: AgentCloseConfirmation?

    // MARK: - Agent State

    @Published var agentSession: AgentSession?
    @Published private(set) var agentTasks: [AgentTask] = []

    // MARK: - Persona State

    @Published var personaId: UUID
    @Published private(set) var personas: [Persona] = []

    // MARK: - Theme State

    @Published private(set) var theme: ThemeProtocol
    @Published private(set) var cachedBackgroundImage: NSImage?

    // MARK: - Pre-computed View Values

    @Published private(set) var filteredSessions: [ChatSessionData] = []
    @Published private(set) var cachedSystemPrompt: String = ""
    @Published private(set) var cachedActivePersona: Persona = .default
    @Published private(set) var cachedPersonaDisplayName: String = "Assistant"

    // MARK: - Private

    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    private var sessionRefreshWorkItem: DispatchWorkItem?

    // MARK: - Initialization

    init(windowId: UUID, personaId: UUID, sessionData: ChatSessionData? = nil) {
        self.windowId = windowId
        self.personaId = personaId
        self.session = ChatSession()
        self.foundationModelAvailable = AppConfiguration.shared.foundationModelAvailable
        self.theme = Self.loadTheme(for: personaId)

        // Load initial data
        self.personas = PersonaManager.shared.personas
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: personaId)

        // Pre-compute view values
        self.cachedSystemPrompt = PersonaManager.shared.effectiveSystemPrompt(for: personaId)
        self.cachedActivePersona = personas.first { $0.id == personaId } ?? .default
        self.cachedPersonaDisplayName = cachedActivePersona.isBuiltIn ? "Assistant" : cachedActivePersona.name
        decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)

        // Configure session
        self.session.personaId = personaId
        self.session.applyInitialModelSelection()
        if let data = sessionData {
            self.session.load(from: data)
        }
        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }

        setupNotificationObservers()
    }

    /// Wrap an existing `ExecutionContext`, reusing its sessions without duplication.
    /// Used for lazy window creation when a user clicks "View" on a toast.
    init(windowId: UUID, executionContext context: ExecutionContext) {
        self.windowId = windowId
        self.personaId = context.personaId
        self.session = context.chatSession
        self.foundationModelAvailable = AppConfiguration.shared.foundationModelAvailable
        self.theme = Self.loadTheme(for: context.personaId)

        self.personas = PersonaManager.shared.personas
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: context.personaId)
        self.cachedSystemPrompt = PersonaManager.shared.effectiveSystemPrompt(for: context.personaId)
        self.cachedActivePersona = personas.first { $0.id == context.personaId } ?? .default
        self.cachedPersonaDisplayName = cachedActivePersona.isBuiltIn ? "Assistant" : cachedActivePersona.name
        decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)

        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }

        if let agentSession = context.agentSession {
            self.mode = .agent
            self.agentSession = agentSession
            agentSession.windowState = self
            refreshAgentTasks()
        }

        setupNotificationObservers()
    }

    deinit {
        print("[ChatWindowState] deinit – windowId: \(windowId)")
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Stops any running execution and breaks reference chains — call when window is closing.
    func cleanup() {
        agentSession?.stopExecution()
        session.stop()
        agentSession = nil
        session.onSessionChanged = nil
    }

    // MARK: - API

    var activePersona: Persona { cachedActivePersona }

    var themeId: UUID? {
        PersonaManager.shared.themeId(for: personaId)
    }

    func switchPersona(to newPersonaId: UUID) {
        if !session.turns.isEmpty { session.save() }
        personaId = newPersonaId
        session.reset(for: newPersonaId)
        refreshTheme()
        refreshSessions()
        refreshPersonaConfig()
        PersonaManager.shared.setActivePersona(newPersonaId)
    }

    func startNewChat() {
        if !session.turns.isEmpty { session.save() }
        session.reset(for: personaId)
        refreshSessions()
    }

    // MARK: - Mode Switching

    func switchMode(to newMode: ChatMode) {
        guard newMode != mode else { return }

        // Save current chat if switching away from chat mode
        if mode == .chat && !session.turns.isEmpty {
            session.save()
        }

        mode = newMode

        // Handle agent tool registration
        if newMode == .agent {
            // Register agent-specific tools
            AgentToolManager.shared.registerTools()

            // Initialize agent session if needed
            if agentSession == nil {
                agentSession = AgentSession(personaId: personaId, windowState: self)
            }
            refreshAgentTasks()
        } else {
            // Unregister agent-specific tools when leaving agent mode
            AgentToolManager.shared.unregisterTools()
        }
    }

    func refreshAgentTasks() {
        do {
            agentTasks = try IssueStore.listTasks(personaId: personaId)
        } catch {
            print("[ChatWindowState] Failed to refresh agent tasks: \(error)")
            agentTasks = []
        }
    }

    func loadSession(_ sessionData: ChatSessionData) {
        guard sessionData.id != session.sessionId else { return }
        if !session.turns.isEmpty { session.save() }

        if let freshData = ChatSessionStore.load(id: sessionData.id) {
            session.load(from: freshData)
        } else {
            session.load(from: sessionData)
        }

        // Update theme if session has different persona
        let sessionPersonaId = sessionData.personaId ?? Persona.defaultId
        if sessionPersonaId != personaId {
            theme = Self.loadTheme(for: sessionPersonaId)
            decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)
        }
    }

    // MARK: - Refresh Methods

    func refreshPersonas() {
        personas = PersonaManager.shared.personas
        cachedActivePersona = personas.first { $0.id == personaId } ?? .default
        cachedPersonaDisplayName = cachedActivePersona.isBuiltIn ? "Assistant" : cachedActivePersona.name
    }

    func refreshSessions() {
        filteredSessions = ChatSessionsManager.shared.sessions(for: personaId)
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
        let newTheme = Self.loadTheme(for: personaId)
        // Skip if theme ID is the same (avoid unnecessary background image decoding)
        let oldThemeId = theme.customThemeConfig?.metadata.id
        let newThemeId = newTheme.customThemeConfig?.metadata.id
        guard oldThemeId != newThemeId else { return }

        theme = newTheme
        decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)
    }

    func refreshPersonaConfig() {
        cachedSystemPrompt = PersonaManager.shared.effectiveSystemPrompt(for: personaId)
        cachedActivePersona = personas.first { $0.id == personaId } ?? .default
        cachedPersonaDisplayName = cachedActivePersona.isBuiltIn ? "Assistant" : cachedActivePersona.name
        session.invalidateTokenCache()
    }

    func refreshAll() async {
        refreshPersonas()
        refreshSessions()
        refreshTheme()
        refreshPersonaConfig()
        await session.refreshModelOptions()
    }

    // MARK: - Private

    private static func loadTheme(for personaId: UUID) -> ThemeProtocol {
        if let themeId = PersonaManager.shared.themeId(for: personaId),
            let custom = ThemeManager.shared.installedThemes.first(where: { $0.metadata.id == themeId })
        {
            return CustomizableTheme(config: custom)
        }
        return ThemeManager.shared.currentTheme
    }

    private func decodeBackgroundImageAsync(themeConfig: CustomTheme?) {
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                themeConfig?.background.decodedImage()
            }.value
            self?.cachedBackgroundImage = image
        }
    }

    private func setupNotificationObservers() {
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .activePersonaChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshPersonas() } }
        )
        // Note: .chatOverlayActivated intentionally not observed here
        // State is loaded in init(), refreshAll() would cause excessive re-renders
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .appConfigurationChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshPersonaConfig() } }
        )
        // Invalidate token cache when tools or skills change (including persona overrides)
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .toolsListChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.session.invalidateTokenCache() } }
        )
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .skillsListChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.session.invalidateTokenCache() } }
        )
        // Refresh theme when global theme changes (only if persona uses global theme)
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
        // Refresh theme when current persona is updated
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .personaUpdated,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let updatedId = notification.object as? UUID
                Task { @MainActor in
                    if let self, updatedId == self.personaId { self.refreshTheme() }
                }
            }
        )
    }
}
