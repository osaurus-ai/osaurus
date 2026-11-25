//
//  FramePreparer.swift
//  OsaurusCore — Computer Use
//
//  Turns a captured frame into the frame the model sees: fitted to the run's
//  `FrameBudget`, with each element's `mark` number drawn over it so the model
//  can match what it sees to the element list. The marks are drawn by the
//  harness from the same snapshot the list was rendered from, so the number on
//  the image and the number in the list always agree, and internal element ids
//  never reach the image.
//
//  The frame keeps its `region`: resizing changes how many pixels show the
//  screen area, not which area, so `ScreenshotPointing` still maps the model's
//  `target.point` back to the screen.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An element mark to draw: its number and its box in the frame's pixels
/// (top-left origin).
public struct FrameMark: Sendable, Equatable {
    public let number: Int
    public let rect: CGRect

    public init(number: Int, rect: CGRect) {
        self.number = number
        self.rect = rect
    }
}

public enum FramePreparer {
    /// Boxes smaller than this on either side (in frame pixels) aren't marked;
    /// the label would cover the control.
    static let minMarkSide: CGFloat = 4

    /// Shrink `image` to fit `budget`. Returns `image` untouched when it already
    /// fits, or when it can't be decoded.
    public static func fit(_ image: CUImage, to budget: FrameBudget) -> CUImage {
        let target = budget.fitted(width: image.width, height: image.height)
        guard target.width != image.width || target.height != image.height else { return image }
        guard let source = decode(image) else { return image }
        return render(source, width: target.width, height: target.height, like: image) { _ in } ?? image
    }

    /// Marks for `snapshot`'s elements that are visible in `image`. Element
    /// `i` carries mark `i + 1`, the numbering `AgentView` uses. Empty when the
    /// frame has no `region` (nothing to map screen frames into).
    public static func marks(for snapshot: CUSnapshot?, in image: CUImage) -> [FrameMark] {
        guard let snapshot, let region = image.region, region.w > 0, region.h > 0,
            image.width > 0, image.height > 0
        else { return [] }
        let sx = CGFloat(image.width) / CGFloat(region.w)
        let sy = CGFloat(image.height) / CGFloat(region.h)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var marks: [FrameMark] = []
        for (index, element) in snapshot.elements.enumerated() {
            let rect = CGRect(
                x: (CGFloat(element.x) - CGFloat(region.x)) * sx,
                y: (CGFloat(element.y) - CGFloat(region.y)) * sy,
                width: CGFloat(element.w) * sx,
                height: CGFloat(element.h) * sy
            ).intersection(bounds)
            guard !rect.isNull, rect.width >= minMarkSide, rect.height >= minMarkSide else { continue }
            marks.append(FrameMark(number: index + 1, rect: rect))
        }
        return marks
    }

    /// `image` with each mark's box outlined and its number in a tag at the
    /// box's top-left corner. Returns `image` when there's nothing to draw or
    /// it can't be decoded.
    public static func drawMarks(_ marks: [FrameMark], on image: CUImage) -> CUImage {
        guard !marks.isEmpty, let source = decode(image) else { return image }
        let height = CGFloat(image.height)
        let fontSize = max(10, min(16, CGFloat(max(image.width, image.height)) / 110))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let stroke = CGColor(red: 0.95, green: 0.15, blue: 0.2, alpha: 0.9)
        let fill = CGColor(red: 0.85, green: 0.1, blue: 0.15, alpha: 0.92)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        return render(source, width: image.width, height: image.height, like: image) { context in
            context.setLineWidth(max(1, fontSize / 9))
            for mark in marks {
                // CGContext is bottom-left origin; marks are top-left.
                let box = CGRect(
                    x: mark.rect.minX,
                    y: height - mark.rect.maxY,
                    width: mark.rect.width,
                    height: mark.rect.height
                )
                context.setStrokeColor(stroke)
                context.stroke(box)

                let text = NSAttributedString(
                    string: String(mark.number),
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
                    ]
                )
                let line = CTLineCreateWithAttributedString(text)
                let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let pad = max(2, fontSize / 5)
                let tagHeight = fontSize + pad * 2
                let tag = CGRect(
                    x: box.minX,
                    y: max(0, box.maxY - tagHeight),
                    width: textWidth + pad * 2,
                    height: tagHeight
                )
                context.setFillColor(fill)
                context.fill(tag)
                context.textPosition = CGPoint(x: tag.minX + pad, y: tag.minY + pad + fontSize * 0.2)
                CTLineDraw(line, context)
            }
        } ?? image
    }

    // MARK: - Pixels

    private static func decode(_ image: CUImage) -> CGImage? {
        guard let data = Data(base64Encoded: image.base64),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Draw `source` scaled to `width`×`height`, run `overlay`, and encode in
    /// `like`'s format, keeping its `region`.
    private static func render(
        _ source: CGImage,
        width: Int,
        height: Int,
        like original: CUImage,
        overlay: (CGContext) -> Void
    ) -> CUImage? {
        guard width > 0, height > 0,
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
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        overlay(context)
        guard let drawn = context.makeImage() else { return nil }

        let png = original.mimeType == "image/png"
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                (png ? UTType.png : UTType.jpeg).identifier as CFString,
                1,
                nil
            )
        else { return nil }
        let properties: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(destination, drawn, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return CUImage(
            base64: (data as Data).base64EncodedString(),
            mimeType: png ? "image/png" : "image/jpeg",
            width: width,
            height: height,
            region: original.region
        )
    }
}
