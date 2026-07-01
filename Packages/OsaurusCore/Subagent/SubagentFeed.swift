//
//  SubagentFeed.swift
//  OsaurusCore — Subagent framework
//
//  The unified legibility surface for any nested subagent run. Generalized
//  from `ComputerUseFeed`/`FeedEvent`/`ComputerUseFeedRegistry`/
//  `ComputerUseInterruptCenter` so spawn, image, and computer_use all
//  emit onto ONE feed type and the chat row binds ONE
//  surface (`NativeToolCallGroupView`) for every subagent row.
//
//  `SubagentActivityEvent` is a superset of the old computer-use `FeedEvent`:
//  it keeps the rich perceive/propose/act/verify kinds AND adds generic
//  `phase`/`progress` kinds so a text-spawn handoff or an image generation
//  job can render a live row too (fixing the text-spawn "frozen turn" gap).
//
//  Combine-backed (like `LiveExecRegistry`) so a SwiftUI row binds once and
//  receives the whole event stream plus the terminal status. The loop never
//  blocks on the feed — it just emits.
//

import Combine
import Foundation

// MARK: - Event

/// One entry in a subagent run's activity feed.
public struct SubagentActivityEvent: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        // Generic lifecycle kinds (every subagent).
        /// A lifecycle phase change (resolving / handoff / running / restoring).
        case phase
        /// Quantitative progress (image gen step %, loop iteration).
        case progress
        /// Free-form human-readable narration.
        case narrate
        /// Terminal outcome.
        case outcome
        /// An error step.
        case error

        // Rich computer-use kinds (preserved so computer_use adopts this feed
        // without losing fidelity).
        case perceive
        case propose
        case confirmRequested = "confirm_requested"
        case confirmed
        case denied
        case blocked
        case act
        case verify
        case retry
    }

    public let id: UUID
    public let timestamp: Date
    /// Step index (perceive→act cycle, loop iteration, or image step). `0`
    /// for lifecycle phases that aren't tied to a step.
    public let step: Int
    public let kind: Kind
    public let title: String
    public let detail: String?
    /// For `act`/`verify`/`outcome`: whether it succeeded. `nil` for neutral
    /// events (perceive, propose, narrate, phase).
    public let success: Bool?
    /// For `progress`: completion in `0...1` when known (e.g. image gen).
    public let fraction: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        step: Int = 0,
        kind: Kind,
        title: String,
        detail: String? = nil,
        success: Bool? = nil,
        fraction: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.step = step
        self.kind = kind
        self.title = title
        self.detail = detail
        self.success = success
        self.fraction = fraction
    }

    /// SF Symbol the UI uses for this event kind.
    public var iconName: String {
        switch kind {
        case .phase: return "circle.dashed"
        case .progress: return "gauge.with.dots.needle.33percent"
        case .narrate: return "text.bubble"
        case .outcome: return "flag.checkered"
        case .error: return "exclamationmark.triangle"
        case .perceive: return "eye"
        case .propose: return "lightbulb"
        case .confirmRequested: return "questionmark.circle"
        case .confirmed: return "checkmark.shield"
        case .denied: return "hand.raised"
        case .blocked: return "nosign"
        case .act: return "cursorarrow.rays"
        case .verify: return "checkmark.circle"
        case .retry: return "arrow.clockwise"
        }
    }
}

// MARK: - Status

/// Terminal status of a subagent run, mirrored to the UI so the row can
/// stop its spinner and show the final disposition.
public enum SubagentRunStatus: Sendable, Equatable {
    case running
    case finished(success: Bool, summary: String)
}

// MARK: - Feed

/// Observable activity feed for a single subagent run. Thread-safe: the
/// loop emits from whatever context it runs on; the UI subscribes on main.
public final class SubagentFeed: @unchecked Sendable {
    /// The originating tool-call id — the key the chat row binds by.
    public let toolCallId: String
    /// Stable kind id of the running subagent (`"spawn"`, `"image"`, …).
    public let kindId: String
    /// One-line human label for the row header (the goal / task / prompt).
    public let title: String
    public let startedAt: Date

    private let lock = NSLock()
    private var _events: [SubagentActivityEvent] = []

    private nonisolated(unsafe) let eventsSubject: CurrentValueSubject<[SubagentActivityEvent], Never>
    private nonisolated(unsafe) let statusSubject: CurrentValueSubject<SubagentRunStatus, Never>

    public init(toolCallId: String, kindId: String, title: String) {
        self.toolCallId = toolCallId
        self.kindId = kindId
        self.title = title
        self.startedAt = Date()
        self.eventsSubject = CurrentValueSubject([])
        self.statusSubject = CurrentValueSubject(.running)
    }

    public var eventsPublisher: AnyPublisher<[SubagentActivityEvent], Never> {
        eventsSubject.eraseToAnyPublisher()
    }

