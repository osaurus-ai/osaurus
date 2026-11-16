//
//  TaskStore.swift
//  osaurus
//
//  The main-actor facade over `TaskDatabase`: queues, live tasks, a hot
//  cache of recently finished ones, and the journal. Writes go behind on a
//  serial queue; reads flush first so they observe every write issued
//  before them.
//

import Foundation
import Observation

@Observable
@MainActor
public final class TaskStore {
    public static let shared = TaskStore(database: .shared, bus: .shared)

    /// Newest terminal tasks kept in memory for the board.
    static let hotCacheLimit = 500

    // MARK: - Observable state

    public private(set) var queues: [TaskQueue] = [TaskQueue.makeDefault()]
    /// Queue pickers, rows and labels only appear once there is a choice.
    public var hasMultipleQueues: Bool { queues.count > 1 }
    /// Tasks that have not finished, by id.
    public private(set) var live: [UUID: OsaurusTask] = [:]
    /// Recently finished tasks, newest first.
    public private(set) var recent: [OsaurusTask] = []
    /// Bumped on every change except a lease heartbeat, so views reload
    /// history reads when something they show moved.
    public private(set) var revision = 0
    public private(set) var isStarted = false
    /// Chat sessions that started at least one task.
    public private(set) var originSessionIds: Set<UUID> = []

    // MARK: - Internals

