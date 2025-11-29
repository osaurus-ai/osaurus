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
    /// AppleScript / Apple Events automation permission
    case automation
    /// Accessibility API access (AXIsProcessTrusted)
    case accessibility

    /// Human-readable name for UI display
    var displayName: String {
        switch self {
        case .automation:
            return "Automation"
        case .accessibility:
            return "Accessibility"
        }
    }

    /// Description of what this permission enables
    var description: String {
        switch self {
        case .automation:
            return "Allows plugins to control other applications using AppleScript and Apple Events."
        case .accessibility:
            return "Allows plugins to interact with UI elements, simulate input, and control the computer."
        }
    }

    /// Icon name for UI display
    var iconName: String {
        switch self {
        case .automation:
            return "applescript"
        case .accessibility:
            return "accessibility"
        }
    }

    /// System icon as fallback
    var systemIconName: String {
        switch self {
        case .automation:
            return "gearshape.2"
        case .accessibility:
            return "figure.stand"
        }
    }

    /// URL scheme to open the relevant System Settings pane
    var systemSettingsURL: URL? {
        switch self {
        case .automation:
            // Opens Privacy & Security > Automation
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .accessibility:
            // Opens Privacy & Security > Accessibility
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}
