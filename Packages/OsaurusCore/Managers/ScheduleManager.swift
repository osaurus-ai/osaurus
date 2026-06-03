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
        // Load schedules from disk
        refresh()

        // Schedule the next timer (cheap — just arms a Task.sleep).
        scheduleNextTimer()

        // Check for missed schedules on startup. Deferred to a later
        // main-actor turn so it doesn't run synchronously on the
        // launch-critical path while `.shared` is being constructed
        // (the App struct builds this property before
        // `applicationDidFinishLaunching`). `checkForMissedSchedules`
        // can immediately dispatch LLM work, which must not block launch.
        Task { @MainActor [weak self] in
            self?.checkForMissedSchedules()
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

        print("[Osaurus] ScheduleManager initialized with \(schedules.count) schedules")
    }

    deinit {
        if let observer = timezoneObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        timerTask?.cancel()
    }

    // MARK: - Public API

    /// Reload schedules from disk
    public func refresh() {
        schedules = ScheduleStore.loadAll()
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
            parameters: parameters,
            folderPath: folderPath,
            folderBookmark: folderBookmark,
            frequency: frequency,
            isEnabled: isEnabled,
            createdAt: Date(),
            updatedAt: Date()
        )

        ScheduleStore.save(schedule)
        refresh()
        scheduleNextTimer()

        NotificationCenter.default.post(name: .schedulesChanged, object: nil)
        print("[Osaurus] Created schedule: \(schedule.name)")

        return schedule
    }

    /// Update an existing schedule
    public func update(_ schedule: Schedule) {
        var updated = schedule
        updated.updatedAt = Date()
        ScheduleStore.save(updated)
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

        guard ScheduleStore.delete(id: id) else { return false }

        refresh()
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
        ScheduleStore.save(schedule)
        refresh()
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

    /// Manually trigger a schedule to run now
    public func runNow(_ scheduleId: UUID) {
        guard let schedule = schedules.first(where: { $0.id == scheduleId }) else { return }
        executeSchedule(schedule)
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
                self?.timerFired()
            } catch {
                // Task was cancelled
            }
        }
    }

    /// Called when the timer fires
    private func timerFired() {
        let now = Date()

        // Find all schedules that should run now
        let schedulesToRun = schedules.filter { schedule in
            guard schedule.isEnabled else { return false }
            guard !runningTasks.keys.contains(schedule.id) else { return false }  // Already running
            return schedule.shouldRunNow(asOf: now)
        }

        // Execute all due schedules
        for schedule in schedulesToRun {
            executeSchedule(schedule)
        }

        // Schedule the next timer
        scheduleNextTimer()
    }

    /// Check for any schedules that were missed while app was closed
    private func checkForMissedSchedules() {
        let now = Date()

        for schedule in schedules where schedule.isEnabled {
            // Skip if already running
            guard !runningTasks.keys.contains(schedule.id) else { continue }

            // For "once" schedules, check if the time has passed
            if case .once(let date) = schedule.frequency {
                // If the once date is in the past but hasn't run yet
                if date <= now && schedule.executionAnchor == nil {
                    print("[Osaurus] Found missed once schedule: \(schedule.name)")
                    executeSchedule(schedule)
                }
            } else {
                // For recurring schedules, check if we missed the last run
                // Only run if an execution anchor exists and the next run after it is in the past.
                if let anchor = schedule.executionAnchor {
                    if let nextAfterAnchor = schedule.frequency.nextRunDate(after: anchor),
                        nextAfterAnchor <= now
                    {
                        print("[Osaurus] Found missed recurring schedule: \(schedule.name)")
                        executeSchedule(schedule)
                    }
                }
            }
        }
    }

    // MARK: - Execution

    /// Execute a schedule by dispatching to TaskDispatcher
    private func executeSchedule(_ schedule: Schedule) {
        // Schedules MUST target an explicit custom agent. nil or built-in
        // agentIds were previously coerced to `Agent.defaultId`, silently
        // running anonymous schedules under the Default agent. Refuse the
        // execution outright now — the Schedules tab requires a real agent
        // selection when creating a schedule.
        if let rejection = Agent.rejectBuiltInForExternalSurface(
            schedule.agentId,
            source: "schedule/executeSchedule"
        ) {
            print("[Osaurus] Skipping schedule '\(schedule.name)': \(rejection.message)")
            return
        }

        var triggeredSchedule = schedule
        triggeredSchedule.lastTriggeredAt = Date()
        ScheduleStore.save(triggeredSchedule)
        refresh()

        let request = DispatchRequest(
            prompt: triggeredSchedule.instructions,
            agentId: triggeredSchedule.agentId,
            title: triggeredSchedule.name,
            parameters: triggeredSchedule.parameters,
            folderPath: triggeredSchedule.folderPath,
            folderBookmark: triggeredSchedule.folderBookmark,
            source: .schedule,
            externalSessionKey: triggeredSchedule.id.uuidString
        )

        print("[Osaurus] Executing schedule: \(triggeredSchedule.name)")

        let task = Task { @MainActor in
            guard let handle = await TaskDispatcher.shared.dispatch(request) else {
                print("[Osaurus] Failed to dispatch schedule: \(triggeredSchedule.name)")
                self.executionTasks.removeValue(forKey: triggeredSchedule.id)
                return
            }

            self.runningTasks[triggeredSchedule.id] = ScheduleRunInfo(
                scheduleId: triggeredSchedule.id,
                scheduleName: triggeredSchedule.name,
                agentId: triggeredSchedule.agentId,
                chatSessionId: UUID()
            )

            let result = await TaskDispatcher.shared.awaitCompletion(handle)
            self.handleResult(result, schedule: triggeredSchedule, request: handle.request)
        }

        executionTasks[triggeredSchedule.id] = task
    }

    // MARK: - Result Handling

    /// Update schedule metadata after task completion.
    /// Result UI is handled by the NotchView.
    private func handleResult(_ result: DispatchResult, schedule: Schedule, request: DispatchRequest) {
        defer {
            executionTasks.removeValue(forKey: schedule.id)
            runningTasks.removeValue(forKey: schedule.id)
        }

        switch result {
        case .completed(let sessionId):
            let chatSessionId = sessionId ?? UUID()

            var updatedSchedule = schedule
            updatedSchedule.lastRunAt = Date()
            updatedSchedule.lastChatSessionId = chatSessionId
            if case .once = schedule.frequency { updatedSchedule.isEnabled = false }

            ScheduleStore.save(updatedSchedule)
            refresh()

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
