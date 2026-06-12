//
//  CSVRowParser.swift
//  osaurus
//
//  Shared delimited-text parser for CSV/TSV adapters and workflow previews.
//

import Foundation

enum CSVRowParser {
    struct Cell: Equatable, Sendable {
        let text: String
        let wasQuoted: Bool
        let sourceRange: DocumentTextRange
    }

    struct Row: Equatable, Sendable {
        let cells: [Cell]
        let sourceRange: DocumentTextRange
    }

    static func parseRows(source: String, delimiter: CSVDelimiter) -> [Row] {
        let delimiterScalar = scalar(for: delimiter)
        let quoteScalar = UnicodeScalar("\"")
        let carriageReturn = UnicodeScalar("\r")
        let lineFeed = UnicodeScalar("\n")
        let scalars = source.unicodeScalars

        var rows: [Row] = []
        var cells: [Cell] = []
        var field = ""
        var fieldStart = 0
        var rowStart = 0
        var offset = 0
        var isQuoted = false
        var wasQuoted = false
        var index = scalars.startIndex

        func finishCell(sourceEnd: Int) {
            let sourceRange = DocumentTextRange(
                startUTF16Offset: fieldStart,
                length: sourceEnd - fieldStart
            )
            cells.append(
                Cell(
                    text: field,
                    wasQuoted: wasQuoted,
                    sourceRange: sourceRange
                )
            )
            field = ""
            wasQuoted = false
        }

        func finishRow(sourceEnd: Int) {
            finishCell(sourceEnd: sourceEnd)
            let rowRange = DocumentTextRange(
                startUTF16Offset: rowStart,
                length: sourceEnd - rowStart
            )
            rows.append(Row(cells: cells, sourceRange: rowRange))
            cells = []
        }

        while index != scalars.endIndex {
            let scalar = scalars[index]
            let scalarLength = utf16Length(of: scalar)

            if isQuoted {
                if scalar == quoteScalar {
                    let nextIndex = scalars.index(after: index)
                    if nextIndex != scalars.endIndex, scalars[nextIndex] == quoteScalar {
                        field.unicodeScalars.append(quoteScalar)
                        scalars.formIndex(after: &index)
                        scalars.formIndex(after: &index)
                        offset += 2
                    } else {
                        isQuoted = false
                        scalars.formIndex(after: &index)
                        offset += scalarLength
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                    scalars.formIndex(after: &index)
                    offset += scalarLength
                }
                continue
            }

            if scalar == quoteScalar, field.isEmpty, fieldStart == offset {
                isQuoted = true
                wasQuoted = true
                scalars.formIndex(after: &index)
                offset += scalarLength
                continue
            }

            if scalar == delimiterScalar {
                finishCell(sourceEnd: offset)
                scalars.formIndex(after: &index)
                offset += scalarLength
                fieldStart = offset
                continue
            }

            if scalar == carriageReturn || scalar == lineFeed {
                finishRow(sourceEnd: offset)
                let nextIndex = scalars.index(after: index)
                if scalar == carriageReturn, nextIndex != scalars.endIndex, scalars[nextIndex] == lineFeed {
                    scalars.formIndex(after: &index)
                    scalars.formIndex(after: &index)
                    offset += 2
                } else {
                    scalars.formIndex(after: &index)
                    offset += scalarLength
                }
                rowStart = offset
                fieldStart = offset
                continue
            }

            field.unicodeScalars.append(scalar)
            scalars.formIndex(after: &index)
            offset += scalarLength
        }

        if !cells.isEmpty || !field.isEmpty || wasQuoted || fieldStart < offset {
            finishRow(sourceEnd: offset)
        }

        return rows
    }

    private static func scalar(for delimiter: CSVDelimiter) -> UnicodeScalar {
        switch delimiter {
        case .comma: return UnicodeScalar(",")
        case .tab: return UnicodeScalar("\t")
        }
    }

    private static func utf16Length(of scalar: UnicodeScalar) -> Int {
        scalar.value <= 0xFFFF ? 1 : 2
    }
}
