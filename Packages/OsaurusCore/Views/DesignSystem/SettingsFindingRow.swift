//
//  SettingsFindingRow.swift
//  osaurus
//
//  One result of a check (preflight, permission doctor, gate inspector):
//  severity glyph, title, optional code or value, detail, and the fix.
//  Problems draw a tinted well; healthy and informational rows stay quiet.
//

import SwiftUI

struct SettingsFindingRow: View {
    @Environment(\.theme) private var theme

    enum Severity: Equatable {
        case ok
        case info
        case warning
        case blocked
        /// Not applicable right now (feature off, step not reached).
        case inactive
    }

    let severity: Severity
    /// Rendered verbatim: findings carry already-localized, data-driven copy.
    let title: String
    /// Monospaced identifier after the title (`missing_root`).
    var code: String? = nil
    /// Short tinted outcome after the title ("Granted", "Ask first").
    var value: String? = nil
    var detail: String? = nil
    /// The repair step, tinted and selectable.
    var fix: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: glyph)
                .font(SettingsFont.glyphSmall)
                .foregroundColor(tint)
                .frame(width: 14)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: theme.settingsTitleToDescription) {
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                    Text(verbatim: title)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.primary)
                    if let value {
                        Text(verbatim: value)
                            .font(SettingsFont.chip)
                            .foregroundColor(tint)
                    }
                    if let code {
                        Text(verbatim: code)
                            .font(SettingsFont.monoSmall)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fix, !fix.isEmpty {
                    Text(verbatim: fix)
                        .font(SettingsFont.chip)
                        .foregroundColor(tint)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .settingsChrome(statusKind.map { .status($0) } ?? .inset)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: severityLabel))
    }

    private var isProblem: Bool {
        severity == .warning || severity == .blocked
    }

    /// Status tone for the row's chrome; only problems get a tinted surface.
    private var statusKind: ThemeStatusKind? {
        switch severity {
        case .warning: .warning
        case .blocked: .error
        case .ok, .info, .inactive: nil
        }
    }

    private var tint: Color {
        switch severity {
        case .ok: theme.status.success.foreground
        case .info: theme.status.info.foreground
        case .warning: theme.status.warning.foreground
        case .blocked: theme.status.error.foreground
        case .inactive: theme.text.tertiary
        }
    }

    private var glyph: String {
        switch severity {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        case .inactive: "minus.circle.fill"
        }
    }

    private var severityLabel: String {
        switch severity {
        case .ok: L("OK")
        case .info: L("Info")
        case .warning: L("Warning")
        case .blocked: L("Blocked")
        case .inactive: L("Inactive")
        }
    }
}
