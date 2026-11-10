//
//  TableView.swift
//  osaurus
//
//  Renders markdown tables using SwiftUI Grid
//

import SwiftUI

struct TableView: View {
    let headers: [String]
    let rows: [[String]]
    let baseWidth: CGFloat

    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(20, enabled: baseComponentEnabled) }

    var body: some View {
        Grid(horizontalSpacing: gridStroke, verticalSpacing: gridStroke) {
            // Headers
            GridRow(alignment: .top) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    TableCell(
                        text: header,
                        isHeader: true,
                        rowIndex: -1
                    )
                }
            }

            // Rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow(alignment: .top) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                        TableCell(
                            text: cell,
                            isHeader: false,
                            rowIndex: rowIndex
                        )
                    }
                    // Fill missing cells if any
                    if row.count < headers.count {
                        ForEach(row.count ..< headers.count, id: \.self) { _ in
                            TableCell(
                                text: "",
                                isHeader: false,
                                rowIndex: rowIndex
                            )
                        }
                    }
                }
            }
        }
        .padding(gridStroke)
        .background(theme.assignedColor("component.library.20.border", fallback: theme.border.subtle))
        .clipShape(RoundedRectangle(cornerRadius: theme.catalogMetric("radius", fallback: 6)))
        .frame(width: baseWidth, alignment: .leading)
    }

    private var gridStroke: CGFloat {
        theme.catalogMetric("borderWidth", fallback: 1)
    }
}

// MARK: - Subviews

private struct TableCell: View {
    let text: String
    let isHeader: Bool
    let rowIndex: Int

    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(20, enabled: baseComponentEnabled) }

    var body: some View {
        renderMarkdown(text.replacingOccurrences(of: "<br>", with: "\n"))
            .assignedTypography(isHeader ? "component.library.20.label" : "component.library.20.text",
                fallback: isHeader ? SettingsFont.compactLabel : SettingsFont.rowDescription)
            .foregroundColor(theme.text.primary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            .frame(maxWidth: .infinity, minHeight: theme.catalogMetric("height", fallback: 0), maxHeight: .infinity, alignment: .topLeading)
            .background(background)
    }

    private var background: Color {
        if isHeader {
            return theme.surface.subtle
        }
        #if OSAURUS_DESIGN_SYSTEM
        return rowIndex % 2 == 0 ? theme.surface.raised : theme.surface.hover
        #else
        return rowIndex % 2 == 0 ? theme.surface.canvas : theme.surface.hover
        #endif
    }

    private func renderMarkdown(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)

        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            var plain = AttributedString(text)
            #if !OSAURUS_DESIGN_SYSTEM
            plain.font = theme.textStyle(.body).weight(isHeader ? .bold : .regular)
            #endif
            plain.foregroundColor = theme.text.primary
            return Text(plain)
        }

        // Apply base font and color
        let monoFont = theme.textStyle(.code)

        #if !OSAURUS_DESIGN_SYSTEM
        attributed.font = theme.textStyle(.body).weight(isHeader ? .bold : .regular)
        #endif
        attributed.foregroundColor = theme.text.primary

        // Style inline code runs
        for run in attributed.runs {
            if let traits = run.inlinePresentationIntent, traits.contains(.code) {
                attributed[run.range].font = monoFont
                #if OSAURUS_DESIGN_SYSTEM
                attributed[run.range].foregroundColor = baseComponentEnabled ? theme.action.primary.default.background : theme.text.disabled
                #else
                attributed[run.range].foregroundColor = theme.action.primary.default.background
                #endif
            }
        }

        return Text(attributed)
    }
}
