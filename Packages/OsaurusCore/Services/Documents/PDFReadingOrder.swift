//
//  PDFReadingOrder.swift
//  osaurus
//
//  Rebuilds a PDF page's text in visual reading order from glyph geometry
//  when the content-stream order PDFKit exposes diverges from the layout.
//  Flattened forms (tax returns, invoices, applications) commonly draw
//  every label first and every value afterwards, so `page.string` hands a
//  model one run of labels and, thirty lines later, a bare column of
//  numbers. Rows rebuilt from geometry put each value back beside its
//  label.
//
//  The pipeline is deterministic and gated: a page is only re-ordered when
//  its stream order provably jumps back up the page several times AND the
//  geometry covers (almost) every character, so prose and two-column pages
//  keep PDFKit's text byte-for-byte. Glyph `characterIndex` values are
//  remapped into the rebuilt text so table detection and anchors stay
//  consistent with whichever text the page ends up carrying.
//

import CoreGraphics
import Foundation

struct PDFReadingOrder {
    typealias Glyph = PDFTableDetector.Glyph

    /// Which text a page carries after resolution.
    enum Order: String, Sendable {
        /// PDFKit's content-stream order (`page.string`), untouched.
        case stream
        /// Rows rebuilt from glyph geometry, top-down then left-to-right.
        case layout
    }

    /// How far stream order departs from top-down order.
    struct Divergence: Equatable {
        /// Consecutive glyph pairs that change visual row.
        let rowTransitions: Int
        /// Row changes that move *up* the page (stream went back up).
        let upwardJumps: Int

        var ratio: Double {
            rowTransitions > 0 ? Double(upwardJumps) / Double(rowTransitions) : 0
        }
    }

    struct Result {
        let text: String
        /// Glyphs valid against `text`. Stream pages return the input
        /// unchanged; layout pages return visible glyphs with remapped
        /// `characterIndex` values (whitespace and hidden glyphs dropped).
        let glyphs: [Glyph]
        let order: Order
        /// Share of the page's non-whitespace UTF-16 units that have a
        /// geometry glyph (1.0 = every character located).
        let coverage: Double
        /// Non-whitespace glyphs drawn entirely outside the crop box or
        /// below `minimumVisibleSize` in both dimensions. Reported so the
        /// adapter can flag hidden text; stream pages never strip them.
        let hiddenGlyphCount: Int
        let divergence: Divergence
    }

    // MARK: - Gate

    /// A page needs at least this many upward jumps ...
    static let minimumUpwardJumps = 3
    /// ... that make up at least this share of its row transitions ...
    static let minimumDivergenceRatio = 0.05
    /// ... and this share of its characters located before it is rebuilt.
    static let minimumCoverage = 0.9
    /// Glyphs taller than this multiple of the page's median glyph height
    /// are display text (watermarks, banners); runs of them are isolated.
    /// PDFKit reports *line* heights for glyphs, and a form title merged
    /// with its small-print neighbour inflates both to ~3x body height, so
    /// the bar sits well above that (a 45° "DRAFT" watermark is ~20x).
    static let displayHeightMultiplier: CGFloat = 6
    /// Two glyphs share a visual row only when the smaller height is at
    /// least this share of the larger: a 20pt year must not swallow the
    /// 6pt small print that happens to sit within its vertical span.
    static let rowHeightSimilarity: CGFloat = 0.5
    /// How many recent rows a glyph may join; rows are visited top-down so
    /// candidates are always the nearest bands.
    static let rowLookback = 6
    /// A glyph smaller than this in both dimensions cannot be seen.
    static let minimumVisibleSize: CGFloat = 1

    // MARK: - Resolve

