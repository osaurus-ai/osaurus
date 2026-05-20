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
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text("Configuration issues", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.warningColor)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(issues, id: \.field) { issue in
                    row(issue)
                }
            }
            .padding(.leading, 25)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.warningColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.warningColor.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func row(_ issue: VMLXServerSettingsIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(
                systemName: issue.severity == .error
                    ? "xmark.octagon.fill" : "exclamationmark.bubble.fill"
            )
            .font(.system(size: 11))
            .foregroundColor(issue.severity == .error ? theme.errorColor : theme.warningColor)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.field)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                Text(issue.message)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
