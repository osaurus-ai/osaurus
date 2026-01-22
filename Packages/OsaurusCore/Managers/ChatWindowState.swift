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
            self?.refreshSessions()
        }

        setupNotificationObservers()
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
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
    }

    func startNewChat() {
        if !session.turns.isEmpty { session.save() }
        session.reset(for: personaId)
        refreshSessions()
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
        // Refresh the global sessions manager from disk first
        ChatSessionsManager.shared.refresh()
        // Then get the filtered sessions for this persona
        filteredSessions = ChatSessionsManager.shared.sessions(for: personaId)
    }

    func refreshTheme() {
        theme = Self.loadTheme(for: personaId)
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
        Task {
            let image = await Task.detached(priority: .utility) {
                themeConfig?.background.decodedImage()
            }.value
            self.cachedBackgroundImage = image
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
    }
}
