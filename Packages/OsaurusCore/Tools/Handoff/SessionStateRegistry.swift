//
//  SessionStateRegistry.swift
//  osaurus
//
//  Live `SessionState` per chat session. The session record is the durable
//  copy (`ChatSessionData.sessionState`); this holds the current object.
//
//  Turn contract:
//    * `finishTurn` keeps the previous object, marks it stale, and sets
//      `inFlight` to the harness's runs.
//    * `applyExtracted` replaces the stale object with the one
//      `SessionStateExtraction` wrote after the turn.
//

import Foundation

@MainActor
public final class SessionStateRegistry {
    public static let shared = SessionStateRegistry()

    private var states: [String: SessionState] = [:]

    init() {}

    /// The state the next prompt sees. Empty for an unknown session.
    public func state(for sessionId: String?) -> SessionState {
        guard let sessionId else { return .empty }
        return states[sessionId] ?? .empty
    }

    /// Load the persisted state when a session opens.
    public func seed(sessionId: String, state: SessionState?) {
        states[sessionId] = state ?? .empty
    }

    /// End the turn: mark the object stale until extraction replaces it,
    /// then overwrite `inFlight` with the harness's runs. Returns the state
    /// for persistence.
    @discardableResult
    public func finishTurn(sessionId: String, inFlight: [RunRef]) -> SessionState {
        var next = states[sessionId] ?? .empty
        next.stale = true
        next.inFlight = inFlight
        states[sessionId] = next
        return next
    }

    /// `SessionStateExtraction`'s object for the finished turn. Replaces the
    /// stale object, keeping the harness's `inFlight`. Nil, changing
    /// nothing, when the object is not stale.
    @discardableResult
    public func applyExtracted(sessionId: String, state: SessionState) -> SessionState? {
        guard let current = states[sessionId], current.stale else { return nil }
        var next = state
        next.stale = false
        next.inFlight = current.inFlight
        states[sessionId] = next
        return next
    }

    func _resetForTests() {
        states = [:]
    }
}
