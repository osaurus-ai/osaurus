//
//  AnchoredCardResizeTransition.swift
//  Osaurus
//

import Foundation

/// Resizes an anchored card with width leading height when both change.
/// Each origin coordinate follows its dimension so the anchored edge stays put.
struct AnchoredCardResizeTransition {
    let from: CGRect
    let to: CGRect
    let startTime: TimeInterval

    private static let dimensionDuration: TimeInterval = 0.26

    private var heightDelay: TimeInterval {
        from.width != to.width && from.height != to.height ? 0.07 : 0
    }

    var duration: TimeInterval { Self.dimensionDuration + heightDelay }

    init(from: CGRect, to: CGRect, startTime: TimeInterval) {
        self.from = from
        self.to = to
        self.startTime = startTime
    }

    func frame(at time: TimeInterval) -> CGRect {
        guard time > startTime else { return from }
        guard !isComplete(at: time) else { return to }

        let widthProgress = progress(at: time, delay: 0)
        let heightProgress = progress(at: time, delay: heightDelay)
        return CGRect(
            x: interpolate(from.origin.x, to.origin.x, progress: widthProgress),
            y: interpolate(from.origin.y, to.origin.y, progress: heightProgress),
            width: interpolate(from.width, to.width, progress: widthProgress),
            height: interpolate(from.height, to.height, progress: heightProgress)
        )
    }

    func isComplete(at time: TimeInterval) -> Bool {
        time >= startTime + duration
    }

    private func progress(at time: TimeInterval, delay: TimeInterval) -> CGFloat {
        let linear = min(max((time - startTime - delay) / Self.dimensionDuration, 0), 1)
        let remaining = 1 - linear
        return CGFloat(1 - remaining * remaining * remaining)
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, progress: CGFloat) -> CGFloat {
        if progress == 0 { return start }
        if progress == 1 { return end }
        return start + (end - start) * progress
    }
}
