//
//  CaptureMode.swift
//  OsaurusCore — Computer Use
//
//  Native macOS driver, brought in-core from osaurus-ai/osaurus-macos-use.
//  The three capture modalities (ax / vision / som) and the set-of-mark
//  envelope builder that fuses the AX tree with an annotated screenshot.
//

import CoreGraphics
import Foundation

// MARK: - Capture Mode
//
//   .ax     — accessibility tree only, no pixels. No Screen Recording
//             permission needed. Fastest. Best for AppKit/SwiftUI apps
//             with rich AX trees.
//   .vision — screenshot only, no AX tree. Smallest payload for
//             vision-first VLMs that ground on pixels.
//   .som    — set-of-mark: AX tree + screenshot, with element-id
//             numbers drawn on every actionable element. Default: lets
//             pixel-grounded models reason visually while still using
//             stable element ids for clicks.

enum CaptureMode: String, Codable, Sendable {
    case ax
    case vision
    case som

    static let `default`: CaptureMode = .som

    static func parse(_ raw: String?) -> CaptureMode {
        guard let raw = raw?.lowercased() else { return .default }
        return CaptureMode(rawValue: raw) ?? .default
    }
}

// MARK: - SOM Result
//
// `elementIndex` is the cua-style addressing layer: a stable integer per
// element in display order, useful for vision-first agents that don't want to
// parse `s7-42` ids.

/// One actionable element annotated with both its snapshot id and its
/// SOM-mode index. The agent can use either to address the element in
/// follow-up clicks.
struct SOMElementRef: Sendable {
    let elementIndex: Int
    let id: String
    let role: String
    let label: String?
    let x: Int
    let y: Int
    let w: Int
    let h: Int
}

struct SOMResult: Sendable {
    let mode: String
    let snapshot: TraversalResult
    let image: CapturedImage?
    let windowId: Int?
    let elements: [SOMElementRef]
    let routeUsed: InputRoute?
}

// MARK: - Builder

/// Build a capture envelope for a given pid, switching on `mode`.
///
/// `windowId` is forwarded to the screenshot path; if absent we fall back
/// to the largest on-screen window for the pid (existing behavior).
func buildCapture(
    pid: Int32,
    mode: CaptureMode,
    windowId: Int? = nil,
    maxElements: Int? = nil,
    focusedWindowOnly: Bool = false
) async -> SOMResult {
    let snapshot = await AccessibilityManager.runOffMain { () -> TraversalResult in
        var filter = ElementFilter(pid: pid)
        if let maxElements { filter.maxElements = maxElements }
        if focusedWindowOnly { filter.focusedWindowOnly = true }
        return AccessibilityManager.shared.traverse(filter: filter)
    }

    let elementRefs: [SOMElementRef] = snapshot.elements.enumerated().map { idx, info in
        SOMElementRef(
            elementIndex: idx + 1,
            id: info.id,
            role: info.role,
            label: info.label,
            x: info.x,
            y: info.y,
            w: info.w,
            h: info.h
        )
    }

    var imageContent: CapturedImage? = nil
    if mode == .som || mode == .vision {
        var opts = ScreenshotOptions()
        opts.pid = pid
        if let wid = windowId { opts.windowId = CGWindowID(wid) }
        // SOM annotation reuses the existing element-id overlay; the agent
        // gets both the numeric index in `elements[]` and the visual id label
        // burned onto the image.
        opts.annotate = (mode == .som)
        imageContent = await ScreenshotController.shared.capture(options: opts)
    }

    return SOMResult(
        mode: mode.rawValue,
        snapshot: snapshot,
        image: imageContent,
        windowId: windowId,
        elements: elementRefs,
        routeUsed: nil
    )
}
