//
//  AppleApp.swift
//  osaurus
//
//  The built-in Apple app tool families. Each case is one per-agent opt-in
//  (one group per app in the agent's Abilities → Tools picker, `capabilities.apple_apps` in
//  the declarative config) that gates a fixed set of `OsaurusTool` names into
//  the model-visible schema. Every tool stays registered in `ToolRegistry`
//  regardless — the composer strips the names for apps the agent has not
//  enabled, exactly like the other gated built-ins (`web_search`, `db_*`).
//
//  These replace the `osaurus.calendar` / `.reminders` / `.contacts` /
//  `.notes` / `.mail` / `.messages` / `.maps` / `.music` plugins from the
//  osaurus-tools registry, which are now superseded (see
//  `PluginManager.supersededPluginIds`).
//

import Foundation

public enum AppleApp: String, CaseIterable, Codable, Sendable, Hashable {
    case calendar
    case reminders
    case contacts
    case notes
    case mail
    case messages
    case maps
    case music
    case shortcuts

    /// Human-readable name shown on the Tools picker group and in plan cards.
    public var displayName: String {
        switch self {
        case .calendar: return L("Calendar")
        case .reminders: return L("Reminders")
        case .contacts: return L("Contacts")
        case .notes: return L("Notes")
        case .mail: return L("Mail")
        case .messages: return L("Messages")
        case .maps: return L("Maps & Location")
        case .music: return L("Music")
        case .shortcuts: return L("Shortcuts")
        }
    }

