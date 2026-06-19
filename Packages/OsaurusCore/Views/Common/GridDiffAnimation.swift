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
    ///
    /// Pass `visibleCount` on large grids to gate the animation: a change
    /// that adds/removes more than `maxAnimatedDelta` cells applies
    /// instantly instead of animating. Animating a wholesale swap (e.g.
    /// clearing a search to reveal the full catalog) forces SwiftUI to
    /// build, measure, and transition every newly inserted cell inside one
    /// spring transaction on the main thread, which has hung large grids
    /// for seconds. Omit `visibleCount` to always animate (fine for small
    /// grids whose worst-case swap is cheap).
    func gridDiffAnimation<T: Equatable>(
        token: T,
        visibleCount: Int? = nil,
        maxAnimatedDelta: Int = 24
    ) -> some View {
        modifier(
            GridDiffAnimationModifier(
                token: token,
                visibleCount: visibleCount,
                maxAnimatedDelta: maxAnimatedDelta
            )
        )
    }

    /// Asymmetric scale + fade transition for individual grid cells.
    /// Apply on each cell inside the `ForEach`.
    func gridDiffCell() -> some View {
        self.transition(GridDiff.cellTransition)
    }
}

/// Applies the mosaic spring on `token` changes, but suppresses it when the
/// visible set jumps by more than `maxAnimatedDelta` cells. `lastCount` trails
/// `visibleCount` by one update, so the body that reacts to a token change
/// still sees the pre-change count and can size the delta correctly.
private struct GridDiffAnimationModifier<T: Equatable>: ViewModifier {
    let token: T
    let visibleCount: Int?
    let maxAnimatedDelta: Int
    @State private var lastCount: Int?

    func body(content: Content) -> some View {
        let animate: Bool
        if let visibleCount, let lastCount {
            animate = abs(visibleCount - lastCount) <= maxAnimatedDelta
        } else {
            // No count provided, or first render: animate as before.
            animate = true
        }

        return
            content
            .animation(animate ? GridDiff.spring : nil, value: token)
            .onChange(of: visibleCount ?? 0) { _, newValue in lastCount = newValue }
            .onAppear { if lastCount == nil { lastCount = visibleCount } }
    }
}
