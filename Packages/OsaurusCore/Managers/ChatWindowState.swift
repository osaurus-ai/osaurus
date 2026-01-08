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
    @Published private(set) var cachedToolList: [ToolRegistry.ToolEntry] = []
    @Published private(set) var cachedSystemPrompt: String = ""
    @Published private(set) var cachedToolOverrides: [String: Bool]?
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
        self.cachedToolOverrides = PersonaManager.shared.effectiveToolOverrides(for: personaId)
        self.cachedToolList = ToolRegistry.shared.listTools(withOverrides: cachedToolOverrides)
        self.cachedSystemPrompt = PersonaManager.shared.effectiveSystemPrompt(for: personaId)
        self.cachedBackgroundImage = theme.customThemeConfig?.background.decodedImage()
        self.cachedActivePersona = personas.first { $0.id == personaId } ?? .default
        self.cachedPersonaDisplayName = cachedActivePersona.isBuiltIn ? "Assistant" : cachedActivePersona.name

        // Configure session
        self.session.personaId = personaId
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
            cachedBackgroundImage = theme.customThemeConfig?.background.decodedImage()
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

    func refreshTheme() {
        theme = Self.loadTheme(for: personaId)
        cachedBackgroundImage = theme.customThemeConfig?.background.decodedImage()
    }

    func refreshToolList() {
        cachedToolOverrides = PersonaManager.shared.effectiveToolOverrides(for: personaId)
        cachedToolList = ToolRegistry.shared.listTools(withOverrides: cachedToolOverrides)
    }

    func refreshPersonaConfig() {
        cachedSystemPrompt = PersonaManager.shared.effectiveSystemPrompt(for: personaId)
        cachedActivePersona = personas.first { $0.id == personaId } ?? .default
        cachedPersonaDisplayName = cachedActivePersona.isBuiltIn ? "Assistant" : cachedActivePersona.name
        refreshToolList()
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

    private func setupNotificationObservers() {
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .activePersonaChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshPersonas() } }
        )
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .chatOverlayActivated,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in await self?.refreshAll() } }
        )
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .appConfigurationChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshPersonaConfig() } }
        )
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .toolsListChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshToolList() } }
        )
    }
}
