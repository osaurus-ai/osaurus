//
//  AttentionCenter.swift
//  osaurus
//
//  The hub for every "a person is needed" moment. Producers (approval
//  queues, clarify, workflow dialogs, channel inbound, shared-agent runs)
//  `raise` an item with a resolver; the center fans it out to notification
//  channels filtered by `NotificationPreferences`, and whichever surface
//  answers first — the inline card, a desktop notification action, the
//  paired phone — calls `resolve`, which runs the producer's resolver once
//  and retracts the item everywhere else.
//
//  The center never owns a continuation: the producer keeps its own wait and
//  only learns the answer through the resolver. In-memory by design — a
//  pending item belongs to a live run, and a relaunch ends that run.
//

import Combine
import Foundation

@MainActor
final class AttentionCenter: ObservableObject {
    static let shared = AttentionCenter()

    typealias Resolver = @MainActor (AttentionResolution) -> Void

    /// Pending items, oldest first.
    @Published private(set) var pending: [AttentionItem] = []
    /// Recently settled items, newest first (bounded).
    @Published private(set) var recent: [AttentionItem] = []

    private var resolvers: [UUID: Resolver] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var channels: [any NotificationChannel] = []
    private var continuations: [UUID: AsyncStream<AttentionEvent>.Continuation] = [:]
    private var observers: [UUID: @MainActor (AttentionEvent) -> Void] = [:]

    /// Sequenced event log for replaying feeds (`GET /attention/events?after=N`).
    private(set) var eventLog: [(seq: Int, event: AttentionEvent)] = []
    private(set) var lastSeq = 0

    static let recentLimit = 100
    static let eventLogLimit = 500
    /// Pending items kept; past this the oldest notices are withdrawn.
    static let pendingLimit = 200
    /// How long a notice (inbound message, conversation started, agent
    /// notification) stays in the feeds when nothing withdraws it.
    static let noticeLifetime: TimeInterval = 24 * 60 * 60

    /// Reads the routing preferences. Injectable for tests.
    var preferences: () -> NotificationPreferences = { NotificationPreferencesStore.snapshot() }

    init(channels: [any NotificationChannel] = []) {
        self.channels = channels
    }

    // MARK: - Channels

    func register(_ channel: any NotificationChannel) {
        channels.removeAll { $0.id == channel.id }
        channels.append(channel)
    }

    /// Installs the shipped channels once at launch.
    func installDefaultChannels() {
        register(InAppAttentionChannel.shared)
        register(DesktopNotificationChannel.shared)
        register(PairedDeviceChannel.shared)
        register(PushChannel.shared)
        AttentionActivityLogger.shared.start(center: self)
    }

    // MARK: - Producers

    /// Raise an item. `resolver` runs exactly once, on the first `resolve`.
    /// Returns the item id (the same id the caller passed in `item`).
    @discardableResult
    func raise(_ item: AttentionItem, resolver: Resolver? = nil) -> UUID {
        var item = item
        if item.expiresAt == nil, !item.kind.isBlocking {
            item.expiresAt = Date().addingTimeInterval(Self.noticeLifetime)
        }
        if let resolver { resolvers[item.id] = resolver }
        let prefs = preferences()
        for channel in channels where channel.supports(item.kind) {
            guard prefs.allows(item.kind, on: channel.id), channel.shouldDeliver(item) else { continue }
            channel.deliver(item)
            item.deliveredTo.append(channel.id.rawValue)
        }
        if !item.deliveredTo.isEmpty { item.deliveredAt = Date() }
        pending.append(item)
        AttentionLog.info(
            "raised id=\(item.id) kind=\(item.kind.rawValue) session=\(item.sessionId?.uuidString ?? "none") "
                + "channels=\(item.deliveredTo.joined(separator: ","))"
        )
        if let expiresAt = item.expiresAt {
            let id = item.id
            let blocking = item.kind.isBlocking
            let delay = max(0, expiresAt.timeIntervalSinceNow)
            expiryTasks[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if blocking {
                    self?.resolve(id: id, with: AttentionResolution(outcome: .timedOut, surface: .system))
                } else {
                    self?.retract(id: id)
                }
            }
        }
        emit(.raised(item))
        trimPending()
        return item.id
    }

    /// Whether `resolution` is an answer the item offered. Notification and
    /// phone answers must match one of the item's actions; the app's own
    /// cards and the system (timeout, run ended) are not restricted, and a
    /// notice can always be dismissed.
    static func accepts(_ resolution: AttentionResolution, for item: AttentionItem) -> Bool {
        switch resolution.surface {
        case .inline, .system: return true
        case .desktop, .phone, .push: break
        }
        let action: AttentionAction
        switch resolution.outcome {
        case .approved: action = .approve
        case .denied: action = .deny
        case .allowedForConversation:
            return item.actions.contains(.allowForConversation) || item.actions.contains(.approveRest)
        case .replied: action = .reply
        case .dismissed:
            if !item.kind.isBlocking { return true }
            action = .dismiss
        case .timedOut, .abandoned: return true
        }
        return item.actions.contains(action)
    }

