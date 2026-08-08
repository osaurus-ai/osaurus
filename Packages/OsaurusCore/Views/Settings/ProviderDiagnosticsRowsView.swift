//
//  ProviderDiagnosticsRowsView.swift
//  osaurus
//
//  Shared compact diagnostics renderer for provider settings rows.
//

import AppKit
import SwiftUI

struct ProviderDiagnosticsRowsView: View {
    @Environment(\.theme) private var theme

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                Text("Diagnostics", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Button(action: copyReport) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainButtonStyle())
                .localizedHelp("Copy")
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleRows) { row in
                    diagnosticRow(row)
                }
                if hiddenCount > 0 {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showingAll = true
                        }
                    } label: {
                        Label(
                            hiddenCount == 1 ? "Show 1 more detail" : "Show \(hiddenCount) more details",
                            systemImage: "chevron.down"
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else if showingAll, maxRows != nil, report.rows.count > (maxRows ?? 0) {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showingAll = false
                        }
                    } label: {
                        Label {
                            Text("Show fewer details", bundle: .module)
                        } icon: {
                            Image(systemName: "chevron.up")
                        }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func diagnosticRow(_ row: ProviderDiagnosticRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: row.severity))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color(for: row.severity))
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Text(row.value)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                }

                if let action = row.action, !action.isEmpty {
                    Text(action)
                        .font(.system(size: 10, weight: .medium))
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
            return theme.successColor
        case .info:
            return theme.infoColor
        case .warning:
            return theme.warningColor
        case .blocked:
            return theme.errorColor
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
