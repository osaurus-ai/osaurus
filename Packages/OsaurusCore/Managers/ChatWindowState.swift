//
//  ChatWindowState.swift
//  osaurus
//
//  Per-window state container that isolates each ChatView window from shared singletons.
//  This eliminates cross-window re-renders caused by @Published changes in shared managers.
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// Per-window state container for ChatView
/// Each window creates its own instance - NOT a singleton
@MainActor
final class ChatWindowState: ObservableObject {
    // MARK: - Identity

    /// Unique identifier for this window
    let windowId: UUID

    // MARK: - Persona State (Local to this window)

    /// This window's persona ID
    @Published var personaId: UUID

    /// Cached list of all personas (refreshed on demand)
    @Published private(set) var personas: [Persona] = []

    // MARK: - Theme State (Local to this window)

    /// This window's cached theme (not reactively bound to ThemeManager)
    @Published private(set) var theme: ThemeProtocol

    // MARK: - Session State

    /// The chat session for this window
    let session: ChatSession

    /// Cached filtered sessions for sidebar (refreshed on demand)
    @Published private(set) var filteredSessions: [ChatSessionData] = []

    // MARK: - Private State

    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []

    // MARK: - Initialization

    /// Create a new window state
    /// - Parameters:
    ///   - windowId: Unique identifier for this window
    ///   - personaId: Initial persona ID for this window
    ///   - sessionData: Optional existing session data to load
    init(
        windowId: UUID,
        personaId: UUID,
        sessionData: ChatSessionData? = nil
    ) {
        self.windowId = windowId
        self.personaId = personaId

        // Create session
        self.session = ChatSession()

        // Load theme for this persona (cached snapshot, not reactive)
        self.theme = Self.loadTheme(for: personaId)

        // Load initial data
        self.personas = PersonaManager.shared.personas
        self.filteredSessions = Self.loadFilteredSessions(for: personaId)

        // Configure session with persona
        self.session.personaId = personaId

        // Load session data if provided
        if let data = sessionData {
            self.session.load(from: data)
        }

        // Set up session change callback
        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessions()
        }

        // Subscribe to notifications for on-demand refresh
        setupNotificationObservers()
    }

    deinit {
        // Clean up notification observers
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - API

    /// The currently active persona object
    var activePersona: Persona {
        personas.first { $0.id == personaId } ?? Persona.default
    }

    /// Switch this window to a different persona
    /// - Parameter newPersonaId: The persona ID to switch to
    func switchPersona(to newPersonaId: UUID) {
        // Save current session before switching
        if !session.turns.isEmpty {
            session.save()
        }

        // Update persona
        personaId = newPersonaId

        // Reset session for new persona
        session.reset(for: newPersonaId)

        // Reload theme for new persona
        refreshTheme()

        // Reload filtered sessions for new persona
        refreshSessions()
    }

    /// Start a new chat within this window (keeps same persona)
    func startNewChat() {
        // Save current session
        if !session.turns.isEmpty {
            session.save()
        }

        // Reset session with same persona
        session.reset(for: personaId)

        // Refresh sessions list
        refreshSessions()
    }

    /// Load a session from the sidebar
    /// - Parameter sessionData: The session to load
    func loadSession(_ sessionData: ChatSessionData) {
        // Don't reload if already on this session
        guard sessionData.id != session.sessionId else { return }

        // Save current session before switching
        if !session.turns.isEmpty {
            session.save()
        }

        // Load fresh data from store
        if let freshData = ChatSessionStore.load(id: sessionData.id) {
            session.load(from: freshData)
        } else {
            session.load(from: sessionData)
        }

        // Apply theme based on the session's persona (if different)
        let sessionPersonaId = sessionData.personaId ?? Persona.defaultId
        if sessionPersonaId != personaId {
            // Session has a different persona - update our local theme
            theme = Self.loadTheme(for: sessionPersonaId)
        }
    }

    // MARK: - Refresh Methods

    /// Refresh the cached personas list
    func refreshPersonas() {
        personas = PersonaManager.shared.personas
    }

    /// Refresh the cached filtered sessions list
    func refreshSessions() {
        filteredSessions = Self.loadFilteredSessions(for: personaId)
    }

    /// Refresh the cached theme for current persona
    func refreshTheme() {
        theme = Self.loadTheme(for: personaId)
    }

    /// Refresh all cached data
    func refreshAll() {
        refreshPersonas()
        refreshSessions()
        refreshTheme()
        session.refreshModelOptions()
    }

    // MARK: - Theme Helpers

    /// Get the effective system prompt for this window's persona
    var effectiveSystemPrompt: String {
        PersonaManager.shared.effectiveSystemPrompt(for: personaId)
    }

    /// Get the effective tool overrides for this window's persona
    var effectiveToolOverrides: [String: Bool]? {
        PersonaManager.shared.effectiveToolOverrides(for: personaId)
    }

    /// Get the theme ID for this window's persona
    var themeId: UUID? {
        PersonaManager.shared.themeId(for: personaId)
    }

    // MARK: - Private Helpers

    /// Load the theme for a persona (returns a snapshot, not a reactive binding)
    private static func loadTheme(for personaId: UUID) -> ThemeProtocol {
        let themeManager = ThemeManager.shared
        let personaManager = PersonaManager.shared

        // Check if persona has a custom theme
        if let themeId = personaManager.themeId(for: personaId),
            let customTheme = themeManager.installedThemes.first(where: { $0.metadata.id == themeId })
        {
            return CustomizableTheme(config: customTheme)
        }

        // Fall back to current global theme
        return themeManager.currentTheme
    }

    /// Load filtered sessions for a persona
    private static func loadFilteredSessions(for personaId: UUID) -> [ChatSessionData] {
        ChatSessionsManager.shared.sessions(for: personaId)
    }

    /// Set up notification observers for optional refresh
    private func setupNotificationObservers() {
        // Observe persona changes (for sidebar refresh when personas are edited)
        let personaObserver = NotificationCenter.default.addObserver(
            forName: .activePersonaChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Only refresh personas list, don't change our persona
                self?.refreshPersonas()
            }
        }
        notificationObservers.append(personaObserver)

        // Observe chat overlay activation (for focus)
        let activationObserver = NotificationCenter.default.addObserver(
            forName: .chatOverlayActivated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
        notificationObservers.append(activationObserver)
    }
}
