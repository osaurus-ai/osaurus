//
//  Screenshot.swift
//  OsaurusCore — Computer Use
//
//  Native macOS driver, brought in-core from osaurus-ai/osaurus-macos-use.
//  Backgrounded window/display capture (works on occluded / off-Space windows)
//  with optional element-id annotation overlay.
//
//  Refactored for in-core use: the original MCP `CallToolResult` content
//  envelope was dropped in favor of a plain `CapturedImage` value the harness
//  turns into its own contract type.
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Captured Image

/// A captured frame as encoded image bytes plus dimensions. `savedPath` is set
/// only when the caller asked the controller to write the image to disk.
struct CapturedImage: Sendable {
    let width: Int
    let height: Int
    /// e.g. "image/jpeg", "image/png"
    let mimeType: String
    /// Encoded image bytes (JPEG/PNG).
    let data: Data
    /// File path when the capture was written to disk; otherwise nil.
    let savedPath: String?

    var base64: String { data.base64EncodedString() }
}

// MARK: - Screenshot Options

struct ScreenshotOptions: Decodable {
    /// Capture only this app's window. Without `windowId`, the largest
    /// on-screen window for that pid is chosen. Works for occluded and
    /// off-screen-Space windows too — `CGWindowListCreateImage` doesn't
    /// require the window to be visible.
    var pid: Int32?

    /// Capture this exact `CGWindowID` (returned by `list_windows`). Beats
    /// the pid heuristic when an app has multiple windows and the agent
    /// already knows which one it wants.
    var windowId: CGWindowID?

    /// Display index to capture (0 = main display, 1, 2, etc.)
    var displayIndex: Int?

    /// Capture all displays as one combined image
    var allDisplays: Bool?

    /// Image format: "png" or "jpeg"
    var format: String?

    /// JPEG quality (0.0 - 1.0), only used for JPEG format
    var quality: Double?

    /// Scale factor (0.0 - 1.0) to reduce image size
    var scale: Double?

    /// If specified, save screenshot to this file path in addition to returning bytes.
    var savePath: String?

    /// If true, overlay element IDs from the most recent snapshot (matched by pid).
    /// Useful for vision-augmented agents to reference IDs straight from the image.
    /// Requires `pid` to be set, and that get_ui_elements has been called for that pid.
    var annotate: Bool?

    init(
        pid: Int32? = nil,
        windowId: CGWindowID? = nil,
        displayIndex: Int? = nil,
        allDisplays: Bool? = nil,
        format: String? = nil,
        quality: Double? = nil,
        scale: Double? = nil,
        savePath: String? = nil,
        annotate: Bool? = nil
    ) {
        self.pid = pid
        self.windowId = windowId
        self.displayIndex = displayIndex
        self.allDisplays = allDisplays
        self.format = format
        self.quality = quality
        self.scale = scale
        self.savePath = savePath
        self.annotate = annotate
    }
}

// MARK: - Display Info

struct DisplayInfo: Encodable, Sendable {
    let index: Int
    let displayId: UInt32
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let isMain: Bool
}

struct DisplayListResult: Encodable, Sendable {
    let displays: [DisplayInfo]
}

// MARK: - Screenshot Controller

final class ScreenshotController: @unchecked Sendable {
    static let shared = ScreenshotController()

    private init() {}

    /// Get list of all connected displays
    func listDisplays() -> DisplayListResult {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        let mainDisplayID = CGMainDisplayID()

        let displayInfos = displays.enumerated().map { index, displayId -> DisplayInfo in
            let bounds = CGDisplayBounds(displayId)
            return DisplayInfo(
                index: index,
                displayId: displayId,
                x: safeInt(bounds.origin.x),
                y: safeInt(bounds.origin.y),
                width: safeInt(bounds.width),
                height: safeInt(bounds.height),
                isMain: displayId == mainDisplayID
            )
        }

        return DisplayListResult(displays: displayInfos)
    }