    static func resolve(
        pageText: String,
        glyphs: [Glyph],
        rotation: Int,
        cropBox: CGRect
    ) throws -> Result {
        try Task.checkCancellation()
        let nsText = pageText as NSString
        let located = glyphs.filter { !$0.text.isPDFWhitespace && $0.bounds.isUsable }
        let hidden = located.filter { isHidden($0.bounds, cropBox: cropBox) }
        let visible = located.filter { !isHidden($0.bounds, cropBox: cropBox) }

        let expectedUnits = nonWhitespaceUTF16Count(of: pageText)
        let locatedUnits = located.reduce(0) { $0 + $1.text.utf16.count }
        let coverage = expectedUnits > 0 ? min(1, Double(locatedUnits) / Double(expectedUnits)) : 1

        let frames = visible.map { readingRect($0.bounds, rotation: rotation) }
        let medianHeight = median(frames.map(\.height))
        let medianWidth = median(frames.map(\.width))
        try Task.checkCancellation()
        let divergence = divergence(frames: frames, medianHeight: medianHeight)

        func stream() -> Result {
            Result(
                text: pageText,
                glyphs: glyphs,
                order: .stream,
                coverage: coverage,
                hiddenGlyphCount: hidden.count,
                divergence: divergence
            )
        }

        guard shouldReorder(divergence: divergence, coverage: coverage), !visible.isEmpty else {
            return stream()
        }

        try Task.checkCancellation()
        let placed = zip(visible, frames).map { Placed(glyph: $0, frame: $1) }
        let (runs, rowCandidates) = splitRuns(placed, medianHeight: medianHeight)
        try Task.checkCancellation()
        var lines = rows(from: rowCandidates).map { row in
            Line(sortKey: row.band.midY, kind: .row(row.glyphs))
        }
        for run in runs {
            let topY = run.map(\.frame.midY).max() ?? 0
            lines.append(Line(sortKey: topY, kind: .run(run)))
        }
        lines.sort { $0.sortKey > $1.sortKey }
        try Task.checkCancellation()

        let wideGap = max(8, medianWidth * 2.2)
        let wordGap = max(0.5, medianWidth * 0.25)
        var output = ""
        var outputUTF16 = 0
        var remapped: [Glyph] = []
        remapped.reserveCapacity(visible.count)

        func append(_ string: String) {
            output += string
            outputUTF16 += string.utf16.count
        }
        func emit(_ item: Placed) {
            remapped.append(
                Glyph(
                    pageIndex: item.glyph.pageIndex,
                    characterIndex: outputUTF16,
                    text: item.glyph.text,
                    bounds: item.glyph.bounds
                )
            )
            append(item.glyph.text)
        }

        for (lineIndex, line) in lines.enumerated() {
            try Task.checkCancellation()
            if lineIndex > 0 { append("\n") }
            switch line.kind {
            case .run(let run):
                // Watermark / rotated text: keep the author's letter order.
                for item in run { emit(item) }
            case .row(let members):
                var previous: Placed?
                for segment in segments(in: members, wideGap: wideGap, text: nsText) {
                    for item in segment {
                        if let previous {
                            append(
                                separator(
                                    from: previous,
                                    to: item,
                                    wideGap: wideGap,
                                    wordGap: wordGap,
                                    text: nsText
                                )
                            )
                        }
                        emit(item)
                        previous = item
                    }
                }
            }
        }

        return Result(
            text: output,
            glyphs: remapped,
            order: .layout,
            coverage: coverage,
            hiddenGlyphCount: hidden.count,
            divergence: divergence
        )
    }

    static func shouldReorder(divergence: Divergence, coverage: Double) -> Bool {
        divergence.upwardJumps >= minimumUpwardJumps
            && divergence.ratio >= minimumDivergenceRatio
            && coverage >= minimumCoverage
    }

    // MARK: - Geometry

