//
//  DocumentParser.swift
//  osaurus
//
//  Parses document files into plain text for context injection.
//  Uses macOS built-in frameworks (PDFKit, NSAttributedString) — no external dependencies.
//

import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum DocumentParser {

    static let maxParsedTextLength = 500_000  // ~500KB of text

    enum ParseError: LocalizedError {
        case unsupportedFormat(String)
        case readFailed(String)
        case fileTooLarge
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext): return "Unsupported file format: .\(ext)"
            case .readFailed(let reason): return "Failed to read file: \(reason)"
            case .fileTooLarge: return "Document is too large to attach"
            case .emptyContent: return "Document appears to be empty"
            }
        }
    }

    // MARK: - Public API

    static func parse(url: URL) throws -> Attachment {
        let results = try parseAll(url: url)
        guard let first = results.first else {
            throw ParseError.emptyContent
        }
        return first
    }

    /// Parse a file into one or more attachments.
    /// PDFs with no extractable text are rendered as page images (one per page).
    static func parseAll(url: URL) throws -> [Attachment] {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent

        // PDF may fall back to image rendering if text extraction yields nothing
        if ext == "pdf" {
            return try parsePDFWithFallback(url: url, filename: filename, fileSize: fileSize)
        }

        let content: String
        switch ext {
        case _ where isPlainText(ext: ext):
            content = try parsePlainText(url: url)
        case "docx":
            content = try parseRichDocument(url: url)
        case "doc":
            content = try parseRichDocument(url: url, type: .docFormat)
        case "rtf", "rtfd":
            content = try parseRichDocument(url: url, type: .rtf)
        case "html", "htm":
            content = try parseRichDocument(url: url, type: .html)
        default:
            throw ParseError.unsupportedFormat(ext)
        }

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.emptyContent
        }

        let trimmed =
            content.count > maxParsedTextLength
            ? String(content.prefix(maxParsedTextLength))
                + "\n\n[Document truncated — exceeded \(maxParsedTextLength) character limit]"
            : content

        return [.document(filename: filename, content: trimmed, fileSize: fileSize)]
    }

    static func canParse(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return isPlainText(ext: ext) || richDocumentExtensions.contains(ext)
    }

    static func isImageFile(url: URL) -> Bool {
        guard let utType = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return utType.conforms(to: .image)
    }

    static var supportedDocumentTypes: [UTType] {
        [
            .plainText, .utf8PlainText,
            .pdf,
            .rtf, .rtfd,
            .html,
            UTType("org.openxmlformats.wordprocessingml.document") ?? .data,  // .docx
            UTType("com.microsoft.word.doc") ?? .data,  // .doc
            .commaSeparatedText,
            .json, .xml, .yaml,
            UTType("public.python-script") ?? .data,
            UTType("public.swift-source") ?? .data,
            UTType("com.netscape.javascript-source") ?? .data,
            UTType("public.shell-script") ?? .data,
        ].compactMap { $0 }
    }

    // MARK: - Plain Text

    private static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv",
        "json", "xml", "yaml", "yml", "toml",
        "log", "ini", "cfg", "conf", "env",
        "swift", "py", "js", "ts", "tsx", "jsx",
        "rs", "go", "java", "kt", "c", "cpp", "h", "hpp",
        "rb", "php", "sh", "bash", "zsh", "fish",
        "css", "scss", "less", "sql",
        "r", "m", "mm", "lua", "pl", "ex", "exs",
        "zig", "nim", "dart", "scala", "groovy",
        "tf", "hcl", "dockerfile",
        "gitignore", "editorconfig", "prettierrc",
    ]

    private static let richDocumentExtensions: Set<String> = [
        "pdf", "docx", "doc", "rtf", "rtfd", "html", "htm",
    ]

    private static func isPlainText(ext: String) -> Bool {
        plainTextExtensions.contains(ext)
    }

    private static func parsePlainText(url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Retry with latin1 for binary-ish text files
            if let data = try? Data(contentsOf: url),
                let str = String(data: data, encoding: .isoLatin1)
            {
                return str
            }
            throw ParseError.readFailed(error.localizedDescription)
        }
    }

    // MARK: - PDF

    /// Maximum number of PDF pages to render as images when text extraction fails
    private static let maxPDFImagePages = 20

    private static func parsePDFWithFallback(url: URL, filename: String, fileSize: Int) throws -> [Attachment] {
        guard let document = PDFDocument(url: url) else {
            throw ParseError.readFailed("Could not open PDF")
        }

        // Try text extraction first
        let text = extractPDFText(from: document)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed =
                text.count > maxParsedTextLength
                ? String(text.prefix(maxParsedTextLength))
                    + "\n\n[Document truncated — exceeded \(maxParsedTextLength) character limit]"
                : text
            return [.document(filename: filename, content: trimmed, fileSize: fileSize)]
        }

        // Text extraction yielded nothing — render pages as images
        let images = renderPDFPagesAsImages(document: document, maxPages: maxPDFImagePages)
        guard !images.isEmpty else {
            throw ParseError.emptyContent
        }

        return images.map { .image($0) }
    }

    private static func extractPDFText(from document: PDFDocument) -> String {
        var pages: [String] = []
        for i in 0 ..< document.pageCount {
            if let page = document.page(at: i), let text = page.string,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                pages.append(text)
            }
        }
        return pages.joined(separator: "\n\n")
    }

    private static let maxPixelsPerPage = 4000 * 4000  // ~16MP cap per page

    private static func renderPDFPagesAsImages(document: PDFDocument, maxPages: Int) -> [Data] {
        let pageCount = min(document.pageCount, maxPages)
        var images: [Data] = []
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        for i in 0 ..< pageCount {
            guard let page = document.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // Render at 2x for readability
            let scale: CGFloat = 2.0
            let intWidth = Int(bounds.width * scale)
            let intHeight = Int(bounds.height * scale)

            guard intWidth > 0, intHeight > 0, intWidth <= maxPixelsPerPage / intHeight else { continue }

            guard
                let context = CGContext(
                    data: nil,
                    width: intWidth,
                    height: intHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                )
            else { continue }

            // White background
            context.setFillColor(CGColor.white)
            context.fill(CGRect(x: 0, y: 0, width: intWidth, height: intHeight))

            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)

            guard let cgImage = context.makeImage() else { continue }
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: bounds.width, height: bounds.height))
            if let pngData = nsImage.pngData() {
                images.append(pngData)
            }
        }
        return images
    }

    // MARK: - Rich Documents (DOCX, RTF, HTML)

    private static func parseRichDocument(url: URL, type: NSAttributedString.DocumentType? = nil) throws -> String {
        do {
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let type = type {
                options[.documentType] = type
            }
            let attributed = try NSAttributedString(
                url: url,
                options: options,
                documentAttributes: nil
            )
            return attributed.string
        } catch {
            throw ParseError.readFailed(error.localizedDescription)
        }
    }
}
