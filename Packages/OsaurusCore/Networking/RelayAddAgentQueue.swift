//
//  RelayAddAgentQueue.swift
//  osaurus
//
//  The relay keeps one outstanding challenge per tunnel: a second
//  `request_challenge` replaces the first nonce, so an `add_agent` signed
//  with the first one comes back `invalid_nonce`. Turning several agents on
//  over a live tunnel (re-pairing the phone does exactly that) therefore
//  has to add them one at a time, or all but the last stay off the relay.
//  This holds that order, with a bounded retry for an attempt the relay
//  refused.
//
//  Each attempt carries a token. A challenge handler checks its token is
//  still current before it signs, so an attempt dropped while it waited
//  (turned off, retried, timed out, restarted for a new address) never sends
//  a stale `add_agent`.
//

import Foundation

struct RelayAddAgentQueue {
    /// Attempts per agent before it is given up on (shown as an error).
    static let maxAttempts = 3

    struct Attempt: Equatable {
        let agentId: UUID
        let token: UUID
        /// Set once `add_agent` has gone out: the relay's answer can only
        /// be about this attempt from then on.
        fileprivate(set) var sentAddress: String?
    }

    private(set) var waiting: [UUID] = []
    private(set) var inFlight: Attempt?
    private var attempts: [UUID: Int] = [:]

    /// Queues an agent. One already waiting stays where it is; the one in
    /// flight starts over at the front (its address may have changed), and
    /// the dropped attempt doesn't count against it.
    mutating func enqueue(_ id: UUID) {
        if inFlight?.agentId == id {
            inFlight = nil
            attempts[id, default: 1] -= 1
            waiting.insert(id, at: 0)
            return
        }
        guard !waiting.contains(id) else { return }
        waiting.append(id)
    }

    /// Drops an agent turned off before its add finished. True when it was
    /// the one in flight, so the caller can move on to the next.
    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        waiting.removeAll { $0 == id }
        attempts.removeValue(forKey: id)
        guard inFlight?.agentId == id else { return false }
        inFlight = nil
        return true
    }

    /// The next attempt, or nil while one is still in flight.
    mutating func start() -> Attempt? {
        guard inFlight == nil, !waiting.isEmpty else { return nil }
        let id = waiting.removeFirst()
        attempts[id, default: 0] += 1
        let attempt = Attempt(agentId: id, token: UUID())
        inFlight = attempt
        return attempt
    }

    func isCurrent(_ token: UUID) -> Bool {
        inFlight?.token == token
    }

    /// Whether the in-flight attempt's `add_agent` has gone out.
    var isAwaitingRelay: Bool {
        inFlight?.sentAddress != nil
    }

    /// Records that `add_agent` went out for `address`. False when the
    /// attempt is no longer current, in which case nothing should be sent.
    mutating func markSent(_ token: UUID, address: String) -> Bool {
        guard inFlight?.token == token else { return false }
        inFlight?.sentAddress = address.lowercased()
        return true
    }

    /// The relay's `agent_added` for `address`: finishes the attempt that
    /// sent it and returns its agent, or nil when it answers no current add.
    mutating func confirm(address: String) -> UUID? {
        guard let attempt = inFlight, attempt.sentAddress == address.lowercased() else { return nil }
        finish(attempt.token)
        return attempt.agentId
    }

    /// Done with the attempt (accepted, or it can't be sent at all).
    mutating func finish(_ token: UUID) {
        guard let attempt = inFlight, attempt.token == token else { return }
        attempts.removeValue(forKey: attempt.agentId)
        inFlight = nil
    }

    /// The in-flight attempt was refused or went unanswered. Puts it back
    /// at the front while attempts remain; returns it with whether it will
    /// retry.
    mutating func fail() -> (id: UUID, willRetry: Bool)? {
        guard let id = inFlight?.agentId else { return nil }
        inFlight = nil
        if attempts[id, default: 0] < Self.maxAttempts {
            waiting.insert(id, at: 0)
            return (id, true)
        }
        attempts.removeValue(forKey: id)
        return (id, false)
    }

    /// The tunnel went away; the next `connect()` authenticates every
    /// enabled agent in one frame, so nothing queued is still needed.
    mutating func reset() {
        waiting.removeAll()
        inFlight = nil
        attempts.removeAll()
    }
}
