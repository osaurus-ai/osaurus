//
//  TaskScheduler.swift
//  osaurus
//
//  Admission for offloaded work. A submission names its queue and the
//  limits it occupies (the queue itself, the agent's safety cap, an
//  automation's lane); the scheduler starts it now, holds it until a slot
//  frees, or refuses it. See docs/TASK_QUEUE.md, "Scheduler".
//

import Foundation

@MainActor
public final class TaskScheduler {
    public static let shared = TaskScheduler(store: .shared, reservations: .shared)

    /// Chain depth past which task-triggered tasks are refused.
    nonisolated public static let maxDepth = 8
    /// Running agent turns per agent, across every queue.
    nonisolated public static let maxTasksPerAgent = 5

    /// One slot pool a task occupies while it runs.
    public struct Limit: Hashable, Sendable {
        public var key: String
        public var capacity: Int
        /// Waiting tasks this key holds before it refuses; nil = unlimited.
        public var maxPending: Int?
        /// Kept while the run waits on the user, and ordered: a waiting
        /// task blocks later ones on the same key.
        public var holdsWhileWaiting: Bool
        public var rejectReason: String

        public init(
            key: String, capacity: Int, maxPending: Int? = nil, holdsWhileWaiting: Bool = false,
            rejectReason: String = "queue_full"
        ) {
            self.key = key
            self.capacity = max(0, capacity)
            self.maxPending = maxPending.map { max(0, $0) }
            self.holdsWhileWaiting = holdsWhileWaiting
            self.rejectReason = rejectReason
        }

        public static func queue(_ id: UUID) -> String { "queue:\(id.uuidString)" }

        public static func agent(_ id: UUID) -> Limit {
            Limit(key: "agent:\(id.uuidString)", capacity: TaskScheduler.maxTasksPerAgent)
        }

        /// An automation's lane: serial (one at a time), per conversation,
        /// or overlapping up to `maxConcurrent`. `maxQueued` fires wait
        /// behind it; past that a fire is refused (`busy` when none may wait).
        public static func lane(eventId: UUID, delivery: EventDeliveryPolicy, conversationKey: String?) -> Limit {
            Limit(
                key: laneKey(eventId: eventId, mode: delivery.mode, conversationKey: conversationKey),
                capacity: delivery.mode == .parallel ? delivery.maxConcurrent : 1,
                maxPending: delivery.maxQueued,
                holdsWhileWaiting: true,
                rejectReason: delivery.maxQueued == 0 ? "busy" : "queue_full")
        }

        public static func laneKey(eventId: UUID, mode: EventDeliveryMode, conversationKey: String?) -> String {
            if mode == .perConversation, let conversationKey, !conversationKey.isEmpty {
                return "lane:\(eventId.uuidString)|\(conversationKey)"
            }
            return "lane:\(eventId.uuidString)"
        }

        public static func lanePrefix(eventId: UUID) -> String { "lane:\(eventId.uuidString)" }

        static func order(queueId: UUID, key: String) -> Limit {
            Limit(key: "order:\(queueId.uuidString)|\(key)", capacity: 1, holdsWhileWaiting: true)
        }
    }

    public enum Admission: Equatable, Sendable {
        /// Admitted now; the caller runs the work inline.
        case started
        /// Waiting; `onStart` runs when admitted.
        case queued(position: Int)
        case rejected(reason: String)
    }

    public struct Submission {
        public var id: UUID
        public var queueId: UUID
        public var limits: [Limit]
        public var claim: ResourceClaim?
        public var orderingKey: String?
        public var depth: Int
        /// Runs synchronously at admission from the waiting list.
        public var onStart: @MainActor () -> Void
        /// A waiting task dropped by overflow (`coalesced`, `dropped_oldest`).
        public var onDrop: @MainActor (String) -> Void

        public init(
            id: UUID, queueId: UUID, limits: [Limit] = [], claim: ResourceClaim? = nil, orderingKey: String? = nil,
            depth: Int = 0, onStart: @escaping @MainActor () -> Void,
            onDrop: @escaping @MainActor (String) -> Void = { _ in }
        ) {
            self.id = id
            self.queueId = queueId
            self.limits = limits
            self.claim = claim
            self.orderingKey = orderingKey
            self.depth = depth
            self.onStart = onStart
            self.onDrop = onDrop
        }
    }

