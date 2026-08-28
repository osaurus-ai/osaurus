//
//  SecureFieldRedaction.swift
//  OsaurusCore — Computer Use
//
//  Shared role guard for AX password fields. Native traversal should avoid
//  reading their contents, and model-facing renderers should drop any secure
//  value that reaches them through a mock or future capture path.
//

import Foundation

enum ComputerUseSecureFieldRedaction {
    static let roles: Set<String> = [
        "securetextfield",
        "axsecuretextfield",
        "securefield",
        "passwordfield",
        "password",
    ]

    static func isSecureRole(_ role: String) -> Bool {
        let lower = role.lowercased()
        let normalized = lower.hasPrefix("ax") ? String(lower.dropFirst(2)) : lower
        return roles.contains(lower) || roles.contains(normalized)
    }

    static func value(role: String, _ value: String?) -> String? {
        isSecureRole(role) ? nil : value
    }

    static func selectedText(role: String, _ selectedText: String?) -> String? {
        isSecureRole(role) ? nil : selectedText
    }
}
