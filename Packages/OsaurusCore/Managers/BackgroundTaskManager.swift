//
//  BackgroundTaskManager.swift
//  osaurus
//
//  Manages agent sessions that continue running after their window is closed.
//  Provides toast integration and window restoration for background tasks.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Background Task Manager

/// Manages detached agent sessions running in background mode
@MainActor
public final class BackgroundTaskManager: ObservableObject {
    public static let shared = BackgroundTaskManager()

    // MARK: - Published State

    /// All background tasks keyed by their original window ID
    @Published public private(set) var backgroundTasks: [UUID: BackgroundTaskState] = [:]

    // MARK: - Private State

    /// Combined cancellables for each task (session + state observers)
    private var taskObservers: [UUID: Set<AnyCancellable>] = [:]

    /// Subject for batching view updates with throttling
    private let viewUpdateSubject = PassthroughSubject<Void, Never>()
    private var viewUpdateCancellable: AnyCancellable?

    // MARK: - Initialization

    private init() {
        setupThrottledViewUpdates()
    }

    /// Setup throttled view updates to prevent excessive re-renders
    private func setupThrottledViewUpdates() {
        viewUpdateCancellable =
            viewUpdateSubject
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
    }

    // MARK: - Public API

    /// Detach a window's agent session to run in background
    @discardableResult
    func detachWindow(
        _ windowId: UUID,
        session: AgentSession,
        windowState: ChatWindowState
    ) -> BackgroundTaskState? {
        guard backgroundTasks[windowId] == nil else {
            return backgroundTasks[windowId]
        }

        guard let currentTask = session.currentTask else {
            return nil
        }

        // Create background task state with initial values
        let state = createInitialState(
            windowId: windowId,
            task: currentTask,
            session: session,
            windowState: windowState
        )

        backgroundTasks[windowId] = state

        // Setup consolidated observation
        observeTask(state, session: session)

        // Seed the activity feed so the toast has immediate context
        state.appendActivity(kind: .info, title: "Running in background")

        print("[BackgroundTaskManager] Detached window \(windowId) with task '\(currentTask.title)'")
        return state
    }

    /// Check if a window is a background task
    public func isBackgroundTask(_ windowId: UUID) -> Bool {
        backgroundTasks[windowId] != nil
    }

    /// Get background task state for a window
    public func taskState(for windowId: UUID) -> BackgroundTaskState? {
        backgroundTasks[windowId]
    }

    /// Open a window for a background task
    public func openTaskWindow(_ backgroundId: UUID) {
        guard let state = backgroundTasks[backgroundId] else { return }

        ChatWindowManager.shared.createWindowForBackgroundTask(
            backgroundId: backgroundId,
            session: state.session,
            windowState: state.windowState
        )

        // Remove from background management - will re-detach if closed while running
        finalizeTask(backgroundId)
    }

    /// Finalize a background task (remove from background management)
    public func finalizeTask(_ backgroundId: UUID) {
        guard backgroundTasks[backgroundId] != nil else { return }

        // Clean up all observers for this task
        taskObservers[backgroundId]?.forEach { $0.cancel() }
        taskObservers.removeValue(forKey: backgroundId)

        backgroundTasks.removeValue(forKey: backgroundId)
    }

    /// Cancel a background task
    public func cancelTask(_ backgroundId: UUID) {
        guard let state = backgroundTasks[backgroundId] else { return }
        state.session.stopExecution()
        state.status = .cancelled
    }

    /// Submit a clarification response
    public func submitClarification(_ backgroundId: UUID, response: String) {
        guard let state = backgroundTasks[backgroundId] else { return }
        Task {
            await state.session.submitClarification(response)
        }
    }

    // MARK: - Private: State Creation

    private func createInitialState(
        windowId: UUID,
        task: AgentTask,
        session: AgentSession,
        windowState: ChatWindowState
    ) -> BackgroundTaskState {
        let state = BackgroundTaskState(
            id: windowId,
            taskId: task.id,
            taskTitle: task.title,
            personaId: windowState.personaId,
            session: session,
            windowState: windowState,
            status: session.hasPendingClarification ? .awaitingClarification : .running,
            progress: calculateProgress(session: session),
            currentStep: getCurrentStep(session: session),
            pendingClarification: session.pendingClarification
        )

        // Copy additional state
        state.issues = session.issues
        state.activeIssueId = session.activeIssue?.id
        state.currentPlan = session.currentPlan
        state.currentPlanStep = session.currentStep

        return state
    }

