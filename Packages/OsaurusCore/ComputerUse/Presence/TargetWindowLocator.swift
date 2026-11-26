//
//  TargetWindowLocator.swift
//  OsaurusCore — Computer Use
//
//  Finds the WindowServer window behind a snapshot's AX window (snapshot ids
//  are AX indexes, not CGWindowIDs) so the shield can be ordered directly above
//  it and follow it as it moves.
//

import AppKit
import CoreGraphics

struct WindowServerWindow: Sendable, Equatable {
    let id: CGWindowID
    let pid: Int32
    /// Global top-left screen points, like AX frames.
    let bounds: CGRect
    let layer: Int
}

enum TargetWindowLocator {
    /// On-screen, normal-layer windows owned by `pid`, front to back.
    static func windows(pid: Int32) -> [WindowServerWindow] {
        let info =
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]]) ?? []
        return info.compactMap(parse).filter { $0.pid == pid && $0.layer == 0 }
    }

    /// The live entry for one window, or nil once it closes or leaves the screen.
    static func window(id: CGWindowID) -> WindowServerWindow? {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[CFString: Any]]) ?? []
        guard let entry = info.first,
            (entry[kCGWindowIsOnscreen] as? Bool) ?? false
        else { return nil }
        return parse(entry)
    }

    /// The window whose bounds overlap `frame` the most; with no frame, the
    /// frontmost one.
    static func bestMatch(for frame: CGRect?, among candidates: [WindowServerWindow]) -> WindowServerWindow? {
        guard let frame else { return candidates.first }
        var best: (window: WindowServerWindow, score: CGFloat)?
        for candidate in candidates {
            let overlap = candidate.bounds.intersection(frame)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let union = candidate.bounds.union(frame)
            let score = (overlap.width * overlap.height) / max(1, union.width * union.height)
            if score > (best?.score ?? 0) { best = (candidate, score) }
        }
        return best?.window
    }

    /// AppKit frame (bottom-left origin) for a top-left global rect.
    static func appKitFrame(fromTopLeft rect: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(
            x: rect.origin.x,
            y: primaryScreenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// A top-left global point inside `rect`, as a SwiftUI point in that rect.
    static func localPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
    }

    @MainActor
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private static func parse(_ entry: [CFString: Any]) -> WindowServerWindow? {
        guard let number = entry[kCGWindowNumber] as? Int,
            let pid = entry[kCGWindowOwnerPID] as? Int32,
            let boundsDict = entry[kCGWindowBounds] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        return WindowServerWindow(
            id: CGWindowID(number),
            pid: pid,
            bounds: bounds,
            layer: entry[kCGWindowLayer] as? Int ?? 0
        )
    }
}