    @ObservationIgnored private let database: TaskDatabase?
    @ObservationIgnored let bus: TaskBus
    @ObservationIgnored private var seqs: [UUID: Int] = [:]
    @ObservationIgnored private var pendingTasks: [UUID: OsaurusTask] = [:]
    @ObservationIgnored private var pendingEvents: [TaskEvent] = []
    @ObservationIgnored private var pendingReservations: [ForegroundReservation] = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var persistenceAvailable = false
    @ObservationIgnored private var startFinished = false
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Void, Never>] = []
    /// Called after a queue's policy changes, so schedulers re-pump.
    @ObservationIgnored var onQueuesChanged: [@MainActor () -> Void] = []

    nonisolated static let ioQueue = DispatchQueue(label: "ai.osaurus.tasks.io", qos: .utility)
    /// Retention runs at launch and then at most this often, on a write.
    static let pruneInterval: TimeInterval = 6 * 3600
    @ObservationIgnored private var lastPrunedAt = Date()

    /// `database: nil` keeps everything in memory (tests).
    public init(database: TaskDatabase?, bus: TaskBus = TaskBus()) {
        self.database = database
        self.bus = bus
    }

    // MARK: - Lifecycle

    /// Opens the store, seeds the Default queue, closes what the last launch
    /// left running and prunes old rows. `seedMaxConcurrent` is the saved
    /// concurrency limit the Default queue inherits on first launch.
    public func start(seedMaxConcurrent: Int? = nil) async {
        guard !isStarted else {
            if !startFinished { await withCheckedContinuation { startWaiters.append($0) } }
            return
        }
        isStarted = true
        defer {
            startFinished = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard let database else { return }
        let loaded = await Self.load(database)
        persistenceAvailable = loaded.ok
        if !loaded.ok { reattachWhenTheKeyArrives() }
        var queues = loaded.queues
        if !queues.contains(where: \.isDefault) {
            let seeded = TaskQueue.makeDefault(
                maxConcurrent: seedMaxConcurrent ?? TaskQueuePolicy.defaultMaxConcurrent)
            queues.insert(seeded, at: 0)
            enqueueQueueWrite(seeded)
        }
        self.queues = Self.sorted(queues)
        recoverInterrupted(loaded.open)
        flush()
        await loadRecent()
    }

    private static func load(_ database: TaskDatabase) async -> (queues: [TaskQueue], open: [OsaurusTask], ok: Bool) {
        await withCheckedContinuation { c in
            ioQueue.async {
                do {
                    if !database.isOpen { try database.open() }
                    let queues = (try? database.queues()) ?? []
                    let open = (try? database.openTasks()) ?? []
                    try? database.prune()
                    c.resume(returning: (queues, open, true))
                } catch {
                    print("[TaskStore] open failed: \(error.localizedDescription)")
                    c.resume(returning: ([], [], false))
                }
            }
        }
    }

    @ObservationIgnored private var keyObserver: NSObjectProtocol?

    private func reattachWhenTheKeyArrives() {
        guard keyObserver == nil else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: StorageKeyManager.storageKeyDidBecomeResident, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.reattach() }
        }
    }

    /// Retries the database after `start` could not open it (the storage
    /// key was not resident yet, or Recovery's Retry). Stored rows win;
    /// queues and tasks made in memory meanwhile are written through.
    /// Returns whether the store is persisting.
    @discardableResult
    public func reattach() async -> Bool {
        guard startFinished, let database else { return false }
        guard !persistenceAvailable else { return true }
        let loaded = await Self.load(database)
        guard loaded.ok, !persistenceAvailable else { return persistenceAvailable }
        persistenceAvailable = true
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        let stored = Set(loaded.queues.map(\.id))
        let memoryOnly = queues.filter { !stored.contains($0.id) }
        memoryOnly.forEach(enqueueQueueWrite)
        queues = Self.sorted(loaded.queues + memoryOnly)
        recoverInterrupted(loaded.open.filter { live[$0.id] == nil })
        for task in live.values { pendingTasks[task.id] = task }
        for task in recent { pendingTasks[task.id] = task }
        for events in journalCache.values { pendingEvents.append(contentsOf: events) }
        flush()
        await loadRecent()
        queuesDidChange()
        return true
    }

    /// Everything the last launch left open becomes `interrupted`, except a
    /// workflow run that resumes this launch.
    private func recoverInterrupted(_ open: [OsaurusTask]) {
        let now = Date()
        for var task in open {
            if let seq = try? database?.lastSeq(taskId: task.id) { seqs[task.id] = seq }
            if let workflowRunId = task.workflowRunId,
                let run = WorkflowRunStore.shared.run(id: workflowRunId), !run.status.isTerminal, !run.isTest
            {
                task.state = TaskState(run.status)
                live[task.id] = task
                continue
            }
            let wasQueued = task.state == .queued || task.state == .received
            task.transition(to: wasQueued ? .cancelled : .interrupted, at: now)
            task.reason = "interrupted"
            task.version += 1
            pendingTasks[task.id] = task
            appendEvent(
                TaskEvent(
                    taskId: task.id, at: now, kind: wasQueued ? .cancelled : .finished, actor: .system("launch"),
                    reason: "interrupted"))
        }
    }

    private func loadRecent() async {
        guard persistenceAvailable, let database else { return }
        let (rows, chats): ([OsaurusTask], Set<UUID>) = await withCheckedContinuation { c in
            Self.ioQueue.async {
                let rows = (try? database.tasks(TaskQuery(limit: Self.hotCacheLimit))) ?? []
                c.resume(returning: (rows, (try? database.originSessionIds()) ?? []))
            }
        }
        recent = rows.filter { $0.state.isTerminal && live[$0.id] == nil }
        if !chats.isSubset(of: originSessionIds) { originSessionIds.formUnion(chats) }
        revision &+= 1
    }

    // MARK: - Queues

    public var defaultQueue: TaskQueue {
        queues.first(where: \.isDefault) ?? TaskQueue.makeDefault()
    }

    public func queue(id: UUID?) -> TaskQueue? {
        guard let id else { return nil }
        return queues.first { $0.id == id }
    }

    /// A queue by slug or name (case-insensitive).
    public func queue(named value: String) -> TaskQueue? {
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return queues.first { $0.slug == needle || $0.name.lowercased() == needle }
            ?? queues.first { $0.slug == TaskQueue.slug(for: value) }
    }

    /// The queue a task lands on: the named one if it exists, else Default.
    public func resolvedQueue(_ id: UUID?) -> TaskQueue {
        queue(id: id) ?? defaultQueue
    }

    public func policy(for queueId: UUID) -> TaskQueuePolicy {
        resolvedQueue(queueId).policy
    }

    @discardableResult
    public func createQueue(name: String, policy: TaskQueuePolicy = TaskQueuePolicy()) -> TaskQueue {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var slug = TaskQueue.slug(for: trimmed)
        var suffix = 2
        while queues.contains(where: { $0.slug == slug }) {
            slug = TaskQueue.slug(for: trimmed) + "-\(suffix)"
            suffix += 1
        }
        let created = TaskQueue(slug: slug, name: trimmed.isEmpty ? slug : trimmed, policy: policy)
        queues = Self.sorted(queues + [created])
        enqueueQueueWrite(created)
        queuesDidChange()
        return created
    }

    public func updateQueue(_ updated: TaskQueue) {
        guard let index = queues.firstIndex(where: { $0.id == updated.id }) else { return }
        var next = updated
        next.isSystem = queues[index].isSystem
        if next.isSystem { next.slug = queues[index].slug }
        guard next != queues[index] else { return }
        queues[index] = next
        enqueueQueueWrite(next)
        queuesDidChange()
    }

    /// Deletes a user queue. Its waiting tasks move to Default; system
    /// queues cannot be deleted.
    @discardableResult
    public func deleteQueue(id: UUID) -> Bool {
        guard let existing = queue(id: id), !existing.isSystem else { return false }
        queues.removeAll { $0.id == id }
        for task in live.values where task.queueId == id {
            update(task.id) { $0.queueId = TaskQueue.defaultID }
        }
        if persistenceAvailable, let database {
            Self.ioQueue.async { try? database.deleteQueue(id: id) }
        }
        queuesDidChange()
        return true
    }

    public func setPaused(_ queueId: UUID, paused: Bool) {
        guard var q = queue(id: queueId), q.policy.paused != paused else { return }
        q.policy.paused = paused
        updateQueue(q)
    }

    private func queuesDidChange() {
        revision &+= 1
        for hook in onQueuesChanged { hook() }
    }

    private func enqueueQueueWrite(_ q: TaskQueue) {
        guard let database else { return }
        Self.ioQueue.async { try? database.upsertQueue(q) }
    }

    private static func sorted(_ queues: [TaskQueue]) -> [TaskQueue] {
        queues.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.createdAt < rhs.createdAt
        }
    }

    // MARK: - Tasks

    public func task(id: UUID) -> OsaurusTask? {
        live[id] ?? recent.first { $0.id == id } ?? pendingTasks[id]
    }

    /// Live tasks, oldest first.
    public var activeTasks: [OsaurusTask] {
        live.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Inserts or replaces a task record and journals `event` with it.
    public func record(_ task: OsaurusTask, event: TaskEvent? = nil) {
        var stored = task
        if let existing = self.task(id: task.id) { stored.version = existing.version + 1 }
        stored.updatedAt = Date()
        apply(stored)
        if let event { appendEvent(event) }
    }

    /// Mutates a task. With `expectedVersion`, a write against a version
    /// that has since moved on is refused and nil is returned.
    @discardableResult
    public func update(
        _ id: UUID, expectedVersion: Int? = nil, _ mutate: (inout OsaurusTask) -> Void
    ) -> OsaurusTask? {
        guard var task = task(id: id) else { return nil }
        if let expectedVersion, expectedVersion != task.version { return nil }
        let before = task
        mutate(&task)
        guard task != before else { return task }
        var leaseAside = task
        leaseAside.lease = before.lease
        task.version = before.version + 1
        task.updatedAt = Date()
        apply(task, bumpsRevision: leaseAside != before)
        return task
    }

    /// Moves a task to `state`, journaling `kind`.
    @discardableResult
    public func transition(
        _ id: UUID, to state: TaskState, kind: TaskEventKind? = nil, actor: TaskActor? = nil, reason: String? = nil,
        data: [String: String] = [:], _ mutate: (inout OsaurusTask) -> Void = { _ in }
    ) -> OsaurusTask? {
        guard let current = task(id: id) else { return nil }
        // A finished task stays finished; late signals only journal.
        if current.state.isTerminal, state != current.state {
            return current
        }
        let updated = update(id) { task in
            task.transition(to: state)
            if let reason, state.isTerminal || state == .queued { task.reason = reason }
            mutate(&task)
        }
        if let kind { journal(id, kind, actor: actor, reason: reason, data: data) }
        return updated
    }

    /// Appends one journal event.
    public func journal(
        _ id: UUID, _ kind: TaskEventKind, actor: TaskActor? = nil, reason: String? = nil, data: [String: String] = [:]
    ) {
        appendEvent(TaskEvent(taskId: id, kind: kind, actor: actor, reason: reason, data: data))
    }

    /// Renews a running task's lease and, when given, its progress note.
    /// Notes are coalesced: only the newest reaches disk per flush.
    public func heartbeat(_ id: UUID, owner: String, note: String? = nil) {
        update(id) { task in
            guard !task.state.isTerminal else { return }
            if task.lease == nil {
                task.lease = TaskLease(owner: owner)
            } else {
                task.lease?.renew()
            }
            if let note { task.progressNote = note }
        }
    }

    private func apply(_ task: OsaurusTask, bumpsRevision: Bool = true) {
        if task.state.isTerminal {
            live.removeValue(forKey: task.id)
            recent.removeAll { $0.id == task.id }
            recent.insert(task, at: 0)
            if recent.count > Self.hotCacheLimit { recent.removeLast(recent.count - Self.hotCacheLimit) }
        } else {
            live[task.id] = task
            recent.removeAll { $0.id == task.id }
        }
        pendingTasks[task.id] = task
        if let chat = task.originSessionId, !originSessionIds.contains(chat) { originSessionIds.insert(chat) }
        if bumpsRevision { revision &+= 1 }
        bus.publish(.taskChanged(task))
        scheduleFlush()
    }

    private func appendEvent(_ event: TaskEvent) {
        var stamped = event
        let next = (seqs[event.taskId] ?? 0) + 1
        seqs[event.taskId] = next
        stamped.seq = next
        pendingEvents.append(stamped)
        journalCache[event.taskId, default: []].append(stamped)
        if journalCache.count > Self.hotCacheLimit * 2 { trimJournalCache() }
        bus.publish(.journal(stamped))
        scheduleFlush()
    }

    /// Journal of tasks touched this launch, for in-memory stores and the
    /// detail sheet's instant first paint.
    @ObservationIgnored private var journalCache: [UUID: [TaskEvent]] = [:]

    private func trimJournalCache() {
        let keep = Set(live.keys).union(recent.prefix(Self.hotCacheLimit).map(\.id))
        journalCache = journalCache.filter { keep.contains($0.key) }
    }

    func recordReservation(_ reservation: ForegroundReservation) {
        pendingReservations.append(reservation)
        scheduleFlush()
    }

    // MARK: - Reads

    /// `task(id:)`, falling back to history for tasks out of the hot cache.
    public func loadTask(id: UUID) async -> OsaurusTask? {
        if let cached = task(id: id) { return cached }
        flush()
        guard persistenceAvailable, let database else { return nil }
        return await withCheckedContinuation { c in
            Self.ioQueue.async { c.resume(returning: try? database.task(id: id)) }
        }
    }

    /// History rows matching `query`, live tasks merged over stored ones.
    public func tasks(_ query: TaskQuery) async -> [OsaurusTask] {
        flush()
        var stored: [OsaurusTask] = []
        if persistenceAvailable, let database {
            stored = await withCheckedContinuation { c in
                Self.ioQueue.async { c.resume(returning: (try? database.tasks(query)) ?? []) }
            }
        }
        return merged(stored, query)
    }

    /// Blocking history read for synchronous callers (tool envelopes).
    public func tasksSnapshot(_ query: TaskQuery) -> [OsaurusTask] {
        flush()
        var stored: [OsaurusTask] = []
        if persistenceAvailable, let database {
            stored = Self.ioQueue.sync { (try? database.tasks(query)) ?? [] }
        }
        return merged(stored, query)
    }

    private func merged(_ stored: [OsaurusTask], _ query: TaskQuery) -> [OsaurusTask] {
        var byId: [UUID: OsaurusTask] = [:]
        for task in stored { byId[task.id] = task }
        for task in recent where query.matches(task) { byId[task.id] = task }
        for task in live.values where query.matches(task) { byId[task.id] = task }
        return Array(byId.values.sorted { $0.createdAt > $1.createdAt }.prefix(query.limit))
    }

    public func events(for taskId: UUID) async -> [TaskEvent] {
        flush()
        guard persistenceAvailable, let database else { return journalCache[taskId] ?? [] }
        let stored: [TaskEvent] = await withCheckedContinuation { c in
            Self.ioQueue.async { c.resume(returning: (try? database.events(taskId: taskId)) ?? []) }
        }
        return stored.isEmpty ? (journalCache[taskId] ?? []) : stored
    }

    // MARK: - Deletion

    public func deleteTasks(subscriptionId: UUID) {
        removeTasks { $0.subscriptionId == subscriptionId }
        guard persistenceAvailable, let database else { return }
        Self.ioQueue.async { try? database.deleteTasks(subscriptionId: subscriptionId) }
    }

    public func deleteTasks(agentId: UUID) {
        removeTasks { $0.agentId == agentId }
        guard persistenceAvailable, let database else { return }
        Self.ioQueue.async { try? database.deleteTasks(agentId: agentId) }
    }

    private func removeTasks(where predicate: (OsaurusTask) -> Bool) {
        live = live.filter { !predicate($0.value) }
        recent.removeAll(where: predicate)
        pendingTasks = pendingTasks.filter { !predicate($0.value) }
        revision &+= 1
    }

    // MARK: - One-shot imports

    /// Runs `body` once per database, keyed by `key`. `body` returns the
    /// tasks to insert as already-finished history, or nil when the source
    /// cannot be read (nothing is marked). Returns true only once the rows
    /// and the done marker are committed (or were already), so a caller may
    /// then retire the source; a failed write retries next launch.
    @discardableResult
    func importOnce(_ key: String, _ body: () -> [OsaurusTask]?) -> Bool {
        guard persistenceAvailable, let database else { return false }
        let done = Self.ioQueue.sync { (try? database.meta(key)) != nil }
        guard !done else { return true }
        guard let imported = body() else { return false }
        return importHistory(key, imported)
    }

    /// Upserts `imported` as finished history and stamps `key`, every call.
    /// For sources that are retired after each import, so a second batch
    /// (rows an older build wrote after a downgrade) still comes across.
    @discardableResult
    func importHistory(_ key: String, _ imported: [OsaurusTask]) -> Bool {
        guard persistenceAvailable, let database else { return false }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let committed: Bool = Self.ioQueue.sync {
            do {
                try database.importTasks(imported, metaKey: key, metaValue: stamp)
                return true
            } catch {
                print("[TaskStore] import \(key) failed: \(error.localizedDescription)")
                return false
            }
        }
        if committed, !imported.isEmpty {
            Task { @MainActor [weak self] in await self?.loadRecent() }
        }
        return committed
    }

    #if DEBUG
        /// Test-only: whether an import stamped `key`.
        func didImportForTesting(_ key: String) -> Bool {
            guard persistenceAvailable, let database else { return false }
            return Self.ioQueue.sync { (try? database.meta(key)) != nil }
        }
    #endif

    // MARK: - Write-behind

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Hands every pending write to the database queue.
    public func flush() {
        flushScheduled = false
        guard persistenceAvailable, let database else {
            // Writes issued before launch opened the store wait for it.
            if database != nil, !isStarted || !startFinished { return }
            pendingTasks.removeAll()
            pendingEvents.removeAll()
            pendingReservations.removeAll()
            return
        }
        let tasks = Array(pendingTasks.values)
        let events = pendingEvents
        let reservations = pendingReservations
        pendingTasks.removeAll()
        pendingEvents.removeAll()
        pendingReservations.removeAll()
        guard !tasks.isEmpty || !events.isEmpty || !reservations.isEmpty else { return }
        let prune = Date().timeIntervalSince(lastPrunedAt) >= Self.pruneInterval
        if prune { lastPrunedAt = Date() }
        Self.ioQueue.async {
            try? database.upsertTasks(tasks)
            try? database.appendEvents(events)
            for reservation in reservations { try? database.upsertReservation(reservation) }
            if prune { try? database.prune() }
        }
    }
}
