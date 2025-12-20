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
    /// Accessibility API access (AXIsProcessTrusted)
    case accessibility
    /// Full Disk Access permission
    case disk

    /// Human-readable name for UI display
    var displayName: String {
        switch self {
        case .automation:
            return "Automation"
        case .automationCalendar:
            return "Automation (Calendar)"
        case .accessibility:
            return "Accessibility"
        case .disk:
            return "Full Disk Access"
        }
    }

    /// Description of what this permission enables
    var description: String {
        switch self {
        case .automation:
            return "Allows plugins to control other applications using AppleScript and Apple Events."
        case .automationCalendar:
            return "Allows plugins to read and create events in Calendar.app via AppleScript."
        case .accessibility:
            return "Allows plugins to interact with UI elements, simulate input, and control the computer."
        case .disk:
            return "Allows plugins to access protected files like the Messages database and other app data."
        }
    }

    /// Icon name for UI display
    var iconName: String {
        switch self {
        case .automation:
            return "applescript"
        case .automationCalendar:
            return "calendar"
        case .accessibility:
            return "accessibility"
        case .disk:
            return "disk"
        }
    }

    /// System icon as fallback
    var systemIconName: String {
        switch self {
        case .automation:
            return "gearshape.2"
        case .automationCalendar:
            return "calendar"
        case .accessibility:
            return "figure.stand"
        case .disk:
            return "externaldrive.fill.badge.checkmark"
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
        case .accessibility:
            // Opens Privacy & Security > Accessibility
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .disk:
            // Opens Privacy & Security > Full Disk Access
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        }
    }
}