    /// Capture a screenshot of the entire screen or a specific window.
    /// Returns nil if capture or encoding fails.
    ///
    /// Uses ScreenCaptureKit (`SCScreenshotManager`): the legacy
    /// `CGWindowListCreateImage` / `CGDisplayCreateImage` paths are unavailable
    /// on the current SDK. SCK still captures occluded / off-Space windows.
    func capture(options: ScreenshotOptions = ScreenshotOptions()) async -> CapturedImage? {
        let image: CGImage?

        if let windowId = options.windowId {
            // Direct window-id capture is the cleanest backgrounded path: it works
            // even if the window is hidden, occluded, or on a different Space.
            image = await captureWindow(windowId: windowId)
        } else if let pid = options.pid {
            image = await captureWindow(pid: pid)
        } else if options.allDisplays == true {
            image = await captureAllDisplays()
        } else if let displayIndex = options.displayIndex {
            image = await captureDisplay(at: displayIndex)
        } else {
            image = await captureFullScreen()
        }

        guard let cgImage = image else {
            return nil
        }

        // Optionally annotate with element IDs before scaling so labels stay legible.
        let annotatedImage: CGImage = {
            if options.annotate == true {
                // When the caller passed a windowId, use that to compute the
                // capture origin; otherwise fall back to the per-pid heuristic.
                let pidForElements: Int32? =
                    options.pid
                    ?? options.windowId.flatMap { ownerPid(for: $0) }
                guard let pid = pidForElements else { return cgImage }
                let elements = AccessibilityManager.shared.mostRecentElements(for: pid)
                let captureOrigin: CGPoint? =
                    options.windowId.flatMap { captureBoundsForWindowId($0)?.origin }
                    ?? captureBoundsForPid(pid)?.origin
                if let origin = captureOrigin,
                    let overlaid = overlayElementIds(
                        on: cgImage,
                        elements: elements,
                        captureOrigin: origin
                    )
                {
                    return overlaid
                }
            }
            return cgImage
        }()

        // Apply scaling - default to 0.5 for reasonable size on Retina displays
        let finalImage: CGImage
        let scale = options.scale ?? 0.5
        if scale > 0 && scale < 1.0 {
            if let scaled = scaleImage(annotatedImage, scale: scale) {
                finalImage = scaled
            } else {
                finalImage = annotatedImage
            }
        } else {
            finalImage = annotatedImage
        }

        // Convert to data - default to JPEG for much smaller file size
        let format = options.format?.lowercased() ?? "jpeg"
        let quality = options.quality ?? 0.7

        guard let data = imageToData(finalImage, format: format, quality: quality) else {
            return nil
        }

        let mimeType = format == "png" ? "image/png" : "image/jpeg"

        // Save to file if path is specified (still return the bytes).
        var savedPath: String? = nil
        if let savePath = options.savePath {
            let url = URL(fileURLWithPath: savePath)
            if (try? data.write(to: url)) != nil {
                savedPath = savePath
            }
        }

        return CapturedImage(
            width: finalImage.width,
            height: finalImage.height,
            mimeType: mimeType,
            data: data,
            savedPath: savedPath
        )
    }

    private func captureFullScreen() async -> CGImage? {
        return await captureDisplay(displayID: CGMainDisplayID())
    }

    private func captureDisplay(at index: Int) async -> CGImage? {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)

        guard index < displayCount else {
            return nil
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        return await captureDisplay(displayID: displays[index])
    }

    private func captureAllDisplays() async -> CGImage? {
        // ScreenCaptureKit captures one display per filter; combining displays is
        // out of scope for the harness (it drives per-window/per-display). Fall
        // back to the main display.
        return await captureDisplay(displayID: CGMainDisplayID())
    }

