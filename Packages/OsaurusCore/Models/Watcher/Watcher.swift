//
//  Watcher.swift
//  osaurus
//
//  Defines a file system watcher that monitors a directory for changes
//  and triggers work tasks with change context.
//

import Foundation

// MARK: - Responsiveness

/// How quickly a watcher reacts to filesystem changes.
/// Maps to debounce window duration internally.
public enum Responsiveness: String, Codable, Sendable, CaseIterable, Equatable {
    /// Screenshots, single-file drops
    case fast
    /// General use (default)
    case balanced
    /// Downloads, batch operations
    case patient
    /// Note-taking, wiki edits, active editing sessions
    case relaxed
    /// Extended writing sessions, periodic syncs
    case deferred
    /// End-of-session checkpoints, long-running activity
    case extended

    /// Single source of truth for each tier's timing and UI strings.
    private var spec: (window: TimeInterval, name: String, description: String) {
        switch self {
        case .fast:
            return (
                0.2,
                L("Fast"),
                L("Triggers in ~200ms. Best for screenshots and single-file drops.")
            )
        case .balanced:
            return (
                1.0,
                L("Balanced"),
                L("Triggers in ~1s. Good for general-purpose monitoring.")
            )
        case .patient:
            return (
                3.0,
                L("Patient"),
                L("Triggers in ~3s. Good for downloads and batch operations.")
            )
        case .relaxed:
            return (
                60.0,
                L("Relaxed"),
                L("Triggers in ~1 minute. Best for note-taking, wiki edits, and other active editing sessions.")
            )
        case .deferred:
            return (
                300.0,
                L("Deferred"),
                L("Triggers in ~5 minutes. Best for extended writing sessions or periodic syncs.")
            )
        case .extended:
            return (
                600.0,
                L("Extended"),
                L("Triggers in ~10 minutes. Best for end-of-session checkpoints or long-running activity.")
            )
        }
    }

    /// The debounce window duration in seconds.
    public var debounceWindow: TimeInterval { spec.window }

    /// Human-readable display name.
    public var displayName: String { spec.name }

    /// One-line description shown beneath the picker.
    public var displayDescription: String { spec.description }

    /// Map a legacy `debounceSeconds` value to a `Responsiveness` tier.
    /// Legacy data only ever held values from the original 3-tier scale (≤3s).
    public static func from(debounceSeconds: TimeInterval) -> Responsiveness {
        if debounceSeconds <= 0.5 { return .fast }
        if debounceSeconds <= 2.0 { return .balanced }
        return .patient
    }
}

// MARK: - Watcher Model

