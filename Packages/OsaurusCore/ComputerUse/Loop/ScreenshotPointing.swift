//
//  ScreenshotPointing.swift
//  OsaurusCore — Computer Use
//
//  Maps a model's `target.point` / zoom `region` from the latest screenshot it
//  was shown to global screen points, reading them in the model's grounding
//  frame (pixels, 0–1000, or 0–1 of the image), and finds the accessibility
//  element under a point so the gate classifies a coordinate action by what
//  it actually hits.
//

import CoreGraphics
import Foundation

enum ScreenshotPointing {

    enum PointResolution: Equatable {
        case screen(CGPoint)
        case invalid(String)
    }

    enum RegionResolution: Equatable {
        case screen(CUScreenRegion)
        case invalid(String)
    }

    /// Smallest close-up a zoom may ask for, in screenshot pixels per side.
    static let minimumZoomSide: Double = 8

    static let ungroundedPointReason =
        "This model hasn't shown it can point at screenshot coordinates, so `target.point` is off. Address the "
        + "element by `mark` or `describe`."
    static let ungroundedZoomReason =
        "This model hasn't shown it can point at screenshot coordinates, so `zoom` is off. Use `screenshot` and "
        + "address elements by `mark` or `describe`."

    static func screenPoint(
        _ point: AgentPoint,
        in frame: CUImage?,
        grounding: GroundingProfile? = .providerPixels
    ) -> PointResolution {
        guard let grounding else { return .invalid(ungroundedPointReason) }
        guard let frame, frame.width > 0, frame.height > 0 else {
            return .invalid(
                "`target.point` needs a screenshot in view. Use `screenshot` first, or address the element "
                    + "by `mark`."
            )
        }
        guard let region = frame.region, region.w > 0, region.h > 0 else {
            return .invalid(
                "The latest screenshot has no known screen position, so a point can't be placed. Address the "
                    + "element by `mark` or `describe`."
            )
        }
        let width = Double(frame.width)
        let height = Double(frame.height)
        guard let pixel = grounding.pixelPoint(x: point.x, y: point.y, width: width, height: height) else {
            return .invalid(
                "Point (\(format(point.x)), \(format(point.y))) is outside the latest screenshot"
                    + extentPhrase(grounding.frame, width: frame.width, height: frame.height) + "."
            )
        }
        return .screen(
            CGPoint(
                x: region.x + pixel.x * region.w / width,
                y: region.y + pixel.y * region.h / height
            )
        )
    }

    static func screenRegion(
        _ area: AgentRegion,
        in frame: CUImage?,
        grounding: GroundingProfile? = .providerPixels
    ) -> RegionResolution {
        guard let grounding else { return .invalid(ungroundedZoomReason) }
        guard let frame, frame.width > 0, frame.height > 0 else {
            return .invalid("`zoom` needs a screenshot in view. Use `screenshot` first.")
        }
        guard let region = frame.region, region.w > 0, region.h > 0 else {
            return .invalid("The latest screenshot has no known screen position, so it can't be zoomed.")
        }
        let width = Double(frame.width)
        let height = Double(frame.height)
        let unit = grounding.pixelsPerUnit(width: width, height: height)
        let minX = max(0, area.x * unit.x)
        let minY = max(0, area.y * unit.y)
        let maxX = min(width, (area.x + area.width) * unit.x)
        let maxY = min(height, (area.y + area.height) * unit.y)
        guard maxX - minX >= minimumZoomSide, maxY - minY >= minimumZoomSide else {
            return .invalid(
                "That region is outside the screenshot"
                    + extentPhrase(grounding.frame, width: frame.width, height: frame.height)
                    + " or smaller than \(Int(minimumZoomSide)) pixels on a side."
            )
        }
        let sx = region.w / width
        let sy = region.h / height
        return .screen(
            CUScreenRegion(
                x: region.x + minX * sx,
                y: region.y + minY * sy,
                w: (maxX - minX) * sx,
                h: (maxY - minY) * sy
            )
        )
    }

    private static func extentPhrase(_ frame: GroundingProfile.CoordinateFrame, width: Int, height: Int) -> String {
        switch frame {
        case .pixels: return ", which is \(width)×\(height) pixels"
        case .normalized1000: return " (coordinates run 0–1000 across its width and height)"
        case .normalizedUnit: return " (coordinates run 0–1 across its width and height)"
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value || abs(value) >= 10 ? String(Int(value.rounded())) : String(format: "%.3g", value)
    }

    /// The innermost captured element whose frame contains `point`.
    static func hitTest(_ point: CGPoint, in snapshot: CUSnapshot?) -> CUElement? {
        guard let snapshot else { return nil }
        var best: CUElement?
        var bestArea = Int.max
        for element in snapshot.elements where element.w > 0 && element.h > 0 {
            let x = Double(element.x)
            let y = Double(element.y)
            guard point.x >= x, point.y >= y,
                point.x < x + Double(element.w), point.y < y + Double(element.h)
            else { continue }
            let area = element.w * element.h
            if area < bestArea {
                best = element
                bestArea = area
            }
        }
        return best
    }
}
