//
//  RichTextPDFRenderer.swift
//  osaurus
//
//  Headless, main-thread-free PDF pagination for an `NSAttributedString`
//  using CoreText (`CTFramesetter`) drawn into a `CGContext` PDF consumer.
//  No `NSPrintOperation`, no `NSTextView`, so it runs inside a tool call
//  on any thread.
//

import CoreGraphics
import CoreText
import Foundation

enum RichTextPDFRenderer {
    struct PageSetup: Sendable {
        var size: CGSize
        var margin: CGFloat

        /// US Letter, 1" margins.
        static let letter = PageSetup(size: CGSize(width: 612, height: 792), margin: 72)
    }

    struct Rendered {
        let data: Data
        let pageCount: Int
    }

    enum RenderError: LocalizedError {
        case contextUnavailable
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .contextUnavailable: return "Could not create a PDF drawing context."
            case .emptyDocument: return "The document has no text to render."
            }
        }
    }

    /// Hard ceiling so a runaway framesetter (zero-progress range) or an
    /// enormous input cannot spin forever.
    static let maxPages = 500

    static func render(
        _ attributed: NSAttributedString,
        page: PageSetup = .letter,
        title: String? = nil
    ) throws -> Rendered {
        guard attributed.length > 0 else { throw RenderError.emptyDocument }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw RenderError.contextUnavailable
        }
        var mediaBox = CGRect(origin: .zero, size: page.size)
        var auxiliary: [CFString: Any] = [kCGPDFContextCreator: "Osaurus"]
        if let title, !title.isEmpty { auxiliary[kCGPDFContextTitle] = title }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, auxiliary as CFDictionary) else {
            throw RenderError.contextUnavailable
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let textRect = mediaBox.insetBy(dx: page.margin, dy: page.margin)
        let path = CGPath(rect: textRect, transform: nil)
        var location = 0
        var pages = 0
        let total = attributed.length

        while location < total, pages < maxPages {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 {
                // Nothing fits (e.g. a single glyph taller than the page).
                // Stop rather than emit blank pages forever.
                break
            }
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.endPDFPage()
            pages += 1
            location = visible.location + visible.length
        }
        context.closePDF()
        guard pages > 0 else { throw RenderError.emptyDocument }
        return Rendered(data: output as Data, pageCount: pages)
    }
}
