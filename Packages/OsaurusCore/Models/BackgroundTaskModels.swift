//
//  BackgroundTaskModels.swift
//  osaurus
//
//  Data models for background task management.
//  Used when agent tasks continue running after their window is closed.
//

import Foundation

// MARK: - Background Task Status

/// Status of a background task
public enum BackgroundTaskStatus: Equatable, Sendable {
    /// Task is actively executing
    case running
    /// Task is paused waiting for user clarification
    case awaitingClarification
    /// Task has completed (success or failure)
    case completed(success: Bool, summary: String)
    /// Task was cancelled
    case cancelled

    /// Whether the task is still active (running or awaiting input)
    public var isActive: Bool {
        switch self {
        case .running, .awaitingClarification:
            return true
        case .completed, .cancelled:
            return false
        }
    }

    /// Display name for UI
    public var displayName: String {
        switch self {
        case .running:
            return "Running"
        case .awaitingClarification:
            return "Waiting"
        case .completed(let success, _):
            return success ? "Completed" : "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Icon name for UI
    public var iconName: String {
        switch self {
        case .running:
            return "arrow.triangle.2.circlepath"
        case .awaitingClarification:
            return "questionmark.circle.fill"
        case .completed(let success, _):
            return success ? "checkmark.circle.fill" : "xmark.circle.fill"
        case .cancelled:
            return "stop.circle.fill"
        }
    }
}

// MARK: - Background Task State

/// State of a task running in the background
/// This is an observable class to allow BackgroundTaskManager to update properties
@MainActor
public final class BackgroundTaskState: ObservableObject, Identifiable {
    /// Original window ID (unique identifier for this background task)
    public let id: UUID

    /// Agent task ID
    public let taskId: String

    /// Display title for the task
    public let taskTitle: String

    /// Persona ID associated with this task
    public let personaId: UUID

    /// The agent session (retained reference, keeps task executing)
    let session: AgentSession

    /// The window state (retained for window recreation)
    let windowState: ChatWindowState

    /// Current status of the background task
    @Published public var status: BackgroundTaskStatus

    /// Progress of the task (0.0 to 1.0, or -1 for indeterminate)
    @Published public var progress: Double

    /// Description of current step being executed
    @Published public var currentStep: String?

    /// Issues for the task
    @Published public var issues: [Issue] = []

    /// ID of the currently active issue
    @Published public var activeIssueId: String?

    /// Current execution plan with steps
    @Published public var currentPlan: ExecutionPlan?

    /// Current step index being executed (0-based)
    @Published public var currentPlanStep: Int = 0

    /// Pending clarification request (when status is .awaitingClarification)
    @Published public var pendingClarification: ClarificationRequest?

    /// When the background task was created
    public let createdAt: Date

    init(
        id: UUID,
        taskId: String,
        taskTitle: String,
        personaId: UUID,
        session: AgentSession,
        windowState: ChatWindowState,
        status: BackgroundTaskStatus = .running,
        progress: Double = 0.0,
        currentStep: String? = nil,
        pendingClarification: ClarificationRequest? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.personaId = personaId
        self.session = session
        self.windowState = windowState
        self.status = status
        self.progress = progress
        self.currentStep = currentStep
        self.pendingClarification = pendingClarification
        self.createdAt = Date()
    }
}
