//
//  XLSXEditor.swift
//  osaurus
//
//  In-place spreadsheet edits on the worksheet XML: set cell values or
//  formulas (keeping each cell's style), insert/delete rows (shifting
//  references in formulas, merges, validations and defined names), and
//  add/rename/delete sheets. Any edit drops the calculation chain and
//  asks Excel/Numbers to recalculate on open, so no stale cached result
//  is presented as current.
//

import Foundation

struct XLSXEditor {
    struct SheetInfo {
        let name: String
        let part: String
        let relationshipId: String
        let element: XMLElement
    }

    let package: OOXMLPackage
    private(set) var summaries: [String] = []
    private(set) var warnings: [String] = []

    private let ns = OOXMLNamespace.spreadsheet
    private let workbookPart: String
    private var needsRecalc = false

    static let operations = ["set_cells", "insert_rows", "delete_rows", "add_sheet", "rename_sheet", "delete_sheet"]
    static let maxCellsPerOperation = 10_000
    static let worksheetContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"

    init(package: OOXMLPackage) throws {
        self.package = package
        workbookPart = try package.mainPart()
        guard try package.root(workbookPart).firstChild("sheets") != nil else {
            throw DocumentEditError("This workbook has no sheet list to edit.")
        }
    }

    mutating func apply(_ op: DocumentOperation) throws {
        switch op.name {
        case "set_cells": try setCells(op)
        case "insert_rows": try shiftRows(op, inserting: true)
        case "delete_rows": try shiftRows(op, inserting: false)
        case "add_sheet": try addSheet(op)
        case "rename_sheet": try renameSheet(op)
        case "delete_sheet": try deleteSheet(op)
        default:
            throw op.fail("unknown op for .xlsx; use one of \(Self.operations.joined(separator: ", ")).")
        }
    }

    /// Called once after every operation ran.
    mutating func finish() throws {
        guard needsRecalc else { return }
        for rel in try package.relationships(of: workbookPart) where rel.type == OOXMLRelationshipType.calcChain {
            let part = OOXMLPackage.resolve(rel.target, from: workbookPart)
            if package.has(part) { try package.removePart(part) }
            try package.removeRelationship(from: workbookPart, id: rel.id)
        }
        let workbook = try package.root(workbookPart)
        let calcPr: XMLElement
        if let existing = workbook.firstChild("calcPr") {
            calcPr = existing
        } else {
            calcPr = workbook.makeChild("calcPr", uri: ns)
            // CT_Workbook order: calcPr follows sheets / functionGroups /
            // externalReferences / definedNames.
            let predecessors = ["definedNames", "externalReferences", "functionGroups", "sheets"]
            if let anchor = predecessors.lazy.compactMap({ workbook.firstChild($0) }).first {
                calcPr.insertSibling(after: anchor)
            } else {
                workbook.addChild(calcPr)
            }
        }
        calcPr.setAttr("fullCalcOnLoad", "1")
        package.markDirty(workbookPart)
    }

    // MARK: - Sheets

    func sheets() throws -> [SheetInfo] {
        let list = try package.root(workbookPart).firstChild("sheets")!
        return try list.childElements("sheet").compactMap { element in
            guard let name = element.attr("name"), let rid = element.attr("r:id") ?? element.attr("id"),
                let part = try package.target(of: rid, from: workbookPart)
            else { return nil }
            return SheetInfo(name: name, part: part, relationshipId: rid, element: element)
        }
    }

    private func sheet(_ op: DocumentOperation, key: String = "sheet", required: Bool = false) throws -> SheetInfo {
        let all = try sheets()
        guard !all.isEmpty else { throw op.fail("the workbook has no sheets.") }
        guard op.has(key) else {
            if required {
                throw op.fail(
                    "`\(key)` is required for \(op.name): name the sheet (or give its 1-based position). Sheets: \(all.map(\.name).joined(separator: ", ")).")
            }
            return all[0]
        }
        if let number = DocumentOperation.coerceInt(op.args[key]), !(op.args[key] is String) {
            return all[try op.position(number, of: all.count, noun: "sheet")]
        }
        let name = try op.string(key)
        if let match = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        throw op.fail("there's no sheet named \"\(name)\". Sheets: \(all.map(\.name).joined(separator: ", ")).")
    }

    private func sheetData(_ sheet: SheetInfo, op: DocumentOperation) throws -> XMLElement {
        guard let data = try package.root(sheet.part).firstChild("sheetData") else {
            throw op.fail("sheet \"\(sheet.name)\" has no cell data section.")
        }
        return data
    }

