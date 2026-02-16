//
//  BackgroundTaskModels.swift
//  osaurus
//
//  Data models for background task management.
//  Used when work tasks continue running after their window is closed.
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

// MARK: - Background Task Activity Feed

/// A single activity item shown in the background task toast mini-log.
public struct BackgroundTaskActivityItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case info
        case progress
        case tool
        case warning
        case success
        case error
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let title: String
    public let detail: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        title: String,
        detail: String? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

// MARK: - Background Task State

/// State of a task running in the background
/// This is an observable class to allow BackgroundTaskManager to update properties
@MainActor
public final class BackgroundTaskState: ObservableObject, Identifiable {
    /// Original window ID (unique identifier for this background task)
    public let id: UUID

    /// Whether this is a chat or work background task
    public let mode: ChatMode

    /// Work task ID (empty string for chat mode)
    public var taskId: String

    /// Display title for the task
    public var taskTitle: String

    /// Agent ID associated with this task
    public let agentId: UUID

    /// The work session (retained reference, keeps task executing).
    /// Present for work mode; nil for chat mode.
    private(set) var session: WorkSession?

    /// The chat session (retained reference for chat mode observation).
    /// Present for chat mode; nil for work mode (use executionContext.chatSession instead).
    private(set) var chatSession: ChatSession?

    /// The execution context (retained for lazy window creation).
    /// Present for dispatched tasks; nil for tasks detached from an existing window.
    private(set) var executionContext: ExecutionContext?

    /// The window state (retained for window recreation when detached from an existing window).
    /// Present for window-detached tasks; nil for dispatched tasks.
    private(set) var windowState: ChatWindowState?

    /// Current status of the background task
    @Published public var status: BackgroundTaskStatus

    /// Progress of the task (0.0 to 1.0, or -1 for indeterminate)
    @Published public var progress: Double

    /// Description of current step being executed
    @Published public var currentStep: String?

    /// Issues for the task (work mode only)
    @Published public var issues: [Issue] = []

    /// ID of the currently active issue (work mode only)
    @Published public var activeIssueId: String?

    /// Current reasoning loop state (work mode only)
    @Published public var loopState: LoopState?

    /// Pending clarification request (when status is .awaitingClarification)
    @Published public var pendingClarification: ClarificationRequest?

    /// Recent activity items used to drive the toast mini-log.
    /// Bounded to avoid unbounded growth and excessive re-renders.
    @Published public private(set) var activityFeed: [BackgroundTaskActivityItem] = []

    /// Timestamp of the most recent activity item (for subtle "fresh update" animations).
    @Published public private(set) var lastActivityAt: Date?

    /// When the background task was created
    public let createdAt: Date

    private let maxActivityItems: Int = 40

    /// Work mode initializer
    init(
        id: UUID,
        taskId: String,
        taskTitle: String,
        agentId: UUID,
        session: WorkSession,
        executionContext: ExecutionContext? = nil,
        windowState: ChatWindowState? = nil,
        status: BackgroundTaskStatus = .running,
        progress: Double = 0.0,
        currentStep: String? = nil,
        pendingClarification: ClarificationRequest? = nil
    ) {
        self.id = id
        self.mode = .work
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.agentId = agentId
        self.session = session
        self.chatSession = nil
        self.executionContext = executionContext
        self.windowState = windowState
        self.status = status
        self.progress = progress
        self.currentStep = currentStep
        self.pendingClarification = pendingClarification
        self.createdAt = Date()
    }

    /// Chat mode initializer
    init(
        id: UUID,
        taskTitle: String,
        agentId: UUID,
        chatSession: ChatSession,
        executionContext: ExecutionContext,
        status: BackgroundTaskStatus = .running,
        currentStep: String? = nil
    ) {
        self.id = id
        self.mode = .chat
        self.taskId = ""
        self.taskTitle = taskTitle
        self.agentId = agentId
        self.session = nil
        self.chatSession = chatSession
        self.executionContext = executionContext
        self.windowState = nil
        self.status = status
        self.progress = -1  // Indeterminate for chat
        self.currentStep = currentStep
        self.pendingClarification = nil
        self.createdAt = Date()
    }

    deinit {
        print("[BackgroundTaskState] deinit – id: \(id), mode: \(mode)")
    }

    /// Release retained session/window references so memory is freed immediately.
    func releaseReferences() {
        session = nil
        chatSession = nil
        executionContext = nil
        windowState = nil
    }

    // MARK: - Activity Feed

    public func appendActivity(_ item: BackgroundTaskActivityItem) {
        // De-dupe exact repeats (common when multiple publishers update at once)
        if let last = activityFeed.last, last.kind == item.kind, last.title == item.title, last.detail == item.detail {
            return
        }

        activityFeed.append(item)
        if activityFeed.count > maxActivityItems {
            activityFeed.removeFirst(activityFeed.count - maxActivityItems)
        }
        lastActivityAt = item.date
    }

    public func appendActivity(kind: BackgroundTaskActivityItem.Kind, title: String, detail: String? = nil) {
        appendActivity(.init(kind: kind, title: title, detail: detail))
    }
}
