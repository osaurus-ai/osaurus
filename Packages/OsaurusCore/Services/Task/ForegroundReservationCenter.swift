//
//  ForegroundReservationCenter.swift
//  osaurus
//
//  Interactive work — a chat turn, an API client holding a connection
//  open — is never queued. It takes a reservation for the duration of the
//  turn so the scheduler can yield background work that would disturb it.
//  A reservation never delays the send that took it.
//
//  Thread-safe: NIO handlers reserve and release off the main actor.
//

import Foundation
import os

public final class ForegroundReservationCenter: @unchecked Sendable {
    public static let shared = ForegroundReservationCenter(recordsHistory: true)

    private let state = OSAllocatedUnfairLock(initialState: [UUID: ForegroundReservation]())
    /// Main-actor hooks run after every change (schedulers re-pump).
    @MainActor private var listeners: [@MainActor () -> Void] = []
    /// Journals reservations into the shared task store.
    private let recordsHistory: Bool

    public init(recordsHistory: Bool = false) {
        self.recordsHistory = recordsHistory
    }

    /// Reservations currently held.
    public var active: [ForegroundReservation] {
        state.withLock { Array($0.values) }.sorted { $0.startedAt < $1.startedAt }
    }

    public var localActive: [ForegroundReservation] { active.filter(\.isLocal) }

    /// Takes a reservation. `model` is the picker id; whether it runs on
    /// this Mac is resolved from the installed-model cache.
    @discardableResult
    public func reserve(owner: String, kind: ForegroundReservation.Kind, model: String?) -> UUID {
        let resolved = Self.resolve(model: model)
        let reservation = ForegroundReservation(
            owner: owner, kind: kind, model: resolved.model, isLocal: resolved.isLocal)
        state.withLock { $0[reservation.id] = reservation }
        changed(reservation)
        return reservation.id
    }

    /// Releases a reservation. Idempotent.
    public func release(_ id: UUID?) {
        guard let id else { return }
        let removed = state.withLock { $0.removeValue(forKey: id) }
        guard var removed else { return }
        removed.endedAt = Date()
        changed(removed)
    }

    @MainActor
    public func addListener(_ listener: @escaping @MainActor () -> Void) {
        listeners.append(listener)
    }

    private func changed(_ reservation: ForegroundReservation) {
        let snapshot = active
        let journal = recordsHistory
        Task { @MainActor in
            if journal {
                TaskStore.shared.recordReservation(reservation)
                TaskStore.shared.bus.publish(.reservationsChanged(snapshot))
            }
            for listener in self.listeners { listener() }
        }
    }

    /// The canonical id and locality of a picker model. Unknown and remote
    /// models are not local: they hold no local RAM.
    public static func resolve(model: String?) -> (model: String?, isLocal: Bool) {
        guard let model, !model.isEmpty else { return (nil, false) }
        if let installed = ModelManager.findInstalledModelFromCache(named: model) {
            return (installed.id.lowercased(), true)
        }
        return (model, false)
    }

    #if DEBUG
        /// Test hook: a reservation with an explicit locality.
        @discardableResult
        func reserveForTesting(owner: String, model: String, isLocal: Bool) -> UUID {
            let reservation = ForegroundReservation(owner: owner, kind: .chat, model: model, isLocal: isLocal)
            state.withLock { $0[reservation.id] = reservation }
            changed(reservation)
            return reservation.id
        }
    #endif
}
