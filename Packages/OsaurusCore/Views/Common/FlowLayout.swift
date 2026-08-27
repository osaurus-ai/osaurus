//
//  FlowLayout.swift
//  osaurus
//
//  Wrapping layout that flows items into rows, breaking to a new line when
//  the current row exceeds the available width.
//

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    /// Horizontal placement of each row inside the available width.
    /// `.leading` (default) matches the historical behavior; `.center` is
    /// used by centered surfaces like the chat empty state's action pills.
    var alignment: HorizontalAlignment = .leading
    /// When true, rows are re-broken so they carry even visual weight: the
    /// greedy minimal row count is kept, but items are repartitioned to
    /// minimize the width spread across rows (7 pills → 4/3 instead of
    /// 2/2/3). Off by default so existing call sites keep greedy wrapping.
    var balanced: Bool = false

    /// Memoizes the row break-down for a given proposed width. SwiftUI calls
    /// `sizeThatFits` and `placeSubviews` (often repeatedly) within one layout
    /// pass, and `computeRows` queries every subview's `sizeThatFits`. Caching
    /// the result keyed by width avoids re-walking all subviews each call.
    struct Cache {
        var width: CGFloat?
        var rows: [Row] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Subviews changed; force a recompute on the next query.
        cache.width = nil
        cache.rows = []
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let rows = rows(proposal: proposal, subviews: subviews, cache: &cache)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(rows.count - 1) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let rows = rows(proposal: proposal, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for row in rows {
            let rowWidth =
                row.items.reduce(CGFloat(0)) { $0 + $1.size.width }
                + CGFloat(max(0, row.items.count - 1)) * spacing
            var x = bounds.minX + rowInset(rowWidth: rowWidth, available: bounds.width)
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// Leading offset that realizes `alignment` for one row.
    private func rowInset(rowWidth: CGFloat, available: CGFloat) -> CGFloat {
        guard available.isFinite, available > rowWidth else { return 0 }
        if alignment == .center { return (available - rowWidth) / 2 }
        if alignment == .trailing { return available - rowWidth }
        return 0
    }

    struct RowItem { let index: Int; let size: CGSize }
    struct Row { let items: [RowItem]; let height: CGFloat }

    /// Returns the cached rows for `proposal`'s width, recomputing only when
    /// the width changes (or the cache was invalidated by a subview change).
    private func rows(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        if cache.width == maxWidth { return cache.rows }
        let computed = computeRows(maxWidth: maxWidth, subviews: subviews)
        cache.width = maxWidth
        cache.rows = computed
        return computed
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentItems: [RowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !currentItems.isEmpty && currentWidth + spacing + size.width > maxWidth {
                rows.append(Row(items: currentItems, height: currentHeight))
                currentItems = []
                currentWidth = 0
                currentHeight = 0
            }
            currentItems.append(RowItem(index: i, size: size))
            currentWidth += (currentItems.count > 1 ? spacing : 0) + size.width
            currentHeight = max(currentHeight, size.height)
        }
        if !currentItems.isEmpty {
            rows.append(Row(items: currentItems, height: currentHeight))
        }
        guard balanced, maxWidth.isFinite, rows.count > 1 else { return rows }
        return rebalanced(rows, maxWidth: maxWidth)
    }

    /// Repartitions the greedily-wrapped `rows` into the same number of rows
    /// while minimizing the total squared slack (unused width) per row — a
    /// convex cost, so widths equalize across rows. Order is preserved; every
    /// row still fits `maxWidth`. Item counts are tiny (pill strips), so the
    /// O(n² · k) dynamic program is negligible.
    private func rebalanced(_ rows: [Row], maxWidth: CGFloat) -> [Row] {
        let items = rows.flatMap(\.items)
        let n = items.count
        let k = rows.count
        guard n > k else { return rows }

        // prefix[i] = total width of items[0..<i] laid out in one row
        // (including inner spacing), so items[i..<j] as a row measures
        // prefix[j] - prefix[i] - (i == 0 ? 0 : spacing).
        var prefix: [CGFloat] = [0]
        for (offset, item) in items.enumerated() {
            prefix.append(prefix[offset] + (offset > 0 ? spacing : 0) + item.size.width)
        }
        func rowWidth(_ i: Int, _ j: Int) -> CGFloat {
            prefix[j] - prefix[i] - (i > 0 ? spacing : 0)
        }

        // cost[r][j] = best total squared slack splitting items[0..<j] into
        // r rows; split[r][j] = start index of the r-th row in that optimum.
        let infinity = CGFloat.greatestFiniteMagnitude
        var cost = [[CGFloat]](repeating: [CGFloat](repeating: infinity, count: n + 1), count: k + 1)
        var split = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: k + 1)
        cost[0][0] = 0
        for r in 1 ... k {
            for j in r ... n {
                for i in (r - 1) ..< j {
                    guard cost[r - 1][i] < infinity else { continue }
                    let width = rowWidth(i, j)
                    guard width <= maxWidth else { continue }
                    let slack = maxWidth - width
                    let candidate = cost[r - 1][i] + slack * slack
                    if candidate < cost[r][j] {
                        cost[r][j] = candidate
                        split[r][j] = i
                    }
                }
            }
        }
        guard cost[k][n] < infinity else { return rows }

        var boundaries: [Int] = [n]
        var j = n
        for r in stride(from: k, through: 1, by: -1) {
            j = split[r][j]
            boundaries.append(j)
        }
        boundaries.reverse()

        var result: [Row] = []
        for r in 0 ..< k {
            let slice = Array(items[boundaries[r] ..< boundaries[r + 1]])
            let height = slice.reduce(CGFloat(0)) { max($0, $1.size.height) }
            result.append(Row(items: slice, height: height))
        }
        return result
    }
}
