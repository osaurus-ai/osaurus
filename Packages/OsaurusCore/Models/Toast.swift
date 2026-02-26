//
//  Toast.swift
//  osaurus
//
//  Toast data models, types, and configuration for the app-wide notification system.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Toast Type

/// The type of toast notification, determining its appearance and behavior
public enum ToastType: String, Codable, Sendable, CaseIterable {
    case success
    case info
    case warning
    case error
    case action
    case loading

    /// SF Symbol icon name for this toast type
    public var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        case .action: return "bolt.circle.fill"
        case .loading: return "arrow.triangle.2.circlepath"
        }
    }

    /// Whether this toast type should auto-dismiss by default
    public var shouldAutoDismiss: Bool {
        switch self {
        case .loading:
            return false
        default:
            return true
        }
    }
}

// MARK: - Toast Position

/// Screen position where toasts are displayed
public enum ToastPosition: String, Codable, Sendable, CaseIterable {
    case topRight
    case topLeft
    case topCenter
    case bottomRight
    case bottomLeft
    case bottomCenter

    /// Display name for UI
    public var displayName: String {
        switch self {
        case .topRight: return "Top Right"
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .bottomRight: return "Bottom Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        }
    }

    /// Horizontal alignment for the toast stack
    public var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .topLeft, .bottomLeft: return .leading
        case .topCenter, .bottomCenter: return .center
        case .topRight, .bottomRight: return .trailing
        }
    }

    /// Vertical alignment for the toast stack
    public var verticalAlignment: VerticalAlignment {
        switch self {
        case .topLeft, .topRight, .topCenter: return .top
        case .bottomLeft, .bottomRight, .bottomCenter: return .bottom
        }
    }

    /// Whether toasts appear at the top of the screen
    public var isTop: Bool {
        switch self {
        case .topLeft, .topRight, .topCenter: return true
        case .bottomLeft, .bottomRight, .bottomCenter: return false
        }
    }

    /// Edge for slide-in animation
    public var slideEdge: Edge {
        switch self {
        case .topLeft, .topRight, .topCenter: return .top
        case .bottomLeft, .bottomRight, .bottomCenter: return .bottom
        }
    }
}

// MARK: - Toast Configuration

/// User-configurable settings for toast behavior and appearance
public struct ToastConfiguration: Codable, Equatable, Sendable {
    /// Where toasts appear on screen
    public var position: ToastPosition

    /// Default timeout in seconds for auto-dismissing toasts (0 = never auto-dismiss)
    public var defaultTimeout: TimeInterval

    /// Maximum number of toasts visible at once
    public var maxVisibleToasts: Int

    /// Whether to visually group toasts by agent
    public var groupByAgent: Bool

    /// Whether toasts are enabled
    public var enabled: Bool

    /// Maximum number of background tasks allowed to run concurrently
    public var maxConcurrentTasks: Int

    public init(
        position: ToastPosition = .topRight,
        defaultTimeout: TimeInterval = 5.0,
        maxVisibleToasts: Int = 5,
        groupByAgent: Bool = true,
        enabled: Bool = true,
        maxConcurrentTasks: Int = 5
    ) {
        self.position = position
        self.defaultTimeout = defaultTimeout
        self.maxVisibleToasts = maxVisibleToasts
        self.groupByAgent = groupByAgent
        self.enabled = enabled
        self.maxConcurrentTasks = maxConcurrentTasks
    }

    public static var `default`: ToastConfiguration {
        ToastConfiguration()
    }

    // Custom decoder so existing configs without newer keys decode gracefully
    public init(from decoder: Decoder) throws {
        let defaults = ToastConfiguration()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(ToastPosition.self, forKey: .position)
        defaultTimeout = try container.decode(TimeInterval.self, forKey: .defaultTimeout)
        maxVisibleToasts = try container.decode(Int.self, forKey: .maxVisibleToasts)
        groupByAgent = try container.decode(Bool.self, forKey: .groupByAgent)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        maxConcurrentTasks =
            try container.decodeIfPresent(Int.self, forKey: .maxConcurrentTasks) ?? defaults.maxConcurrentTasks
    }
}

// MARK: - Toast Configuration Store

/// Persistence layer for toast configuration
public enum ToastConfigurationStore {
    private static var fileURL: URL {
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.config())
        return OsaurusPaths.resolvePath(new: OsaurusPaths.toastConfigFile(), legacy: "ToastConfiguration.json")
    }

    public static func load() -> ToastConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .default }
        do {
            return try JSONDecoder().decode(ToastConfiguration.self, from: Data(contentsOf: fileURL))
        } catch {
            print("[Osaurus] Failed to load toast configuration: \(error)")
            return .default
        }
    }

    public static func save(_ configuration: ToastConfiguration) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: fileURL, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save toast configuration: \(error)")
        }
    }
}

// MARK: - Toast Model

/// A single toast notification
public struct Toast: Identifiable, Sendable {
    /// Unique identifier for this toast
    public let id: UUID

    /// Type of toast (determines appearance)
    public var type: ToastType

    /// Primary title text
    public var title: String

    /// Optional secondary message
    public var message: String?

    /// Custom timeout override (nil uses default, 0 = never auto-dismiss)
    public var timeout: TimeInterval?

    /// Optional agent ID for avatar display
    public var agentId: UUID?

    /// Custom avatar image data (base64 encoded for Sendable)
    public var avatarImageData: Data?

    /// Action button title (for .action type)
    public var actionTitle: String?

    /// Action identifier (for handling action callbacks) - legacy string-based
    public var actionId: String?

    /// Structured action (preferred over actionId)
    public var action: ToastAction?

    /// Custom theme ID override (for agent-specific theming)
    public var customThemeId: UUID?

