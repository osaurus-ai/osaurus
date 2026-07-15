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

/// Lifecycle status of an agent request. Every request moves through an
/// explicit state machine that is independent of whether any chat window is
/// currently displaying it:
///
///     queued → running → waitingForInput → running → completed / failed
///     queued / running → cancelled
///
/// Only explicit Stop/cancel, app shutdown, budget exhaustion, or terminal
/// execution ends a request — never a UI context switch.
public enum BackgroundTaskStatus: Equatable, Sendable {
    /// Accepted but not yet started: waiting for an execution slot under the
    /// configured concurrency limits. Promoted FIFO as capacity frees up.
    case queued
    /// Task is actively executing
    case running
    /// Task is paused waiting for user input (e.g. a clarify prompt). Alive,
    /// but not consuming an execution slot.
    case waitingForInput
    /// Task finished successfully
    case completed(summary: String)
    /// Task finished with an error
    case failed(summary: String)
    /// Task was cancelled
    case cancelled

    /// Whether the task is still alive (queued, running, or awaiting input)
    public var isActive: Bool {
        switch self {
        case .queued, .running, .waitingForInput:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    /// Whether the task currently occupies one of the limited execution
    /// slots. Queued tasks haven't started; waiting tasks released their
    /// slot so queued work can be promoted while they idle on the user.
    public var consumesExecutionSlot: Bool {
        self == .running
    }

    /// Whether the task ended in a terminal state (success, failure, or cancel)
    public var isTerminal: Bool { !isActive }

    /// Display name for UI
    public var displayName: String {
        switch self {
        case .queued:
            return L("Queued")
        case .running:
            return L("Running")
        case .waitingForInput:
            return L("Waiting")
        case .completed:
            return L("Completed")
        case .failed:
            return L("Failed")
        case .cancelled:
            return L("Cancelled")
        }
    }

    /// Icon name for UI
    public var iconName: String {
        switch self {
        case .queued:
            return "clock"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .waitingForInput:
            return "questionmark.circle.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
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

/// Small transcript excerpt retained by a completed notch tab after its live
/// `ChatSession` has been released. Enough context remains visible to decide
/// whether and how to follow up; the full persisted session is rehydrated only
/// when the user replies or opens Chat.
public struct BackgroundTaskContextMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

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

    /// Recent conversational context used by the notch follow-up UI. This is
    /// captured at completion and persisted with retained tabs, allowing the
    /// live ChatSession and its observers to be released without reducing the
    /// tab to an unhelpful "Chat completed" summary.
    @Published public private(set) var contextPreview: [BackgroundTaskContextMessage] = []

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

    /// `agent_runs.id` row this task is bound to in
    /// `SchedulerDatabase`. Populated only when the agent has the DB
    /// feature enabled (spec §5.5). `markCompleted` reads this back to
    /// stamp the terminal `recordRunEnd` row. `nil` for DB-disabled
    /// agents and for headless callers that built `BackgroundTaskState`
    /// without going through `dispatchChat`.
    public var agentRunId: UUID?

    /// Running token/USD counters for the current run (Phase 4 budget
    /// enforcement, spec §11.3). Populated by the streaming engine as
    /// it observes provider usage payloads. `BackgroundTaskManager`
    /// compares these against `runTokensLimit` / `runCostUSDLimit` on
    /// every update and cancels the task when exceeded.
    public var tokensIn: Int = 0
    public var tokensOut: Int = 0
    public var costUSD: Double = 0
    /// Hard ceilings copied from `Agent.settings.limits` at dispatch.
    /// `nil` disables that dimension. Stored locally so the budget
    /// check doesn't have to hop back to MainActor mid-stream.
    public var runTokensLimit: Int?
    public var runCostUSDLimit: Double?
    /// Set true by `BackgroundTaskManager` when a budget cap fires;
    /// `markCompleted` uses this to write a clear error message into
    /// `agent_runs.error` rather than the generic "cancelled" text.
    public var budgetExhaustedReason: String?

    /// Returns the first budget dimension that's been exceeded, or
    /// nil when usage is still under all configured caps.
    public func budgetExceededReason() -> String? {
        if let limit = runTokensLimit, limit > 0 {
            let used = tokensIn + tokensOut
            if used >= limit {
                return "token cap (\(used) ≥ \(limit))"
            }
        }
        if let limit = runCostUSDLimit, limit > 0, costUSD >= limit {
            return String(format: "USD cap (%.4f ≥ %.4f)", costUSD, limit)
        }
        return nil
    }

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

    /// Restore a lightweight terminal tab from durable metadata. No live
    /// session/context is allocated until the user replies or opens Chat.
    init(
        retainedId id: UUID,
        taskTitle: String,
        agentId: UUID,
        status: BackgroundTaskStatus,
        createdAt: Date,
        source: SessionSource,
        sourcePluginId: String?,
        externalSessionKey: String?,
        contextPreview: [BackgroundTaskContextMessage]
    ) {
        self.id = id
        self.taskTitle = taskTitle
        self.agentId = agentId
        self.chatSession = nil
        self.executionContext = nil
        self.status = status
        self.currentStep = nil
        self.createdAt = createdAt
        self.source = source
        self.sourcePluginId = sourcePluginId
        self.externalSessionKey = externalSessionKey
        self.showToast = true
        self.contextPreview = contextPreview
    }

    deinit {
        print("[BackgroundTaskState] deinit – id: \(id)")
    }

    /// Release retained session/context references so memory is freed immediately.
    func releaseReferences() {
        chatSession = nil
        executionContext = nil
    }

    /// Install a fully hydrated persisted conversation before resuming or
    /// opening a retained tab.
    func restoreReferences(context: ExecutionContext) {
        chatSession = context.chatSession
        executionContext = context
    }

    /// Snapshot the most recent conversational turns, excluding tool/system
    /// protocol rows and blank messages. The short excerpt is intentionally
    /// bounded so durable tabs stay lightweight.
    func captureContextPreview(maxMessages: Int = 4) {
        guard let session = chatSession else { return }
        contextPreview =
            session.turns
            .filter { turn in
                (turn.role == .user || turn.role == .assistant)
                    && !turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .suffix(maxMessages)
            .map {
                BackgroundTaskContextMessage(
                    role: $0.role.rawValue,
                    content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
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
