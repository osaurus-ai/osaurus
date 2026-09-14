//
//  ScheduleManager.swift
//  osaurus
//
//  Manages scheduled tasks with precise timer-based execution.
//  Uses efficient scheduling that only wakes when needed.
//

import Foundation
import Observation

/// Notification posted when schedules change
extension Notification.Name {
    public static let schedulesChanged = Notification.Name("schedulesChanged")
    public static let scheduleExecutionCompleted = Notification.Name("scheduleExecutionCompleted")
}

/// Outcome of a manual `runNow` press.
public enum ScheduleRunNowResult: Sendable, Equatable {
    case started
    case alreadyRunning
    case notFound
}

/// Manages scheduled AI tasks with precise timer-based execution
@Observable
@MainActor
public final class ScheduleManager {
    public static let shared = ScheduleManager()

    // MARK: - Observable State

    /// All schedules
    public private(set) var schedules: [Schedule] = []

    /// Per-agent schedule counts, kept in sync with `schedules`.
    /// Lets `AgentCard` look up its count in O(1) instead of
    /// re-filtering the array on every render.
    public private(set) var scheduleCountsByAgent: [UUID: Int] = [:]

    /// Currently running tasks (schedule ID -> run info)
    public private(set) var runningTasks: [UUID: ScheduleRunInfo] = [:]

    // MARK: - Private State

    /// The task that waits for the next scheduled execution
    @ObservationIgnored
    private nonisolated(unsafe) var timerTask: Task<Void, Never>?

    /// Active execution tasks
    private var executionTasks: [UUID: Task<Void, Never>] = [:]

    /// Observer for timezone changes
    @ObservationIgnored
    private nonisolated(unsafe) var timezoneObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        // Load schedules, arm the timer, and check for missed schedules.
        // All deferred to a later main-actor turn: the disk load now runs
        // on the schedule I/O queue (it has hung the main thread in the
        // field), and `checkForMissedSchedules` can immediately dispatch
        // LLM work, which must not block launch (the App struct builds
        // this property before `applicationDidFinishLaunching`).
        Task { @MainActor [weak self] in
            await self?.refreshFromDisk()
            self?.scheduleNextTimer()
            self?.checkForMissedSchedules()
            if let self {
                print(
                    "[Osaurus] ScheduleManager initialized with \(self.schedules.count) schedules")
            }
        }

