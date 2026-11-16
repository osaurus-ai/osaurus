//
//  ServerSettingsBanners.swift
//  osaurus
//
//  Top-of-content validation banner that surfaces
//  `VMLXServerSettingsIssue`s reported by the runtime's validator.
//  Restart-required state is shown inline in
//  `ServerSettingsActionBar`, not here, so this file is now a single
//  banner.
//

@preconcurrency import MLXLMCommon
import SwiftUI

/// Banner that lists the active `VMLXServerSettingsIssue`s. Hidden
/// when `issues` is empty (parent is responsible for the guard).
struct ServerSettingsValidationBanner: View {
    let issues: [VMLXServerSettingsIssue]

    var body: some View {
        SettingsCallout(
            icon: "exclamationmark.triangle.fill",
            title: "Configuration issues",
            message: "",
            tone: issues.contains { $0.severity == .error } ? .error : .warning,
            quote: issues.map { "\($0.field): \($0.message)" }.joined(separator: "\n")
        )
    }
}
