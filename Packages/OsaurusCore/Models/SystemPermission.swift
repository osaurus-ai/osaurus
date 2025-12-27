//
//  SystemPermission.swift
//  osaurus
//
//  Defines system-level permissions that plugins can require.
//

import Foundation

/// System-level macOS permissions that plugins can declare as requirements.
/// These are checked at the OS level, not per-tool grants.
enum SystemPermission: String, CaseIterable, Codable, Sendable {
    /// AppleScript / Apple Events automation permission (System Events)
    case automation
    /// AppleScript automation permission for Calendar.app specifically
    case automationCalendar = "automation_calendar"
    /// EventKit Calendar access permission
    case calendar
    /// EventKit Reminders access permission
    case reminders
    /// Location Services permission
    case location
    /// AppleScript automation permission for Notes.app
    case notes
    /// AppleScript automation permission for Maps.app
    case maps
    /// Accessibility API access (AXIsProcessTrusted)
    case accessibility
    /// Contacts access permission
    case contacts
    /// Full Disk Access permission
    case disk
    /// Microphone access permission (for voice transcription)
    case microphone
    /// Screen Recording permission (for system audio capture)
    case screenRecording = "screen_recording"

    /// Human-readable name for UI display
    var displayName: String {
        switch self {
        case .automation:
            return "Automation"
        case .automationCalendar:
            return "Automation (Calendar)"
        case .calendar:
            return "Calendar"
        case .reminders:
            return "Reminders"
        case .location:
            return "Location"
        case .notes:
            return "Notes"
        case .maps:
            return "Maps"
        case .accessibility:
            return "Accessibility"
        case .contacts:
            return "Contacts"
        case .disk:
            return "Full Disk Access"
        case .microphone:
            return "Microphone"
        case .screenRecording:
            return "Screen Recording"
        }
    }

    /// Description of what this permission enables
    var description: String {
        switch self {
        case .automation:
            return "Allows plugins to control other applications using AppleScript and Apple Events."
        case .automationCalendar:
            return "Allows plugins to read and create events in Calendar.app via AppleScript."
        case .calendar:
            return "Allows plugins to access your calendar to read and create events directly."
        case .reminders:
            return "Allows plugins to access your reminders to read and create tasks."
        case .location:
            return "Allows plugins to access your current location."
        case .notes:
            return "Allows plugins to read and create notes in the Notes app via AppleScript."
        case .maps:
            return "Allows plugins to control Maps app via AppleScript."
        case .accessibility:
            return "Allows plugins to interact with UI elements, simulate input, and control the computer."
        case .contacts:
            return "Allows plugins to access and search contacts."
        case .disk:
            return "Allows plugins to access protected files like the Messages database and other app data."
        case .microphone:
            return "Allows voice transcription using the microphone for speech-to-text."
        case .screenRecording:
            return "Allows capturing system audio for transcription. Screen content is not recorded."
        }
    }

    /// Icon name for UI display
    var iconName: String {
        switch self {
        case .automation:
            return "applescript"
        case .automationCalendar:
            return "calendar"
        case .calendar:
            return "calendar.badge.plus"
        case .reminders:
            return "list.bullet.clipboard"
        case .location:
            return "location"
        case .notes:
            return "note"
        case .maps:
            return "map"
        case .accessibility:
            return "accessibility"
        case .contacts:
            return "person.crop.circle"
        case .disk:
            return "disk"
        case .microphone:
            return "mic"
        case .screenRecording:
            return "display"
        }
    }

    /// System icon as fallback
    var systemIconName: String {
        switch self {
        case .automation:
            return "gearshape.2"
        case .automationCalendar:
            return "calendar"
        case .calendar:
            return "calendar"
        case .reminders:
            return "list.bullet.rectangle"
        case .location:
            return "location.fill"
        case .notes:
            return "note.text"
        case .maps:
            return "map.fill"
        case .accessibility:
            return "figure.stand"
        case .contacts:
            return "person.crop.circle"
        case .disk:
            return "externaldrive.fill.badge.checkmark"
        case .microphone:
            return "mic.fill"
        case .screenRecording:
            return "rectangle.inset.filled.on.rectangle"
        }
    }

    /// URL scheme to open the relevant System Settings pane
    var systemSettingsURL: URL? {
        switch self {
        case .automation:
            // Opens Privacy & Security > Automation
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .automationCalendar:
            // Opens Privacy & Security > Automation (Calendar is listed under the app)
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .calendar:
            // Opens Privacy & Security > Calendars
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        case .reminders:
            // Opens Privacy & Security > Reminders
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        case .location:
            // Opens Privacy & Security > Location Services
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        case .notes:
            // Opens Privacy & Security > Automation (Notes is listed under the app)
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .maps:
            // Opens Privacy & Security > Automation (Maps is listed under the app)
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .accessibility:
            // Opens Privacy & Security > Accessibility
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .contacts:
            // Opens Privacy & Security > Contacts
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
        case .disk:
            // Opens Privacy & Security > Full Disk Access
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .microphone:
            // Opens Privacy & Security > Microphone
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .screenRecording:
            // Opens Privacy & Security > Screen Recording
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }
}