    private func captureWindow(pid: Int32) async -> CGImage? {
        // Pick the largest reasonable window for the pid, then capture it.
        let windowList =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]]

        if let windows = windowList {
            var best: (id: CGWindowID, area: Double)? = nil
            for window in windows {
                guard let windowPID = window[kCGWindowOwnerPID] as? Int32, windowPID == pid,
                    let windowID = window[kCGWindowNumber] as? CGWindowID,
                    let bounds = window[kCGWindowBounds] as? [String: Any],
                    let width = bounds["Width"] as? Double,
                    let height = bounds["Height"] as? Double,
                    width > 100, height > 100
                else { continue }
                let area = width * height
                if best == nil || area > best!.area { best = (windowID, area) }
            }
            if let best, let image = await captureWindow(windowId: best.id) {
                return image
            }
        }
        // Fall back to full-screen capture.
        return await captureFullScreen()
    }

    /// Capture exactly one window by id via ScreenCaptureKit. Works on occluded
    /// and off-Space windows. The caller already decided which window it wants.
    private func captureWindow(windowId: CGWindowID) async -> CGImage? {
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            ),
            let scWindow = content.windows.first(where: { $0.windowID == windowId })
        else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let scale = backingScale(forFrame: scWindow.frame)
        let config = SCStreamConfiguration()
        config.width = max(1, safeInt(scWindow.frame.width * scale))
        config.height = max(1, safeInt(scWindow.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    private func captureDisplay(displayID: CGDirectDisplayID) async -> CGImage? {
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            ),
            let scDisplay = content.displays.first(where: { $0.displayID == displayID })
        else { return nil }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let scale = backingScale(forFrame: scDisplay.frame)
        let config = SCStreamConfiguration()
        config.width = max(1, safeInt(Double(scDisplay.width) * scale))
        config.height = max(1, safeInt(Double(scDisplay.height) * scale))
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    /// Backing scale (pixels per point) for whichever display contains `frame`'s
    /// center. SCK frames are in points; we capture at pixel resolution so OCR /
    /// vision keeps detail. Uses CoreGraphics (thread-safe, unlike `NSScreen`)
    /// and defaults to 2.0 (Retina) when no display matches.
    private func backingScale(forFrame frame: CGRect) -> Double {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var displayID = CGMainDisplayID()
        var matched: [CGDirectDisplayID] = Array(repeating: 0, count: 8)
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(center, 8, &matched, &count) == .success, count > 0 {
            displayID = matched[0]
        }
        let bounds = CGDisplayBounds(displayID)
        guard let mode = CGDisplayCopyDisplayMode(displayID), bounds.width > 0 else { return 2.0 }
        let pixelWidth = Double(mode.pixelWidth)
        let pointWidth = Double(bounds.width)
        let scale = pixelWidth / max(pointWidth, 1)
        return scale > 0 ? scale : 2.0
    }

    /// Owner pid for a CGWindowID. Used to look up the element cache when
    /// the caller annotates a windowId-only screenshot.
    fileprivate func ownerPid(for windowId: CGWindowID) -> Int32? {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowId) as? [[CFString: Any]]
        return info?.first?[kCGWindowOwnerPID] as? Int32
    }

    /// Bounds of a specific window in screen coordinates. Mirrors
    /// `captureBoundsForPid` for the windowId-driven path.
    fileprivate func captureBoundsForWindowId(_ windowId: CGWindowID) -> CGRect? {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowId) as? [[CFString: Any]]
        guard let entry = info?.first,
            let bounds = entry[kCGWindowBounds] as? [String: Any],
            let x = bounds["X"] as? Double,
            let y = bounds["Y"] as? Double,
            let w = bounds["Width"] as? Double,
            let h = bounds["Height"] as? Double
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func scaleImage(_ image: CGImage, scale: Double) -> CGImage? {
        let newWidth = Int(Double(image.width) * scale)
        let newHeight = Int(Double(image.height) * scale)

        guard newWidth > 0, newHeight > 0 else {
            return nil
        }

        guard
            let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        return context.makeImage()
    }

    private func imageToData(_ image: CGImage, format: String, quality: Double) -> Data? {
        let bitmapRep = NSBitmapImageRep(cgImage: image)

        switch format {
        case "jpeg", "jpg":
            return bitmapRep.representation(
                using: .jpeg,
                properties: [.compressionFactor: quality]
            )
        default:
            return bitmapRep.representation(using: .png, properties: [:])
        }
    }

    /// Compute the screen-space bounds of the captured region so we can map
    /// AX (global) coordinates to image-local coordinates.
    /// Returns nil if we can't determine bounds; callers should skip annotation.
    fileprivate func captureBoundsForPid(_ pid: Int32) -> CGRect? {
        let windowList =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]]
        guard let windows = windowList else { return nil }

        for window in windows {
            if let windowPID = window[kCGWindowOwnerPID] as? Int32, windowPID == pid,
                let bounds = window[kCGWindowBounds] as? [String: Any],
                let x = bounds["X"] as? Double,
                let y = bounds["Y"] as? Double,
                let w = bounds["Width"] as? Double,
                let h = bounds["Height"] as? Double,
                w > 100, h > 100
            {
                return CGRect(x: x, y: y, width: w, height: h)
            }
        }
        return nil
    }
}

// MARK: - Annotation Overlay

/// Draws element-ID labels on top of `image` so vision-capable agents can
/// reference IDs visually. `captureOrigin` is the screen-space origin of the
/// capture so we can subtract it from each element's global AX coordinates.
private func overlayElementIds(
    on image: CGImage,
    elements: [(id: String, frame: CGRect)],
    captureOrigin: CGPoint
) -> CGImage? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0, !elements.isEmpty else { return image }

    guard
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return nil }

    // Draw original image
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Set up colors: red boxes, white text on red
    let boxStroke = CGColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 0.95)
    let labelFill = CGColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 0.85)
    context.setStrokeColor(boxStroke)
    context.setLineWidth(1.5)

    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    let font = NSFont.boldSystemFont(ofSize: 11)
    let textAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]

    for element in elements {
        let f = element.frame
        // Convert global top-left coords to image-local coords.
        // CGContext is bottom-left origin; flip y.
        let localX = f.origin.x - captureOrigin.x
        let localTopY = f.origin.y - captureOrigin.y
        let bottomY = CGFloat(height) - localTopY - f.size.height
        let rect = CGRect(x: localX, y: bottomY, width: f.size.width, height: f.size.height)
        if rect.maxX <= 0 || rect.maxY <= 0 || rect.minX >= CGFloat(width)
            || rect.minY >= CGFloat(height)
        {
            continue
        }

        context.stroke(rect)

        // Draw a small label in the top-left of the element with the id
        let labelText = element.id
        let attributed = NSAttributedString(string: labelText, attributes: textAttrs)
        let textSize = attributed.size()
        let pad: CGFloat = 2
        let labelRect = CGRect(
            x: rect.minX,
            y: rect.maxY - textSize.height - pad * 2,
            width: textSize.width + pad * 2,
            height: textSize.height + pad * 2
        )
        context.setFillColor(labelFill)
        context.fill(labelRect)
        attributed.draw(at: CGPoint(x: labelRect.minX + pad, y: labelRect.minY + pad))
    }

    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}
