//
//  Watcher.swift
//  osaurus
//
//  Defines a file system watcher that monitors a directory for changes
//  and triggers agent tasks with change context.
//

import Foundation

// MARK: - Responsiveness

/// How quickly a watcher reacts to filesystem changes.
/// Maps to debounce window duration internally.
public enum Responsiveness: String, Codable, Sendable, CaseIterable, Equatable {
    /// ~200ms -- screenshots, single-file drops
    case fast
    /// ~1s -- general use (default)
    case balanced
    /// ~3s -- downloads, torrents, build output
    case patient

    /// The debounce window duration in seconds
    public var debounceWindow: TimeInterval {
        switch self {
        case .fast: return 0.2
        case .balanced: return 1.0
        case .patient: return 3.0
        }
    }

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .patient: return "Patient"
        }
    }

    /// Description for UI
    public var displayDescription: String {
        switch self {
        case .fast: return "Triggers quickly. Best for screenshots, single-file drops."
        case .balanced: return "Waits for rapid changes to settle. Good for general use."
        case .patient: return "Waits longer for downloads and batch operations to finish."
        }
    }

    /// Map a legacy debounceSeconds value to the nearest Responsiveness
    public static func from(debounceSeconds: TimeInterval) -> Responsiveness {
        if debounceSeconds <= 0.5 {
            return .fast
        } else if debounceSeconds <= 2.0 {
            return .balanced
        } else {
            return .patient
        }
    }
}

// MARK: - Watcher Model

/// A file system watcher that monitors a directory for changes and triggers agent tasks
public struct Watcher: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for the watcher
    public let id: UUID
    /// Display name of the watcher
    public var name: String
    /// Instructions to send to the agent when changes are detected
    public var instructions: String
    /// The persona to use for the agent (nil = default persona)
    public var personaId: UUID?
    /// Extra parameters for future extensibility
    public var parameters: [String: String]
    /// The directory to monitor (display path)
    public var watchPath: String?
    /// Security-scoped bookmark for the watched directory
    public var watchBookmark: Data?
    /// Agent working directory path (defaults to watched folder if nil)
    public var folderPath: String?
    /// Security-scoped bookmark for the agent working directory (defaults to watchBookmark if nil)
    public var folderBookmark: Data?
    /// Whether the watcher is active
    public var isEnabled: Bool
    /// Whether to monitor subdirectories recursively (default: false for performance)
    public var recursive: Bool
    /// How quickly the watcher reacts to changes
    public var responsiveness: Responsiveness
    /// Seconds to wait after LLM completes before re-fingerprinting (FSEvents latency x2)
    public var settleSeconds: TimeInterval
    /// When the watcher last triggered an agent task
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
        personaId: UUID? = nil,
        parameters: [String: String] = [:],
        watchPath: String? = nil,
        watchBookmark: Data? = nil,
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
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
        self.personaId = personaId
        self.parameters = parameters
        self.watchPath = watchPath
        self.watchBookmark = watchBookmark
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
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
        case id, name, instructions, personaId, parameters
        case watchPath, watchBookmark
        case folderPath, folderBookmark
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
        personaId = try container.decodeIfPresent(UUID.self, forKey: .personaId)
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        watchPath = try container.decodeIfPresent(String.self, forKey: .watchPath)
        watchBookmark = try container.decodeIfPresent(Data.self, forKey: .watchBookmark)
        folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)
        folderBookmark = try container.decodeIfPresent(Data.self, forKey: .folderBookmark)
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
        try container.encodeIfPresent(personaId, forKey: .personaId)
        try container.encode(parameters, forKey: .parameters)
        try container.encodeIfPresent(watchPath, forKey: .watchPath)
        try container.encodeIfPresent(watchBookmark, forKey: .watchBookmark)
        try container.encodeIfPresent(folderPath, forKey: .folderPath)
        try container.encodeIfPresent(folderBookmark, forKey: .folderBookmark)
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

    /// The effective folder bookmark for the agent workspace (falls back to watch bookmark)
    public var effectiveFolderBookmark: Data? {
        folderBookmark ?? watchBookmark
    }

    /// The effective folder path for the agent workspace (falls back to watch path)
    public var effectiveFolderPath: String? {
        folderPath ?? watchPath
    }

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
    public let personaId: UUID?
    public var chatSessionId: UUID
    public let startedAt: Date
    public let changeCount: Int

    public init(
        id: UUID = UUID(),
        watcherId: UUID,
        watcherName: String,
        personaId: UUID?,
        chatSessionId: UUID,
        startedAt: Date = Date(),
        changeCount: Int = 0
    ) {
        self.id = id
        self.watcherId = watcherId
        self.watcherName = watcherName
        self.personaId = personaId
        self.chatSessionId = chatSessionId
        self.startedAt = startedAt
        self.changeCount = changeCount
    }
}
