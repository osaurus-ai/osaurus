//
//  XLSXFormula.swift
//  osaurus
//
//  A1-reference rewriting for spreadsheet formulas: shifting row numbers
//  when rows are inserted/deleted, and renaming sheet prefixes. A small
//  scanner (not a regex) so string literals, function names that look
//  like references (`LOG10(`), and quoted sheet names are handled.
//

import Foundation

enum XLSXFormula {
    struct CellRef: Equatable {
        var column: Int
        var row: Int
        var absoluteColumn = false
        var absoluteRow = false

        init(column: Int, row: Int, absoluteColumn: Bool = false, absoluteRow: Bool = false) {
            self.column = column
            self.row = row
            self.absoluteColumn = absoluteColumn
            self.absoluteRow = absoluteRow
        }

        init?(_ text: String) {
            var chars = Substring(text)
            absoluteColumn = chars.first == "$"
            if absoluteColumn { chars = chars.dropFirst() }
            let letters = chars.prefix { $0.isASCII && $0.isUppercase }
            guard (1...3).contains(letters.count) else { return nil }
            chars = chars.dropFirst(letters.count)
            absoluteRow = chars.first == "$"
            if absoluteRow { chars = chars.dropFirst() }
            guard !chars.isEmpty, chars.allSatisfy({ $0.isASCII && $0.isNumber }), let row = Int(chars), row >= 1,
                row <= 1_048_576
            else { return nil }
            var column = 0
            for scalar in letters.unicodeScalars { column = column * 26 + Int(scalar.value) - 64 }
            guard column <= 16_384 else { return nil }
            self.column = column
            self.row = row
        }

        var text: String {
            (absoluteColumn ? "$" : "") + Self.columnName(column) + (absoluteRow ? "$" : "") + String(row)
        }

        var plain: String { Self.columnName(column) + String(row) }

        static func columnName(_ column: Int) -> String {
            var n = column
            var name = ""
            while n > 0 {
                let rem = (n - 1) % 26
                name = String(UnicodeScalar(UInt8(65 + rem))) + name
                n = (n - 1) / 26
            }
            return name
        }
    }

    /// Visit every A1 reference (`A1`, `$B$2`, `A1:C9`, `Sheet!A1`,
    /// `'My Sheet'!A1:B2`). `visit` gets the sheet name (nil when
    /// unqualified), the original prefix text (`Sheet!` / `'My Sheet'!` /
    /// ""), and the reference text; it returns the replacement for the
    /// whole match.
    static func scan(_ formula: String, visit: (_ sheet: String?, _ prefix: String, _ ref: String) -> String) -> String {
        let chars = Array(formula)
        let n = chars.count
        var out = ""
        var i = 0

        func isIdentChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "." || c == "$"
        }

        func readCell(_ start: Int) -> Int? {
            var j = start
            if j < n, chars[j] == "$" { j += 1 }
            let letterStart = j
            while j < n, chars[j].isASCII, chars[j].isUppercase { j += 1 }
            guard (1...3).contains(j - letterStart) else { return nil }
            if j < n, chars[j] == "$" { j += 1 }
            let digitStart = j
            while j < n, chars[j].isASCII, chars[j].isNumber { j += 1 }
            guard j > digitStart else { return nil }
            if j < n, isIdentChar(chars[j]) || chars[j] == "(" { return nil }
            return j
        }

        /// A cell or range starting at `start`; returns its end index.
        func readRef(_ start: Int) -> Int? {
            guard let end = readCell(start) else { return nil }
            if end < n, chars[end] == ":", let end2 = readCell(end + 1) { return end2 }
            return end
        }

