//
//  EventSourceAdapter.swift
//  osaurus
//
//  The runtime half of a source kind (the static half is its
//  `EventSourceDescriptor`). `EventManager` owns one adapter per kind and
//  drives every one of them the same way: start on launch, reconcile when
//  the event set changes, forget/cancel per event, install/uninstall
//  provider-side setup on enable/disable, and Run Now. Adapters hand
//  occurrences to `EventManager.submit`; admission, dedupe, queueing and
//  the ledger are shared.
//

import Foundation

/// What a source is doing for one event, for the list, the detail view and
/// `osaurus_inspect`.
public struct EventSourceStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Folder convergence loop.
        case folder(WatcherPhase)
        /// A poll tick is fetching.
        case polling
        /// A stream is connecting / connected.
        case connecting
        case connected
        /// No enabled event needs the scope.
        case paused
    }

    public var phase: Phase = .idle
    public var lastTickAt: Date?
    public var nextTickAt: Date?
    public var lastError: String?
    /// Provider-side setup (webhook registration, subscription): nil when
    /// the kind has none.
    public var installed: Bool?
    /// Human-readable cursor (`uidvalidity:uid`, last received date).
    public var cursor: String?
    /// A condition worth showing that is not an error ("Mail is not running").
    public var note: String?

    public init(
        phase: Phase = .idle, lastTickAt: Date? = nil, nextTickAt: Date? = nil, lastError: String? = nil,
        installed: Bool? = nil, cursor: String? = nil, note: String? = nil
    ) {
        self.phase = phase
        self.lastTickAt = lastTickAt
        self.nextTickAt = nextTickAt
        self.lastError = lastError
        self.installed = installed
        self.cursor = cursor
        self.note = note
    }

    /// Work in flight that the list shows as running. A poll is a check,
    /// not a run, so it does not count.
    public var isActive: Bool {
        switch phase {
        case .folder(let watcher): watcher != .idle
        case .idle, .polling, .connecting, .connected, .paused: false
        }
    }

    public var folderPhase: WatcherPhase? {
        if case .folder(let watcher) = phase { return watcher }
        return nil
    }

    var isEmpty: Bool { self == EventSourceStatus() }

    /// Fields for `osaurus_inspect`.
    var inspection: [String: Any] {
        var out: [String: Any] = ["phase": phaseLabel]
        if let lastTickAt { out["last_tick_at"] = EventPayload.iso8601(lastTickAt) }
        if let nextTickAt { out["next_tick_at"] = EventPayload.iso8601(nextTickAt) }
        if let lastError { out["last_error"] = lastError }
        if let installed { out["installed"] = installed }
        if let cursor { out["cursor"] = cursor }
        if let note { out["note"] = note }
        return out
    }

    var phaseLabel: String {
        switch phase {
        case .idle: "idle"
        case .folder(let watcher): "folder_\(watcher.rawValue)"
        case .polling: "polling"
        case .connecting: "connecting"
        case .connected: "connected"
        case .paused: "paused"
        }
    }
}

extension EventSourceStatus {
    /// Folds a runtime report into the status the views show.
    mutating func apply(_ report: SourceRuntimeReport) {
        switch report {
        case .ticking:
            phase = .polling
        case .ticked(let at, let next):
            phase = .idle
            lastTickAt = at
            nextTickAt = next
            lastError = nil
        case .failed(let at, let error, let next):
            phase = .idle
            lastTickAt = at
            nextTickAt = next
            lastError = error
        case .connecting:
            phase = .connecting
        case .connected:
            phase = .connected
            nextTickAt = nil
            lastError = nil
        case .disconnected(let error, let retryAt):
            phase = .connecting
            lastError = error
            nextTickAt = retryAt
        case .stopped:
            phase = .paused
            nextTickAt = nil
        }
    }
}

@MainActor
protocol EventSourceAdapter: AnyObject {
    var kind: EventSourceKind { get }
    /// Launch work after events load (missed schedule slots, stream connects).
    func start() async
    func stop()
    /// The event set changed: re-arm timers, streams, poll scopes.
    func reconcile(_ events: [OsaurusEvent]) async
    /// Drop all runtime state for an event (deleted or source replaced).
    func forget(_ eventId: UUID)
    /// Stop in-flight source work for an event (Stop Runs, disable).
    func cancel(_ eventId: UUID)
    /// Provider-side setup: register a webhook, start a subscription. Called
    /// when an event is created or enabled; `uninstall` when it is disabled,
    /// deleted or re-sourced; `reconcileInstalled` on launch. State persists
    /// in `event_source_state`.
    func install(_ event: OsaurusEvent) async throws
    func uninstall(_ event: OsaurusEvent) async
    func reconcileInstalled(_ events: [OsaurusEvent]) async
    /// An event of this kind was saved: created (`previous` nil) or
    /// edited, including turned on or off. Not called for run bookkeeping.
    func eventDidChange(_ event: OsaurusEvent, previous: OsaurusEvent?)
    /// The latest real item for Run Now; nil means use the config's sample.
    func sample(for event: OsaurusEvent) async -> JSONValue?
    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult
    func status(_ eventId: UUID) -> EventSourceStatus
}

extension JSONValue {
    /// Adapter state round-trip: a Codable value as stored JSON.
    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: EventStore.encoder.encode(value))
    }

    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try EventStore.decoder.decode(T.self, from: JSONEncoder().encode(self))
    }
}

extension EventSourceAdapter {
    func start() async {}
    func forget(_ eventId: UUID) {}
    func cancel(_ eventId: UUID) {}
    func install(_ event: OsaurusEvent) async throws {}
    func uninstall(_ event: OsaurusEvent) async {}
    func reconcileInstalled(_ events: [OsaurusEvent]) async {}
    func eventDidChange(_ event: OsaurusEvent, previous: OsaurusEvent?) {}
    func sample(for event: OsaurusEvent) async -> JSONValue? { nil }
}