    private struct Pending {
        var submission: Submission
        var limits: [Limit]
        var enqueuedAt: Date
        var waitReason: String?
    }

    private struct Occupant {
        var queueId: UUID
        var limits: [Limit]
        /// Released the keys that do not hold while waiting.
        var suspended: Bool
    }

    let store: TaskStore
    let arbiter: ResourceArbiter
    private var pending: [Pending] = []
    private var occupants: [UUID: Occupant] = [:]
    private var running: [String: Int] = [:]
    private var isPumping = false
    private var needsPump = false
    private var holdTimer: Task<Void, Never>?
    private var sandboxRefresh: Task<Void, Never>?
    private let sandboxSnapshot: @MainActor () -> SandboxPodSnapshot
    /// Re-reads who holds the sandbox VM; the pump runs again when it frees up.
    private let refreshSandbox: @Sendable () async -> Void

    public init(
        store: TaskStore, reservations: ForegroundReservationCenter,
        sandboxSnapshot: @escaping @MainActor () -> SandboxPodSnapshot = { SandboxPodOccupancy.shared.snapshot },
        refreshSandbox: @escaping @Sendable () async -> Void = TaskScheduler.refreshLiveSandbox
    ) {
        self.store = store
        self.arbiter = ResourceArbiter(reservations: reservations)
        self.sandboxSnapshot = sandboxSnapshot
        self.refreshSandbox = refreshSandbox
        store.onQueuesChanged.append { [weak self] in self?.pump() }
        reservations.addListener { [weak self] in self?.pump() }
        SandboxPodOccupancy.shared.addListener { [weak self] in self?.pump() }
    }

    public nonisolated static func refreshLiveSandbox() async {
        #if os(macOS)
            guard SandboxBackend.current == .virtualMachine else { return }
            await SandboxManager.shared.refreshOccupancy()
        #endif
    }

    // MARK: - Submission

    public func submit(_ submission: Submission) -> Admission {
        if submission.depth > Self.maxDepth { return .rejected(reason: "loop_guard") }
        let policy = store.policy(for: submission.queueId)
        var limits = [queueLimit(submission.queueId)] + submission.limits
        if policy.orderingMode == .perKey, let key = submission.orderingKey, !key.isEmpty {
            limits.append(.order(queueId: submission.queueId, key: key))
        }
        if policy.overflow == .coalesceByKey, let key = submission.orderingKey, !key.isEmpty {
            drop(reason: "coalesced") { $0.submission.queueId == submission.queueId && $0.submission.orderingKey == key }
        }
        for limit in limits {
            guard let maxPending = limit.maxPending else { continue }
            if isFull(limit, maxPending: maxPending) {
                let isQueueKey = limit.key == Limit.queue(submission.queueId)
                if isQueueKey, policy.overflow == .dropOldest,
                    let oldest = pending.first(where: { $0.submission.queueId == submission.queueId })
                {
                    let oldestId = oldest.submission.id
                    drop(reason: "dropped_oldest") { $0.submission.id == oldestId }
                    if !isFull(limit, maxPending: maxPending) { continue }
                }
                return .rejected(reason: limit.rejectReason)
            }
        }
        let now = Date()
        let orderedKeys = Set(limits.filter(\.holdsWhileWaiting).map(\.key))
        let behindOrdered = pending.contains { entry in
            !orderedKeys.isDisjoint(with: entry.limits.filter(\.holdsWhileWaiting).map(\.key))
        }
        if !behindOrdered,
            case .admit(let note) = canStart(
                limits, queueId: submission.queueId, claim: submission.claim, since: now)
        {
            occupy(submission.id, queueId: submission.queueId, limits: limits)
            if let note { store.journal(submission.id, .resourceWait, actor: .system("scheduler"), reason: note) }
            return .started
        }
        pending.append(Pending(submission: submission, limits: limits, enqueuedAt: now))
        noteWait(at: pending.count - 1)
        scheduleHoldExpiry()
        scheduleSandboxRefresh()
        return .queued(position: pending.filter { $0.submission.queueId == submission.queueId }.count)
    }

