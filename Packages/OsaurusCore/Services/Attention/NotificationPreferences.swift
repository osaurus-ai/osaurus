//
//  NotificationPreferences.swift
//  osaurus
//
//  Which attention kinds reach which notification channels. JSON on disk at
//  `~/.osaurus/config/notifications.json`, cached in memory like
//  `ActivityLogSettings` so routing never reads the disk.
//

import Foundation

public enum NotificationChannelID: String, Codable, Sendable, CaseIterable {
    case inApp = "in_app"
    case desktop
    case phone
    case push

    var displayName: String {
        switch self {
        case .inApp: return L("In the app")
        case .desktop: return L("Desktop")
        case .phone: return L("iPhone")
        case .push: return L("Push")
        }
    }
}

/// The groups the Settings UI exposes. Each maps to a set of kinds so the
/// switch list stays short while routing stays per kind.
public enum NotificationCategory: String, Codable, Sendable, CaseIterable {
    /// Tool approvals, owner approvals, config plans, Computer Use, secrets, MCP forms, privacy reviews.
    case approvals
    /// Clarifying questions and workflow forms.
    case questions
    /// Channel messages and messages from other participants.
    case messages
    /// Teammates or remote agents starting a conversation with a shared agent.
    case sharedConversations = "shared_conversations"
    /// The agent `notify` tool and owner pings.
    case agentNotices = "agent_notices"

    public init(kind: AttentionKind) {
        switch kind {
        case .toolApproval, .ownerApproval, .configApproval, .computerUse, .secretRequest, .elicitation,
            .privacyReview:
            self = .approvals
        case .clarification, .workflowDialog: self = .questions
        case .inboundMessage: self = .messages
        case .inboundSharedRun: self = .sharedConversations
        case .agentNotice: self = .agentNotices
        }
    }
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    /// Per category, the channels that are switched on.
    public var routes: [NotificationCategory: Set<NotificationChannelID>]
    /// Desktop notifications only when the app isn't frontmost (in-app
    /// cards already show what's needed).
    public var desktopOnlyWhenInactive: Bool

    public static let `default` = NotificationPreferences(
        routes: [
            .approvals: [.inApp, .desktop, .phone, .push],
            .questions: [.inApp, .desktop, .phone, .push],
            .messages: [.inApp, .phone],
            .sharedConversations: [.inApp, .desktop, .phone],
            .agentNotices: [.inApp, .desktop, .phone, .push],
        ],
        desktopOnlyWhenInactive: true
    )

    public init(routes: [NotificationCategory: Set<NotificationChannelID>], desktopOnlyWhenInactive: Bool) {
        self.routes = routes
        self.desktopOnlyWhenInactive = desktopOnlyWhenInactive
    }

    public func allows(_ kind: AttentionKind, on channel: NotificationChannelID) -> Bool {
        let category = NotificationCategory(kind: kind)
        let enabled = routes[category] ?? Self.default.routes[category] ?? []
        return enabled.contains(channel)
    }

    public func isOn(_ category: NotificationCategory, _ channel: NotificationChannelID) -> Bool {
        (routes[category] ?? Self.default.routes[category] ?? []).contains(channel)
    }

    public mutating func set(_ category: NotificationCategory, _ channel: NotificationChannelID, _ on: Bool) {
        var set = routes[category] ?? Self.default.routes[category] ?? []
        if on { set.insert(channel) } else { set.remove(channel) }
        routes[category] = set
    }

    private enum CodingKeys: String, CodingKey { case routes, desktopOnlyWhenInactive }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: [String]].self, forKey: .routes) ?? [:]
        var routes = Self.default.routes
        for (key, channels) in raw {
            guard let category = NotificationCategory(rawValue: key) else { continue }
            routes[category] = Set(channels.compactMap(NotificationChannelID.init(rawValue:)))
        }
        self.routes = routes
        desktopOnlyWhenInactive = try c.decodeIfPresent(Bool.self, forKey: .desktopOnlyWhenInactive) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var raw: [String: [String]] = [:]
        for (category, channels) in routes { raw[category.rawValue] = channels.map(\.rawValue).sorted() }
        try c.encode(raw, forKey: .routes)
        try c.encode(desktopOnlyWhenInactive, forKey: .desktopOnlyWhenInactive)
    }
}

extension Notification.Name {
    static let notificationPreferencesChanged = Notification.Name("ai.osaurus.notificationPreferencesChanged")
}

public enum NotificationPreferencesStore {
    private nonisolated(unsafe) static var cached: NotificationPreferences?
    private nonisolated(unsafe) static var overrideURL: URL?
    private static let lock = NSLock()

    /// Test hook. Pass nil to restore the real path.
    public nonisolated static func setOverrideFileURL(_ url: URL?) {
        lock.withLock {
            overrideURL = url
            cached = nil
        }
    }

    public nonisolated static func snapshot() -> NotificationPreferences {
        if let cached = lock.withLock({ cached }) { return cached }
        let loaded = load() ?? .default
        lock.withLock { cached = loaded }
        return loaded
    }

    /// Nil when there is no file, or when it didn't decode — in that case
    /// the file is moved aside (`<name>.corrupt-<timestamp>`) so the next
    /// save starts fresh without destroying what was there.
    nonisolated static func load() -> NotificationPreferences? {
        switch AttentionFileIO.read(NotificationPreferences.self, from: fileURL()) {
        case .loaded(let prefs): return prefs
        case .missing, .corrupt: return nil
        }
    }

    public nonisolated static func save(_ prefs: NotificationPreferences) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard AttentionFileIO.write(prefs, to: fileURL(), encoder: encoder) else { return }
        lock.withLock { cached = prefs }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .notificationPreferencesChanged, object: nil)
        }
    }

    private nonisolated static func fileURL() -> URL {
        lock.withLock { overrideURL } ?? OsaurusPaths.notificationPreferencesFile()
    }
}
