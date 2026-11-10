//
//  ConfigDiffView.swift
//  OsaurusCore
//
//  A unified configuration diff, shared by the approval card and the
//  Configuration History section. Removed lines read red, added lines green.
//

import SwiftUI

/// The diff text itself, scrollable, one row per line.
struct ConfigDiffText: View {
    let text: String
    var maxHeight: CGFloat = 220

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) {
                    _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(color(for: line))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(theme.space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: maxHeight)
        .settingsChrome(.code)
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return theme.text.tertiary }
        if line.hasPrefix("@@") { return theme.status.info.foreground }
        if line.hasPrefix("+") { return theme.status.success.foreground }
        if line.hasPrefix("-") { return theme.status.error.foreground }
        return theme.text.secondary
    }
}

/// "Show exact changes" disclosure for the approval card: open for short
/// diffs, collapsed over `collapseThreshold` lines.
struct ConfigDiffDisclosure: View {
    static let collapseThreshold = 20

    let text: String
    @State private var expanded: Bool

    @Environment(\.theme) private var theme

    init(text: String) {
        self.text = text
        _expanded = State(initialValue: !Self.startsCollapsed(text))
    }

    static func lineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    static func startsCollapsed(_ text: String) -> Bool { lineCount(text) > collapseThreshold }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .glyphSize(9)
                    Text(
                        expanded
                            ? L("Hide exact changes")
                            : L("Show exact changes (\(Self.lineCount(text)) lines)")
                    )
                    .promptText(.caption, fallback: .micro, weight: 600, theme: theme)
                }
                .foregroundColor(theme.text.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            if expanded {
                ConfigDiffText(text: text)
            }
        }
    }
}