        // Listen for timezone changes
        timezoneObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleNextTimer()
            }
        }
    }

    deinit {
        if let observer = timezoneObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        timerTask?.cancel()
    }

    // MARK: - Public API

    /// Serial queue for all `ScheduleStore` disk I/O. Loads and saves used
    /// to run synchronously on the main actor and showed up in hang
    /// reports; routing every read/write through one background queue
    /// keeps the main thread free and preserves write ordering.
    private nonisolated static let ioQueue = DispatchQueue(
        label: "com.dinoki.osaurus.schedule-io", qos: .userInitiated)

    private nonisolated static func persist(_ work: @escaping @Sendable () -> Void) {
        ioQueue.async(execute: work)
    }

    /// Reload schedules from disk (async, off the main actor). Mutating
    /// callers apply their change to `schedules` in-memory first, so this
    /// reconcile only picks up external/disk-side differences.
    public func refresh() {
        Task { @MainActor [weak self] in
            await self?.refreshFromDisk()
        }
    }

    public func refreshFromDisk() async {
        let loaded = await withCheckedContinuation { continuation in
            Self.ioQueue.async { continuation.resume(returning: ScheduleStore.loadAll()) }
        }
        schedules = loaded
        recomputeAgentCounts()
    }

    /// Apply a created/updated schedule to the in-memory list so reads
    /// (timer arming, UI) see it immediately, without waiting on disk.
    private func applyLocal(_ schedule: Schedule) {
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
        schedules.sort { $0.createdAt > $1.createdAt }
        recomputeAgentCounts()
    }

    /// Number of schedules linked to the given agent.
    public func scheduleCount(forAgentId agentId: UUID) -> Int {
        scheduleCountsByAgent[agentId] ?? 0
    }

    private func recomputeAgentCounts() {
        var counts: [UUID: Int] = [:]
        for schedule in schedules {
            guard let agentId = schedule.agentId else { continue }
            counts[agentId, default: 0] += 1
        }
        scheduleCountsByAgent = counts
    }

    /// Create a new schedule
    @discardableResult
    public func create(
        name: String,
        instructions: String,
        agentId: UUID? = nil,
        target: AgentDispatchTarget? = nil,
        parameters: [String: String] = [:],
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        frequency: ScheduleFrequency,
        isEnabled: Bool = true
    ) -> Schedule {
        let schedule = Schedule(
            id: UUID(),
            name: name,
            instructions: instructions,
            agentId: agentId,
            target: target,
            parameters: parameters,
            folderPath: folderPath,
            folderBookmark: folderBookmark,
            frequency: frequency,
            isEnabled: isEnabled,
            createdAt: Date(),
            updatedAt: Date()
        )

        applyLocal(schedule)
        Self.persist { ScheduleStore.save(schedule) }
        scheduleNextTimer()

        NotificationCenter.default.post(name: .schedulesChanged, object: nil)
        print("[Osaurus] Created schedule: \(schedule.name)")

        return schedule
    }

    /// Update an existing schedule
    public func update(_ schedule: Schedule) {
        var updated = schedule
        updated.updatedAt = Date()
        applyLocal(updated)
        Self.persist { [updated] in ScheduleStore.save(updated) }
        // Reconcile: `save` merges run history from the previous on-disk
        // copy, which the in-memory apply above can't see.
        refresh()
        scheduleNextTimer()

        NotificationCenter.default.post(name: .schedulesChanged, object: nil)
        print("[Osaurus] Updated schedule: \(schedule.name)")
    }

    /// Delete a schedule
    @discardableResult
    public func delete(id: UUID) -> Bool {
        // Cancel any running execution
        if let task = executionTasks[id] {
            task.cancel()
            executionTasks.removeValue(forKey: id)
        }
        runningTasks.removeValue(forKey: id)

        guard schedules.contains(where: { $0.id == id }) else { return false }
        schedules.removeAll { $0.id == id }
        recomputeAgentCounts()
        Self.persist { _ = ScheduleStore.delete(id: id) }
        scheduleNextTimer()

        NotificationCenter.default.post(name: .schedulesChanged, object: nil)
        print("[Osaurus] Deleted schedule: \(id)")

        return true
    }

    /// Toggle a schedule's enabled state
    public func setEnabled(_ id: UUID, enabled: Bool) {
        guard var schedule = schedules.first(where: { $0.id == id }) else { return }
        schedule.isEnabled = enabled
        schedule.updatedAt = Date()
        applyLocal(schedule)
        Self.persist { [schedule] in ScheduleStore.save(schedule) }
        scheduleNextTimer()

        NotificationCenter.default.post(name: .schedulesChanged, object: nil)
    }

    /// Get a schedule by ID
    public func schedule(for id: UUID) -> Schedule? {
        schedules.first { $0.id == id }
    }

    /// Check if a schedule is currently running
    public func isRunning(_ scheduleId: UUID) -> Bool {
        runningTasks[scheduleId] != nil
    }

    /// Manually trigger a schedule to run now. Overlapping a scheduled run
    /// is a deliberate refuse — the UI should surface `.alreadyRunning`
    /// rather than start a second turn or toast a fake Started.
    @discardableResult
    public func runNow(_ scheduleId: UUID) -> ScheduleRunNowResult {
        guard let schedule = schedules.first(where: { $0.id == scheduleId }) else {
            return .notFound
        }
        if isInFlight(schedule.id) { return .alreadyRunning }
        // A hand-pressed button. The user is watching this run, so it keeps the
        // normal right to load its model -- even though it arrives with the same
        // `source: .schedule` as the 3am cron fire below. That is exactly why the
        // intent is passed explicitly instead of inferred from `source`.
        return executeSchedule(schedule, loadIntent: .interactive) ? .started : .notFound
    }

    private func isInFlight(_ scheduleId: UUID) -> Bool {
        runningTasks[scheduleId] != nil || executionTasks[scheduleId] != nil
    }

    // MARK: - Plugin Grouping

    /// Key used in `Schedule.parameters` to group schedules by the plugin they
    /// were installed from. Set by the Claude plugin importer.
    /// `nonisolated` so non-MainActor code (aggregator/tests) can read
    /// the key without hopping to the main actor first.
    public nonisolated static let pluginIdParameterKey = "pluginId"

    /// Returns all schedules associated with a plugin id.
    public func schedules(forPluginId pluginId: String) -> [Schedule] {
        schedules.filter { $0.parameters[Self.pluginIdParameterKey] == pluginId }
    }

    /// Delete every schedule installed by a plugin. Returns the number deleted.
    @discardableResult
    public func deleteByPluginId(_ pluginId: String) -> Int {
        let matches = schedules(forPluginId: pluginId)
        var count = 0
        for schedule in matches where delete(id: schedule.id) {
            count += 1
        }
        return count
    }

    /// Cancel a running schedule execution
    public func cancelExecution(_ scheduleId: UUID) {
        if let task = executionTasks[scheduleId] {
            task.cancel()
            executionTasks.removeValue(forKey: scheduleId)
        }

        runningTasks.removeValue(forKey: scheduleId)
    }

    /// Freeze the manager for app termination: cancel the next-run timer, all
    /// in-flight execution tasks, and remove the timezone observer so nothing
    /// can dispatch a new LLM run mid-teardown. Lightweight and synchronous —
    /// safe to call at the top of the quit chain. Idempotent.
    public func stop() {
        cancelTimer()

        if let observer = timezoneObserver {
            NotificationCenter.default.removeObserver(observer)
            timezoneObserver = nil
        }

        for (_, task) in executionTasks {
            task.cancel()
        }
        executionTasks.removeAll()
        runningTasks.removeAll()
    }

    // MARK: - Timer Management

    /// Cancel the current timer task
    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Schedule the next timer based on all enabled schedules
    private func scheduleNextTimer() {
        cancelTimer()

        // Find the next schedule to run
        let enabledSchedules = schedules.filter { $0.isEnabled }
        guard !enabledSchedules.isEmpty else {
            print("[Osaurus] No enabled schedules, timer cancelled")
            return
        }

        // Find the soonest next run date
        let now = Date()
        var soonestDate: Date?
        var schedulesToRun: [Schedule] = []

        for schedule in enabledSchedules {
            guard let nextRun = schedule.nextRunDateAfterExecutionAnchor(asOf: now) else { continue }

            if soonestDate == nil || nextRun < soonestDate! {
                soonestDate = nextRun
                schedulesToRun = [schedule]
            } else if let soonest = soonestDate, abs(nextRun.timeIntervalSince(soonest)) < 1 {
                // Same time (within 1 second tolerance)
                schedulesToRun.append(schedule)
            }
        }

        guard let fireDate = soonestDate else {
            print("[Osaurus] No upcoming schedule runs")
            return
        }

        let delay = max(0, fireDate.timeIntervalSince(now))
        print(
            "[Osaurus] Next schedule timer in \(String(format: "%.1f", delay)) seconds (\(schedulesToRun.count) schedule(s))"
        )

        // Use Task with sleep - clean async/await approach that works with @MainActor
        timerTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.timerFired(scheduledFireDate: fireDate)
            } catch {
                // Task was cancelled
            }
        }
    }

    /// Called when the timer fires
    private func timerFired(scheduledFireDate: Date) {
        let now = Date()

        // Find all schedules that should run now
        let schedulesToRun = schedules.filter { schedule in
            guard schedule.isEnabled else { return false }
            guard !isInFlight(schedule.id) else { return false }
            return schedule.shouldRunNow(asOf: now)
        }

        // Timer fired on its own. Nobody is waiting on this, so it must not
        // evict the model the user is actually chatting with.
        for schedule in schedulesToRun {
            executeSchedule(schedule, loadIntent: .background, scheduledFireTime: scheduledFireDate)
        }

        // Schedule the next timer
        scheduleNextTimer()
    }

    /// Check for any schedules that were missed while app was closed
    private func checkForMissedSchedules() {
        let now = Date()

        for schedule in schedules where schedule.isEnabled {
            guard !isInFlight(schedule.id) else { continue }

            if case .once(let date) = schedule.frequency {
                if date <= now && schedule.executionAnchor == nil {
                    print("[Osaurus] Found missed once schedule: \(schedule.name)")
                    executeSchedule(schedule, loadIntent: .background, scheduledFireTime: date)
                }
            } else if schedule.hasMissedRecurringRun(asOf: now),
                let slot = schedule.latestDueSlot(asOf: now)
            {
                print("[Osaurus] Found missed recurring schedule: \(schedule.name)")
                executeSchedule(schedule, loadIntent: .background, scheduledFireTime: slot)
            }
        }
    }

    // MARK: - Execution

    /// Execute a schedule by dispatching to TaskDispatcher.
    /// `scheduledFireTime` is the slot the timer or missed path was armed
    /// for. `runNow` leaves it nil and stamps wall clock.
    @discardableResult
    private func executeSchedule(
        _ schedule: Schedule,
        loadIntent: ModelLoadIntent,
        scheduledFireTime: Date? = nil
    ) -> Bool {
        if isInFlight(schedule.id) { return false }

        // Schedules MUST target an explicit custom agent. nil or built-in
        // agentIds were previously coerced to `Agent.defaultId`, silently
        // running anonymous schedules under the Default agent. Refuse the
        // execution outright now — the Schedules tab requires a real agent
        // selection when creating a schedule. A shared workspace agent is a
        // teammate's custom agent by construction (the router never shares
        // a built-in), so the local guard applies to local targets only;
        // `BackgroundTaskManager` runs the relay preflight for workspace
        // targets and refuses offline / unshared hosts before queueing.
        if schedule.workspaceTarget == nil,
            let rejection = Agent.rejectBuiltInForExternalSurface(
                schedule.agentId,
                source: "schedule/executeSchedule"
            )
        {
            print("[Osaurus] Skipping schedule '\(schedule.name)': \(rejection.message)")
            return false
        }

        var triggeredSchedule = schedule
        triggeredSchedule.lastTriggeredAt = scheduledFireTime ?? Date()
        applyLocal(triggeredSchedule)
        Self.persist { [triggeredSchedule] in ScheduleStore.save(triggeredSchedule) }

        let runInfo = ScheduleRunInfo(
            scheduleId: triggeredSchedule.id,
            scheduleName: triggeredSchedule.name,
            agentId: triggeredSchedule.agentId,
            chatSessionId: UUID()
        )
        runningTasks[triggeredSchedule.id] = runInfo

        let request = DispatchRequest(
            prompt: triggeredSchedule.instructions,
            target: triggeredSchedule.target,
            title: triggeredSchedule.name,
            parameters: triggeredSchedule.parameters,
            folderPath: triggeredSchedule.folderPath,
            folderBookmark: triggeredSchedule.folderBookmark,
            source: .schedule,
            externalSessionKey: triggeredSchedule.id.uuidString,
            loadIntent: loadIntent
        )

        print("[Osaurus] Executing schedule: \(triggeredSchedule.name)")

        let task = Task { @MainActor in
            guard let handle = await TaskDispatcher.shared.dispatch(request) else {
                // A refused workspace run (host offline, unshared, key
                // lapsed) is a normal failed fire: log the reason, keep the
                // regular next-fire time, and never retry in a loop.
                if let ref = triggeredSchedule.workspaceTarget,
                    let reason = BackgroundTaskManager.shared.consumeWorkspaceDispatchRefusal(for: ref)
                {
                    print("[Osaurus] Schedule '\(triggeredSchedule.name)' refused: \(reason)")
                } else {
                    print("[Osaurus] Failed to dispatch schedule: \(triggeredSchedule.name)")
                }
                self.executionTasks.removeValue(forKey: triggeredSchedule.id)
                self.runningTasks.removeValue(forKey: triggeredSchedule.id)
                return
            }

            let result = await TaskDispatcher.shared.awaitCompletion(handle)
            self.handleResult(result, schedule: triggeredSchedule, request: handle.request)
        }

        executionTasks[triggeredSchedule.id] = task
        return true
    }

    // MARK: - Result Handling

    /// Update schedule metadata after task completion.
    /// Result UI is handled by the chat sidebar's Activity section.
    private func handleResult(_ result: DispatchResult, schedule: Schedule, request: DispatchRequest) {
        defer {
            executionTasks.removeValue(forKey: schedule.id)
            runningTasks.removeValue(forKey: schedule.id)
        }

        switch result {
        case .completed(let sessionId):
            let chatSessionId = sessionId ?? UUID()

            var updatedSchedule = schedules.first(where: { $0.id == schedule.id }) ?? schedule
            let completionTime = Date()
            updatedSchedule.lastRunAt = max(completionTime, updatedSchedule.lastTriggeredAt ?? completionTime)
            updatedSchedule.lastChatSessionId = chatSessionId
            if case .once = schedule.frequency { updatedSchedule.isEnabled = false }

            applyLocal(updatedSchedule)
            Self.persist { [updatedSchedule] in ScheduleStore.save(updatedSchedule) }

            // executeSchedule rejects schedules without a real custom-agent
            // id up front, so `schedule.agentId` is guaranteed non-nil here.
            // The previous `?? Agent.defaultId` notification fallback would
            // have mis-attributed result toasts to the Default agent for
            // any zombie schedule slipping through.
            var userInfo: [String: Any] = [
                "scheduleId": schedule.id,
                "sessionId": chatSessionId,
            ]
            if let agentId = schedule.agentId {
                userInfo["agentId"] = agentId
            }
            NotificationCenter.default.post(
                name: .scheduleExecutionCompleted,
                object: nil,
                userInfo: userInfo
            )
            print("[Osaurus] Schedule completed: \(schedule.name)")

        case .cancelled:
            print("[Osaurus] Schedule cancelled: \(schedule.name)")

        case .failed(let error):
            print("[Osaurus] Schedule failed: \(schedule.name) - \(error)")
        }
    }
}