    public var statusPublisher: AnyPublisher<SubagentRunStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    public func currentEvents() -> [SubagentActivityEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    public func currentStatus() -> SubagentRunStatus { statusSubject.value }

    /// Mutate the event buffer under the lock and publish the resulting
    /// snapshot — the single funnel every event change flows through, so the
    /// lock and the `send` can never drift apart.
    private func mutateEvents(_ body: (inout [SubagentActivityEvent]) -> Void) {
        lock.lock()
        body(&_events)
        let snapshot = _events
        lock.unlock()
        eventsSubject.send(snapshot)
    }

    /// Append an event and notify observers.
    public func emit(_ event: SubagentActivityEvent) {
        mutateEvents { $0.append(event) }
    }

    /// Convenience: emit a lifecycle phase row.
    public func emitPhase(_ title: String, detail: String? = nil) {
        emit(SubagentActivityEvent(kind: .phase, title: title, detail: detail))
    }

    /// Convenience: emit a progress row (fraction in `0...1` when known).
    ///
    /// Consecutive progress emissions with the SAME `title` update the existing
    /// row in place — reusing its `id` + `timestamp` so SwiftUI animates the
    /// bar/detail instead of inserting a new row per tick. This keeps an image
    /// job showing ONE "generating" row whose progress advances, rather than a
    /// row per step. A different title, or any non-progress event emitted in
    /// between, starts a fresh row.
    public func emitProgress(
        _ title: String,
        fraction: Double? = nil,
        step: Int = 0,
        detail: String? = nil
    ) {
        mutateEvents { events in
            let coalesce = events.last.map { $0.kind == .progress && $0.title == title } ?? false
            let event = SubagentActivityEvent(
                id: coalesce ? events[events.count - 1].id : UUID(),
                timestamp: coalesce ? events[events.count - 1].timestamp : Date(),
                step: step,
                kind: .progress,
                title: title,
                detail: detail,
                fraction: fraction
            )
            if coalesce {
                events[events.count - 1] = event
            } else {
                events.append(event)
            }
        }
    }

    /// Mark the run finished. Idempotent.
    public func finish(success: Bool, summary: String) {
        if case .finished = statusSubject.value { return }
        statusSubject.send(.finished(success: success, summary: summary))
    }
}

// MARK: - Registry

/// Process-wide map from a subagent tool-call id to its live `SubagentFeed`,
/// mirroring `LiveExecRegistry` for shell tools. The host registers the feed
/// when a run starts; the chat row binds by tool-call id to render the inline
/// activity pane, and unregisters after a short grace tail so a row that
/// mounts just after a fast run finishes can still replay events + status.
public final class SubagentFeedRegistry: @unchecked Sendable {
    public static let shared = SubagentFeedRegistry()

    private let lock = NSLock()
    private var feeds: [String: SubagentFeed] = [:]
    private var pendingDrops: [String: Task<Void, Never>] = [:]

    private nonisolated(unsafe) let feedsSubject = CurrentValueSubject<[String: SubagentFeed], Never>(
        [:])

    private init() {}

    /// Grace window between `unregister` and the feed being dropped, so a
    /// late-mounting row still binds, replays events, and sees the final
    /// status. Matches `LiveExecRegistry.dropGrace`.
    private static let dropGrace: TimeInterval = 5

    /// Live snapshot of every registered feed. The chat layer subscribes once
    /// and attaches the matching feed to each subagent tool-call row by id.
    public var feedsPublisher: AnyPublisher<[String: SubagentFeed], Never> {
        feedsSubject.eraseToAnyPublisher()
    }

    /// Synchronous lookup so a cell can decide "live pane vs. static result"
    /// inline without awaiting a publisher tick.
    public func feed(for toolCallId: String) -> SubagentFeed? {
        lock.lock()
        defer { lock.unlock() }
        return feeds[toolCallId]
    }

    public func register(_ feed: SubagentFeed) {
        lock.lock()
        pendingDrops.removeValue(forKey: feed.toolCallId)?.cancel()
        feeds[feed.toolCallId] = feed
        let snapshot = feeds
        lock.unlock()
        feedsSubject.send(snapshot)
    }

    /// Schedule the feed for removal after the grace window.
    public func unregister(toolCallId: String) {
        lock.lock()
        pendingDrops.removeValue(forKey: toolCallId)?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.dropGrace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.drop(toolCallId: toolCallId)
        }
        pendingDrops[toolCallId] = task
        lock.unlock()
    }

    private func drop(toolCallId: String) {
        lock.lock()
        pendingDrops.removeValue(forKey: toolCallId)
        feeds.removeValue(forKey: toolCallId)
        let snapshot = feeds
        lock.unlock()
        feedsSubject.send(snapshot)
    }

    /// Drop a single feed immediately (no grace), without disturbing other
    /// live runs the way `clearAll()` would. Used by the stop path and by
    /// tests that must avoid racing the shared singleton.
    public func removeNow(toolCallId: String) {
        drop(toolCallId: toolCallId)
    }

    /// Test-only: drop everything immediately.
    public func clearAll() {
        lock.lock()
        for (_, task) in pendingDrops { task.cancel() }
        pendingDrops.removeAll()
        feeds.removeAll()
        lock.unlock()
        feedsSubject.send([:])
    }
}

// MARK: - Interrupt center

/// Process-wide registry mapping a run's tool-call id to its `InterruptToken`,
/// so a feed pane's stop button can reach the running loop without tearing
/// down the whole chat turn. Generalized from `ComputerUseInterruptCenter`.
public final class SubagentInterruptCenter: @unchecked Sendable {
    public static let shared = SubagentInterruptCenter()

    private let lock = NSLock()
    private var tokens: [String: InterruptToken] = [:]

    private init() {}

    public func register(_ token: InterruptToken, for toolCallId: String) {
        lock.lock()
        tokens[toolCallId] = token
        lock.unlock()
    }

    public func unregister(_ toolCallId: String) {
        lock.lock()
        tokens.removeValue(forKey: toolCallId)
        lock.unlock()
    }

    /// Trip the token for a run, if one is registered. Returns whether a
    /// token was found.
    @discardableResult
    public func interrupt(_ toolCallId: String) -> Bool {
        lock.lock()
        let token = tokens[toolCallId]
        lock.unlock()
        token?.interrupt()
        return token != nil
    }
}