    // MARK: - set_cells

    private enum CellValue {
        case clear
        case formula(String)
        case text(String)
        case number(Double)
        case bool(Bool)
    }

    private mutating func setCells(_ op: DocumentOperation) throws {
        let target = try sheet(op)
        var assignments: [(XLSXFormula.CellRef, CellValue)] = []
        func value(_ raw: Any?) throws -> CellValue {
            switch raw {
            case nil, is NSNull: return .clear
            case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return .bool(n.boolValue)
            case let n as NSNumber:
                guard n.doubleValue.isFinite else { throw op.fail("cell values must be finite numbers.") }
                return .number(n.doubleValue)
            case let s as String:
                if s.hasPrefix("="), s.count > 1 { return .formula(String(s.dropFirst())) }
                return .text(s)
            default:
                throw op.fail("cell values must be text, numbers, true/false, null, or a formula string starting with \"=\".")
            }
        }
        func cellRef(_ raw: String) throws -> XLSXFormula.CellRef {
            guard let ref = XLSXFormula.CellRef(raw.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "$", with: "")) else {
                throw op.fail("\"\(raw)\" isn't a cell reference like B3.")
            }
            return ref
        }
        if let dict = op.args["cells"] as? [String: Any] {
            for key in dict.keys.sorted() { assignments.append((try cellRef(key), try value(dict[key]))) }
        } else if let array = op.args["cells"] as? [[String: Any]] {
            for entry in array {
                guard let ref = (entry["ref"] ?? entry["cell"]) as? String else {
                    throw op.fail("each `cells` entry needs a `ref` like \"B3\".")
                }
                assignments.append((try cellRef(ref), try value(entry["value"])))
            }
        } else {
            throw op.fail("`cells` must map cell references to values, e.g. {\"B3\": 42, \"C3\": \"=SUM(B1:B3)\"}.")
        }
        guard !assignments.isEmpty else { throw op.fail("`cells` is empty.") }
        guard assignments.count <= Self.maxCellsPerOperation else {
            throw op.fail("\(assignments.count) cells is over the \(Self.maxCellsPerOperation)-cell limit per operation; split it up.")
        }

