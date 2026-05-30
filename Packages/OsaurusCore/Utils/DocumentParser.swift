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

    /// Hard byte cap applied before the file is read into memory. The post-read
    /// `maxParsedTextLength` trim only bounds the *decoded* text, so a crafted
    /// latin-1 or rich-document input could still balloon RAM during decode.
    /// Matches the image cap in `FloatingInputCard`.
    static let maxFileSize = 10 * 1024 * 1024
    private static let registryAdapterTimeout = UnfairLockedBox<TimeInterval>(15)

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

    static func withRegistryAdapterTimeoutForTesting<T>(
        _ timeout: TimeInterval,
        _ body: () throws -> T
    ) rethrows -> T {
        let previous = registryAdapterTimeout.get()
        registryAdapterTimeout.set(timeout)
        defer { registryAdapterTimeout.set(previous) }
        return try body()
    }

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
        if fileSize > maxFileSize {
            throw ParseError.fileTooLarge
        }
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent

        // Registry-routed path. Returns nil when no adapter claims the file
        // OR when the claiming adapter surfaces `.emptyContent` /
        // `.unsupportedFormat`, so the legacy switch below still handles
        // e.g. image-only PDFs and any format an adapter hasn't taken over.
        if let attachments = try routeThroughRegistry(url: url, fileSize: fileSize) {
            return attachments
        }

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
        if isPlainText(ext: ext) || richDocumentExtensions.contains(ext) {
            return true
        }

        let uti = UTType(filenameExtension: ext)?.identifier
        return DocumentFormatRegistry.shared.adapter(for: url, uti: uti) != nil
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
        ].compactMap { $0 } + structuredDocumentTypes
    }

    private static let structuredDocumentTypes: [UTType] = [
        UTType(filenameExtension: "xlsx"),
        UTType(filenameExtension: "pptx"),
        UTType(filenameExtension: "potx"),
    ].compactMap { $0 }

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

    /// Whether `ext` is one of the extensions decoded as raw plain text
    /// (source code, CSV/TSV, JSON, config, etc.). Exposed so callers
    /// like `file_read` can keep the raw line-numbered read path for
    /// these — preserving `start_line`/`end_line` semantics — and only
    /// route the binary-but-text-extractable formats (pdf/docx/pptx/...)
    /// through the parser.
    static func isPlainTextExtension(_ ext: String) -> Bool {
        isPlainText(ext: ext.lowercased())
    }

    private static func parsePlainText(url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Retry with latin1 for binary-ish text files
            if let data = try? Data(contentsOf: url) {
                if let str = String(data: data, encoding: .isoLatin1) {
                    return str
                }
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
            if let page = document.page(at: i), let text = page.string {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pages.append(text)
                }
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

    // MARK: - Registry shim

    /// Tries the document format registry before the legacy switch. The
    /// registry runs async; we block on a dedicated dispatch queue so the
    /// synchronous `parseAll` contract is preserved during the migration
    /// window. Once every caller is async (stage-4 PR 10), this shim goes
    /// away.
    ///
    /// Return value conventions:
    /// - `nil` — no adapter is registered, or an adapter declined the file
    ///   via `.emptyContent` / `.unsupportedFormat`; legacy path handles it.
    /// - non-nil — the adapter produced a text view; convert to
    ///   `[Attachment]` by wrapping `textFallback`.
    /// - throws — adapter produced a non-recoverable error (size / read /
    ///   write); surface as `ParseError`.
    private static func routeThroughRegistry(url: URL, fileSize: Int) throws -> [Attachment]? {
        let registry = DocumentFormatRegistry.shared
        guard let adapter = registry.adapter(for: url) else { return nil }

        let sizeLimit = DocumentLimits.limit(forFormatId: adapter.formatId)
        do {
            let document = try runBlocking {
                try await adapter.parse(url: url, sizeLimit: sizeLimit)
            }
            return [.structuredDocument(document)]
        } catch DocumentAdapterError.emptyContent, DocumentAdapterError.unsupportedFormat {
            // Fall through so the legacy switch (image-only PDFs, formats
            // without an adapter yet) still gets a shot.
            return nil
        } catch DocumentAdapterError.sizeLimitExceeded {
            throw ParseError.fileTooLarge
        } catch let DocumentAdapterError.readFailed(reason) {
            throw ParseError.readFailed(reason)
        } catch DocumentAdapterError.writeFailed, DocumentAdapterError.cancelled {
            throw ParseError.readFailed("Adapter emitted non-read error for ingress")
        } catch BlockingAwaitError.timedOut(let timeout) {
            throw ParseError.readFailed("Document adapter timed out after \(formatTimeout(timeout)) seconds")
        } catch {
            throw ParseError.readFailed(error.localizedDescription)
        }
    }

    /// Synchronously awaits an async body. The shim is called from
    /// `parseAll` which is itself invoked from UI callbacks that are still
    /// synchronous — see `FloatingInputCard`. Dropping the semaphore means
    /// reworking every ingress call site, which isn't in scope for PR 3.
    private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = UnfairLockedBox<Result<T, Error>?>(nil)

        let task = Task.detached {
            let result: Result<T, Error>
            do {
                result = .success(try await body())
            } catch {
                result = .failure(error)
            }
            resultBox.set(result)
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: deadline(after: registryAdapterTimeout.get()))
        guard waitResult == .success else {
            // Adapter implementations are extension points. A hung adapter
            // should lose its ingest attempt, not wedge the synchronous UI
            // bridge that is still in place while parser callers migrate.
            task.cancel()
            throw BlockingAwaitError.timedOut(registryAdapterTimeout.get())
        }

        guard let result = resultBox.get() else {
            throw BlockingAwaitError.missingResult
        }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private static func deadline(after timeout: TimeInterval) -> DispatchTime {
        guard timeout.isFinite, timeout > 0 else { return .now() }
        let milliseconds = max(1, Int((min(timeout, 86_400) * 1_000).rounded(.up)))
        return .now() + .milliseconds(milliseconds)
    }

    private static func formatTimeout(_ timeout: TimeInterval) -> String {
        timeout.rounded() == timeout
            ? String(Int(timeout))
            : String(format: "%.2f", timeout)
    }

    private enum BlockingAwaitError: Error {
        case timedOut(TimeInterval)
        case missingResult
    }
}

/// Tiny lock-box so the blocking-await shim above can hand a value back
/// across the actor/thread boundary without tripping Swift 6 sendability.
private final class UnfairLockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); defer { lock.unlock() }; value = newValue }
}
