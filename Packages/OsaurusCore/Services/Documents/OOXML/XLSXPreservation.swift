//
//  XLSXPreservation.swift
//  osaurus
//
//  What a `file_write` regeneration would drop from an existing workbook.
//  `file_write` builds a workbook from rows (values and formulas only), so
//  replacing a workbook that carries styles, layout, validation or other
//  parts silently destroys them. `file_edit` edits the package in place and
//  keeps them; this check lets `file_write` refuse the lossy replacement and
//  point at the edit instead.
//

import Foundation

enum XLSXPreservation {
    /// Human-readable names of the workbook features in `data` that a
    /// row-based regeneration cannot write back, in a stable order. Empty
    /// for a workbook with plain values and formulas only (which includes
    /// every workbook `file_write` itself generates), and for bytes that are
    /// not a readable package (nothing to lose).
    static func featuresLostByRegeneration(_ data: Data) -> [String] {
        guard let package = try? OOXMLPackage(data: data) else { return [] }
        let parts = package.partNames
        func text(_ part: String) -> String {
            guard let bytes = try? package.data(part) else { return "" }
            return String(decoding: bytes, as: UTF8.self)
        }
        let sheets = parts.filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
        let sheetXML = sheets.map(text).joined(separator: "\n")
        var found: [String] = []
        func note(_ label: String, _ present: Bool) { if present && !found.contains(label) { found.append(label) } }

        // A cell style index other than 0 carries fonts, fills, borders or a
        // number format (currency, percent, dates).
        note("cell formatting and number formats", sheetXML.range(of: #"<c [^>]*\bs="[1-9]"#, options: .regularExpression) != nil)
        note("column widths", sheetXML.contains("<cols"))
        note("row heights", sheetXML.contains("customHeight=\"1\""))
        note("freeze panes", sheetXML.contains("<pane"))
        note("filters", sheetXML.contains("<autoFilter"))
        note("data validation", sheetXML.contains("<dataValidations"))
        note("conditional formatting", sheetXML.contains("<conditionalFormatting"))
        note("merged cells", sheetXML.contains("<mergeCells"))
        note("hyperlinks", sheetXML.contains("<hyperlinks"))
        note("sheet protection", sheetXML.contains("<sheetProtection"))
        note("defined names", text("xl/workbook.xml").contains("<definedNames"))
        note("comments", parts.contains { $0.hasPrefix("xl/comments") || $0.hasPrefix("xl/threadedComments") })
        note("charts", parts.contains { $0.hasPrefix("xl/charts/") })
        note("pivot tables", parts.contains { $0.hasPrefix("xl/pivotTables/") || $0.hasPrefix("xl/pivotCache/") })
        note("tables", parts.contains { $0.hasPrefix("xl/tables/") })
        note("images and drawings", parts.contains { $0.hasPrefix("xl/media/") || $0.hasPrefix("xl/drawings/drawing") })
        note("macros", parts.contains { $0.hasSuffix("vbaProject.bin") })
        return found
    }
}
