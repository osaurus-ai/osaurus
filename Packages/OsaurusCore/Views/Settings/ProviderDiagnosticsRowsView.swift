//
//  ProviderDiagnosticsRowsView.swift
//  osaurus
//
//  Shared compact diagnostics renderer for provider settings rows.
//

import AppKit
import SwiftUI

struct ProviderDiagnosticsRowsView: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let report: ProviderDiagnosticReport
    var maxRows: Int?
    @State private var showingAll = false

    private var visibleRows: [ProviderDiagnosticRow] {
        guard let maxRows, !showingAll else { return report.rows }
        return Array(report.rows.prefix(maxRows))
    }

    private var hiddenCount: Int {
        max(0, report.rows.count - visibleRows.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "stethoscope")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundColor(theme.text.tertiary)
                Text("Diagnostics", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)
                Spacer()
                Button(action: copyReport) {
                    Image(systemName: "doc.on.doc")
                        .glyphSize(.footnote, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainButtonStyle())
                .localizedHelp("Copy")
            }

            VStack(alignment: .leading, spacing: theme.space.s6) {
                ForEach(visibleRows) { row in
                    diagnosticRow(row)
                }
                if hiddenCount > 0 {
                    Button {
                        withAnimation(theme.motion.quick) {
                            showingAll = true
                        }
                    } label: {
                        Label(
                            hiddenCount == 1 ? "Show 1 more detail" : "Show \(hiddenCount) more details",
                            systemImage: "chevron.down"
                        )
                        .componentInspectionText(47, role: .label, fallback: .footnote, weight: 500, theme: theme)
                        .foregroundColor(theme.text.link)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else if showingAll, maxRows != nil, report.rows.count > (maxRows ?? 0) {
                    Button {
                        withAnimation(theme.motion.quick) {
                            showingAll = false
                        }
                    } label: {
                        Label {
                            Text("Show fewer details", bundle: .module)
                        } icon: {
                            Image(systemName: "chevron.up")
                        }
                        .componentInspectionText(47, role: .label, fallback: .footnote, weight: 500, theme: theme)
                        .foregroundColor(theme.text.link)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s8)
    }

    private func diagnosticRow(_ row: ProviderDiagnosticRow) -> some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: icon(for: row.severity))
                .glyphSize(.micro, weight: .semibold)
                .foregroundColor(color(for: row.severity))
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                    Text(row.title)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)
                    Text(row.value)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(2)
                }

                if let action = row.action, !action.isEmpty {
                    Text(action)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                        .foregroundColor(color(for: row.severity))
                        .lineLimit(2)
                }
            }
        }
    }

    private func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.pasteboardText, forType: .string)
    }

    private func color(for severity: ProviderDiagnosticSeverity) -> Color {
        switch severity {
        case .ok:
            return theme.status.success.foreground
        case .info:
            return theme.status.info.foreground
        case .warning:
            return theme.status.warning.foreground
        case .blocked:
            return theme.status.error.foreground
        }
    }

    private func icon(for severity: ProviderDiagnosticSeverity) -> String {
        switch severity {
        case .ok:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.octagon.fill"
        }
    }
}
