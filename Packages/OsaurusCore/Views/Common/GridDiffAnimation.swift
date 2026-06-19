//
//  GridDiffAnimation.swift
//  osaurus
//
//  Shared mosaic transition for grids whose visible item set changes —
//  search/filter/sort in ModelDownloadView, add/remove in AgentsView, etc.
//
//  Usage:
//    LazyVGrid(...) {
//        ForEach(items, id: \.id) { item in
//            Cell(item).gridDiffCell()
//        }
//    }
//    .gridDiffAnimation(token: changeToken)
//
//  `token` should fingerprint everything that affects the visible item
//  set (search text, sort option, filter state, IDs). When the token
//  changes, SwiftUI snapshot-diffs the ForEach: surviving cells slide to
//  their new grid position, removed cells scale-fade out, inserted ones
//  scale-fade in.
//

import SwiftUI

/// Namespace for the shared spring + transition. Exposed so callers can
/// compose with other animations or override per-call site if needed.
enum GridDiff {
    static var spring: Animation {
        .spring(response: 0.42, dampingFraction: 0.82)
    }

    static var cellTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.85).combined(with: .opacity),
            removal: .scale(scale: 0.85).combined(with: .opacity)
        )
    }
}

extension View {
    /// Drives the implicit grid mosaic animation. Apply on the grid
    /// container (e.g. `LazyVGrid`). The animation fires whenever
    /// `token` changes — so build a token that captures every input
    /// affecting the visible set.
    func gridDiffAnimation<T: Equatable>(token: T) -> some View {
        self.animation(GridDiff.spring, value: token)
    }

    /// Asymmetric scale + fade transition for individual grid cells.
    /// Apply on each cell inside the `ForEach`.
    func gridDiffCell() -> some View {
        self.transition(GridDiff.cellTransition)
    }
}