    /// SF Symbol for the Tools picker group.
    public var icon: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .contacts: return "person.crop.circle"
        case .notes: return "note.text"
        case .mail: return "envelope"
        case .messages: return "message"
        case .maps: return "map"
        case .music: return "music.note"
        case .shortcuts: return "square.stack.3d.up"
        }
    }

    /// macOS permissions the app's tools need. Individual tools may narrow
    /// this (for example `messages_read` needs only Full Disk Access while
    /// `messages_send` needs only Automation for Messages); the union is
    /// what the Tools picker requests on enable and flags when missing.
    var systemPermissions: [SystemPermission] {
        switch self {
        case .calendar: return [.calendar]
        case .reminders: return [.reminders]
        case .contacts: return [.contacts]
        case .notes: return [.notes]
        case .mail: return [.automationMail]
        case .messages: return [.disk, .automationMessages]
        case .maps: return [.location]
        case .music: return [.automationMusic]
        case .shortcuts: return []
        }
    }

    /// Tool names this app contributes. This is the gate list the composer
    /// strips; it MUST match the `name` of every tool the app registers.
    public var toolNames: Set<String> {
        switch self {
        case .calendar:
            return [
                "calendar_list", "calendar_events", "calendar_create_event",
                "calendar_update_event", "calendar_delete_event", "calendar_open_event",
            ]
        case .reminders:
            return [
                "reminders_lists", "reminders_fetch", "reminders_create", "reminders_update",
                "reminders_complete", "reminders_delete", "reminders_open",
            ]
        case .contacts:
            return [
                "contacts_me", "contacts_search", "contacts_list", "contacts_get",
                "contacts_create", "contacts_update", "contacts_open",
            ]
        case .notes:
            return [
                "notes_folders", "notes_list", "notes_search", "notes_read",
                "notes_create", "notes_append", "notes_open",
            ]
        case .mail:
            return [
                "mail_mailboxes", "mail_list", "mail_read", "mail_search", "mail_compose",
                "mail_reply", "mail_move", "mail_set_status", "mail_thread",
            ]
        case .messages:
            return [
                "messages_conversations", "messages_read", "messages_unread",
                "messages_search", "messages_send",
            ]
        case .maps:
            return [
                "location_current", "location_geocode", "location_reverse_geocode",
                "maps_search", "maps_explore", "maps_directions", "maps_eta", "maps_open",
            ]
        case .music:
            return [
                "music_now_playing", "music_playback", "music_set_volume",
                "music_playlists", "music_search", "music_play",
            ]
        case .shortcuts:
            return ["shortcuts_list", "shortcuts_run"]
        }
    }

    /// Every Apple tool name across all apps.
    public static let allToolNames: Set<String> = allCases.reduce(into: Set<String>()) {
        $0.formUnion($1.toolNames)
    }

    /// Reverse lookup: which app owns a tool name (nil for non-Apple tools).
    public static func app(forTool name: String) -> AppleApp? {
        allCases.first { $0.toolNames.contains(name) }
    }

    /// Tool names for a set of enabled apps.
    public static func toolNames(for apps: Set<AppleApp>) -> Set<String> {
        apps.reduce(into: Set<String>()) { $0.formUnion($1.toolNames) }
    }

    /// Tool names for every app NOT in `apps` (what the composer strips).
    public static func disabledToolNames(enabled apps: Set<AppleApp>) -> Set<String> {
        allCases.filter { !apps.contains($0) }.reduce(into: Set<String>()) {
            $0.formUnion($1.toolNames)
        }
    }

    /// Case-insensitive parse used by the declarative config and migration.
    public static func parse(_ raw: String) -> AppleApp? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let app = AppleApp(rawValue: key) { return app }
        switch key {
        case "location", "maps & location", "maps_location": return .maps
        case "imessage": return .messages
        case "apple notes": return .notes
        case "apple music": return .music
        default: return nil
        }
    }

    /// Sorted display order (matches `allCases`).
    public static func sorted(_ apps: Set<AppleApp>) -> [AppleApp] {
        allCases.filter { apps.contains($0) }
    }

    /// Superseded osaurus-tools plugin id for this app, when one existed.
    public var supersededPluginId: String? {
        switch self {
        case .calendar: return "osaurus.calendar"
        case .reminders: return "osaurus.reminders"
        case .contacts: return "osaurus.contacts"
        case .notes: return "osaurus.notes"
        case .mail: return "osaurus.mail"
        case .messages: return "osaurus.messages"
        case .maps: return "osaurus.maps"
        case .music: return "osaurus.music"
        case .shortcuts: return nil
        }
    }

    /// Legacy osaurus-tools plugin tool names → the native tool that replaces
    /// each, keyed by the superseded plugin id (the owning app is implied by
    /// the id; see `supersededPluginId`). Used by the one-time
    /// `manualToolNames` migration, which applies a plugin's map ONLY when
    /// that plugin's folder is actually installed — these names (`play`,
    /// `send_message`, `create_note`, …) are common in unrelated plugins and
    /// MCP servers and must never be hijacked. `search_messages` shipped in
    /// both the Mail and Messages plugins and appears under both.
    public static let legacyPluginToolNamesByPlugin: [String: [String: String]] = [
        "osaurus.calendar": [
            "list_calendars": "calendar_list",
            "get_events": "calendar_events",
            "search_events": "calendar_events",
            "create_event": "calendar_create_event",
            "open_event": "calendar_open_event",
        ],
        "osaurus.reminders": [
            "get_reminders": "reminders_fetch",
            "search_reminders": "reminders_fetch",
            "create_reminder": "reminders_create",
            "get_lists": "reminders_lists",
            "open_reminder": "reminders_open",
        ],
        "osaurus.contacts": [
            "find_contact_by_name": "contacts_search",
            "find_contact_by_phone": "contacts_search",
            "find_number": "contacts_search",
            "get_all_numbers": "contacts_list",
        ],
        "osaurus.notes": [
            "list_notes": "notes_list",
            "search_notes": "notes_search",
            "create_note": "notes_create",
        ],
        "osaurus.mail": [
            "list_mailboxes": "mail_mailboxes",
            "list_messages": "mail_list",
            "read_message": "mail_read",
            "search_messages": "mail_search",
            "compose_message": "mail_compose",
            "reply_to_message": "mail_reply",
            "move_message": "mail_move",
            "set_message_status": "mail_set_status",
            "get_thread": "mail_thread",
        ],
        "osaurus.messages": [
            "search_messages": "messages_search",
            "send_message": "messages_send",
            "read_messages": "messages_read",
            "get_unread_messages": "messages_unread",
            "list_conversations": "messages_conversations",
            "detect_spam": "messages_unread",
        ],
        "osaurus.maps": [
            "maps_search_locations": "maps_search",
            "maps_get_directions": "maps_directions",
            "maps_drop_pin": "maps_open",
            "maps_get_current_location": "location_current",
            "maps_save_location": "maps_open",
            "maps_list_guides": "maps_open",
            "maps_add_to_guide": "maps_open",
            "maps_create_guide": "maps_open",
        ],
        "osaurus.music": [
            "open_music": "music_playback",
            "play": "music_playback",
            "pause": "music_playback",
            "next_track": "music_playback",
            "previous_track": "music_playback",
            "set_volume": "music_set_volume",
            "get_current_track": "music_now_playing",
            "get_library_stats": "music_playlists",
            "list_playlists": "music_playlists",
            "search_songs": "music_search",
            "play_song": "music_play",
            "play_playlist": "music_play",
        ],
    ]

    /// The app that owned a superseded plugin id, when one existed.
    public static func app(forSupersededPlugin pluginId: String) -> AppleApp? {
        allCases.first { $0.supersededPluginId == pluginId }
    }
}