        while i < n {
            let c = chars[i]
            if c == "\"" {
                var j = i + 1
                while j < n {
                    if chars[j] == "\"" {
                        if j + 1 < n, chars[j + 1] == "\"" { j += 2; continue }
                        break
                    }
                    j += 1
                }
                let stop = min(j, n - 1)
                out += String(chars[i...stop])
                i = stop + 1
                continue
            }
            if c == "'" {
                var j = i + 1
                while j < n {
                    if chars[j] == "'" {
                        if j + 1 < n, chars[j + 1] == "'" { j += 2; continue }
                        break
                    }
                    j += 1
                }
                if j + 1 < n, chars[j + 1] == "!", let end = readRef(j + 2) {
                    let sheet = String(chars[(i + 1)..<j]).replacingOccurrences(of: "''", with: "'")
                    out += visit(sheet, String(chars[i...(j + 1)]), String(chars[(j + 2)..<end]))
                    i = end
                    continue
                }
                let stop = min(j, n - 1)
                out += String(chars[i...stop])
                i = stop + 1
                continue
            }
            let afterIdent = i > 0 && isIdentChar(chars[i - 1])
            if !afterIdent, c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < n, isIdentChar(chars[j]) { j += 1 }
                if j < n, chars[j] == "!", let end = readRef(j + 1) {
                    let sheet = String(chars[i..<j])
                    out += visit(sheet, String(chars[i...j]), String(chars[(j + 1)..<end]))
                    i = end
                    continue
                }
                if let end = readRef(i) {
                    out += visit(nil, "", String(chars[i..<end]))
                    i = end
                    continue
                }
                out += String(chars[i..<j])
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Row remapping for an insert (`delta > 0`) or delete (`delta < 0`)
    /// of `abs(delta)` rows at `at`.
    struct RowShift {
        let at: Int
        let delta: Int

        func map(_ row: Int) -> Int? {
            if row < at { return row }
            if delta >= 0 { return row + delta }
            let count = -delta
            if row < at + count { return nil }
            return row - count
        }

        /// Range endpoints; a range losing some rows shrinks, one losing
        /// all of them disappears.
        func map(_ r1: Int, _ r2: Int) -> (Int, Int)? {
            if delta >= 0 { return (map(r1)!, map(r2)!) }
            let lo = map(r1) ?? at
            let hi = map(r2) ?? (at - 1)
            return hi >= lo ? (lo, hi) : nil
        }
    }

    static func shift(ref: String, by shift: RowShift) -> String? {
        let parts = ref.split(separator: ":", maxSplits: 1).map(String.init)
        guard var a = CellRef(parts[0]) else { return ref }
        if parts.count == 2, var b = CellRef(parts[1]) {
            guard let (r1, r2) = shift.map(a.row, b.row) else { return nil }
            a.row = r1
            b.row = r2
            return a.text + ":" + b.text
        }
        guard let row = shift.map(a.row) else { return nil }
        a.row = row
        return a.text
    }

    /// Shift references to `targetSheet` inside a formula that lives on
    /// `formulaSheet` (nil for workbook-level defined names).
    static func shift(_ formula: String, formulaSheet: String?, targetSheet: String, by rowShift: RowShift) -> String {
        scan(formula) { sheet, prefix, ref in
            let applies =
                sheet.map { $0.caseInsensitiveCompare(targetSheet) == .orderedSame }
                ?? (formulaSheet?.caseInsensitiveCompare(targetSheet) == .orderedSame)
            guard applies else { return prefix + ref }
            guard let shifted = shift(ref: ref, by: rowShift) else { return prefix + "#REF!" }
            return prefix + shifted
        }
    }

    /// Move every *relative* reference by `(rows, columns)` — how a shared
    /// formula's dependent cells derive their own formula from the master
    /// cell. Absolute parts (`$A`, `$1`) stay put; anything pushed off the
    /// sheet becomes `#REF!`.
    static func translate(_ formula: String, rows: Int, columns: Int) -> String {
        guard rows != 0 || columns != 0 else { return formula }
        func move(_ text: String) -> String? {
            guard var ref = CellRef(text) else { return text }
            if !ref.absoluteRow { ref.row += rows }
            if !ref.absoluteColumn { ref.column += columns }
            guard ref.row >= 1, ref.row <= 1_048_576, ref.column >= 1, ref.column <= 16_384 else { return nil }
            return ref.text
        }
        return scan(formula) { _, prefix, ref in
            let parts = ref.split(separator: ":", maxSplits: 1).map(String.init)
            let moved = parts.map(move)
            guard moved.allSatisfy({ $0 != nil }) else { return prefix + "#REF!" }
            return prefix + moved.compactMap { $0 }.joined(separator: ":")
        }
    }

    static func renameSheet(_ formula: String, from old: String, to new: String) -> String {
        scan(formula) { sheet, prefix, ref in
            guard let sheet, sheet.caseInsensitiveCompare(old) == .orderedSame else { return prefix + ref }
            return quotedSheetName(new) + "!" + ref
        }
    }

    static func references(_ formula: String, sheet target: String) -> Bool {
        var found = false
        _ = scan(formula) { sheet, prefix, ref in
            if sheet?.caseInsensitiveCompare(target) == .orderedSame { found = true }
            return prefix + ref
        }
        return found
    }

    static func quotedSheetName(_ name: String) -> String {
        let simple =
            name.first.map { $0.isLetter || $0 == "_" } == true
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
            && CellRef(name.uppercased()) == nil
        return simple ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