    /// Settles every blocking item as abandoned (the app is quitting), so
    /// each waiting run and caller hears an answer instead of a dropped
    /// connection.
    func abandonAllBlocking() {
        for item in pending where item.kind.isBlocking {
            resolve(id: item.id, with: AttentionResolution(outcome: .abandoned, surface: .system))
        }
    }

    /// Answer an item from any surface. False when it is unknown or already
    /// settled (answered elsewhere first).
    @discardableResult
    func resolve(id: UUID, with resolution: AttentionResolution) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        guard Self.accepts(resolution, for: pending[index]) else {
            AttentionLog.error(
                "refused id=\(id) outcome=\(resolution.outcome.rawValue) surface=\(resolution.surface.rawValue)")
            return false
        }
        return settle(index: index, with: resolution)
    }

    /// Records the answer the item's producer took through its own channel
    /// (a sealed secret from an iPhone), which the item's actions can't
    /// offer on the shared surfaces. False when it is unknown or already
    /// settled.
    @discardableResult
    func settleFromProducer(id: UUID, with resolution: AttentionResolution) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        return settle(index: index, with: resolution)
    }

    private func settle(index: Int, with resolution: AttentionResolution) -> Bool {
        let id = pending[index].id
        var item = pending.remove(at: index)
        item.state = .resolved(resolution)
        item.settledAt = Date()
        expiryTasks.removeValue(forKey: id)?.cancel()
        let resolver = resolvers.removeValue(forKey: id)
        for channel in channels where item.deliveredTo.contains(channel.id.rawValue) {
            channel.retract(item)
        }
        remember(item)
        AttentionLog.info(
            "resolved id=\(id) kind=\(item.kind.rawValue) outcome=\(resolution.outcome.rawValue) "
                + "surface=\(resolution.surface.rawValue)"
        )
        emit(.resolved(item))
        resolver?(resolution)
        return true
    }

    /// Withdraw an item without an answer (the producer settled it itself,
    /// or the run ended). Non-blocking items use this when dismissed by
    /// opening the conversation.
    func retract(id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        var item = pending.remove(at: index)
        item.state = .retracted
        item.settledAt = Date()
        expiryTasks.removeValue(forKey: id)?.cancel()
        resolvers.removeValue(forKey: id)
        for channel in channels where item.deliveredTo.contains(channel.id.rawValue) {
            channel.retract(item)
        }
        remember(item)
        emit(.retracted(item))
    }

    /// Retract every pending item for a session (the user opened it, or the
    /// run finished).
    func retractAll(sessionId: UUID, kinds: Set<AttentionKind>? = nil) {
        for item in pending where item.sessionId == sessionId && (kinds?.contains(item.kind) ?? true) {
            retract(id: item.id)
        }
    }

    func item(id: UUID) -> AttentionItem? {
        pending.first { $0.id == id } ?? recent.first { $0.id == id }
    }

    // MARK: - Observation

    func stream() -> AsyncStream<AttentionEvent> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: token) }
            }
        }
    }

    /// Synchronous observer, called on the main actor in emission order.
    @discardableResult
    func observe(_ handler: @escaping @MainActor (AttentionEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// Events after `seq` still in the replay window, or nil when `seq` is
    /// older than the window (the client should re-list).
    func events(after seq: Int) -> [(seq: Int, event: AttentionEvent)]? {
        if seq >= lastSeq { return [] }
        if let first = eventLog.first, seq < first.seq - 1 { return nil }
        return eventLog.filter { $0.seq > seq }
    }

    // MARK: - Private

    /// Keeps `pending` bounded: the oldest notices go first. Blocking items
    /// are never dropped here; each has its own timeout or run teardown.
    private func trimPending() {
        var excess = pending.count - Self.pendingLimit
        guard excess > 0 else { return }
        for item in pending where !item.kind.isBlocking {
            guard excess > 0 else { break }
            retract(id: item.id)
            excess -= 1
        }
    }

    private func remember(_ item: AttentionItem) {
        recent.insert(item, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    private func emit(_ event: AttentionEvent) {
        lastSeq += 1
        eventLog.append((lastSeq, event))
        if eventLog.count > Self.eventLogLimit { eventLog.removeFirst(eventLog.count - Self.eventLogLimit) }
        for handler in observers.values { handler(event) }
        for continuation in continuations.values { continuation.yield(event) }
    }

    // MARK: - Tests

    func resetForTesting() {
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll()
        resolvers.removeAll()
        pending.removeAll()
        recent.removeAll()
        eventLog.removeAll()
        lastSeq = 0
    }
}
