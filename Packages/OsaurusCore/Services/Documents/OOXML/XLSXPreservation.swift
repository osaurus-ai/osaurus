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
        let sheets = parts.filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
        let roots = sheets.compactMap { try? package.root($0) }
        func elements(_ localName: String) -> [XMLElement] {
            roots.flatMap { $0.descendants(localName) }
        }
        var found: [String] = []
        func note(_ label: String, _ present: Bool) { if present && !found.contains(label) { found.append(label) } }

        // OOXML namespace prefixes and XML whitespace/attribute quoting are arbitrary. Inspect
        // parsed local names, as the editor does, rather than serialized spellings like `<c `.
        note("cell formatting and number formats", elements("c").contains { (Int($0.attr("s") ?? "0") ?? 0) > 0 })
        note("column widths", !elements("cols").isEmpty)
        note("row heights", elements("row").contains { ["1", "true"].contains($0.attr("customHeight") ?? "") })
        note("freeze panes", !elements("pane").isEmpty)
        note("filters", !elements("autoFilter").isEmpty)
        note("data validation", !elements("dataValidations").isEmpty)
        note("conditional formatting", !elements("conditionalFormatting").isEmpty)
        note("merged cells", !elements("mergeCells").isEmpty)
        note("hyperlinks", !elements("hyperlinks").isEmpty)
        note("sheet protection", !elements("sheetProtection").isEmpty)
        note("defined names", (try? package.root("xl/workbook.xml").descendants("definedNames").isEmpty) == false)
        note("comments", parts.contains { $0.hasPrefix("xl/comments") || $0.hasPrefix("xl/threadedComments") })
        note("charts", parts.contains { $0.hasPrefix("xl/charts/") })
        note("pivot tables", parts.contains { $0.hasPrefix("xl/pivotTables/") || $0.hasPrefix("xl/pivotCache/") })
        note("tables", parts.contains { $0.hasPrefix("xl/tables/") })
        note("images and drawings", parts.contains { $0.hasPrefix("xl/media/") || $0.hasPrefix("xl/drawings/drawing") })
        note("macros", parts.contains { $0.hasSuffix("vbaProject.bin") })
        return found
    }

    /// The first-party osaurus.xlsx plugin's `save_xlsx` writes a minimal package (sheets, values, formulas,
    /// merges). With `overwrite: true` over an existing workbook it drops everything else, the same loss
    /// `file_write` refuses. Returns the refusal envelope when that would happen, nil otherwise (including
    /// whenever the target cannot be resolved: the plugin then runs exactly as before).
    static func pluginOverwriteRefusal(
        pluginId: String, toolName: String, argumentsJSON: String, folderRoot: URL?
    ) -> String? {
        guard pluginId == "osaurus.xlsx", toolName == "save_xlsx",
            let data = argumentsJSON.data(using: .utf8),
            let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            args["overwrite"] as? Bool == true, args["dry_run"] as? Bool != true,
            var path = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        else { return nil }
        // save_xlsx adds the extension when it is missing.
        if URL(fileURLWithPath: path).pathExtension.lowercased() != "xlsx" { path += ".xlsx" }
        let expanded = (path as NSString).expandingTildeInPath
        let target: URL
        if expanded.hasPrefix("/") {
            target = URL(fileURLWithPath: expanded)
        } else if let folderRoot {
            target = folderRoot.appendingPathComponent(expanded)
        } else {
            return nil
        }
        guard let existing = try? Data(contentsOf: target) else { return nil }
        let lost = featuresLostByRegeneration(existing)
        guard !lost.isEmpty else { return nil }
        let operations = DocumentEditService.operationNames(for: "xlsx").joined(separator: ", ")
        // `invalid_args`, not `rejected`: the model has to be able to switch tools in the same turn.
        return ToolEnvelope.failure(
            kind: .invalidArgs,
            message:
                "'\(path)' already exists and has \(lost.joined(separator: ", ")). save_xlsx writes a minimal workbook "
                + "(values and formulas only), so overwriting it would drop all of that. Edit it in place with `file_edit` "
                + "`operations` instead, which keeps everything else, e.g. {\"path\": \"\(path)\", \"operations\": [{\"op\": "
                + "\"set_cells\", \"cells\": {\"B2\": 42, \"C2\": \"=SUM(B2:B9)\"}}]} (first sheet unless `sheet` is given; "
                + "operations: \(operations)). To keep the plugin's result, save it to a new path. The file was not changed.",
            field: "overwrite",
            expected: "file_edit operations for an existing formatted workbook, or a new path",
            tool: toolName,
            retryable: false,
            metadata: ["retry_with_tool": "file_edit", "features_preserved_by_edit": lost]
        )
    }
}
