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
//   .som    — set-of-mark: AX tree + screenshot, with public mark
//             numbers drawn on every actionable element. Default: lets
//             pixel-grounded models reason visually while still using
//             stable public marks for clicks.

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
// `elementIndex` is the CUA-style public mark: a snapshot-scoped stable integer
// derived from the snapshot id when available, useful for vision-first agents
// that don't want to parse `s7-42` ids.

/// One actionable element annotated with its snapshot id and public SOM mark.
/// The agent addresses the element by mark; the raw id is an internal resolver
/// handle and must not be rendered into model text or screenshot pixels.
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

    let publicMarks = SnapshotIdFormat.publicMarks(for: snapshot.elements.map(\.id))
    let elementRefs: [SOMElementRef] = snapshot.elements.enumerated().map { idx, info in
        SOMElementRef(
            elementIndex: publicMarks[idx],
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
        // SOM annotation burns the same public numeric mark shown in
        // `elements[]` onto the image. Internal AX ids stay out of pixels.
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
