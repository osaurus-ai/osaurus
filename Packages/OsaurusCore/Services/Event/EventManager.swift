//
//  EventManager.swift
//  osaurus
//
//  The one place events live at run time. Sources hand it occurrences;
//  it filters, de-duplicates, queues, runs, and ledgers every one of them.
//
//      source adapter → submit → filter → dedupe → TaskScheduler (queue + lane)
//                     → AgentTurnWorker | WorkflowRunWorker → task + ledger
//
//  Every occurrence is a task (`TaskStore`, id = run id); the `EventRun`
//  ledger row is written with it, so Automations History and
//  `GET /events/{token}/runs/{id}` read the same state.
//
//  Channel agent turns are the exception: `ingestChannelMessage` hands
//  them to `AgentChannelInboundRelay`, which owns conversation steering,
//  quick reattach and reply delivery; the manager still ledgers them.
//

import Foundation
import Observation

extension Notification.Name {
    public static let eventsChanged = Notification.Name("osaurusEventsChanged")
}

@Observable
@MainActor
public final class EventManager {
    public static let shared = EventManager()

    // MARK: - Observable state

    public private(set) var events: [OsaurusEvent] = []
    /// Agent → number of agent events that run it.
    public private(set) var eventCountsByAgent: [UUID: Int] = [:]
    /// Event → runs in flight.
    public private(set) var runningCounts: [UUID: Int] = [:]
    /// What each event's source is doing (folder phase, last poll, error),
    /// published by the adapters.
    public private(set) var sourceStatus: [UUID: EventSourceStatus] = [:]
    /// Bumped whenever a ledger row changes, so views reload.
    public private(set) var ledgerRevision = 0
    public private(set) var isStarted = false

    /// Folder events' convergence phase, for the list.
    public var folderPhases: [UUID: WatcherPhase] {
        sourceStatus.compactMapValues { status in
            status.folderPhase.flatMap { $0 == .idle ? nil : $0 }
        }
    }

    // MARK: - Runtime

