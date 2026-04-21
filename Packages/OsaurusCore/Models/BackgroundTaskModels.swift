//
//  BackgroundTaskModels.swift
//  osaurus
//
//  Data models for background chat task management.
//  Used for chat sessions that continue running after their window is closed
//  or that started without a window (HTTP / scheduler / plugin / watcher dispatch).
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
            return L("Running")
        case .awaitingClarification:
            return L("Waiting")
        case .completed(let success, _):
            return success ? L("Completed") : L("Failed")
        case .cancelled:
            return L("Cancelled")
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
        case toolCall
        case toolResult
        case thinking
        case writing
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

/// State of a chat task running in the background.
/// Observable so BackgroundTaskManager can update properties from publishers.
@MainActor
public final class BackgroundTaskState: ObservableObject, Identifiable {
    /// Original window ID (unique identifier for this background task)
    public let id: UUID

    /// Display title for the task
    public var taskTitle: String

    /// Agent ID associated with this task
    public let agentId: UUID

    /// The chat session driving this task. Retained so the session keeps
    /// running while the user has no window open for it.
    private(set) var chatSession: ChatSession?

    /// The execution context. Retained for lazy window creation.
    private(set) var executionContext: ExecutionContext?

    /// Current status of the background task
    @Published public var status: BackgroundTaskStatus

    /// Description of current step being executed
    @Published public var currentStep: String?

    /// Recent activity items used to drive the toast mini-log.
    /// Bounded to avoid unbounded growth and excessive re-renders.
    @Published public private(set) var activityFeed: [BackgroundTaskActivityItem] = []

    /// Timestamp of the most recent activity item (for subtle "fresh update" animations).
    @Published public private(set) var lastActivityAt: Date?

    /// When the background task was created
    public let createdAt: Date

    /// Plugin that originated this dispatch (for on_task_event callback routing).
    public var sourcePluginId: String?

    /// Origin of the dispatch — drives toast styling and the persisted
    /// `SessionSource`. Defaults to `.plugin` for back-compat with the
    /// pre-source-tagging callers that built `BackgroundTaskState` directly.
    public var source: SessionSource = .plugin

    /// External grouping key (e.g. Telegram chat id). Mirrors
    /// `DispatchRequest.externalSessionKey` so the toast / notch can show
    /// it inline and the manager can debounce duplicate dispatches.
    public var externalSessionKey: String?

    /// Whether the toast/notch UI should surface this task. Headless callers
    /// (e.g. webhooks responding inline) set this to `false` to keep the
    /// notch quiet while the task still lives in `backgroundTasks` for
    /// completion signaling.
    public var showToast: Bool = true

    /// Latest draft content sent by the plugin (e.g. for live-update messages).
    public var draftText: String?

    private let maxActivityItems: Int = 40

    init(
        id: UUID,
        taskTitle: String,
        agentId: UUID,
        chatSession: ChatSession,
        executionContext: ExecutionContext,
        status: BackgroundTaskStatus = .running,
        currentStep: String? = nil,
        source: SessionSource = .plugin,
        sourcePluginId: String? = nil,
        externalSessionKey: String? = nil,
        showToast: Bool = true
    ) {
        self.id = id
        self.taskTitle = taskTitle
        self.agentId = agentId
        self.chatSession = chatSession
        self.executionContext = executionContext
        self.status = status
        self.currentStep = currentStep
        self.createdAt = Date()
        self.source = source
        self.sourcePluginId = sourcePluginId
        self.externalSessionKey = externalSessionKey
        self.showToast = showToast
    }

    deinit {
        print("[BackgroundTaskState] deinit – id: \(id)")
    }

    /// Release retained session/context references so memory is freed immediately.
    func releaseReferences() {
        chatSession = nil
        executionContext = nil
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
