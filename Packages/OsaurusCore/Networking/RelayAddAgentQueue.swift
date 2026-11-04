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

import Foundation

struct RelayAddAgentQueue {
    /// Attempts per agent before it is given up on (shown as an error).
    static let maxAttempts = 3

    private(set) var waiting: [UUID] = []
    private(set) var inFlight: UUID?
    private var attempts: [UUID: Int] = [:]

    /// Queues an agent unless it is already waiting or in flight.
    mutating func enqueue(_ id: UUID) {
        guard inFlight != id, !waiting.contains(id) else { return }
        waiting.append(id)
    }

    /// Drops an agent turned off before its add finished. True when it was
    /// the one in flight, so the caller can move on to the next.
    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        waiting.removeAll { $0 == id }
        attempts.removeValue(forKey: id)
        guard inFlight == id else { return false }
        inFlight = nil
        return true
    }

    /// The next agent to add, or nil while one is still in flight.
    mutating func start() -> UUID? {
        guard inFlight == nil, !waiting.isEmpty else { return nil }
        let id = waiting.removeFirst()
        inFlight = id
        attempts[id, default: 0] += 1
        return id
    }

    /// The relay accepted `id` (or it can't be added at all): done with it.
    mutating func finish(_ id: UUID) {
        attempts.removeValue(forKey: id)
        if inFlight == id { inFlight = nil }
        waiting.removeAll { $0 == id }
    }

    /// The in-flight add was refused or went unanswered. Puts it back at the
    /// front while attempts remain; returns it with whether it will retry.
    mutating func fail() -> (id: UUID, willRetry: Bool)? {
        guard let id = inFlight else { return nil }
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