    /// Maps unrotated page-space bounds (what PDFKit reports) into "reading
    /// space": x grows to the right and y grows upward *as displayed*, so
    /// rows can be clustered along the rendered horizontal on rotated pages.
    static func readingRect(_ rect: CGRect, rotation: Int) -> CGRect {
        switch ((rotation % 360) + 360) % 360 {
        case 90:
            // Displayed clockwise: page minX becomes the top edge.
            return CGRect(x: rect.minY, y: -rect.maxX, width: rect.height, height: rect.width)
        case 180:
            return CGRect(x: -rect.maxX, y: -rect.maxY, width: rect.width, height: rect.height)
        case 270:
            return CGRect(x: -rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        default:
            return rect
        }
    }

    static func isHidden(_ bounds: CGRect, cropBox: CGRect) -> Bool {
        if max(bounds.width, bounds.height) < minimumVisibleSize { return true }
        if !cropBox.isNull, !cropBox.isEmpty, !bounds.intersects(cropBox) { return true }
        return false
    }

    static func divergence(frames: [CGRect], medianHeight: CGFloat) -> Divergence {
        guard frames.count > 1, medianHeight > 0 else {
            return Divergence(rowTransitions: 0, upwardJumps: 0)
        }
        var transitions = 0
        var upward = 0
        for index in 1 ..< frames.count {
            let delta = frames[index].midY - frames[index - 1].midY
            if abs(delta) > medianHeight * 0.5 { transitions += 1 }
            if delta > medianHeight * 0.8 { upward += 1 }
        }
        return Divergence(rowTransitions: transitions, upwardJumps: upward)
    }

    // MARK: - Runs

    private struct Placed {
        let glyph: Glyph
        let frame: CGRect
    }

    private struct Row {
        var glyphs: [Placed]
        var band: CGRect
    }

    private struct Line {
        enum Kind {
            case row([Placed])
            case run([Placed])
        }
        let sortKey: CGFloat
        let kind: Kind
    }

    /// Separates stream-order runs that do not read horizontally (diagonal
    /// watermarks, rotated labels, display-size banners) from the glyphs
    /// that take part in row clustering. Splicing a 160pt "DRAFT" letter by
    /// letter into whichever body rows its bounds overlap would corrupt
    /// those rows; emitting the run as one line keeps both intact.
    private static func splitRuns(
        _ glyphs: [Placed],
        medianHeight: CGFloat
    ) -> (runs: [[Placed]], rows: [Placed]) {
        let ordered = glyphs.sorted { $0.glyph.characterIndex < $1.glyph.characterIndex }
        var groups: [[Placed]] = []
        var current: [Placed] = []
        for item in ordered {
            if let previous = current.last, isLinked(previous, item, medianHeight: medianHeight) {
                current.append(item)
            } else {
                if !current.isEmpty { groups.append(current) }
                current = [item]
            }
        }
        if !current.isEmpty { groups.append(current) }

        var runs: [[Placed]] = []
        var rows: [Placed] = []
        for group in groups {
            // A lone display-size glyph is isolated too: its box spans many
            // body rows and would swallow them into one visual row.
            if group.count >= 2 || group.contains(where: { isDisplay($0, medianHeight: medianHeight) }) {
                runs.append(group)
            } else {
                rows.append(contentsOf: group)
            }
        }
        return (runs, rows)
    }

    private static func isDisplay(_ item: Placed, medianHeight: CGFloat) -> Bool {
        medianHeight > 0 && item.frame.height > medianHeight * displayHeightMultiplier
    }

    /// Two glyphs continue a non-horizontal run when they are adjacent in
    /// the same source token and either are both display-size or stack
    /// vertically: their x-extents overlap heavily while the baseline moves.
    /// Horizontal text never satisfies the second test, because consecutive
    /// letters occupy disjoint x-extents (kerning overlaps a few percent at
    /// most), so apostrophes, superscripts and punctuation stay in place.
    private static func isLinked(_ previous: Placed, _ next: Placed, medianHeight: CGFloat) -> Bool {
        // A column of separate values has whitespace between them in the
        // source; only same-token neighbours can form a run.
        guard next.glyph.characterIndex == previous.glyph.characterRange.upperBound else { return false }
        if isDisplay(previous, medianHeight: medianHeight), isDisplay(next, medianHeight: medianHeight) {
            return true
        }
        let xOverlap = min(previous.frame.maxX, next.frame.maxX) - max(previous.frame.minX, next.frame.minX)
        let minWidth = max(min(previous.frame.width, next.frame.width), 0.01)
        let minHeight = max(min(previous.frame.height, next.frame.height), 0.01)
        let dy = abs(next.frame.midY - previous.frame.midY)
        return xOverlap >= minWidth * 0.4 && dy > minHeight * 0.2
    }

    // MARK: - Rows

    /// Clusters glyphs into visual rows top-down. A glyph joins a recent
    /// row when it overlaps the row's running band by at least half of the
    /// smaller height *and* the heights are comparable, so a large heading
    /// and the small caption sitting inside its vertical span stay apart
    /// while a bold label still shares its row with a regular value.
    private static func rows(from glyphs: [Placed]) -> [Row] {
        let ordered = glyphs.sorted {
            if abs($0.frame.midY - $1.frame.midY) > 0.01 {
                return $0.frame.midY > $1.frame.midY
            }
            return $0.frame.minX < $1.frame.minX
        }
        var rows: [Row] = []
        for item in ordered {
            var joined = false
            var index = rows.count - 1
            var examined = 0
            while index >= 0, examined < rowLookback {
                if fits(item.frame, band: rows[index].band) {
                    rows[index].glyphs.append(item)
                    rows[index].band = runningBand(rows[index].glyphs)
                    joined = true
                    break
                }
                index -= 1
                examined += 1
            }
            if !joined {
                rows.append(Row(glyphs: [item], band: item.frame))
            }
        }
        return rows
    }

    private static func fits(_ frame: CGRect, band: CGRect) -> Bool {
        let overlap = min(frame.maxY, band.maxY) - max(frame.minY, band.minY)
        guard overlap > 0 else { return false }
        let smaller = min(frame.height, band.height)
        let larger = max(frame.height, band.height)
        guard larger > 0, smaller / larger >= rowHeightSimilarity else { return false }
        return overlap >= smaller * 0.5
    }

    private static func runningBand(_ glyphs: [Placed]) -> CGRect {
        let count = CGFloat(glyphs.count)
        let minY = glyphs.reduce(CGFloat(0)) { $0 + $1.frame.minY } / count
        let maxY = glyphs.reduce(CGFloat(0)) { $0 + $1.frame.maxY } / count
        return CGRect(x: 0, y: minY, width: 1, height: max(maxY - minY, 0.01))
    }

    // MARK: - Segments

    /// Splits a row into stream-contiguous, left-to-right monotonic pieces
    /// and orders the pieces by their left edge. Glyphs are emitted piece
    /// by piece rather than in a flat x-sort because PDFKit reports one
    /// line box for every glyph it merged into a line: a form title drawn
    /// over its small-print neighbour hands both the same y and height, and
    /// a flat sort would interleave their letters. Pieces also break at wide
    /// gaps so a checkbox mark drawn separately still lands between the
    /// labels it sits among.
    private static func segments(in members: [Placed], wideGap: CGFloat, text: NSString) -> [[Placed]] {
        let byStream = members.sorted { $0.glyph.characterIndex < $1.glyph.characterIndex }
        var segments: [[Placed]] = []
        var current: [Placed] = []
        for item in byStream {
            if let last = current.last, continues(last, item, wideGap: wideGap, text: text) {
                current.append(item)
            } else {
                if !current.isEmpty { segments.append(current) }
                current = [item]
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments.sorted { lhs, rhs in
            let leftEdge = lhs[0].frame.minX
            let rightEdge = rhs[0].frame.minX
            if abs(leftEdge - rightEdge) > 0.01 { return leftEdge < rightEdge }
            return lhs[0].glyph.characterIndex < rhs[0].glyph.characterIndex
        }
    }

    private static func continues(_ previous: Placed, _ next: Placed, wideGap: CGFloat, text: NSString) -> Bool {
        guard next.frame.minX >= previous.frame.minX - 0.01,
            next.frame.minX - previous.frame.maxX <= wideGap
        else { return false }
        return sourceAdjacent(previous, next, text: text)
    }

    /// Whether only whitespace (or nothing) separates two glyphs in the
    /// source text.
    private static func sourceAdjacent(_ previous: Placed, _ next: Placed, text: NSString) -> Bool {
        let previousEnd = previous.glyph.characterRange.upperBound
        let nextStart = next.glyph.characterIndex
        if nextStart == previousEnd { return true }
        guard nextStart > previousEnd, nextStart <= text.length else { return false }
        let between = text.substring(with: NSRange(location: previousEnd, length: nextStart - previousEnd))
        return between.allSatisfy(\.isWhitespace)
    }

    // MARK: - Spacing

    private static func separator(
        from previous: Placed,
        to next: Placed,
        wideGap: CGFloat,
        wordGap: CGFloat,
        text: NSString
    ) -> String {
        let gap = next.frame.minX - previous.frame.maxX
        if gap > wideGap { return "   " }
        if next.glyph.characterIndex == previous.glyph.characterRange.upperBound { return "" }  // same token
        if gap > wordGap { return " " }
        // Source whitespace between stream-sequential glyphs is a space the
        // author put there even when the glyph boxes nearly touch.
        return sourceAdjacent(previous, next, text: text) ? " " : ""
    }

    // MARK: - Helpers

    private static func nonWhitespaceUTF16Count(of text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            count += scalar.utf16.count
        }
        return count
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

private extension String {
    var isPDFWhitespace: Bool {
        unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }
}

private extension CGRect {
    var isUsable: Bool {
        !isNull && !isEmpty && origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }
}