    @ObservationIgnored let scheduler: TaskScheduler
    var taskStore: TaskStore { scheduler.store }
    @ObservationIgnored let ledger: EventRunDatabase
    @ObservationIgnored private(set) lazy var scheduleSource = ScheduleEventSource(manager: self)
    @ObservationIgnored private(set) lazy var folderSource = FolderEventSource(manager: self)
    @ObservationIgnored private(set) lazy var webhookSource = WebhookEventSource(manager: self)
    @ObservationIgnored private(set) lazy var channelSource = ChannelMessageEventSource(manager: self)
    @ObservationIgnored private(set) lazy var emailSource = EmailEventSource(manager: self)
    @ObservationIgnored private(set) lazy var rssSource = RSSEventSource(manager: self)
    @ObservationIgnored private(set) lazy var sseSource = SSEEventSource(manager: self)
    @ObservationIgnored private(set) lazy var runFailedSource = RunFailedEventSource(manager: self)
    @ObservationIgnored private(set) lazy var appSource = AppEventsSource(manager: self)
    /// Poll / stream / maintenance loops for adapters that pull.
    @ObservationIgnored private(set) lazy var runtime = SourceRuntimeSupervisor(host: .manager(self))
    /// One adapter per source kind, in launch order. Tests swap entries.
    @ObservationIgnored lazy var adapters: [any EventSourceAdapter] = EventSourceKind.allCases.map {
        makeAdapter(for: $0)
    }
    /// Non-terminal runs, by run id.
    @ObservationIgnored private var liveRuns: [UUID: EventRun] = [:]
    /// Occurrences recently accepted, by `eventId|dedupeKey`.
    @ObservationIgnored private var recentDedupe: [String: (runId: UUID, at: Date)] = [:]
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<EventRun, Never>]] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored let persistsToDisk: Bool

    typealias ActionRunner = @MainActor (
        _ taskId: UUID, OsaurusEvent, EventOccurrence, TaskStartedHandler
    ) async -> TaskOutcome
    /// Runs an admitted occurrence's action; tests substitute a fake.
    @ObservationIgnored var runAction: ActionRunner = { taskId, event, occurrence, onStarted in
        await AutomationWorker.run(taskId: taskId, event: event, occurrence: occurrence, onStarted: onStarted)
    }
    /// Posts a workflow's final output when the occurrence has no live
    /// sink (after a relaunch); tests substitute a fake.
    @ObservationIgnored var channelReplier: WorkflowChannelReplier = .live
    /// The workflow run the last launch's event row followed, once this
    /// launch's resume pass picked it up (or closed it) and it ended.
    /// Tests substitute a fake.
    @ObservationIgnored var resumedWorkflowResult: @MainActor (UUID) async -> WorkflowRun? = { id in
        await WorkflowRunService.shared.awaitResumePass()
        return await WorkflowRunService.shared.result(of: id)
    }
    /// Checks that an automation's agent, workflow and channel still exist;
    /// tests substitute one that accepts placeholder agents.
    @ObservationIgnored var targetLookup = EventTargetLookup.live

    /// Serial queue for event files and ledger writes; reads go through it
    /// too so they observe every write issued before them.
    nonisolated static let ioQueue = DispatchQueue(label: "ai.osaurus.events.io", qos: .userInitiated)

    /// A manager that does not persist gets its own scheduler and in-memory
    /// task store, so tests never share slots with the app's queues.
    init(ledger: EventRunDatabase = .shared, persistsToDisk: Bool = true, scheduler: TaskScheduler? = nil) {
        self.ledger = ledger
        self.persistsToDisk = persistsToDisk
        self.scheduler =
            scheduler
            ?? (persistsToDisk
                ? .shared
                : TaskScheduler(store: TaskStore(database: nil), reservations: ForegroundReservationCenter()))
    }

    private func makeAdapter(for kind: EventSourceKind) -> any EventSourceAdapter {
        switch kind {
        case .schedule: scheduleSource
        case .folder: folderSource
        case .webhook: webhookSource
        case .rss: rssSource
        case .sse: sseSource
        case .runFailed: runFailedSource
        case .app: appSource
        case .email: emailSource
        case .channelMessage: channelSource
        }
    }

    func adapter(for kind: EventSourceKind) -> any EventSourceAdapter {
        adapters.first { $0.kind == kind } ?? makeAdapter(for: kind)
    }

    // MARK: - Lifecycle

    /// Migrates legacy schedules/watchers/channel routes on first launch,
    /// loads events, and arms the schedule and folder sources. Called once
    /// from app launch, before channel transports start.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        let ledger = self.ledger
        let persists = persistsToDisk
        let taskStore = self.taskStore
        loadTask = Task { @MainActor [weak self] in
            if persists {
                await taskStore.start(seedMaxConcurrent: ToastManager.shared.configuration.maxConcurrentTasks)
                TaskActivityLogger.start(store: taskStore)
            }
            let (loaded, ledgerOpen): ([OsaurusEvent], Bool) = await withCheckedContinuation { continuation in
                Self.ioQueue.async {
                    let ledgerOpen = ledger.ensureOpen()
                    if persists {
                        EventMigration.runIfNeeded(ledger: ledger)
                        EmailAutomationMigration.runIfNeeded(ledger: ledger)
                        ChannelAccountMigration.runIfNeeded()
                    }
                    continuation.resume(returning: (persists ? EventStore.loadAll() : [], ledgerOpen))
                }
            }
            guard let self else { return }
            if persists, !ledgerOpen { self.reopenLedgerWhenTheKeyArrives() }
            self.events = loaded
            self.recomputeCounts()
            if persists {
                self.publishChannelListeners()
                self.importLedgerIntoTasks()
                await TaskMigration.importAgentRuns(into: self.taskStore)
                await SelfScheduleAutomations.migrateLegacyNextRuns(manager: self)
            }
            await self.closeInterruptedRuns()
            for adapter in self.adapters {
                await adapter.reconcile(self.events)
                await adapter.start()
            }
            for adapter in self.adapters {
                await adapter.reconcileInstalled(self.events.filter { $0.sourceKind == adapter.kind })
            }
            NotificationCenter.default.post(name: .eventsChanged, object: nil)
            print("[Osaurus] EventManager started with \(self.events.count) events")
        }
    }

    @ObservationIgnored private var keyObserver: NSObjectProtocol?

    /// The ledger could not open at launch (usually the storage key was not
    /// resident yet); retry once it is.
    private func reopenLedgerWhenTheKeyArrives() {
        guard keyObserver == nil else { return }
        let ledger = self.ledger
        keyObserver = NotificationCenter.default.addObserver(
            forName: StorageKeyManager.storageKeyDidBecomeResident, object: nil, queue: .main
        ) { [weak self] _ in
            Self.ioQueue.async {
                guard ledger.ensureOpen() else { return }
                Task { @MainActor [weak self] in
                    guard let self, let keyObserver = self.keyObserver else { return }
                    NotificationCenter.default.removeObserver(keyObserver)
                    self.keyObserver = nil
                    self.importLedgerIntoTasks()
                }
            }
        }
    }

    /// Waits until `start()` has loaded events (no-op once loaded).
    func awaitLoaded() async {
        await loadTask?.value
    }

    /// Stops every source and drops queued fires so nothing new runs during
    /// quit. Running turns are left to `BackgroundTaskManager`'s teardown.
    public func stop() {
        for adapter in adapters { adapter.stop() }
        let runtime = self.runtime
        Task { await runtime.stopAll() }
        for runId in scheduler.dropPending(keyPrefix: "lane:") {
            settle(runId, status: .cancelled, reason: "app_quit")
        }
    }

    /// One-time import of the ledger's finished rows as tasks, so the Tasks
    /// view starts with the history Automations already had.
    private func importLedgerIntoTasks() {
        let ledger = self.ledger
        let byId = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        taskStore.importOnce("import.event_runs.v1") {
            let rows: [EventRun]? = Self.ioQueue.sync { try? ledger.recentRuns(limit: 5000) }
            return rows?.filter(\.status.isTerminal).map { Self.task(from: $0, event: byId[$0.eventId]) }
        }
    }

    /// Reloads events from disk (after an external edit or a config apply).
    public func reload() async {
        let loaded: [OsaurusEvent] = await withCheckedContinuation { continuation in
            Self.ioQueue.async { continuation.resume(returning: EventStore.loadAll()) }
        }
        events = loaded
        didChangeEvents()
    }

    /// Closes what the last launch left open, except workflow runs that
    /// continue this launch: their rows follow them to the end.
    func closeInterruptedRuns() async {
        let open: [EventRun] = await withCheckedContinuation { continuation in
            Self.ioQueue.async { [ledger] in continuation.resume(returning: (try? ledger.openRuns()) ?? []) }
        }
        for var run in open {
            if let workflowRunId = run.workflowRunId, let event = event(for: run.eventId),
                case .workflow = event.action, run.status == .running || run.status == .awaitingUser,
                let workflowRun = WorkflowRunStore.shared.run(id: workflowRunId), !workflowRun.status.isTerminal,
                !workflowRun.isTest
            {
                // The workflow run picks up where it stopped, so the row
                // follows it and the rule's final post still goes out.
                liveRuns[run.id] = run
                let occurrence = EventOccurrence(
                    eventId: run.eventId, firedAt: run.firedAt, payload: .object([:]),
                    conversationKey: workflowRun.caller.channelReply?.conversationKey)
                followParkedWorkflow(
                    runId: run.id, workflowRunId: workflowRunId, event: event, occurrence: occurrence,
                    wait: resumedWorkflowResult)
                continue
            }
            run.status = .cancelled
            run.reason = "interrupted"
            run.finishedAt = run.finishedAt ?? Date()
            write(run)
        }
        Self.ioQueue.async { [ledger] in try? ledger.pruneAll() }
    }

    // MARK: - Queries

    public func event(for id: UUID) -> OsaurusEvent? {
        events.first { $0.id == id }
    }

    public func events(targeting agentId: UUID) -> [OsaurusEvent] {
        events.filter { $0.agentId == agentId }
    }

    public func eventCount(forAgentId agentId: UUID) -> Int {
        eventCountsByAgent[agentId] ?? 0
    }

    public func events(forWorkflowID id: UUID) -> [OsaurusEvent] {
        events.filter { $0.action.workflow?.workflowID == id }
    }

    public func events(forPluginId pluginId: String) -> [OsaurusEvent] {
        events.filter { $0.parameters[OsaurusEvent.pluginIdParameterKey] == pluginId }
    }

    public func events(kind: AgentChannelKind, connectionId: String) -> [OsaurusEvent] {
        let id = AgentChannelConnection.normalizedId(connectionId)
        return events.filter {
            guard let source = $0.source.channelMessage else { return false }
            return source.kind == kind && AgentChannelConnection.normalizedId(source.connectionId) == id
        }
    }

    public func event(forWebhookToken token: String) -> OsaurusEvent? {
        guard !token.isEmpty else { return nil }
        return events.first { event in
            guard let configured = event.source.webhook?.token else { return false }
            return WebhookVerification.constantTimeEquals(configured, token)
        }
    }

    public func isRunning(_ eventId: UUID) -> Bool {
        (runningCounts[eventId] ?? 0) > 0 || (sourceStatus[eventId]?.isActive ?? false)
    }

    /// The event's source status as its adapter reports it.
    public func status(of eventId: UUID) -> EventSourceStatus {
        guard let event = event(for: eventId) else { return EventSourceStatus() }
        return adapter(for: event.sourceKind).status(eventId)
    }

    public func queuedCount(_ eventId: UUID) -> Int {
        scheduler.pendingCount(keyPrefix: TaskScheduler.Limit.lanePrefix(eventId: eventId))
    }

    /// Whether any of the event's lanes has a run going.
    func isLaneBusy(_ eventId: UUID) -> Bool {
        scheduler.runningCount(keyPrefix: TaskScheduler.Limit.lanePrefix(eventId: eventId)) > 0
    }

    public func runs(eventId: UUID, limit: Int = 100) async -> [EventRun] {
        let stored: [EventRun] = await withCheckedContinuation { continuation in
            Self.ioQueue.async { [ledger] in
                continuation.resume(returning: (try? ledger.runs(eventId: eventId, limit: limit)) ?? [])
            }
        }
        return merged(stored, live: liveRuns.values.filter { $0.eventId == eventId }, limit: limit)
    }

    /// Blocking read for synchronous callers (tool envelopes); a short
    /// indexed query.
    func runsSnapshot(eventId: UUID, limit: Int) -> [EventRun] {
        let stored: [EventRun] = Self.ioQueue.sync { [ledger] in
            (try? ledger.runs(eventId: eventId, limit: limit)) ?? []
        }
        return merged(stored, live: liveRuns.values.filter { $0.eventId == eventId }, limit: limit)
    }

    func liveRun(_ id: UUID) -> EventRun? { liveRuns[id] }

    public func run(id: UUID) async -> EventRun? {
        if let live = liveRuns[id] { return live }
        return await withCheckedContinuation { continuation in
            Self.ioQueue.async { [ledger] in continuation.resume(returning: try? ledger.run(id: id)) }
        }
    }

    private func merged(_ stored: [EventRun], live: [EventRun], limit: Int) -> [EventRun] {
        var byId: [UUID: EventRun] = [:]
        for run in stored { byId[run.id] = run }
        for run in live { byId[run.id] = run }
        return Array(byId.values.sorted { $0.firedAt > $1.firedAt }.prefix(limit))
    }

    // MARK: - CRUD

    /// `telemetryOrigin` (`user` or `config`) counts the creation in
    /// `automation_created`; nil keeps agent self-schedules and plugin
    /// installs out of that metric.
    @discardableResult
    public func create(_ event: OsaurusEvent, telemetryOrigin: String? = nil) -> OsaurusEvent {
        var created = event
        created.updatedAt = Date()
        ensureWebhookSecret(created)
        applyLocal(created)
        persist(created)
        didChangeEvents()
        if created.isEnabled { install(created) }
        adapter(for: created.sourceKind).eventDidChange(created, previous: nil)
        if let telemetryOrigin {
            FeatureTelemetry.automationCreated(trigger: created.sourceKind.rawValue, origin: telemetryOrigin)
        }
        return created
    }

    public func update(_ event: OsaurusEvent) {
        var updated = event
        updated.updatedAt = Date()
        let previous = self.event(for: event.id)
        let resourced = previous.map { $0.source != updated.source } ?? false
        if let previous, resourced {
            let old = adapter(for: previous.sourceKind)
            old.forget(event.id)
            sourceStatus.removeValue(forKey: event.id)
            Task { await old.uninstall(previous) }
        }
        // A secret belongs to one sender: GitHub's generated key is useless
        // to Stripe, and a pasted Stripe key must not pose as Osaurus's own.
        if let before = previous?.source.webhook, let after = updated.source.webhook,
            before.provider != after.provider
        {
            EventSecretsKeychain.deleteSecret(eventID: updated.id)
        }
        ensureWebhookSecret(updated)
        applyLocal(updated)
        persist(updated)
        didChangeEvents()
        if let previous {
            if updated.isEnabled, resourced || !previous.isEnabled {
                install(updated)
            } else if !updated.isEnabled, previous.isEnabled, !resourced {
                let current = adapter(for: updated.sourceKind)
                Task { await current.uninstall(updated) }
            }
        } else if updated.isEnabled {
            install(updated)
        }
        let samePrevious = previous?.sourceKind == updated.sourceKind ? previous : nil
        adapter(for: updated.sourceKind).eventDidChange(updated, previous: samePrevious)
    }

    /// Provider-side setup for an enabled event; a failure shows on the
    /// event's status instead of blocking the save.
    private func install(_ event: OsaurusEvent) {
        let adapter = adapter(for: event.sourceKind)
        Task { [weak self] in
            do {
                try await adapter.install(event)
            } catch {
                self?.setSourceStatus(event.id) {
                    $0.installed = false
                    $0.lastError = error.localizedDescription
                }
            }
        }
    }

    /// A webhook that checks a secret or signature needs one to check
    /// against. Providers that issue their own signing secret get it pasted
    /// in, not generated here.
    private func ensureWebhookSecret(_ event: OsaurusEvent) {
        guard let webhook = event.source.webhook, webhook.checksSecret,
            !WebhookProviderProfile.profile(for: webhook).secretIssuedByProvider,
            !EventSecretsKeychain.hasSecret(eventID: event.id)
        else { return }
        EventSecretsKeychain.saveSecret(EventSecretsKeychain.makeSecret(), eventID: event.id)
    }

    @discardableResult
    public func delete(id: UUID) -> Bool {
        guard let existing = event(for: id) else { return false }
        cancelRuns(eventId: id)
        let adapter = adapter(for: existing.sourceKind)
        adapter.forget(id)
        sourceStatus.removeValue(forKey: id)
        if existing.isEnabled { Task { await adapter.uninstall(existing) } }
        events.removeAll { $0.id == id }
        EventSecretsKeychain.deleteSecret(eventID: id)
        taskStore.deleteTasks(subscriptionId: id)
        if persistsToDisk {
            Self.ioQueue.async { [ledger] in
                _ = EventStore.delete(id: id)
                try? ledger.deleteRuns(eventId: id)
            }
        }
        didChangeEvents()
        return true
    }

    public func setEnabled(_ id: UUID, enabled: Bool) {
        guard var event = event(for: id), event.isEnabled != enabled else { return }
        event.isEnabled = enabled
        if !enabled { cancelRuns(eventId: id) }
        update(event)
    }

    @discardableResult
    public func deleteByPluginId(_ pluginId: String) -> Int {
        events(forPluginId: pluginId).reduce(0) { $0 + (delete(id: $1.id) ? 1 : 0) }
    }

    /// Only the plugin's events with this name, so reinstalling replaces
    /// what it recreates and leaves the rest.
    @discardableResult
    func deleteByPluginId(_ pluginId: String, named name: String) -> Int {
        events(forPluginId: pluginId).filter { $0.name == name }.reduce(0) { $0 + (delete(id: $1.id) ? 1 : 0) }
    }

    /// New URL token for a webhook event; the old URL stops working at once.
    @discardableResult
    public func rotateWebhookToken(_ id: UUID) -> String? {
        guard var event = event(for: id), var webhook = event.source.webhook else { return nil }
        webhook.token = WebhookSourceConfig.makeToken()
        event.source = .webhook(webhook)
        update(event)
        return webhook.token
    }

    /// New signing/shared secret for a webhook event. Returned once.
    @discardableResult
    public func rotateWebhookSecret(_ id: UUID) -> String? {
        guard event(for: id)?.source.webhook != nil else { return nil }
        let secret = EventSecretsKeychain.makeSecret()
        guard EventSecretsKeychain.saveSecret(secret, eventID: id) else { return nil }
        return secret
    }

    /// Runtime bookkeeping that is not an edit (no `updatedAt` bump).
    func updateState(_ id: UUID, _ mutate: (inout OsaurusEvent) -> Void) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        var event = events[index]
        mutate(&event)
        guard event != events[index] else { return }
        events[index] = event
        persist(event)
    }

    func adjustRunningCount(_ id: UUID, by delta: Int) {
        let next = (runningCounts[id] ?? 0) + delta
        runningCounts[id] = next > 0 ? next : nil
    }

    func setFolderPhase(_ id: UUID, _ phase: WatcherPhase) {
        setSourceStatus(id) { $0.phase = phase == .idle ? .idle : .folder(phase) }
    }

    /// Adapters publish their per-event status through here.
    func setSourceStatus(_ id: UUID, _ mutate: (inout EventSourceStatus) -> Void) {
        var status = sourceStatus[id] ?? EventSourceStatus()
        mutate(&status)
        guard status != sourceStatus[id] ?? EventSourceStatus() else { return }
        sourceStatus[id] = status.isEmpty ? nil : status
    }

    // MARK: - Source state

    /// Adapter state (cursors, baselines, provider registrations) by scope.
    func sourceState(scope: String) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            Self.ioQueue.async { [ledger] in
                continuation.resume(returning: try? ledger.sourceState(scope: scope))
            }
        }
    }

    /// Writes (or with nil, clears) adapter state. Writes are ordered on the
    /// ledger queue, so a later read sees them.
    func setSourceState(_ state: JSONValue?, scope: String) {
        let now = Date()
        Self.ioQueue.async { [ledger] in
            if let state {
                try? ledger.setSourceState(state, scope: scope, at: now)
            } else {
                try? ledger.deleteSourceState(scope: scope)
            }
        }
    }

    private func applyLocal(_ event: OsaurusEvent) {
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.append(event)
        }
        events.sort { $0.createdAt > $1.createdAt }
    }

    private func persist(_ event: OsaurusEvent) {
        guard persistsToDisk else { return }
        Self.ioQueue.async { EventStore.save(event) }
    }

    /// Waits for queued event writes, then reads the saved events back.
    func persistedEventsNow() -> [OsaurusEvent] {
        guard persistsToDisk else { return events }
        return Self.ioQueue.sync { EventStore.loadAll() }
    }

    private func didChangeEvents() {
        recomputeCounts()
        if persistsToDisk { publishChannelListeners() }
        let snapshot = events
        // Adapters hold their manager unowned: keep it alive while they run.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for adapter in self.adapters { await adapter.reconcile(snapshot) }
        }
        NotificationCenter.default.post(name: .eventsChanged, object: nil)
    }

    private func recomputeCounts() {
        var counts: [UUID: Int] = [:]
        for event in events {
            guard let agentId = event.agentId else { continue }
            counts[agentId, default: 0] += 1
        }
        eventCountsByAgent = counts
    }

    // MARK: - Fire now

    /// Runs the event once by hand. `samplePayload` stands in for the
    /// source's data: a webhook body, or `{ "text": … }` for a channel event.
    @discardableResult
    public func fireNow(_ id: UUID, samplePayload: JSONValue? = nil) async -> EventFireResult {
        guard let event = event(for: id) else {
            return EventFireResult(runId: UUID(), status: .suppressed, reason: "event_not_found")
        }
        if isLaneBusy(id) && event.delivery.maxQueued == 0 {
            return EventFireResult(runId: UUID(), status: .suppressed, reason: "busy")
        }
        let adapter = adapter(for: event.sourceKind)
        var sample = samplePayload
        if sample == nil { sample = await adapter.sample(for: event) }
        return await adapter.fireNow(event, sample: sample)
    }

    /// Cancels the event's queued fires and its running agent turns or
    /// workflow runs.
    public func cancelRuns(eventId: UUID) {
        for runId in scheduler.dropPending(keyPrefix: TaskScheduler.Limit.lanePrefix(eventId: eventId)) {
            settle(runId, status: .cancelled, reason: "cancelled")
        }
        if let event = event(for: eventId) { adapter(for: event.sourceKind).cancel(eventId) }
        for run in liveRuns.values where run.eventId == eventId && run.status == .running {
            stopRunning(run)
        }
    }

    /// Whether `taskId` is one of this manager's live runs.
    public func hasLiveRun(_ taskId: UUID) -> Bool { liveRuns[taskId] != nil }

    /// Stops one task this manager started: a waiting fire is dropped, a
    /// running agent turn or workflow run is cancelled. Returns false when
    /// the task is not one of this manager's live runs.
    @discardableResult
    public func stopTask(_ taskId: UUID, actor: TaskActor = .user) -> Bool {
        guard let run = liveRuns[taskId] else { return false }
        taskStore.journal(taskId, .cancelled, actor: actor, reason: "stopped")
        if scheduler.cancelPending(taskId) {
            settle(taskId, status: .cancelled, reason: "cancelled")
            return true
        }
        stopRunning(run)
        return true
    }

    private func stopRunning(_ run: EventRun) {
        if let workflowRunId = run.workflowRunId {
            WorkflowRunService.shared.cancel(workflowRunId)
        } else if let sessionId = run.sessionId {
            BackgroundTaskManager.shared.cancelTask(sessionId)
        }
    }

    // MARK: - Pipeline

    /// Filters, de-duplicates and queues one occurrence. Returns at once;
    /// the run settles later (see `submitAndWait`).
    @discardableResult
    func submit(_ occurrence: EventOccurrence) -> EventFireResult {
        guard let event = event(for: occurrence.eventId) else {
            return EventFireResult(runId: UUID(), status: .suppressed, reason: "event_not_found")
        }
        var run = EventRun(
            eventId: event.id,
            eventName: event.name,
            sourceKind: event.sourceKind,
            actionKind: event.action.kind,
            firedAt: occurrence.firedAt,
            dedupeKey: occurrence.dedupeKey,
            conversationKey: occurrence.conversationKey,
            summary: occurrence.summary
        )
        if occurrence.trigger == .manual { run.summary["trigger"] = "manual" }

        if let rejection = admissionRejection(event: event, occurrence: occurrence) {
            run.status = rejection.status
            run.reason = rejection.reason
            return settleNew(run)
        }
        rememberDedupe(event: event, occurrence: occurrence, runId: run.id)

        let runId = run.id
        liveRuns[runId] = run
        syncTask(from: run)
        var limits = [
            TaskScheduler.Limit.lane(
                eventId: event.id, delivery: event.delivery, conversationKey: occurrence.conversationKey)
        ]
        var claim: ResourceClaim?
        switch event.action {
        case .agent(let action):
            if let agentId = action.target?.localId {
                limits.append(.agent(agentId))
                claim = ResourceArbiter.claim(forAgent: agentId)
            }
        case .workflow(let action):
            claim = ResourceArbiter.claim(forWorkflow: action.workflowID)
        case .prompt:
            break
        }
        let admission = scheduler.submit(
            TaskScheduler.Submission(
                id: runId,
                queueId: taskStore.resolvedQueue(event.delivery.queueId).id,
                limits: limits,
                claim: claim,
                orderingKey: occurrence.conversationKey,
                onStart: { [weak self] in
                    Task { @MainActor in await self?.execute(runId: runId, occurrence: occurrence) }
                },
                onDrop: { [weak self] reason in self?.settle(runId, status: .suppressed, reason: reason) }
            ))
        switch admission {
        case .started:
            Task { @MainActor [weak self] in await self?.execute(runId: runId, occurrence: occurrence) }
            return EventFireResult(runId: runId, status: .running, reason: nil)
        case .queued(let position):
            run.status = .queued
            run.summary["queue_position"] = String(position)
            write(run)
            return EventFireResult(runId: runId, status: .queued, reason: nil)
        case .rejected(let reason):
            liveRuns.removeValue(forKey: runId)
            run.status = .suppressed
            run.reason = reason
            return settleNew(run)
        }
    }

    /// `submit`, then waits for the run to settle (folder convergence).
    func submitAndWait(_ occurrence: EventOccurrence) async -> EventRun {
        let result = submit(occurrence)
        if let live = liveRuns[result.runId] {
            return await withCheckedContinuation { continuation in
                if liveRuns[live.id] == nil {
                    continuation.resume(returning: live)
                } else {
                    waiters[live.id, default: []].append(continuation)
                }
            }
        }
        return await run(id: result.runId)
            ?? EventRun(
                id: result.runId, eventId: occurrence.eventId, eventName: "", sourceKind: .folder,
                actionKind: .agent, status: result.status, reason: result.reason)
    }

    /// Why an occurrence does not run, checked before it takes a lane.
    func admissionRejection(event: OsaurusEvent, occurrence: EventOccurrence) -> (
        status: EventRunStatus, reason: String
    )? {
        if occurrence.trigger == .source, !event.isEnabled { return (.suppressed, "disabled") }
        if let filtered = EventMatcher.filterRejection(event.filter, payload: occurrence.payload) {
            return (.filtered, filtered)
        }
        if let original = duplicateOf(event: event, occurrence: occurrence) {
            return (.duplicate, "duplicate_of:\(original.uuidString)")
        }
        if let problem = EventInspection.targetProblem(event, lookup: targetLookup) {
            return (.suppressed, problem.reason)
        }
        switch event.action {
        case .agent(let action):
            if let rejection = AgentTurnWorker.agentRejection(action.target, eventName: event.name) {
                return (.suppressed, rejection)
            }
        case .workflow(let action):
            if InstalledWorkflowStore.shared.workflow(id: action.workflowID) == nil {
                return (.suppressed, "workflow_unavailable")
            }
        case .prompt:
            break
        }
        return nil
    }

    private func dedupeKey(event: OsaurusEvent, occurrence: EventOccurrence) -> String? {
        guard occurrence.trigger == .source, event.delivery.dedupe != .none,
            let key = occurrence.dedupeKey
        else { return nil }
        return event.id.uuidString + "|" + key
    }

    private func duplicateOf(event: OsaurusEvent, occurrence: EventOccurrence) -> UUID? {
        guard let key = dedupeKey(event: event, occurrence: occurrence), let raw = occurrence.dedupeKey else {
            return nil
        }
        switch event.delivery.dedupe {
        case .none:
            return nil
        case .window(let seconds):
            let since = occurrence.firedAt.addingTimeInterval(-seconds)
            if let recent = recentDedupe[key], recent.at >= since { return recent.runId }
            let stored: EventRun? = Self.ioQueue.sync { [ledger] in
                try? ledger.firstOccurrence(eventId: event.id, dedupeKey: raw, since: since)
            }
            return stored?.id
        case .durable:
            if let recent = recentDedupe[key] { return recent.runId }
            return Self.ioQueue.sync { [ledger] in
                (try? ledger.seenKey(eventId: event.id, dedupeKey: raw)) ?? nil
            }
        }
    }

    /// Records an admitted occurrence's key. A durable key is written at
    /// admission, before the run settles, so a redelivery during the run
    /// or after a relaunch is a duplicate.
    func rememberDedupe(event: OsaurusEvent, occurrence: EventOccurrence, runId: UUID) {
        guard let key = dedupeKey(event: event, occurrence: occurrence) else { return }
        if event.delivery.dedupe == .durable, let raw = occurrence.dedupeKey {
            let at = occurrence.firedAt
            Self.ioQueue.async { [ledger] in
                try? ledger.insertSeenKey(eventId: event.id, dedupeKey: raw, runId: runId, at: at)
            }
        }
        recentDedupe[key] = (runId, occurrence.firedAt)
        if recentDedupe.count > 2000 {
            let cutoff = Date().addingTimeInterval(-3600)
            recentDedupe = recentDedupe.filter { $0.value.at >= cutoff }
        }
    }

    private func execute(runId: UUID, occurrence: EventOccurrence) async {
        // The lane (and queue slot) frees when the action returns; a
        // workflow parked on a form keeps its row live but not its lane.
        defer { scheduler.finish(runId) }
        guard var run = liveRuns[runId] else { return }
        guard let event = event(for: occurrence.eventId) else {
            settle(runId, status: .cancelled, reason: "event_deleted")
            return
        }
        run.status = .running
        run.startedAt = Date()
        write(run)
        runningCounts[event.id, default: 0] += 1
        defer {
            let remaining = (runningCounts[event.id] ?? 1) - 1
            runningCounts[event.id] = remaining > 0 ? remaining : nil
        }
        if event.sourceKind != .schedule {
            updateState(event.id) { $0.lastFiredAt = occurrence.firedAt }
        }

        let outcome = await runAction(runId, event, occurrence) {
            [weak self] sessionId, workflowRunId in
            guard let self, var live = self.liveRuns[runId] else { return }
            live.sessionId = sessionId ?? live.sessionId
            live.workflowRunId = workflowRunId ?? live.workflowRunId
            self.write(live)
        }
        guard var finished = liveRuns[runId] else { return }
        finished.sessionId = outcome.sessionId ?? finished.sessionId
        finished.workflowRunId = outcome.workflowRunId ?? finished.workflowRunId
        finished.error = outcome.error
        finished.reason = outcome.reason ?? finished.reason
        finished.summary.merge(outcome.summary) { _, new in new }

        if outcome.status == .waitingUser, let workflowRunId = finished.workflowRunId {
            finished.status = .awaitingUser
            write(finished)
            followParkedWorkflow(runId: runId, workflowRunId: workflowRunId, event: event, occurrence: occurrence)
            return
        }
        liveRuns[runId] = finished
        let status = EventRunStatus(outcome.status == .running ? .succeeded : outcome.status)
        await replyWithWorkflowOutputIfNeeded(event: event, occurrence: occurrence, status: status, run: finished)
        if let workflowRunId = finished.workflowRunId { ChannelReplyRegistry.shared.unregister(runID: workflowRunId) }
        settle(runId, status: status, reason: finished.reason)
    }

    /// A workflow parked on a form: the lane is free again, and the ledger
    /// row follows the run until it ends.
    private func followParkedWorkflow(
        runId: UUID, workflowRunId: UUID, event: OsaurusEvent, occurrence: EventOccurrence,
        wait: @escaping @MainActor (UUID) async -> WorkflowRun? = { await WorkflowRunService.shared.result(of: $0) }
    ) {
        Task { @MainActor [weak self] in
            let final = await wait(workflowRunId)
            guard let self else { return }
            let outcome = WorkflowRunWorker.outcome(of: final, runID: workflowRunId)
            guard var live = self.liveRuns[runId] else { return }
            live.error = outcome.error
            self.liveRuns[runId] = live
            let status = EventRunStatus(outcome.status)
            await self.replyWithWorkflowOutputIfNeeded(
                event: event, occurrence: occurrence, status: status, run: live)
            ChannelReplyRegistry.shared.unregister(runID: workflowRunId)
            let ended = outcome.status.isTerminal
            self.settle(runId, status: ended ? status : .cancelled, reason: ended ? nil : "interrupted")
        }
    }

    private func replyWithWorkflowOutputIfNeeded(
        event: OsaurusEvent, occurrence: EventOccurrence, status: EventRunStatus, run: EventRun
    ) async {
        guard case .workflow = event.action, event.reply.replyWithWorkflowOutput,
            let workflowRunId = run.workflowRunId
        else { return }
        let workflowRun = WorkflowRunStore.shared.run(id: workflowRunId)
        // After a relaunch the platform's reply closure is gone; the run's
        // caller still names the conversation.
        let fallbackCaller = workflowRun?.caller.channelReply != nil ? workflowRun?.caller : nil
        guard occurrence.replySink != nil || fallbackCaller != nil else { return }
        // A `reply` step already spoke for this run: posting the output
        // too would say everything twice. A failure is still reported.
        if status == .succeeded, ChannelReplyRegistry.shared.hasStepReplied(runID: workflowRunId) {
            if var live = liveRuns[run.id] {
                live.summary["replied_by_step"] = "true"
                liveRuns[run.id] = live
            }
            return
        }
        let text: String?
        switch status {
        case .succeeded:
            text = WorkflowRunWorker.replyText(from: workflowRun?.output)
        case .failed:
            text = L("Sorry, \(event.name) could not finish this one.")
        default:
            text = nil
        }
        guard let text, !text.isEmpty else { return }
        let failure: String?
        if let sink = occurrence.replySink {
            failure = await sink.send(
                text, agentId: nil, sessionId: nil, extraDetails: ["event": event.name], trigger: .workflowReply)
        } else if let fallbackCaller {
            let delivery = await channelReplier.send(
                text, runID: workflowRunId, caller: fallbackCaller, marksReplied: false,
                extraDetails: ["event": event.name])
            failure = delivery.sent ? nil : (delivery.error ?? delivery.reason ?? L("The channel did not take the reply."))
        } else {
            return
        }
        if let failure {
            if var live = liveRuns[run.id] {
                live.summary["reply_error"] = failure
                liveRuns[run.id] = live
            }
        } else if var live = liveRuns[run.id] {
            live.summary["replied"] = "true"
            liveRuns[run.id] = live
        }
    }

    // MARK: - Ledger

    /// Records a non-terminal row and keeps it live.
    func write(_ run: EventRun) {
        if run.status.isTerminal {
            liveRuns.removeValue(forKey: run.id)
        } else {
            liveRuns[run.id] = run
        }
        ledgerRevision &+= 1
        syncTask(from: run)
        let ledger = self.ledger
        Self.ioQueue.async { try? ledger.upsert(run) }
    }

    // MARK: - Task record

    /// Writes the run's task: the same id, state, links and reason. The
    /// ledger row and the task always move together.
    func syncTask(from run: EventRun) {
        let state = Self.taskState(of: run)
        guard let existing = taskStore.task(id: run.id) else {
            var task = Self.task(from: run, event: event(for: run.eventId))
            task.transition(to: state)
            let kind: TaskEventKind = state.isTerminal && !state.didRun ? .suppressed : .enqueued
            taskStore.record(
                task,
                event: TaskEvent(
                    taskId: run.id, kind: kind, actor: task.createdBy, reason: run.reason,
                    data: ["source": run.sourceKind.rawValue]))
            return
        }
        let changed = existing.state != state
        taskStore.update(run.id) { task in
            if changed, !task.state.isTerminal { task.transition(to: state) }
            task.sessionId = run.sessionId ?? task.sessionId
            task.workflowRunId = run.workflowRunId ?? task.workflowRunId
            task.lastError = run.error
            task.reason = run.reason
            task.summary = run.summary
            if state == .running { task.lease = task.lease ?? TaskLease(owner: "automation") }
        }
        guard changed, !existing.state.isTerminal else { return }
        let kind: TaskEventKind
        switch state {
        case .running: kind = existing.state == .waitingUser ? .resumed : .started
        case .waitingUser: kind = .waitingUser
        case .cancelled, .interrupted: kind = .cancelled
        case .failed: kind = .error
        case .suppressed, .filtered, .duplicate: kind = .suppressed
        default: kind = state.isTerminal ? .finished : .enqueued
        }
        taskStore.journal(run.id, kind, actor: .system("automations"), reason: run.reason ?? run.error)
        if state.isTerminal, kind != .finished, state.didRun || state == .suppressed {
            taskStore.journal(run.id, .finished, actor: .system("automations"), reason: state.rawValue)
        }
    }

    static func taskState(of run: EventRun) -> TaskState {
        if run.status == .cancelled, run.reason == "interrupted" { return .interrupted }
        return TaskState(run.status)
    }

    /// The task an automation run is, for the live write and the one-time
    /// ledger import.
    static func task(from run: EventRun, event: OsaurusEvent?) -> OsaurusTask {
        let work: TaskWork
        switch event?.action {
        case .workflow(let action)?:
            work = .workflowRun(WorkflowRunWork(workflowID: action.workflowID, callerKind: "event"))
        case .agent(let action)?:
            work = .agentTurn(
                AgentTurnWork(
                    agentId: action.target?.localId,
                    targetKey: action.target?.localId?.uuidString ?? action.target?.workspaceRef?.key,
                    source: event.map {
                        SelfScheduleAutomations.isAgentOwned($0)
                            ? .selfSchedule : AgentTurnWorker.persistedSource($0.sourceKind)
                    } ?? .automation))
        case .prompt?:
            work = .agentTurn(AgentTurnWork(agentId: nil, source: .automation))
        case nil:
            work =
                run.actionKind == .workflow
                ? .workflowRun(WorkflowRunWork(workflowID: run.workflowRunId ?? run.eventId, callerKind: "event"))
                : .agentTurn(AgentTurnWork(agentId: nil, source: .automation))
        }
        let manual = run.summary["trigger"] == "manual"
        let wakeOwner = event.flatMap(SelfScheduleAutomations.ownerAgentId(of:))
        let origin: TaskOrigin
        let createdBy: TaskActor
        if let wakeOwner {
            origin = .selfSchedule
            createdBy = manual ? .user : .agent(wakeOwner)
        } else {
            origin = run.sourceKind == .channelMessage ? .channel : (manual ? .manual : .automation)
            createdBy = manual ? .user : .system("automations")
        }
        var task = OsaurusTask(
            id: run.id,
            title: run.eventName,
            queueId: event?.delivery.queueId ?? TaskQueue.defaultID,
            subscriptionId: run.eventId,
            origin: origin,
            createdBy: createdBy,
            work: work,
            orderingKey: run.conversationKey,
            idempotencyKey: run.dedupeKey.map { "\(run.eventId.uuidString)|\($0)" },
            state: taskState(of: run),
            summary: run.summary,
            createdAt: run.firedAt)
        task.reason = run.reason
        task.lastError = run.error
        task.sessionId = run.sessionId
        task.workflowRunId = run.workflowRunId
        task.queuedAt = run.status == .queued ? run.firedAt : nil
        task.startedAt = run.startedAt
        task.admittedAt = run.startedAt
        task.finishedAt = run.finishedAt
        if task.state.isTerminal, task.finishedAt == nil { task.finishedAt = run.firedAt }
        return task
    }

    /// A row that never took a lane (filtered, duplicate, rejected).
    @discardableResult
    func settleNew(_ run: EventRun) -> EventFireResult {
        var settled = run
        settled.finishedAt = Date()
        finalize(settled)
        return EventFireResult(runId: settled.id, status: settled.status, reason: settled.reason)
    }

    /// Ends a live run.
    func settle(_ runId: UUID, status: EventRunStatus, reason: String?) {
        guard var run = liveRuns[runId] else { return }
        run.status = status
        if let reason { run.reason = reason }
        run.finishedAt = Date()
        finalize(run)
    }

    /// Records an occurrence handled outside the queue (channel agent turns).
    func record(_ run: EventRun) {
        if run.status.isTerminal {
            finalize(run)
        } else {
            write(run)
        }
    }

    private func finalize(_ run: EventRun) {
        liveRuns.removeValue(forKey: run.id)
        write(run)
        let event = event(for: run.eventId)
        if run.status.didRun || run.status == .suppressed {
            updateState(run.eventId) { event in
                event.lastStatus = run.status
                if run.status.didRun {
                    event.lastRunAt = run.finishedAt ?? Date()
                    if let sessionId = run.sessionId { event.lastSessionId = sessionId }
                    if let workflowRunId = run.workflowRunId { event.lastWorkflowRunId = workflowRunId }
                }
            }
        }
        if run.status != .filtered && run.status != .duplicate {
            EventActivityLogger.log(run, event: event)
            FeatureTelemetry.automationRunFinished(trigger: run.sourceKind.rawValue, status: run.status.rawValue)
        }
        if run.status == .failed, let failures = adapter(for: .runFailed) as? RunFailedEventSource {
            failures.automationRunFailed(run, event: event)
        }
        let ledger = self.ledger
        if run.status.didRun {
            Self.ioQueue.async { try? ledger.prune(eventId: run.eventId) }
        }
        for waiter in waiters.removeValue(forKey: run.id) ?? [] {
            waiter.resume(returning: run)
        }
    }
}