        let data = try sheetData(target, op: op)
        for (ref, value) in assignments {
            try setCell(ref, value, in: data, op: op)
        }
        try updateDimension(target)
        package.markDirty(target.part)
        needsRecalc = true
        let formulas = assignments.filter { if case .formula = $0.1 { return true } else { return false } }.count
        summaries.append(
            "Set \(assignments.count) cell\(assignments.count == 1 ? "" : "s") on \"\(target.name)\""
                + (formulas > 0 ? " (\(formulas) formula\(formulas == 1 ? "" : "s"))" : ""))
        if formulas > 0 {
            warnings.append("Formula results are recalculated when the workbook is opened in Excel or Numbers.")
        }
    }

    private func setCell(_ ref: XLSXFormula.CellRef, _ value: CellValue, in data: XMLElement, op: DocumentOperation) throws {
        let row = rowElement(ref.row, in: data, create: true)!
        row.removeAttr("spans")
        let cells = row.childElements("c")
        var cell = cells.first { XLSXFormula.CellRef($0.attr("r") ?? "")?.column == ref.column }
        if cell == nil {
            if case .clear = value { return }
            let created = row.makeChild("c", uri: ns)
            created.setAttr("r", ref.plain)
            if let next = cells.first(where: { (XLSXFormula.CellRef($0.attr("r") ?? "")?.column ?? 0) > ref.column }) {
                created.insertSibling(before: next)
            } else {
                row.addChild(created)
            }
            cell = created
        }
        guard let cell else { return }
        if let f = cell.firstChild("f") {
            let kind = f.attr("t")
            if kind == "array" || (kind == "shared" && f.attr("ref") != nil) {
                throw op.fail("\(ref.plain) holds a \(kind == "array" ? "array" : "shared") formula that other cells depend on; set that whole block of cells explicitly instead.")
            }
        }
        cell.removeAttr("t")
        for child in cell.elementChildren where ["f", "v", "is"].contains(child.local) { child.detach() }
        switch value {
        case .clear:
            if cell.attr("s") == nil { cell.detach() }
        case .formula(let formula):
            let f = cell.makeChild("f", uri: ns)
            f.stringValue = formula
            cell.insertChild(f, at: 0)
        case .text(let text):
            cell.setAttr("t", "inlineStr")
            let isElement = cell.makeChild("is", uri: ns)
            let t = isElement.makeChild("t", uri: ns)
            let text = OOXMLText.stripInvalidXML(text)
            t.stringValue = text
            OOXMLText.applySpacePreserve(t, text)
            isElement.addChild(t)
            cell.addChild(isElement)
        case .number(let number):
            let v = cell.makeChild("v", uri: ns)
            v.stringValue = Self.numberText(number)
            cell.addChild(v)
        case .bool(let flag):
            cell.setAttr("t", "b")
            let v = cell.makeChild("v", uri: ns)
            v.stringValue = flag ? "1" : "0"
            cell.addChild(v)
        }
    }

    static func numberText(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    private func rowElement(_ number: Int, in data: XMLElement, create: Bool) -> XMLElement? {
        let rows = data.childElements("row")
        if let existing = rows.first(where: { Int($0.attr("r") ?? "") == number }) { return existing }
        guard create else { return nil }
        let row = data.makeChild("row", uri: ns)
        row.setAttr("r", String(number))
        if let next = rows.first(where: { (Int($0.attr("r") ?? "") ?? 0) > number }) {
            row.insertSibling(before: next)
        } else {
            data.addChild(row)
        }
        return row
    }

    private func updateDimension(_ sheet: SheetInfo) throws {
        let root = try package.root(sheet.part)
        guard let data = root.firstChild("sheetData") else { return }
        var minRow = Int.max, maxRow = 0, minCol = Int.max, maxCol = 0
        for row in data.childElements("row") {
            for cell in row.childElements("c") {
                guard let ref = XLSXFormula.CellRef(cell.attr("r") ?? "") else { continue }
                minRow = min(minRow, ref.row); maxRow = max(maxRow, ref.row)
                minCol = min(minCol, ref.column); maxCol = max(maxCol, ref.column)
            }
        }
        let text =
            maxRow == 0
            ? "A1"
            : (minRow == maxRow && minCol == maxCol
                ? XLSXFormula.CellRef(column: minCol, row: minRow).plain
                : XLSXFormula.CellRef(column: minCol, row: minRow).plain + ":"
                    + XLSXFormula.CellRef(column: maxCol, row: maxRow).plain)
        if let dimension = root.firstChild("dimension") {
            dimension.setAttr("ref", text)
        }
    }

    // MARK: - insert_rows / delete_rows

    private mutating func shiftRows(_ op: DocumentOperation, inserting: Bool) throws {
        let target = try sheet(op)
        let at = try op.int("at")
        let count = try op.optionalInt("count") ?? 1
        guard at >= 1, at <= 1_048_576 else { throw op.fail("`at` must be a row number from 1.") }
        guard count >= 1, count <= 10_000 else { throw op.fail("`count` must be between 1 and 10000.") }
        let shift = XLSXFormula.RowShift(at: at, delta: inserting ? count : -count)
        let data = try sheetData(target, op: op)
        let sheetRels = try package.relationships(of: target.part)

        // Refusals first, so a failed operation leaves the workbook untouched.
        for f in data.descendants("f") where f.attr("t") == "array" {
            guard let ref = f.attr("ref"), let (r1, r2) = Self.rowSpan(ref), Self.straddles(r1, r2, shift) else { continue }
            throw op.fail(
                "rows \(r1)–\(r2) hold an array formula (\(ref)); Excel doesn't allow inserting or deleting rows inside one. Rewrite that block instead.")
        }
        if !inserting {
            for row in data.childElements("row") {
                guard let r = Int(row.attr("r") ?? ""), shift.map(r) == nil else { continue }
                for f in row.descendants("f") where f.attr("t") == "array" {
                    guard let range = f.attr("ref"), let (r1, r2) = Self.rowSpan(range), shift.map(r1) != nil || shift.map(r2) != nil
                    else { continue }
                    throw op.fail("row \(r) holds an array formula that also fills rows you're keeping; delete or rewrite that whole block instead.")
                }
            }
        } else if let maxRow = data.childElements("row").compactMap({ Int($0.attr("r") ?? "") }).max(),
            maxRow >= at, maxRow + count > 1_048_576
        {
            throw op.fail("inserting would push rows past Excel's last row.")
        }
        let tableParts = Self.related(sheetRels, from: target.part, suffix: "/table")
        for part in tableParts {
            let table = try package.root(part)
            guard let ref = table.attr("ref"), let (r1, r2) = Self.rowSpan(ref) else { continue }
            let name = table.attr("displayName") ?? table.attr("name") ?? "table"
            let headerRows = Int(table.attr("headerRowCount") ?? "1") ?? 1
            let totalsRows = Int(table.attr("totalsRowCount") ?? "0") ?? 0
            if !inserting, headerRows > 0, shift.map(r1) == nil {
                throw op.fail("deleting row \(r1) would remove the header row of table \"\(name)\"; delete the table in Excel first.")
            }
            if !inserting, totalsRows > 0, shift.map(r2) == nil {
                throw op.fail("deleting row \(r2) would remove the totals row of table \"\(name)\".")
            }
            guard let shifted = XLSXFormula.shift(ref: ref, by: shift), let (n1, n2) = Self.rowSpan(shifted),
                n2 - n1 + 1 - headerRows - totalsRows >= 1
            else {
                throw op.fail("table \"\(name)\" would be left with no data rows; delete the table in Excel first.")
            }
        }
        for part in Self.related(sheetRels, from: target.part, suffix: "/pivotTable") {
            let pivot = try package.root(part)
            guard let location = pivot.firstChild("location"), let ref = location.attr("ref"), let (r1, r2) = Self.rowSpan(ref)
            else { continue }
            let overlaps = inserting ? (r1 < at && r2 >= at) : (r1 <= at + count - 1 && r2 >= at)
            if overlaps {
                throw op.fail(
                    "rows \(r1)–\(r2) are a pivot table (\(pivot.attr("name") ?? "PivotTable")); Excel doesn't allow inserting or deleting rows inside one. Move it in Excel first.")
            }
        }
        var pivotSources: [(part: String, element: XMLElement, ref: String)] = []
        for rel in try package.relationships(of: workbookPart) where rel.type.hasSuffix("/pivotCacheDefinition") {
            let part = OOXMLPackage.resolve(rel.target, from: workbookPart)
            guard package.has(part) else { continue }
            let definition = try package.root(part)
            for source in definition.descendants("worksheetSource") {
                guard source.attr("sheet")?.caseInsensitiveCompare(target.name) == .orderedSame, let ref = source.attr("ref")
                else { continue }
                guard XLSXFormula.shift(ref: ref, by: shift) != nil else {
                    throw op.fail("deleting rows \(at)–\(at + count - 1) would remove every row a pivot table reads (\(ref)); refresh or delete the pivot table in Excel first.")
                }
                pivotSources.append((part, source, ref))
            }
        }

        // Shared formulas that partly sit on the moving side can't stay
        // shared (their dependents derive from the master by fixed
        // offsets), so they become explicit per-cell formulas first.
        let expanded = expandSharedFormulas(straddling: shift, in: data)

        var removed = 0
        for row in data.childElements("row") {
            guard let r = Int(row.attr("r") ?? "") else { continue }
            guard let newRow = shift.map(r) else {
                row.detach()
                removed += 1
                continue
            }
            if newRow != r { row.setAttr("r", String(newRow)) }
            for cell in row.childElements("c") {
                if var ref = XLSXFormula.CellRef(cell.attr("r") ?? "") {
                    ref.row = newRow
                    cell.setAttr("r", ref.plain)
                }
            }
        }

        var adjustedFormulas = 0
        func shiftFormulaText(_ element: XMLElement, on sheetName: String?) -> Bool {
            guard let text = element.stringValue, !text.isEmpty else { return false }
            let shifted = XLSXFormula.shift(text, formulaSheet: sheetName, targetSheet: target.name, by: shift)
            guard shifted != text else { return false }
            element.stringValue = shifted
            adjustedFormulas += 1
            return true
        }
        for info in try sheets() {
            let root = try package.root(info.part)
            var changed = info.part == target.part
            // Cell formulas, conditional-formatting `formula` (incl. x14
            // `xm:f`) and data-validation `formula1`/`formula2`.
            for f in root.descendants("f") {
                if shiftFormulaText(f, on: info.name) { changed = true }
                if info.part == target.part, let ref = f.attr("ref") {
                    if let shifted = XLSXFormula.shift(ref: ref, by: shift) { f.setAttr("ref", shifted) }
                }
            }
            for element in root.descendants("formula") + root.descendants("formula1") + root.descendants("formula2") {
                if shiftFormulaText(element, on: info.name) { changed = true }
            }
            // Chart series ranges live in chart parts hanging off the
            // sheet's drawing; they are always sheet-qualified.
            for chart in try chartParts(of: info.part) {
                var chartChanged = false
                for f in try package.root(chart).descendants("f") where shiftFormulaText(f, on: nil) { chartChanged = true }
                if chartChanged { package.markDirty(chart) }
            }
            if changed { package.markDirty(info.part) }
        }

        let root = try package.root(target.part)
        for merge in root.descendants("mergeCell") {
            guard let ref = merge.attr("ref") else { continue }
            if let shifted = XLSXFormula.shift(ref: ref, by: shift) { merge.setAttr("ref", shifted) } else { merge.detach() }
        }
        if let merges = root.firstChild("mergeCells") {
            let n = merges.childElements("mergeCell").count
            if n == 0 { merges.detach() } else { merges.setAttr("count", String(n)) }
        }
        for element in root.descendants("hyperlink") + root.descendants("autoFilter") {
            guard let ref = element.attr("ref") else { continue }
            if let shifted = XLSXFormula.shift(ref: ref, by: shift) { element.setAttr("ref", shifted) } else { element.detach() }
        }
        for element in root.descendants("conditionalFormatting") + root.descendants("dataValidation") {
            guard let sqref = element.attr("sqref") else { continue }
            let kept = sqref.split(separator: " ").compactMap { XLSXFormula.shift(ref: String($0), by: shift) }
            if kept.isEmpty { element.detach() } else { element.setAttr("sqref", kept.joined(separator: " ")) }
        }
        // x14 extensions carry the range as element text (`xm:sqref`).
        for element in root.descendants("sqref") {
            guard let text = element.stringValue, !text.isEmpty else { continue }
            let kept = text.split(separator: " ").compactMap { XLSXFormula.shift(ref: String($0), by: shift) }
            if kept.isEmpty {
                // Drop the whole x14 rule/validation that owned it.
                var owner: XMLElement? = element
                while let candidate = owner, !["conditionalFormatting", "dataValidation"].contains(candidate.local) {
                    owner = candidate.parent as? XMLElement
                }
                (owner ?? element).detach()
            } else {
                element.stringValue = kept.joined(separator: " ")
            }
        }
        for validations in root.childElements("dataValidations") {
            let n = validations.childElements("dataValidation").count
            if n == 0 { validations.detach() } else { validations.setAttr("count", String(n)) }
        }
        try updateDimension(target)
        package.markDirty(target.part)

        for part in tableParts {
            let table = try package.root(part)
            if let ref = table.attr("ref"), let shifted = XLSXFormula.shift(ref: ref, by: shift) { table.setAttr("ref", shifted) }
            for filter in table.descendants("autoFilter") {
                if let ref = filter.attr("ref"), let shifted = XLSXFormula.shift(ref: ref, by: shift) { filter.setAttr("ref", shifted) }
            }
            for element in table.descendants("calculatedColumnFormula") + table.descendants("totalsRowFormula") {
                _ = shiftFormulaText(element, on: target.name)
            }
            package.markDirty(part)
        }
        for part in Self.related(sheetRels, from: target.part, suffix: "/pivotTable") {
            let pivot = try package.root(part)
            if let location = pivot.firstChild("location"), let ref = location.attr("ref"),
                let shifted = XLSXFormula.shift(ref: ref, by: shift)
            {
                location.setAttr("ref", shifted)
                package.markDirty(part)
            }
        }
        for source in pivotSources {
            if let shifted = XLSXFormula.shift(ref: source.ref, by: shift) { source.element.setAttr("ref", shifted) }
            try package.root(source.part).setAttr("refreshOnLoad", "1")
            package.markDirty(source.part)
        }
        try shiftAnnotations(sheetRels, from: target.part, by: shift)

        let workbook = try package.root(workbookPart)
        for name in workbook.descendants("definedName") {
            guard let text = name.stringValue else { continue }
            let shifted = XLSXFormula.shift(text, formulaSheet: nil, targetSheet: target.name, by: shift)
            if shifted != text { name.stringValue = shifted; package.markDirty(workbookPart) }
        }

        needsRecalc = true
        let rows = count == 1 ? "row" : "rows"
        summaries.append(
            inserting
                ? "Inserted \(count) \(rows) at row \(at) on \"\(target.name)\""
                : "Deleted \(count) \(rows) from row \(at) on \"\(target.name)\"" + (removed == 0 ? " (they were empty)" : ""))
        if adjustedFormulas > 0 {
            summaries.append("Adjusted references in \(adjustedFormulas) formula\(adjustedFormulas == 1 ? "" : "s")")
        }
        if expanded > 0 {
            summaries.append("Expanded \(expanded) shared formula cell\(expanded == 1 ? "" : "s") into explicit formulas")
        }
        if !pivotSources.isEmpty {
            warnings.append("Pivot tables reading \"\(target.name)\" refresh when the workbook is opened.")
        }
    }

    /// Whether the row range partly (not wholly) sits on the moving side
    /// of an insert/delete — the case where fixed-offset structures
    /// (shared/array formulas, pivot tables) can't simply be shifted.
    static func straddles(_ r1: Int, _ r2: Int, _ shift: XLSXFormula.RowShift) -> Bool {
        if shift.delta > 0 { return r1 < shift.at && r2 >= shift.at }
        let lo = shift.at, hi = shift.at - shift.delta - 1
        let overlaps = r1 <= hi && r2 >= lo
        let fullyRemoved = r1 >= lo && r2 <= hi
        return overlaps && !fullyRemoved
    }

    static func rowSpan(_ ref: String) -> (Int, Int)? {
        let parts = ref.split(separator: ":", maxSplits: 1).compactMap { XLSXFormula.CellRef(String($0)) }
        guard let first = parts.first else { return nil }
        let last = parts.count == 2 ? parts[1] : first
        return (min(first.row, last.row), max(first.row, last.row))
    }

    private static func related(_ rels: [OOXMLPackage.Relationship], from part: String, suffix: String) -> [String] {
        rels.filter { !$0.external && $0.type.hasSuffix(suffix) }.map { OOXMLPackage.resolve($0.target, from: part) }
    }

    /// Chart parts reachable from a worksheet through its drawing(s).
    private func chartParts(of sheetPart: String) throws -> [String] {
        var out: [String] = []
        for drawing in Self.related(try package.relationships(of: sheetPart), from: sheetPart, suffix: "/drawing")
        where package.has(drawing) {
            for chart in Self.related(try package.relationships(of: drawing), from: drawing, suffix: "/chart") where package.has(chart) {
                out.append(chart)
            }
        }
        return out
    }

    /// Turn every shared-formula block whose `ref` straddles the shift
    /// into explicit per-cell formulas. Returns the number of cells
    /// rewritten. Blocks entirely on one side keep sharing: all of their
    /// cells move together, so the master-relative offsets stay valid.
    private func expandSharedFormulas(straddling shift: XLSXFormula.RowShift, in data: XMLElement) -> Int {
        struct Block {
            var master: (cell: XLSXFormula.CellRef, f: XMLElement)?
            var members: [(cell: XLSXFormula.CellRef, f: XMLElement)] = []
        }
        var blocks: [String: Block] = [:]
        for row in data.childElements("row") {
            for cell in row.childElements("c") {
                guard let f = cell.firstChild("f"), f.attr("t") == "shared", let si = f.attr("si"),
                    let ref = XLSXFormula.CellRef(cell.attr("r") ?? "")
                else { continue }
                if f.attr("ref") != nil, let text = f.stringValue, !text.isEmpty {
                    blocks[si, default: Block()].master = (ref, f)
                }
                blocks[si, default: Block()].members.append((ref, f))
            }
        }
        var expanded = 0
        for si in blocks.keys.sorted() {
            let block = blocks[si]!
            guard let master = block.master, let text = master.f.stringValue else { continue }
            let rows = block.members.map(\.cell.row)
            var (r1, r2) = (rows.min() ?? master.cell.row, rows.max() ?? master.cell.row)
            if let ref = master.f.attr("ref"), let span = Self.rowSpan(ref) {
                r1 = min(r1, span.0)
                r2 = max(r2, span.1)
            }
            guard Self.straddles(r1, r2, shift) else { continue }
            for member in block.members {
                member.f.stringValue = XLSXFormula.translate(
                    text, rows: member.cell.row - master.cell.row, columns: member.cell.column - master.cell.column)
                member.f.removeAttr("t")
                member.f.removeAttr("si")
                member.f.removeAttr("ref")
                expanded += 1
            }
        }
        return expanded
    }

    /// Comments (legacy + threaded), their VML anchors, and drawing
    /// anchors follow the rows they were attached to.
    private func shiftAnnotations(_ rels: [OOXMLPackage.Relationship], from sheetPart: String, by shift: XLSXFormula.RowShift) throws {
        for part in Self.related(rels, from: sheetPart, suffix: "/comments") + Self.related(rels, from: sheetPart, suffix: "/threadedComment")
        where package.has(part) {
            let root = try package.root(part)
            for comment in root.descendants("comment") + root.descendants("threadedComment") {
                guard let ref = comment.attr("ref") else { continue }
                if let shifted = XLSXFormula.shift(ref: ref, by: shift) { comment.setAttr("ref", shifted) } else { comment.detach() }
            }
            package.markDirty(part)
        }
        // Zero-based anchor rows: a row that disappears snaps to the
        // first row after the deleted block.
        func mapAnchorRow(_ zeroBased: Int) -> Int {
            (shift.map(zeroBased + 1) ?? shift.at) - 1
        }
        for part in Self.related(rels, from: sheetPart, suffix: "/vmlDrawing") where package.has(part) {
            guard let root = try? package.root(part) else { continue }  // VML isn't always well-formed; leave it alone.
            for row in root.descendants("Row") {
                guard let value = Int((row.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                if shift.map(value + 1) == nil {
                    // Its comment was deleted with the row.
                    var shape: XMLElement? = row
                    while let candidate = shape, candidate.local != "shape" { shape = candidate.parent as? XMLElement }
                    (shape ?? row).detach()
                } else {
                    row.stringValue = String(mapAnchorRow(value))
                }
            }
            for anchor in root.descendants("Anchor") {
                var numbers = (anchor.stringValue ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard numbers.count == 8 else { continue }
                numbers[2] = mapAnchorRow(numbers[2])
                numbers[6] = max(mapAnchorRow(numbers[6]), numbers[2])
                anchor.stringValue = numbers.map(String.init).joined(separator: ", ")
            }
            package.markDirty(part)
        }
        for part in Self.related(rels, from: sheetPart, suffix: "/drawing") where package.has(part) {
            let root = try package.root(part)
            for marker in root.descendants("from") + root.descendants("to") {
                guard let row = marker.firstChild("row"), let value = Int(row.stringValue ?? "") else { continue }
                row.stringValue = String(mapAnchorRow(value))
            }
            package.markDirty(part)
        }
    }

    // MARK: - Sheet operations

    private func validateSheetName(_ name: String, op: DocumentOperation, excluding: String? = nil) throws {
        guard !name.isEmpty, name.count <= 31 else { throw op.fail("sheet names must be 1–31 characters.") }
        guard name.rangeOfCharacter(from: CharacterSet(charactersIn: ":\\/?*[]")) == nil,
            !name.hasPrefix("'"), !name.hasSuffix("'")
        else { throw op.fail("sheet names can't contain : \\ / ? * [ ] or start/end with an apostrophe.") }
        guard name.caseInsensitiveCompare("History") != .orderedSame else {
            throw op.fail("\"History\" is reserved by Excel.")
        }
        let taken = try sheets().map(\.name).filter { $0 != excluding }
        if taken.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw op.fail("a sheet named \"\(name)\" already exists.")
        }
    }

    private mutating func addSheet(_ op: DocumentOperation) throws {
        let name = try op.string("name").trimmingCharacters(in: .whitespaces)
        try validateSheetName(name, op: op)
        let existing = try sheets()
        var n = existing.count + 1
        while package.has("xl/worksheets/sheet\(n).xml") { n += 1 }
        let part = "xl/worksheets/sheet\(n).xml"
        package.setXML(
            part,
            try OOXMLPackage.newXML(
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                    + "<worksheet xmlns=\"\(ns)\" xmlns:r=\"\(OOXMLNamespace.officeRelationships)\">"
                    + "<dimension ref=\"A1\"/><sheetData/></worksheet>"))
        try package.addOverride(part, contentType: Self.worksheetContentType)
        let rid = try package.addRelationship(from: workbookPart, type: OOXMLRelationshipType.worksheet, to: part)

        let list = try package.root(workbookPart).firstChild("sheets")!
        let maxId = list.childElements("sheet").compactMap { Int($0.attr("sheetId") ?? "") }.max() ?? 0
        let element = list.makeChild("sheet", uri: ns)
        element.setAttr("name", name)
        element.setAttr("sheetId", String(maxId + 1))
        if let after = try op.optionalString("after"), !after.isEmpty,
            let anchor = existing.first(where: { $0.name.caseInsensitiveCompare(after) == .orderedSame })
        {
            element.insertSibling(after: anchor.element)
        } else {
            list.addChild(element)
        }
        element.setRelationshipId(rid)
        package.markDirty(workbookPart)
        needsRecalc = true
        summaries.append("Added sheet \"\(name)\"")
    }

    private mutating func renameSheet(_ op: DocumentOperation) throws {
        let target = try sheet(op, required: true)
        let newName = try op.string("name").trimmingCharacters(in: .whitespaces)
        guard newName != target.name else { throw op.fail("the sheet is already named \"\(newName)\".") }
        try validateSheetName(newName, op: op, excluding: target.name)
        target.element.setAttr("name", newName)
        var updated = 0
        var charts = 0
        for info in try sheets() {
            let root = try package.root(info.part)
            var changed = false
            for f in root.descendants("f") + root.descendants("formula") + root.descendants("formula1") + root.descendants("formula2") {
                guard let text = f.stringValue, !text.isEmpty else { continue }
                let renamed = XLSXFormula.renameSheet(text, from: target.name, to: newName)
                if renamed != text { f.stringValue = renamed; changed = true; updated += 1 }
            }
            if changed { package.markDirty(info.part) }
            for chart in try chartParts(of: info.part) {
                var chartChanged = false
                for f in try package.root(chart).descendants("f") {
                    guard let text = f.stringValue, !text.isEmpty else { continue }
                    let renamed = XLSXFormula.renameSheet(text, from: target.name, to: newName)
                    if renamed != text { f.stringValue = renamed; chartChanged = true; charts += 1 }
                }
                if chartChanged { package.markDirty(chart) }
            }
        }
        for rel in try package.relationships(of: workbookPart) where rel.type.hasSuffix("/pivotCacheDefinition") {
            let part = OOXMLPackage.resolve(rel.target, from: workbookPart)
            guard package.has(part) else { continue }
            var changed = false
            for source in try package.root(part).descendants("worksheetSource")
            where source.attr("sheet")?.caseInsensitiveCompare(target.name) == .orderedSame {
                source.setAttr("sheet", newName)
                changed = true
            }
            if changed { package.markDirty(part) }
        }
        for name in try package.root(workbookPart).descendants("definedName") {
            guard let text = name.stringValue else { continue }
            let renamed = XLSXFormula.renameSheet(text, from: target.name, to: newName)
            if renamed != text { name.stringValue = renamed }
        }
        package.markDirty(workbookPart)
        needsRecalc = true
        summaries.append(
            "Renamed sheet \"\(target.name)\" to \"\(newName)\""
                + (updated > 0 ? " (updated \(updated) formula\(updated == 1 ? "" : "s"))" : "")
                + (charts > 0 ? " (updated \(charts) chart range\(charts == 1 ? "" : "s"))" : ""))
    }

    private mutating func deleteSheet(_ op: DocumentOperation) throws {
        let all = try sheets()
        let target = try sheet(op, required: true)
        guard all.count > 1 else { throw op.fail("a workbook needs at least one sheet.") }
        let visibleOthers = all.filter { $0.part != target.part && ($0.element.attr("state") ?? "visible") == "visible" }
        guard !visibleOthers.isEmpty else { throw op.fail("this is the only visible sheet; a workbook needs one.") }
        let index = all.firstIndex { $0.part == target.part }!

        var dangling = 0
        var danglingCharts = 0
        for info in all where info.part != target.part {
            for f in try package.root(info.part).descendants("f") where XLSXFormula.references(f.stringValue ?? "", sheet: target.name) {
                dangling += 1
            }
            for chart in try chartParts(of: info.part) {
                for f in try package.root(chart).descendants("f") where XLSXFormula.references(f.stringValue ?? "", sheet: target.name) {
                    danglingCharts += 1
                }
            }
        }
        target.element.detach()
        try package.removeRelationship(from: workbookPart, id: target.relationshipId)
        try package.removePart(target.part)

        let workbook = try package.root(workbookPart)
        for name in workbook.descendants("definedName") {
            guard let local = Int(name.attr("localSheetId") ?? "") else { continue }
            if local == index { name.detach() } else if local > index { name.setAttr("localSheetId", String(local - 1)) }
        }
        if let names = workbook.firstChild("definedNames"), names.childElements("definedName").isEmpty { names.detach() }
        for view in workbook.descendants("workbookView") {
            for key in ["activeTab", "firstSheet"] {
                if let value = Int(view.attr(key) ?? ""), value >= all.count - 1 { view.setAttr(key, "0") }
            }
        }
        package.markDirty(workbookPart)
        needsRecalc = true
        summaries.append("Deleted sheet \"\(target.name)\"")
        if dangling > 0 {
            warnings.append("\(dangling) formula\(dangling == 1 ? "" : "s") on other sheets referred to \"\(target.name)\" and will show #REF! until fixed.")
        }
        if danglingCharts > 0 {
            warnings.append("\(danglingCharts) chart series on other sheets plotted data from \"\(target.name)\" and will be empty until repointed.")
        }
    }
}
