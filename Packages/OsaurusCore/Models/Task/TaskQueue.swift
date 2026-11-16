//
//  TaskQueue.swift
//  osaurus
//
//  A queue is a resource lane with a policy. One system queue, Default,
//  exists from first launch; users add their own.
//

import Foundation

public struct TaskQueue: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public var slug: String
    public var name: String
    public var isSystem: Bool
    public var policy: TaskQueuePolicy
    public var createdAt: Date

    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-00000000D0FA")!
    public static let defaultSlug = "default"

    public init(
        id: UUID = UUID(), slug: String, name: String, isSystem: Bool = false,
        policy: TaskQueuePolicy = TaskQueuePolicy(), createdAt: Date = Date()
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.isSystem = isSystem
        self.policy = policy
        self.createdAt = createdAt
    }

    public static func makeDefault(maxConcurrent: Int = TaskQueuePolicy.defaultMaxConcurrent) -> TaskQueue {
        TaskQueue(
            id: defaultID, slug: defaultSlug, name: L("Default"), isSystem: true,
            policy: TaskQueuePolicy(maxConcurrent: maxConcurrent))
    }

    public var isDefault: Bool { id == Self.defaultID }

    /// A url-safe slug from a display name.
    public static func slug(for name: String) -> String {
        let lowered = name.lowercased()
        var slug = ""
        var lastDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash, !slug.isEmpty {
                slug.append("-")
                lastDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "queue" : slug
    }
}

public enum TaskOverflowPolicy: String, Codable, Sendable, CaseIterable {
    /// A task past `maxPending` is refused (`queue_full`).
    case reject
    /// Older waiting tasks with the same ordering key are dropped.
    case coalesceByKey = "coalesce_by_key"
    /// The oldest waiting task is dropped to make room.
    case dropOldest = "drop_oldest"

    public var displayName: String {
        switch self {
        case .reject: L("Refuse new tasks")
        case .coalesceByKey: L("Keep only the newest per conversation")
        case .dropOldest: L("Drop the oldest waiting task")
        }
    }
}

public enum TaskOrderingMode: String, Codable, Sendable, CaseIterable {
    /// Arrival order; a blocked task never blocks an unrelated one.
    case fifo
    /// One running task per ordering key (conversation, folder).
    case perKey = "per_key"
    /// No ordering.
    case parallel

    public var displayName: String {
        switch self {
        case .fifo: L("In order")
        case .perKey: L("One at a time per conversation")
        case .parallel: L("Any order")
        }
    }
}

public struct TaskRetryPolicy: Codable, Sendable, Equatable, Hashable {
    public var maxAttempts: Int
    public var backoffSeconds: Double

    public init(maxAttempts: Int = 1, backoffSeconds: Double = 0) {
        self.maxAttempts = max(1, maxAttempts)
        self.backoffSeconds = max(0, backoffSeconds)
    }
}

/// Where a task goes after its last failed attempt.
public enum TaskExhaustedPolicy: Codable, Sendable, Equatable, Hashable {
    case needsAttention
    case routeTo(UUID)
}

public enum TaskRunWindow: String, Codable, Sendable, CaseIterable {
    case always
    case idleOnly = "idle_only"
}

/// A deterministic rule on queued or waiting tasks (Phase 3).
public struct TaskTimerRule: Codable, Sendable, Equatable, Hashable {
    public enum Action: String, Codable, Sendable {
        case notify, move, cancel
    }

    public var afterSeconds: Double
    public var action: Action
    public var targetQueueId: UUID?

    public init(afterSeconds: Double, action: Action, targetQueueId: UUID? = nil) {
        self.afterSeconds = afterSeconds
        self.action = action
        self.targetQueueId = targetQueueId
    }
}

public struct TaskQueuePolicy: Codable, Sendable, Equatable, Hashable {
    public static let defaultMaxConcurrent = 20
    public static let maxConcurrentCeiling = 64
    public static let maxPendingCeiling = 1000

    public var maxConcurrent: Int
    /// nil = unlimited.
    public var maxPending: Int?
    public var overflow: TaskOverflowPolicy
    public var orderingMode: TaskOrderingMode
    public var priorityClass: TaskPriorityClass
    public var retry: TaskRetryPolicy
    public var onExhausted: TaskExhaustedPolicy
    public var timers: [TaskTimerRule]
    public var paused: Bool
    public var runWindow: TaskRunWindow

    public init(
        maxConcurrent: Int = TaskQueuePolicy.defaultMaxConcurrent,
        maxPending: Int? = nil,
        overflow: TaskOverflowPolicy = .reject,
        orderingMode: TaskOrderingMode = .fifo,
        priorityClass: TaskPriorityClass = .normal,
        retry: TaskRetryPolicy = TaskRetryPolicy(),
        onExhausted: TaskExhaustedPolicy = .needsAttention,
        timers: [TaskTimerRule] = [],
        paused: Bool = false,
        runWindow: TaskRunWindow = .always
    ) {
        self.maxConcurrent = Self.clampConcurrent(maxConcurrent)
        self.maxPending = maxPending.map { min(max(0, $0), Self.maxPendingCeiling) }
        self.overflow = overflow
        self.orderingMode = orderingMode
        self.priorityClass = priorityClass
        self.retry = retry
        self.onExhausted = onExhausted
        self.timers = timers
        self.paused = paused
        self.runWindow = runWindow
    }

    /// 0 is allowed so tests (and a user draining a queue) can hold
    /// everything without pausing.
    public static func clampConcurrent(_ value: Int) -> Int {
        min(max(0, value), maxConcurrentCeiling)
    }

    private enum CodingKeys: String, CodingKey {
        case maxConcurrent, maxPending, overflow, orderingMode, priorityClass, retry, onExhausted, timers, paused,
            runWindow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxConcurrent: try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? Self.defaultMaxConcurrent,
            maxPending: try c.decodeIfPresent(Int.self, forKey: .maxPending),
            overflow: try c.decodeIfPresent(TaskOverflowPolicy.self, forKey: .overflow) ?? .reject,
            orderingMode: try c.decodeIfPresent(TaskOrderingMode.self, forKey: .orderingMode) ?? .fifo,
            priorityClass: try c.decodeIfPresent(TaskPriorityClass.self, forKey: .priorityClass) ?? .normal,
            retry: try c.decodeIfPresent(TaskRetryPolicy.self, forKey: .retry) ?? TaskRetryPolicy(),
            onExhausted: try c.decodeIfPresent(TaskExhaustedPolicy.self, forKey: .onExhausted) ?? .needsAttention,
            timers: try c.decodeIfPresent([TaskTimerRule].self, forKey: .timers) ?? [],
            paused: try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false,
            runWindow: try c.decodeIfPresent(TaskRunWindow.self, forKey: .runWindow) ?? .always
        )
    }
}
