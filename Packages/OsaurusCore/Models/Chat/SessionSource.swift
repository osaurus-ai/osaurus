//
//  SessionSource.swift
//  osaurus
//
//  Origin of a persisted chat session. Lets the sidebar (and any
//  programmatic consumer) distinguish between user-driven chats,
//  plugin-initiated work, HTTP API callers, and scheduled / watched
//  background tasks.
//

import Foundation

public enum SessionSource: String, Codable, CaseIterable, Sendable {
    /// User-initiated chat from the in-app UI.
    case chat
    /// Plugin host API (`dispatch`, `complete`, `complete_stream`).
    case plugin
    /// External HTTP caller (e.g. `/v1/chat/completions`, `/v1/messages`).
    case http
    /// Recurring scheduled task created via `ScheduleManager`.
    case schedule
    /// File-system watcher trigger (`WatcherManager`).
    case watcher
    /// Self-scheduled wake-up (spec §4.2 / §9). The agent itself
    /// asked to be woken by calling `schedule_next_run`; the
    /// `NextRunScheduler` is what dispatched this turn. Distinct
    /// from `.schedule` (user-authored recurring schedules) so the
    /// audit trail can tell them apart.
    case selfSchedule = "self_schedule"
}

// MARK: - UI Helpers

/// Shared formatting used by the sidebar source badge, the toast header
/// subtitle, and the notch expanded subtitle. Keeping these in one place
/// guarantees the audit dimension reads identically across every surface.
extension SessionSource {

    /// Short clause that follows the status / timestamp ("via Telegram",
    /// "scheduled", etc.). `nil` for user-driven chat sessions, which need
    /// no decoration.
    ///
    /// `pluginDisplayName` is supplied by the caller so this helper stays
    /// free of `@MainActor` plugin-manager lookups; pass `nil` to fall
    /// back to a generic "via plugin" label.
    public func originLabel(pluginDisplayName: String? = nil) -> String? {
        switch self {
        case .chat:
            return nil
        case .plugin:
            if let pluginDisplayName, !pluginDisplayName.isEmpty {
                return "via \(pluginDisplayName)"
            }
            return "via plugin"
        case .http:
            return "via API"
        case .schedule:
            return "scheduled"
        case .watcher:
            return "watcher"
        case .selfSchedule:
            return "self-scheduled"
        }
    }

    /// SF Symbol used by the sidebar source badge.
    public var iconName: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .plugin: return "puzzlepiece.extension.fill"
        case .http: return "network"
        case .schedule: return "clock.fill"
        case .watcher: return "eye.fill"
        case .selfSchedule: return "alarm.fill"
        }
    }

    /// Short, human-readable label used in filter chips ("All / Chat / …").
    public var shortLabel: String {
        switch self {
        case .chat: return "Chat"
        case .plugin: return "Plugin"
        case .http: return "API"
        case .schedule: return "Schedule"
        case .watcher: return "Watcher"
        case .selfSchedule: return "Self-scheduled"
        }
    }
}

// MARK: - Plugin Display Name

/// Resolves a user-facing label for a plugin id. Falls back to the raw id
/// (or the suffix of `sandbox:<user>` pseudo-ids used by the bridge).
///
/// Lives next to `SessionSource` so the toast / notch / sidebar can share
/// one canonical implementation instead of three near-identical copies.
@MainActor
public enum PluginDisplayNameResolver {
    public static func displayName(for pluginId: String) -> String {
        if let manifestName = PluginManager.shared.loadedPlugin(for: pluginId)?
            .plugin.manifest.name,
            !manifestName.isEmpty
        {
            return manifestName
        }
        if pluginId.hasPrefix("sandbox:") {
            return String(pluginId.dropFirst("sandbox:".count))
        }
        return pluginId
    }
}
