//
//  FileReadImageSupport.swift
//  osaurus
//
//  Image handling for `file_read`: load + bound an image for a vision
//  model, or recognise its text (Vision OCR) for a text-only model.
//  Also renders image-only PDF pages for OCR so scanned documents are
//  readable through the same tool.
//

import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum FileReadImageSupport {
    /// Largest source file we'll open at all. Anything bigger is refused
    /// with the binary envelope — a 200 MB TIFF is not a chat attachment.
    static let maxSourceBytes = 64 * 1024 * 1024
    /// Longest side / encoded-byte budget for what reaches the model.
    /// Mirrors `RemoteImagePayloadPolicy` so remote providers never see a
    /// second downscale.
    static let maxLongSidePixels = RemoteImagePayloadPolicy.maxLongSidePixels
    static let maxEncodedBytes = RemoteImagePayloadPolicy.maxEncodedBytes
    /// Image-only PDF: OCR at most this many pages per read.
    static let maxOCRPDFPages = 20
    /// Pixel scale for rendering PDF pages before OCR (2x of the 72 dpi
    /// media box keeps small body text legible for Vision).
    static let pdfRenderScale: CGFloat = 2.0

    struct LoadedImage: Sendable {
        /// Bytes that will be attached (possibly re-encoded as JPEG).
        let data: Data
        /// MIME subtype of `data` (`png`, `jpeg`, ...).
        let mimeSubtype: String
        let pixelWidth: Int
        let pixelHeight: Int
        /// Size of the file on disk, before any downscale.
        let sourceBytes: Int
        /// True when `data` is a downscaled JPEG rendition, not the original bytes.
        let downscaled: Bool
    }

    enum LoadError: Error {
        case unreadable
        case undecodable
        case tooLarge(bytes: Int)
    }

    /// Read an image file, validate it decodes, and bound it to the wire
    /// budget. Pure ImageIO — safe off the main thread.
    static func load(url: URL) throws -> LoadedImage {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > maxSourceBytes { throw LoadError.tooLarge(bytes: size) }
        guard let bytes = try? Data(contentsOf: url, options: [.mappedIfSafe]), !bytes.isEmpty else {
            throw LoadError.unreadable
        }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else {
            throw LoadError.undecodable
        }
        let subtype = mimeSubtype(of: source) ?? "png"
        let oversized = max(width, height) > maxLongSidePixels || bytes.count > maxEncodedBytes
        // Formats a vision API may not accept inline (HEIC/TIFF/BMP) are
        // re-encoded even when small, so the attachment is always PNG/JPEG/GIF/WebP.
        let needsTranscode = !["png", "jpeg", "gif", "webp"].contains(subtype)
        if oversized || needsTranscode {
            if let jpeg = RemoteImagePayloadPolicy.downsizedJPEGData(from: bytes) {
                let scale = min(1.0, Double(maxLongSidePixels) / Double(max(width, height)))
                return LoadedImage(
                    data: jpeg,
                    mimeSubtype: "jpeg",
                    pixelWidth: max(1, Int((Double(width) * scale).rounded())),
                    pixelHeight: max(1, Int((Double(height) * scale).rounded())),
                    sourceBytes: bytes.count,
                    downscaled: true
                )
            }
            if oversized { throw LoadError.tooLarge(bytes: bytes.count) }
        }
        return LoadedImage(
            data: Data(bytes),
            mimeSubtype: subtype,
            pixelWidth: width,
            pixelHeight: height,
            sourceBytes: bytes.count,
            downscaled: false
        )
    }

    private static func mimeSubtype(of source: CGImageSource) -> String? {
        guard let uti = CGImageSourceGetType(source) as String?,
            let type = UTType(uti),
            let mime = type.preferredMIMEType,
            mime.hasPrefix("image/")
        else { return nil }
        return String(mime.dropFirst("image/".count))
    }

    // MARK: - OCR

    /// Recognised text lines, top-to-bottom, left-to-right. Empty when the
    /// image has no legible text. Vision runs its own worker threads; this
    /// just awaits the completion handler.
    static func recognizeTextLines(in data: Data) async -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [] }
        return await recognizeTextLines(in: image)
    }

    static func recognizeTextLines(in image: CGImage) async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                continuation.resume(returning: orderedLines(from: observations))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Vision returns observations in detection order, not reading order.
    /// Sort by the top edge (descending in Vision's bottom-left origin),
    /// then by the left edge, and merge observations that share a line.
    private static func orderedLines(from observations: [VNRecognizedTextObservation]) -> [String] {
        struct Item {
            let text: String
            let box: CGRect
        }
        let items: [Item] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Item(text: text, box: observation.boundingBox)
        }
        let sorted = items.sorted { lhs, rhs in
            let lhsTop = lhs.box.maxY
            let rhsTop = rhs.box.maxY
            // Same visual line when the vertical centres are within half a line height.
            let tolerance = min(lhs.box.height, rhs.box.height) * 0.5
            if abs(lhs.box.midY - rhs.box.midY) <= tolerance {
                return lhs.box.minX < rhs.box.minX
            }
            return lhsTop > rhsTop
        }
        var lines: [String] = []
        var currentLine: [String] = []
        var currentMidY: CGFloat?
        var currentHeight: CGFloat = 0
        for item in sorted {
            if let midY = currentMidY,
                abs(item.box.midY - midY) <= min(item.box.height, currentHeight) * 0.5
            {
                currentLine.append(item.text)
            } else {
                if !currentLine.isEmpty { lines.append(currentLine.joined(separator: "  ")) }
                currentLine = [item.text]
                currentMidY = item.box.midY
                currentHeight = item.box.height
            }
        }
        if !currentLine.isEmpty { lines.append(currentLine.joined(separator: "  ")) }
        return lines
    }

    struct PDFOCRResult {
        let text: String
        let pagesScanned: Int
        let totalPages: Int
    }

    /// Render the first `maxOCRPDFPages` pages of an image-only PDF and OCR
    /// each one. Pages are separated by a `--- page N ---` marker so the
    /// `N|` gutter still lets the model cite a location.
    static func ocrImageOnlyPDF(url: URL) async -> PDFOCRResult? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        let total = document.pageCount
        let limit = min(total, maxOCRPDFPages)
        var chunks: [String] = []
        var recognizedLines = 0
        for index in 0 ..< limit {
            if Task.isCancelled { break }
            guard let page = document.page(at: index), let image = render(page: page) else { continue }
            let lines = await recognizeTextLines(in: image)
                .filter { $0.contains(where: { !$0.isWhitespace }) }
            chunks.append("--- page \(index + 1) ---")
            chunks.append(contentsOf: lines)
            recognizedLines += lines.count
        }
        // Page markers alone are not a read: with nothing recognised the
        // caller raises the honest image-only-PDF error instead.
        guard recognizedLines > 0 else { return nil }
        return PDFOCRResult(text: chunks.joined(separator: "\n"), pagesScanned: limit, totalPages: total)
    }

    private static func render(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let width = Int((bounds.width * pdfRenderScale).rounded(.up))
        let height = Int((bounds.height * pdfRenderScale).rounded(.up))
        guard width > 0, height > 0, width * height <= 40_000_000 else { return nil }
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
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: pdfRenderScale, y: pdfRenderScale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        return context.makeImage()
    }

    // MARK: - Envelope helpers

    /// Data URL for a loaded image, matching the composer's attachment
    /// shape so provider encoders treat both identically.
    static func dataURL(for image: LoadedImage) -> String {
        "data:image/\(image.mimeSubtype);base64,\(image.data.base64EncodedString())"
    }
}
