//
//  WorkflowSharePanels.swift
//  osaurus
//
//  What gets shared beside what stays on this Mac, above who can see a
//  shared workflow. The lines come from `WorkflowShareSummary`.
//

import SwiftUI

struct WorkflowSharePanels: View {
    @Environment(\.theme) private var theme
    let summary: WorkflowShareSummary

    var body: some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            panel(
                title: L("What gets shared"), lines: summary.shared, icon: "checkmark",
                tint: theme.statusInk(.success), chrome: .status(.success))
            panel(
                title: L("What stays on your Mac"), lines: summary.staysOnMac, icon: "lock",
                tint: theme.text.secondary, chrome: .card)
        }
        .fixedSize(horizontal: false, vertical: true)
        .settingsLandingAnchor("workflows.shareSummary")
    }

    private func panel(title: String, lines: [String], icon: String, tint: Color, chrome: SettingsChrome) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            Text(verbatim: title)
                .textStyle(.body, weight: 600)
                .foregroundStyle(chrome == .card ? theme.text.primary : tint)
                .accessibilityAddTraits(.isHeader)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                    Image(systemName: icon)
                        .glyphSize(.caption, weight: .semibold)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(verbatim: line)
                        .font(SettingsFont.compactLabel)
                        .foregroundStyle(theme.text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(theme.space.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsChrome(chrome)
        .accessibilityElement(children: .combine)
    }
}