    private func isFull(_ limit: Limit, maxPending: Int) -> Bool {
        let held = (running[limit.key] ?? 0) + pending.filter { $0.limits.contains { $0.key == limit.key } }.count
        return held >= capacity(of: limit) + maxPending
    }

    private func queueLimit(_ queueId: UUID) -> Limit {
        let policy = store.policy(for: queueId)
        return Limit(key: Limit.queue(queueId), capacity: policy.maxConcurrent, maxPending: policy.maxPending)
    }

    /// Queue capacity follows the live policy, so an edit applies at once.
    private func capacity(of limit: Limit) -> Int {
        if limit.key.hasPrefix("queue:"), let id = UUID(uuidString: String(limit.key.dropFirst(6))) {
            return store.policy(for: id).maxConcurrent
        }
        return limit.capacity
    }

    private enum StartDecision {
        case admit(note: String?)
        case wait(reason: String?)
    }

    private func canStart(_ limits: [Limit], queueId: UUID, claim: ResourceClaim?, since: Date) -> StartDecision {
        if store.policy(for: queueId).paused { return .wait(reason: "paused") }
        for limit in limits where (running[limit.key] ?? 0) >= capacity(of: limit) {
            return .wait(reason: nil)
        }
        switch arbiter.decide(claim: claim, waitingSince: since, sandbox: sandboxSnapshot()) {
        case .admit(let note): return .admit(note: note)
        case .wait(let reason): return .wait(reason: reason)
        }
    }

    // MARK: - Occupancy

    /// Marks a task as holding its slots. Forced (no capacity check) and
    /// idempotent; a suspended occupant resumes.
    public func occupy(_ id: UUID, queueId: UUID = TaskQueue.defaultID, limits: [Limit]? = nil) {
        if let occupant = occupants[id] {
            if occupant.suspended { resume(id) }
            return
        }
        let held = limits ?? [queueLimit(queueId)]
        occupants[id] = Occupant(queueId: queueId, limits: held, suspended: false)
        for limit in held { running[limit.key, default: 0] += 1 }
    }

    /// The run waits on the user: give back the slots that do not hold
    /// while waiting, keep the rest.
    public func suspend(_ id: UUID) {
        guard var occupant = occupants[id], !occupant.suspended else { return }
        occupant.suspended = true
        occupants[id] = occupant
        for limit in occupant.limits where !limit.holdsWhileWaiting { decrement(limit.key) }
        pump()
    }

    /// The user answered: take the released slots back without re-admission.
    public func resume(_ id: UUID) {
        guard var occupant = occupants[id], occupant.suspended else { return }
        occupant.suspended = false
        occupants[id] = occupant
        for limit in occupant.limits where !limit.holdsWhileWaiting { running[limit.key, default: 0] += 1 }
    }

