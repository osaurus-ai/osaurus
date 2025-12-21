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

    @Environment(\.theme) private var theme

    var body: some View {
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            // Headers
            GridRow {
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
                GridRow {
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
        .padding(1)
        .background(theme.primaryBorder)  // Grid lines color
        .cornerRadius(6)
        .frame(width: baseWidth, alignment: .leading)
    }
}

// MARK: - Subviews

private struct TableCell: View {
    let text: String
    let isHeader: Bool
    let rowIndex: Int

    @Environment(\.theme) private var theme

    var body: some View {
        renderMarkdown(text.replacingOccurrences(of: "<br>", with: "\n"))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }

    private var background: Color {
        if isHeader {
            return theme.secondaryBackground
        }
        return rowIndex % 2 == 0 ? theme.primaryBackground : theme.secondaryBackground.opacity(0.3)
    }

    private func renderMarkdown(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)

        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return Text(text)
                .font(
                    theme.font(
                        size: CGFloat(isHeader ? theme.bodySize : theme.bodySize),
                        weight: isHeader ? .bold : .regular
                    )
                )
                .foregroundColor(theme.primaryText)
        }

        // Apply base font and color
        let baseFont = theme.font(size: CGFloat(theme.bodySize), weight: isHeader ? .bold : .regular)
        let monoFont = theme.monoFont(size: CGFloat(theme.bodySize) * 0.9, weight: .regular)

        attributed.font = baseFont
        attributed.foregroundColor = theme.primaryText

        // Style inline code runs
        for run in attributed.runs {
            if let traits = run.inlinePresentationIntent, traits.contains(.code) {
                attributed[run.range].font = monoFont
                attributed[run.range].foregroundColor = theme.accentColor
            }
        }

        return Text(attributed)
    }
}
