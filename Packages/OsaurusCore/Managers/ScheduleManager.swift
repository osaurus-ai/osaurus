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

    /// The timer for the next scheduled execution
    private nonisolated(unsafe) var nextTimer: DispatchSourceTimer?

    /// The queue for timer operations
    private let timerQueue = DispatchQueue(label: "com.osaurus.scheduleTimer", qos: .utility)

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
        // Cancel timer directly since we can't call @MainActor methods from deinit
        nextTimer?.cancel()
        nextTimer = nil
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
        frequency: ScheduleFrequency,
        isEnabled: Bool = true
    ) -> Schedule {
        let schedule = Schedule(
            id: UUID(),
            name: name,
            instructions: instructions,
            personaId: personaId,
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

        if let runInfo = runningTasks[scheduleId], let toastId = runInfo.toastId {
            ToastManager.shared.dismiss(id: toastId)
        }
        runningTasks.removeValue(forKey: scheduleId)
    }

    // MARK: - Timer Management

    /// Cancel the current timer
    private func cancelTimer() {
        nextTimer?.cancel()
        nextTimer = nil
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

        // Create precise timer
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            // Dispatch to main queue for @MainActor safety
            DispatchQueue.main.async {
                self?.timerFired()
            }
        }
        timer.resume()
        nextTimer = timer
    }

    /// Called when the timer fires
    private func timerFired() {
        let now = Date()

        // Find all schedules that should run now
        let schedulesToRun = schedules.filter { schedule in
            guard schedule.isEnabled else { return false }
            guard !runningTasks.keys.contains(schedule.id) else { return false }  // Already running
            guard let nextRun = schedule.frequency.nextRunDate() else { return false }
            // Run if the next run time is now or in the past (within 60s tolerance)
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

    /// Execute a schedule by creating a chat window and using its session for streaming
    private func executeSchedule(_ schedule: Schedule) {
        let personaId = schedule.personaId ?? Persona.defaultId

        // Create the chat window (hidden) - this gives us a real ChatSession with proper streaming
        let windowId = ChatWindowManager.shared.createWindow(personaId: personaId, showImmediately: false)

        // Get the window state and session
        guard let windowState = ChatWindowManager.shared.windowState(id: windowId) else {
            print("[Osaurus] Failed to get window state for schedule: \(schedule.name)")
            return
        }

        let session = windowState.session

        // Set the session title to the schedule name
        session.title = schedule.name

        // Create run info (session ID will be assigned when message is sent)
        var runInfo = ScheduleRunInfo(
            scheduleId: schedule.id,
            scheduleName: schedule.name,
            personaId: schedule.personaId,
            chatSessionId: UUID(),  // Placeholder, will be updated
            startedAt: Date()
        )

        // Show loading toast with action to show the chat window
        let loadingToast = Toast(
            type: .loading,
            title: "Running \"\(schedule.name)\"",
            message: "Tap to view progress...",
            personaId: personaId,
            actionTitle: "View",
            action: .showChatWindow(windowId: windowId)
        )
        let toastId = ToastManager.shared.show(loadingToast)
        runInfo.toastId = toastId

        runningTasks[schedule.id] = runInfo

        print("[Osaurus] Executing schedule: \(schedule.name)")

        // Execute in a task to properly await model loading before sending
        let task = Task { @MainActor in
            // Ensure model options are loaded (ChatSession.init starts this async but may not be done)
            await session.refreshModelOptions()

            // Send the message - this triggers ChatSession's streaming which updates the UI in real-time
            session.send(schedule.instructions)

            // Observe when streaming completes
            await self.observeCompletion(
                schedule: schedule,
                session: session,
                windowId: windowId,
                toastId: toastId
            )
        }

        executionTasks[schedule.id] = task
    }

    /// Observe the ChatSession until streaming completes
    private func observeCompletion(
        schedule: Schedule,
        session: ChatSession,
        windowId: UUID,
        toastId: UUID
    ) async {
        // Wait for streaming to start (give it a moment)
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Poll until streaming completes or task is cancelled
        while session.isStreaming && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)  // 250ms polling
        }

        // Check for cancellation
        guard !Task.isCancelled else {
            print("[Osaurus] Schedule execution cancelled: \(schedule.name)")
            ToastManager.shared.dismiss(id: toastId)
            // Close the hidden window if cancelled
            ChatWindowManager.shared.closeWindow(id: windowId)
            cleanupExecution(scheduleId: schedule.id)
            return
        }

        // Get the session ID (it's created when the first message is sent)
        let chatSessionId = session.sessionId ?? UUID()

        // Update run info with actual session ID
        if var runInfo = runningTasks[schedule.id] {
            runInfo.chatSessionId = chatSessionId
            runningTasks[schedule.id] = runInfo
        }

        // Update schedule with last run info
        var updatedSchedule = schedule
        updatedSchedule.lastRunAt = Date()
        updatedSchedule.lastChatSessionId = chatSessionId

        // Auto-disable "once" schedules after execution
        if case .once = schedule.frequency {
            updatedSchedule.isEnabled = false
        }

        ScheduleStore.save(updatedSchedule)
        refresh()

        // Dismiss loading toast and show success
        ToastManager.shared.dismiss(id: toastId)

        ToastManager.shared.action(
            "Completed \"\(schedule.name)\"",
            message: "Scheduled task finished successfully",
            action: .showChatWindow(windowId: windowId),
            buttonTitle: "View Chat",
            timeout: 10.0
        )

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

        // Cleanup
        cleanupExecution(scheduleId: schedule.id)
    }

    /// Clean up after execution completes
    private func cleanupExecution(scheduleId: UUID) {
        executionTasks.removeValue(forKey: scheduleId)
        runningTasks.removeValue(forKey: scheduleId)
    }
}
