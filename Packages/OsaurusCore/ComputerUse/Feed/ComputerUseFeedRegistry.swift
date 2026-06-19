//
//  ComputerUseFeedRegistry.swift
//  OsaurusCore — Computer Use
//
//  Process-wide map from a `computer_use` tool-call id to its live
//  `ComputerUseFeed`, mirroring `LiveExecRegistry` for shell tools. The
//  entry tool registers the feed when a run starts; the chat row binds to
//  it by tool-call id to render the inline activity pane, and unregisters
//  after a short grace tail so a row that mounts just after a fast run
//  finishes can still replay the events and see the terminal status.
//

import Combine
import Foundation

/// Observable registry of running (and recently finished) Computer Use feeds.
/// Thread-safe via an internal lock; the loop registers/looks-up from any
/// context and the UI subscribes on main.
public final class ComputerUseFeedRegistry: @unchecked Sendable {
    public static let shared = ComputerUseFeedRegistry()

    private let lock = NSLock()
    private var feeds: [String: ComputerUseFeed] = [:]
    private var pendingDrops: [String: Task<Void, Never>] = [:]

    private nonisolated(unsafe) let feedsSubject = CurrentValueSubject<[String: ComputerUseFeed], Never>(
        [:])

    private init() {}

    /// Grace window between `unregister` and the feed being dropped, so a
    /// late-mounting row still binds, replays events, and sees the final
    /// status. Matches the spirit of `LiveExecRegistry.dropGrace`.
    private static let dropGrace: TimeInterval = 5

    /// Live snapshot of every registered feed. The chat layer subscribes once
    /// and attaches the matching feed to each `computer_use` tool-call row by id.
    public var feedsPublisher: AnyPublisher<[String: ComputerUseFeed], Never> {
        feedsSubject.eraseToAnyPublisher()
    }

    /// Synchronous lookup so a cell can decide "live pane vs. static result"
    /// inline without awaiting a publisher tick.
    public func feed(for toolCallId: String) -> ComputerUseFeed? {
        lock.lock()
        defer { lock.unlock() }
        return feeds[toolCallId]
    }

    public func register(_ feed: ComputerUseFeed) {
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