    // MARK: - Private: Consolidated Observation

    private func observeTask(_ state: BackgroundTaskState, session: AgentSession) {
        var cancellables = Set<AnyCancellable>()
        let windowId = state.id

        // Forward state changes with throttling
        state.objectWillChange
            .sink { [weak self] _ in
                self?.viewUpdateSubject.send()
            }
            .store(in: &cancellables)

        // Combine execution-related publishers for batched updates
        Publishers.CombineLatest3(
            session.$isExecuting,
            session.$pendingClarification,
            session.$currentTask
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] isExecuting, clarification, task in
            self?.handleExecutionChange(
                windowId: windowId,
                isExecuting: isExecuting,
                clarification: clarification,
                task: task,
                session: session
            )
        }
        .store(in: &cancellables)

        // Combine progress-related publishers
        Publishers.CombineLatest3(
            session.$issues,
            session.$currentPlan,
            session.$currentStep
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] issues, plan, stepIndex in
            self?.handleProgressChange(
                windowId: windowId,
                issues: issues,
                plan: plan,
                stepIndex: stepIndex,
                session: session
            )
        }
        .store(in: &cancellables)

        // Observe active issue separately (less frequent)
        session.$activeIssue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] issue in
                guard let state = self?.backgroundTasks[windowId] else { return }
                state.activeIssueId = issue?.id
            }
            .store(in: &cancellables)

        // Observe activity events for the toast mini-log
        session.activityPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, let state = self.backgroundTasks[windowId] else { return }
                self.recordActivityEvent(event, into: state)
            }
            .store(in: &cancellables)

        taskObservers[windowId] = cancellables
    }

    // MARK: - Private: Activity Event Mapping

    private func recordActivityEvent(_ event: AgentActivityEvent, into state: BackgroundTaskState) {
        switch event {
        case .startedIssue(let title):
            state.appendActivity(kind: .info, title: "Issue", detail: title)

        case .planCreated(let stepCount):
            state.appendActivity(kind: .info, title: "Plan", detail: "\(stepCount) steps")

        case .willExecuteStep(let index, let total, let description):
            // Suppress unused variable warnings - parameters are intentionally not used here.
            // Step info is already shown in the toast header + progress bar, so we skip
            // redundant mini-log entries to keep the activity feed focused on high-signal events.
            _ = index; _ = total; _ = description
            return

        case .completedStep(let index, let total):
            // Suppress unused variable warnings - parameters are intentionally not used here.
            // Step completion is reflected via the progress bar UI, no need for mini-log entry.
            _ = index; _ = total
            return

        case .toolExecuted(let name):
            state.appendActivity(kind: .tool, title: "Tool", detail: name)

        case .needsClarification:
            state.appendActivity(kind: .warning, title: "Needs input")

        case .injectedUserInput:
            state.appendActivity(kind: .info, title: "Context injected")

        case .retrying(let attempt, let waitSeconds):
            state.appendActivity(kind: .warning, title: "Retrying", detail: "Attempt \(attempt), wait \(waitSeconds)s")

        case .generatedArtifact(let filename, let isFinal):
            state.appendActivity(kind: .info, title: isFinal ? "Final artifact" : "Artifact", detail: filename)

        case .completedIssue(let success):
            state.appendActivity(kind: success ? .success : .error, title: success ? "Issue completed" : "Issue failed")
        }
    }

    // MARK: - Private: State Update Handlers

    private func handleExecutionChange(
        windowId: UUID,
        isExecuting: Bool,
        clarification: ClarificationRequest?,
        task: AgentTask?,
        session: AgentSession
    ) {
        guard let state = backgroundTasks[windowId] else { return }

        // Update clarification
        state.pendingClarification = clarification

        // Determine status
        if task?.status == .cancelled {
            state.status = .cancelled
        } else if clarification != nil {
            state.status = .awaitingClarification
        } else if isExecuting {
            state.status = .running
            if state.currentStep == nil {
                state.currentStep = "Working..."
            }
        } else {
            // Execution stopped - check completion
            checkTaskCompletion(state: state, session: session)
        }
    }

    private func handleProgressChange(
        windowId: UUID,
        issues: [Issue],
        plan: ExecutionPlan?,
        stepIndex: Int,
        session: AgentSession
    ) {
        guard let state = backgroundTasks[windowId] else { return }

        // Update raw state
        state.issues = issues
        state.currentPlan = plan
        state.currentPlanStep = stepIndex

        // Calculate and update progress
        let newProgress = calculateProgress(
            issues: issues,
            plan: plan,
            stepIndex: stepIndex,
            isExecuting: session.isExecuting
        )

        // Only update if progress changed significantly (reduces re-renders)
        let significantChange = abs(state.progress - newProgress) > 0.01
        let indeterminateChanged = (state.progress < 0) != (newProgress < 0)
        if significantChange || indeterminateChanged {
            state.progress = newProgress
        }

        // Update current step description
        state.currentStep = getCurrentStep(
            issues: issues,
            plan: plan,
            stepIndex: stepIndex,
            isExecuting: session.isExecuting
        )
    }

    // MARK: - Private: Progress Calculation

    private func calculateProgress(session: AgentSession) -> Double {
        calculateProgress(
            issues: session.issues,
            plan: session.currentPlan,
            stepIndex: session.currentStep,
            isExecuting: session.isExecuting
        )
    }

    private func calculateProgress(
        issues: [Issue],
        plan: ExecutionPlan?,
        stepIndex: Int,
        isExecuting: Bool
    ) -> Double {
        let totalIssues = issues.count

        if totalIssues > 0 {
            let closedIssues = issues.filter { $0.status == .closed }.count
            var progress = Double(closedIssues) / Double(totalIssues)

            // Add fractional progress from current plan
            if let plan = plan, !plan.steps.isEmpty {
                let stepProgress = Double(min(stepIndex, plan.steps.count)) / Double(plan.steps.count)
                progress += stepProgress / Double(totalIssues)
            }

            return progress
        } else if let plan = plan, !plan.steps.isEmpty {
            return Double(min(stepIndex, plan.steps.count)) / Double(plan.steps.count)
        } else if isExecuting {
            return -1  // Indeterminate
        }

        return 0
    }

    private func getCurrentStep(session: AgentSession) -> String? {
        getCurrentStep(
            issues: session.issues,
            plan: session.currentPlan,
            stepIndex: session.currentStep,
            isExecuting: session.isExecuting
        )
    }

    private func getCurrentStep(
        issues: [Issue],
        plan: ExecutionPlan?,
        stepIndex: Int,
        isExecuting: Bool
    ) -> String? {
        if let plan = plan, !plan.steps.isEmpty {
            if stepIndex < plan.steps.count {
                return plan.steps[stepIndex].description
            } else {
                return issues.count > 1 ? "Completing issue..." : "Completing..."
            }
        } else if isExecuting {
            return "Working..."
        }
        return nil
    }

    // MARK: - Private: Completion Check

    private func checkTaskCompletion(state: BackgroundTaskState, session: AgentSession) {
        guard !session.hasPendingClarification else { return }

        let issues = session.issues
        let allIssuesClosed = !issues.isEmpty && issues.allSatisfy { $0.status == .closed }
        let taskCompleted = session.currentTask?.status == .completed

        if allIssuesClosed || taskCompleted {
            state.status = .completed(success: true, summary: "Task completed successfully")
            state.progress = 1.0
            state.currentStep = nil
        } else if session.currentTask == nil {
            let closedCount = issues.filter { $0.status == .closed }.count
            let summary =
                !issues.isEmpty
                ? "Completed \(closedCount)/\(issues.count) issues"
                : "Task ended"
            state.status = .completed(success: closedCount == issues.count, summary: summary)
        }
    }
}