    /// When this toast was created
    public let createdAt: Date

    /// Progress value for loading toasts (0.0 - 1.0, nil = indeterminate)
    public var progress: Double?

    public init(
        id: UUID = UUID(),
        type: ToastType,
        title: String,
        message: String? = nil,
        timeout: TimeInterval? = nil,
        agentId: UUID? = nil,
        avatarImageData: Data? = nil,
        actionTitle: String? = nil,
        actionId: String? = nil,
        action: ToastAction? = nil,
        customThemeId: UUID? = nil,
        createdAt: Date = Date(),
        progress: Double? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.message = message
        self.timeout = timeout
        self.agentId = agentId
        self.avatarImageData = avatarImageData
        self.actionTitle = actionTitle
        self.actionId = actionId
        self.action = action
        self.customThemeId = customThemeId
        self.createdAt = createdAt
        self.progress = progress
    }

    /// Effective action ID (from action or legacy actionId)
    public var effectiveActionId: String? {
        action?.actionId ?? actionId
    }

    /// Effective action title (from actionTitle or action's default)
    public var effectiveActionTitle: String? {
        actionTitle ?? action?.defaultButtonTitle
    }

    /// Decode avatar image from data
    public var avatarImage: NSImage? {
        guard let data = avatarImageData else { return nil }
        return NSImage(data: data)
    }

    /// Effective timeout considering toast type defaults
    public func effectiveTimeout(defaultTimeout: TimeInterval) -> TimeInterval? {
        if let timeout = timeout {
            return timeout > 0 ? timeout : nil
        }
        return type.shouldAutoDismiss ? defaultTimeout : nil
    }
}

// MARK: - Toast Action

/// Predefined actions that can be triggered from toasts
public enum ToastAction: Equatable, Sendable {
    /// Open a chat window with optional agent
    case openChat(agentId: UUID?)

    /// Open a chat window and load a specific session
    case openChatSession(sessionId: UUID, agentId: UUID?)

    /// Show an existing chat window by its window ID
    case showChatWindow(windowId: UUID)

    /// Open settings/management window to a specific tab
    case openSettings(tab: String?)

    /// Open a URL in the default browser
    case openURL(URL)

    /// Show the main app window
    case showMainWindow

    /// Show a dispatched execution context (lazily creates a window from ExecutionContext)
    case showExecutionContext(contextId: UUID)

    /// Custom action with string identifier (for backward compatibility)
    case custom(id: String)

    /// The display title for the action button
    public var defaultButtonTitle: String {
        switch self {
        case .openChat:
            return "Open Chat"
        case .openChatSession:
            return "View Session"
        case .showChatWindow:
            return "View"
        case .openSettings:
            return "Open Settings"
        case .openURL:
            return "Open"
        case .showMainWindow:
            return "Show"
        case .showExecutionContext:
            return "View"
        case .custom:
            return "Action"
        }
    }

    /// String identifier for serialization/notification
    public var actionId: String {
        switch self {
        case .openChat(let agentId):
            if let id = agentId {
                return "openChat:\(id.uuidString)"
            }
            return "openChat"
        case .openChatSession(let sessionId, let agentId):
            if let pid = agentId {
                return "openChatSession:\(sessionId.uuidString):\(pid.uuidString)"
            }
            return "openChatSession:\(sessionId.uuidString)"
        case .showChatWindow(let windowId):
            return "showChatWindow:\(windowId.uuidString)"
        case .openSettings(let tab):
            if let t = tab {
                return "openSettings:\(t)"
            }
            return "openSettings"
        case .openURL(let url):
            return "openURL:\(url.absoluteString)"
        case .showMainWindow:
            return "showMainWindow"
        case .showExecutionContext(let contextId):
            return "showExecutionContext:\(contextId.uuidString)"
        case .custom(let id):
            return id
        }
    }

    /// Parse from action ID string
    public static func from(actionId: String) -> ToastAction? {
        let parts = actionId.split(separator: ":", maxSplits: 2).map(String.init)

        guard let command = parts.first else { return nil }

        switch command {
        case "openChat":
            if parts.count > 1, let uuid = UUID(uuidString: parts[1]) {
                return .openChat(agentId: uuid)
            }
            return .openChat(agentId: nil)

        case "openChatSession":
            guard parts.count > 1, let sessionId = UUID(uuidString: parts[1]) else { return nil }
            let agentId = parts.count > 2 ? UUID(uuidString: parts[2]) : nil
            return .openChatSession(sessionId: sessionId, agentId: agentId)

        case "showChatWindow":
            guard parts.count > 1, let windowId = UUID(uuidString: parts[1]) else { return nil }
            return .showChatWindow(windowId: windowId)

        case "openSettings":
            let tab = parts.count > 1 ? parts[1] : nil
            return .openSettings(tab: tab)

        case "openURL":
            guard parts.count > 1, let url = URL(string: parts[1]) else { return nil }
            return .openURL(url)

        case "showMainWindow":
            return .showMainWindow

        case "showExecutionContext":
            guard parts.count > 1, let contextId = UUID(uuidString: parts[1]) else { return nil }
            return .showExecutionContext(contextId: contextId)

        default:
            return .custom(id: actionId)
        }
    }
}

// MARK: - Toast Action Result

/// Result type for toast action callbacks
public struct ToastActionResult: Sendable {
    public let toastId: UUID
    public let actionId: String
    public let action: ToastAction?

    public init(toastId: UUID, actionId: String) {
        self.toastId = toastId
        self.actionId = actionId
        self.action = ToastAction.from(actionId: actionId)
    }
}

// MARK: - Toast Notification Names

extension Notification.Name {
    /// Posted when a toast action button is tapped
    public static let toastActionTriggered = Notification.Name("toastActionTriggered")
}
