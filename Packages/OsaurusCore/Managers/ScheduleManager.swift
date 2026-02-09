//
//  ScheduleManager.swift
//  osaurus
//
//  Manages scheduled tasks with precise timer-based execution.
//  Uses efficient scheduling that only wakes when needed.
//

import Combine
import Foundation

/// Notification posted when schedules change
extension Notification.Name {
    public static let schedulesChanged = Notification.Name("schedulesChanged")
    public static let scheduleExecutionCompleted = Notification.Name("scheduleExecutionCompleted")
}

/// Manages scheduled AI tasks with precise timer-based execution
@MainActor
public final class ScheduleManager: ObservableObject {
    public static let shared = ScheduleManager()

    // MARK: - Published State

    /// All schedules
    @Published public private(set) var schedules: [Schedule] = []

    /// Currently running tasks (schedule ID -> run info)
    @Published public private(set) var runningTasks: [UUID: ScheduleRunInfo] = [:]

    // MARK: - Private State

    /// The task that waits for the next scheduled execution
    private var timerTask: Task<Void, Never>?

    /// Active execution tasks
    private var executionTasks: [UUID: Task<Void, Never>] = [:]

    /// Observer for timezone changes
    private nonisolated(unsafe) var timezoneObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        // Load schedules from disk
        refresh()

        // Check for missed schedules on startup
        checkForMissedSchedules()

        // Schedule the next timer
        scheduleNextTimer()

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
        objectWillChange.send()
    }

    /// Create a new schedule
    @discardableResult
    public func create(
        name: String,
        instructions: String,
        personaId: UUID? = nil,
        mode: ChatMode = .chat,
        parameters: [String: String] = [:],
        frequency: ScheduleFrequency,
        isEnabled: Bool = true
    ) -> Schedule {
        let schedule = Schedule(
            id: UUID(),
            name: name,
            instructions: instructions,
            personaId: personaId,
            mode: mode,
            parameters: parameters,
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

    /// Cancel a running schedule execution
    public func cancelExecution(_ scheduleId: UUID) {
        if let task = executionTasks[scheduleId] {
            task.cancel()
            executionTasks.removeValue(forKey: scheduleId)
        }

        runningTasks.removeValue(forKey: scheduleId)
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
            guard let nextRun = schedule.frequency.nextRunDate(after: now) else { continue }

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

            // Determine reference time for checking next run:
            // - If schedule has run before, use lastRunAt (finds the next run after that)
            // - Otherwise, look back up to 1 hour (handles new schedules + system sleep)
            let checkFrom: Date
            if let lastRun = schedule.lastRunAt {
                checkFrom = lastRun
            } else {
                checkFrom = now.addingTimeInterval(-3600)  // 1 hour ago
            }

            guard let nextRun = schedule.frequency.nextRunDate(after: checkFrom) else { return false }

            // Run if the scheduled time is now or in the recent past (with small future tolerance)
            return nextRun <= now.addingTimeInterval(60)
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
                if date <= now && schedule.lastRunAt == nil {
                    print("[Osaurus] Found missed once schedule: \(schedule.name)")
                    executeSchedule(schedule)
                }
            } else {
                // For recurring schedules, check if we missed the last run
                // Only run if lastRunAt is nil or the next run after lastRunAt is in the past
                if let lastRun = schedule.lastRunAt {
                    if let nextAfterLast = schedule.frequency.nextRunDate(after: lastRun),
                        nextAfterLast <= now
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
        let request = DispatchRequest(
            mode: schedule.mode,
            prompt: schedule.instructions,
            personaId: schedule.personaId,
            title: schedule.name,
            parameters: schedule.parameters
        )

        print("[Osaurus] Executing schedule: \(schedule.name) (\(schedule.mode.displayName) mode)")

        let task = Task { @MainActor in
            guard let handle = await TaskDispatcher.shared.dispatch(request) else {
                print("[Osaurus] Failed to dispatch schedule: \(schedule.name)")
                return
            }

            self.runningTasks[schedule.id] = ScheduleRunInfo(
                scheduleId: schedule.id,
                scheduleName: schedule.name,
                personaId: schedule.personaId,
                chatSessionId: UUID()
            )

            let result = await TaskDispatcher.shared.awaitCompletion(handle)
            self.handleResult(result, schedule: schedule, request: handle.request)
        }

        executionTasks[schedule.id] = task
    }

    // MARK: - Result Handling

    /// Update schedule metadata and show result toast via TaskDispatcher.
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

            TaskDispatcher.shared.showResultToast(for: request, result: result)

            NotificationCenter.default.post(
                name: .scheduleExecutionCompleted,
                object: nil,
                userInfo: [
                    "scheduleId": schedule.id,
                    "sessionId": chatSessionId,
                    "personaId": schedule.personaId ?? Persona.defaultId,
                ]
            )
            print("[Osaurus] Schedule completed: \(schedule.name)")

        case .cancelled:
            print("[Osaurus] Schedule cancelled: \(schedule.name)")

        case .failed(let error):
            print("[Osaurus] Schedule failed: \(schedule.name) - \(error)")
            TaskDispatcher.shared.showResultToast(for: request, result: result)
        }
    }
}
