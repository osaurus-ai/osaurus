//
//  ComputerUseFeed.swift
//  OsaurusCore — Computer Use
//
//  The legibility surface for one Computer Use run. Every perceive / propose
//  / gate / act / verify step appends a `FeedEvent`; the chat row and the
//  `ComputerUseView` panel observe the feed and render the live activity
//  pane. The loop never blocks on the feed — it just emits.
//
//  Combine-backed (like `LiveExecRegistry`) so a SwiftUI row can bind once
//  and receive the whole event stream plus the terminal status.
//

import Combine
import Foundation

/// One entry in a run's activity feed.
public struct FeedEvent: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case perceive
        case propose
        case confirmRequested = "confirm_requested"
        case confirmed
        case denied
        case blocked
        case act
        case verify
        case narrate
        case retry
        case outcome
        case error
    }

    public let id: UUID
    public let timestamp: Date
    public let step: Int
    public let kind: Kind
    public let title: String
    public let detail: String?
    /// For `act`/`verify`/`outcome`: whether it succeeded. `nil` for neutral
    /// events (perceive, propose, narrate).
    public let success: Bool?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        step: Int,
        kind: Kind,
        title: String,
        detail: String? = nil,
        success: Bool? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.step = step
        self.kind = kind
        self.title = title
        self.detail = detail
        self.success = success
    }

    /// SF Symbol the UI uses for this event kind.
    public var iconName: String {
        switch kind {
        case .perceive: return "eye"
        case .propose: return "lightbulb"
        case .confirmRequested: return "questionmark.circle"
        case .confirmed: return "checkmark.shield"
        case .denied: return "hand.raised"
        case .blocked: return "nosign"
        case .act: return "cursorarrow.rays"
        case .verify: return "checkmark.circle"
        case .narrate: return "text.bubble"
        case .retry: return "arrow.clockwise"
        case .outcome: return "flag.checkered"
        case .error: return "exclamationmark.triangle"
        }
    }
}

/// Terminal status of a run, mirrored to the UI so the row can stop its
/// spinner and show the final disposition.
public enum FeedStatus: Sendable, Equatable {
    case running
    case finished(success: Bool, summary: String)
}

/// Observable activity feed for a single run. Thread-safe: the loop emits
/// from whatever context it runs on; the UI subscribes on main.
public final class ComputerUseFeed: @unchecked Sendable {
    public let toolCallId: String
    public let goal: String
    public let startedAt: Date

    private let lock = NSLock()
    private var _events: [FeedEvent] = []

    private nonisolated(unsafe) let eventsSubject: CurrentValueSubject<[FeedEvent], Never>
    private nonisolated(unsafe) let statusSubject: CurrentValueSubject<FeedStatus, Never>

    public init(toolCallId: String, goal: String) {
        self.toolCallId = toolCallId
        self.goal = goal
        self.startedAt = Date()
        self.eventsSubject = CurrentValueSubject([])
        self.statusSubject = CurrentValueSubject(.running)
    }

    public var eventsPublisher: AnyPublisher<[FeedEvent], Never> {
        eventsSubject.eraseToAnyPublisher()
    }

    public var statusPublisher: AnyPublisher<FeedStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    public func currentEvents() -> [FeedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    public func currentStatus() -> FeedStatus { statusSubject.value }

    /// Append an event and notify observers.
    public func emit(_ event: FeedEvent) {
        lock.lock()
        _events.append(event)
        let snapshot = _events
        lock.unlock()
        eventsSubject.send(snapshot)
    }

    /// Mark the run finished. Idempotent.
    public func finish(success: Bool, summary: String) {
        if case .finished = statusSubject.value { return }
        statusSubject.send(.finished(success: success, summary: summary))
    }
}