    /// Frees everything the task holds (or drops it from the waiting list)
    /// and admits what can start.
    public func finish(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.submission.id == id }) {
            pending.remove(at: index)
        }
        if let occupant = occupants.removeValue(forKey: id) {
            for limit in occupant.limits where !(occupant.suspended && !limit.holdsWhileWaiting) {
                decrement(limit.key)
            }
        }
        pump()
    }

    /// Drops a waiting task without starting it. Returns whether it was waiting.
    @discardableResult
    public func cancelPending(_ id: UUID) -> Bool {
        guard let index = pending.firstIndex(where: { $0.submission.id == id }) else { return false }
        pending.remove(at: index)
        pump()
        return true
    }

    /// Drops every waiting task whose limits include a key with `prefix`.
    public func dropPending(keyPrefix prefix: String) -> [UUID] {
        let dropped = pending.filter { $0.limits.contains { $0.key.hasPrefix(prefix) } }.map(\.submission.id)
        pending.removeAll { $0.limits.contains { $0.key.hasPrefix(prefix) } }
        return dropped
    }

    private func drop(reason: String, where predicate: (Pending) -> Bool) {
        let dropped = pending.filter(predicate)
        guard !dropped.isEmpty else { return }
        pending.removeAll(where: predicate)
        for entry in dropped { entry.submission.onDrop(reason) }
    }

    private func decrement(_ key: String) {
        let next = (running[key] ?? 0) - 1
        running[key] = next > 0 ? next : nil
    }

    // MARK: - Pump

    /// Admits waiting tasks oldest first. A task blocked on a shared slot
    /// pool is skipped, so it never blocks unrelated work; a task blocked
    /// on an ordered key (a lane) holds later tasks on that key.
    public func pump() {
        if isPumping {
            needsPump = true
            return
        }
        isPumping = true
        defer { isPumping = false }
        repeat {
            needsPump = false
            var index = 0
            var blockedOrdered: Set<String> = []
            while index < pending.count {
                let entry = pending[index]
                let ordered = entry.limits.filter(\.holdsWhileWaiting).map(\.key)
                if !blockedOrdered.isDisjoint(with: ordered) {
                    index += 1
                    continue
                }
                switch canStart(
                    entry.limits, queueId: entry.submission.queueId, claim: entry.submission.claim,
                    since: entry.enqueuedAt)
                {
                case .admit(let note):
                    pending.remove(at: index)
                    occupy(entry.submission.id, queueId: entry.submission.queueId, limits: entry.limits)
                    if let note {
                        store.journal(entry.submission.id, .resourceWait, actor: .system("scheduler"), reason: note)
                    }
                    entry.submission.onStart()
                case .wait(let reason):
                    if pending[index].waitReason != reason {
                        pending[index].waitReason = reason
                        noteWait(at: index)
                    }
                    blockedOrdered.formUnion(ordered)
                    index += 1
                }
            }
        } while needsPump
        scheduleHoldExpiry()
        scheduleSandboxRefresh()
    }

    /// While work waits on `sandbox_busy`, re-check the VM now and then:
    /// a background job ending or an MCP request closing is not an event
    /// the occupancy sees on its own.
    private func scheduleSandboxRefresh() {
        guard pending.contains(where: { $0.waitReason == ResourceArbiter.sandboxBusy }) else {
            sandboxRefresh?.cancel()
            sandboxRefresh = nil
            return
        }
        guard sandboxRefresh == nil else { return }
        let refresh = refreshSandbox
        sandboxRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.sandboxRefreshInterval))
            guard !Task.isCancelled else { return }
            await refresh()
            self?.sandboxRefresh = nil
            self?.pump()
        }
    }

    static let sandboxRefreshInterval: TimeInterval = 15

    /// Mirrors a waiting task's reason onto its record and journal.
    private func noteWait(at index: Int) {
        let entry = pending[index]
        let id = entry.submission.id
        if entry.waitReason == nil {
            let decision = canStart(
                entry.limits, queueId: entry.submission.queueId, claim: entry.submission.claim, since: entry.enqueuedAt)
            if case .wait(let reason) = decision, let reason { pending[index].waitReason = reason }
        }
        let reason = pending[index].waitReason
        guard store.task(id: id)?.waitReason != reason else { return }
        store.update(id) { $0.waitReason = reason }
        if let reason { store.journal(id, .resourceWait, actor: .system("scheduler"), reason: reason) }
    }

    /// Re-pumps when the oldest foreground hold expires.
    private func scheduleHoldExpiry() {
        holdTimer?.cancel()
        holdTimer = nil
        let held = pending.filter { $0.waitReason == "foreground_active" }
        guard let oldest = held.map(\.enqueuedAt).min() else { return }
        let delay = max(1, ResourceArbiter.maxForegroundHold - Date().timeIntervalSince(oldest))
        holdTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    // MARK: - Queries

    public func isPending(_ id: UUID) -> Bool { pending.contains { $0.submission.id == id } }
    public func isOccupying(_ id: UUID) -> Bool { occupants[id] != nil }

    public func runningCount(key: String) -> Int { running[key] ?? 0 }

    public func runningCount(keyPrefix prefix: String) -> Int {
        running.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
    }

    public func pendingCount(keyPrefix prefix: String) -> Int {
        pending.filter { $0.limits.contains { $0.key.hasPrefix(prefix) } }.count
    }

    /// Waiting task ids on a queue, in admission order.
    public func pendingIds(queueId: UUID) -> [UUID] {
        pending.filter { $0.submission.queueId == queueId }.map(\.submission.id)
    }

    public func waitReason(_ id: UUID) -> String? {
        pending.first { $0.submission.id == id }?.waitReason
    }
}