/// A file system watcher that monitors a directory for changes and triggers work tasks
public struct Watcher: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for the watcher
    public let id: UUID
    /// Display name of the watcher
    public var name: String
    /// Instructions to send to the AI when changes are detected
    public var instructions: String
    /// The agent to dispatch to (nil = default agent)
    public var agentId: UUID?
    /// Extra parameters for future extensibility
    public var parameters: [String: String]
    /// The directory to monitor (display path)
    public var watchPath: String?
    /// Security-scoped bookmark for the watched directory
    public var watchBookmark: Data?
    /// Whether the watcher is active
    public var isEnabled: Bool
    /// Whether to monitor subdirectories recursively (default: false for performance)
    public var recursive: Bool
    /// How quickly the watcher reacts to changes
    public var responsiveness: Responsiveness
    /// Seconds to wait after LLM completes before re-fingerprinting (FSEvents latency x2)
    public var settleSeconds: TimeInterval
    /// When the watcher last triggered an work task
    public var lastTriggeredAt: Date?
    /// The chat session ID from the last run (for viewing results)
    public var lastChatSessionId: UUID?
    /// When the watcher was created
    public let createdAt: Date
    /// When the watcher was last modified
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String,
        agentId: UUID? = nil,
        parameters: [String: String] = [:],
        watchPath: String? = nil,
        watchBookmark: Data? = nil,
        isEnabled: Bool = true,
        recursive: Bool = false,
        responsiveness: Responsiveness = .balanced,
        settleSeconds: TimeInterval = 2.0,
        lastTriggeredAt: Date? = nil,
        lastChatSessionId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.agentId = agentId
        self.parameters = parameters
        self.watchPath = watchPath
        self.watchBookmark = watchBookmark
        self.isEnabled = isEnabled
        self.recursive = recursive
        self.responsiveness = responsiveness
        self.settleSeconds = settleSeconds
        self.lastTriggeredAt = lastTriggeredAt
        self.lastChatSessionId = lastChatSessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Backward-Compatible Decoding

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, agentId, parameters
        case personaId  // legacy key for migration
        case watchPath, watchBookmark
        case isEnabled, recursive
        case responsiveness, settleSeconds
        case debounceSeconds  // legacy key for migration
        case lastTriggeredAt, lastChatSessionId
        case createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        instructions = try container.decode(String.self, forKey: .instructions)
        agentId =
            try container.decodeIfPresent(UUID.self, forKey: .agentId)
            ?? container.decodeIfPresent(UUID.self, forKey: .personaId)
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        watchPath = try container.decodeIfPresent(String.self, forKey: .watchPath)
        watchBookmark = try container.decodeIfPresent(Data.self, forKey: .watchBookmark)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? false

        // Migration: map legacy debounceSeconds to responsiveness
        if let resp = try container.decodeIfPresent(Responsiveness.self, forKey: .responsiveness) {
            responsiveness = resp
        } else if let legacy = try container.decodeIfPresent(TimeInterval.self, forKey: .debounceSeconds) {
            responsiveness = Responsiveness.from(debounceSeconds: legacy)
        } else {
            responsiveness = .balanced
        }

        settleSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .settleSeconds) ?? 2.0
        lastTriggeredAt = try container.decodeIfPresent(Date.self, forKey: .lastTriggeredAt)
        lastChatSessionId = try container.decodeIfPresent(UUID.self, forKey: .lastChatSessionId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(instructions, forKey: .instructions)
        try container.encodeIfPresent(agentId, forKey: .agentId)
        try container.encode(parameters, forKey: .parameters)
        try container.encodeIfPresent(watchPath, forKey: .watchPath)
        try container.encodeIfPresent(watchBookmark, forKey: .watchBookmark)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(recursive, forKey: .recursive)
        try container.encode(responsiveness, forKey: .responsiveness)
        try container.encode(settleSeconds, forKey: .settleSeconds)
        try container.encodeIfPresent(lastTriggeredAt, forKey: .lastTriggeredAt)
        try container.encodeIfPresent(lastChatSessionId, forKey: .lastChatSessionId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        // Note: debounceSeconds is NOT encoded -- it's a legacy read-only key
    }

    // MARK: - Computed Properties

    /// Human-readable status description
    public var statusDescription: String {
        if !isEnabled {
            return "Paused"
        }
        if let lastTriggered = lastTriggeredAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Last triggered \(formatter.localizedString(for: lastTriggered, relativeTo: Date()))"
        }
        return "Watching"
    }

    /// Short display path for the watched folder
    public var displayWatchPath: String {
        guard let path = watchPath else { return "No folder selected" }
        // Abbreviate home directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Watcher Phase

/// The current phase of a watcher's state machine
public enum WatcherPhase: String, Sendable {
    /// Waiting for changes
    case idle
    /// Coalescing rapid events before processing
    case debouncing
    /// LLM is working on the changes
    case processing
    /// Waiting for self-caused FSEvents to flush
    case settling
}

// MARK: - Watcher Run Info

/// Information about a currently running watcher task
public struct WatcherRunInfo: Identifiable, Sendable {
    public let id: UUID
    public let watcherId: UUID
    public let watcherName: String
    public let agentId: UUID?
    public var chatSessionId: UUID
    public let startedAt: Date
    public let changeCount: Int

    public init(
        id: UUID = UUID(),
        watcherId: UUID,
        watcherName: String,
        agentId: UUID?,
        chatSessionId: UUID,
        startedAt: Date = Date(),
        changeCount: Int = 0
    ) {
        self.id = id
        self.watcherId = watcherId
        self.watcherName = watcherName
        self.agentId = agentId
        self.chatSessionId = chatSessionId
        self.startedAt = startedAt
        self.changeCount = changeCount
    }
}
