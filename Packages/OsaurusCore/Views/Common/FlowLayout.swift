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
            var x = bounds.minX
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
        return rows
    }
}
