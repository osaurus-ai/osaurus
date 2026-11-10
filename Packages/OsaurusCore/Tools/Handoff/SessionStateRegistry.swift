//
//  SessionStateRegistry.swift
//  osaurus
//
//  Live `SessionState` per chat session. The session record is the durable
//  copy (`ChatSessionData.sessionState`); this holds the current object and
//  the turn's pending `state` write between the tool call and the end of
//  the turn.
//
//  Turn contract:
//    * `state` calls during a turn replace the pending write; the last wins.
//    * `finishTurn` commits the pending write (clearing `stale`), or keeps
//      the previous object and marks it stale when the turn made none.
//    * `inFlight` is always the harness's list, whatever the model wrote.
//    * `applyExtracted` replaces a stale object with the one
//      `SessionStateExtraction` wrote after the turn.
//

import Foundation

@MainActor
public final class SessionStateRegistry {
    public static let shared = SessionStateRegistry()

    private var states: [String: SessionState] = [:]
    private var pending: [String: SessionState] = [:]

    init() {}

    /// The state the next prompt sees. Empty for an unknown session.
    public func state(for sessionId: String?) -> SessionState {
        guard let sessionId else { return .empty }
        return states[sessionId] ?? .empty
    }

    /// Load the persisted state when a session opens. Leaves a pending
    /// write alone.
    public func seed(sessionId: String, state: SessionState?) {
        states[sessionId] = state ?? .empty
    }

    /// A model `state` call. Replaces any earlier write this turn.
    public func recordModelWrite(sessionId: String, state: SessionState) {
        pending[sessionId] = state
    }

    /// Whether this turn has written state yet.
    public func hasPendingWrite(sessionId: String) -> Bool {
        pending[sessionId] != nil
    }

    /// Drop a pending write without committing it (cancelled turn).
    public func discardPending(sessionId: String) {
        pending[sessionId] = nil
    }

    /// End the turn: commit or mark stale, then overwrite `inFlight` with
    /// the harness's runs. Returns the committed state for persistence.
    @discardableResult
    public func finishTurn(sessionId: String, inFlight: [RunRef]) -> SessionState {
        var next: SessionState
        if let write = pending.removeValue(forKey: sessionId) {
            next = write
            next.stale = false
        } else {
            next = states[sessionId] ?? .empty
            next.stale = true
        }
        next.inFlight = inFlight
        states[sessionId] = next
        return next
    }

    /// `SessionStateExtraction`'s object for a turn that ended without a
    /// `state` call. Replaces the stale object, keeping the harness's
    /// `inFlight`. Nil, changing nothing, when the object is not stale.
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
        pending = [:]
    }
}
