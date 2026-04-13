//
//  FileImportService.swift
//  osaurus
//
//  Registry-backed file import service with explicit built-in registration.
//

import AppKit
import Foundation
import os
import PDFKit
import UniformTypeIdentifiers

public enum FileImportError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case readFailed(String)
    case fileTooLarge(maxBytes: Int)
    case emptyContent
    case invalidFilePath
    case pluginImportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported file format: .\(ext)"
        case .readFailed(let reason):
            return "Failed to read file: \(reason)"
        case .fileTooLarge(let maxBytes):
            return
                "Document exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)) attachment limit"
        case .emptyContent:
            return "Document appears to be empty"
        case .invalidFilePath:
            return "Only regular files can be attached"
        case .pluginImportFailed(let reason):
            return "Plugin import failed: \(reason)"
        }
    }
}

enum FileImportService {
    static let maxParsedTextLength = 500_000
    static let maxPDFImagePages = 20
    static let defaultMaxInputBytes = 25 * 1024 * 1024

    private static let builtInRegistration = OSAllocatedUnfairLock(initialState: false)

    static func parse(url: URL) async throws -> Attachment {
        let attachments = try await parseAll(url: url)
        guard let first = attachments.first else {
            throw FileImportError.emptyContent
        }
        return first
    }

    static func parseAll(url: URL) async throws -> [Attachment] {
        ensureBuiltInImportersRegistered()

        guard url.isFileURL else {
            throw FileImportError.invalidFilePath
        }

        let ext = url.pathExtension.lowercased()
        let fileSize = try fileSize(for: url)

        guard let importer = FileImportRegistry.shared.importer(for: url) else {
            throw FileImportError.unsupportedFormat(ext)
        }

        try validate(url: url, descriptor: importer.descriptor, fileSize: fileSize)
        let attachments = try await importer.importFile(at: url)
        let normalized = normalizeAttachments(
            attachments,
            fallbackFilename: url.lastPathComponent,
            fallbackFileSize: fileSize
        )

        guard !normalized.isEmpty else {
            throw FileImportError.emptyContent
        }

        return normalized
    }

    static func canImport(url: URL) -> Bool {
        ensureBuiltInImportersRegistered()
        return FileImportRegistry.shared.canImport(url: url)
    }

    static var supportedDocumentTypes: [UTType] {
        ensureBuiltInImportersRegistered()
        return FileImportRegistry.shared.supportedDocumentTypes()
    }

    static func registerPluginImporters(from plugin: ExternalPlugin) {
        ensureBuiltInImportersRegistered()
        FileImportRegistry.shared.unregisterPluginImporters(pluginId: plugin.id)

        for spec in plugin.manifest.capabilities.file_importers ?? [] {
            let descriptor = FileImportDescriptor(
                id: "\(plugin.id).\(spec.id)",
                extensions: spec.extensions,
                utTypes: spec.ut_types,
                mimeTypes: spec.mime_types,
                maxBytes: spec.max_bytes,
                source: .nativePlugin,
                outputMode: spec.output_mode,
                toolId: spec.tool_id,
                outputSchemaVersion: spec.output_schema_version
            )
            FileImportRegistry.shared.register(
                PluginBackedFileImporter(
                    descriptor: descriptor,
                    plugin: plugin,
                    toolId: spec.tool_id
                ),
                ownerPluginId: plugin.id
            )
        }
    }

    static func unregisterPluginImporters(pluginId: String) {
        FileImportRegistry.shared.unregisterPluginImporters(pluginId: pluginId)
    }

    static func registerBuiltInImporters(on registry: FileImportRegistry) {
        builtInImporters().forEach { registry.register($0) }
    }

    private static func ensureBuiltInImportersRegistered() {
        builtInRegistration.withLock { builtInsRegistered in
            guard !builtInsRegistered else { return }
            registerBuiltInImporters(on: FileImportRegistry.shared)
            builtInsRegistered = true
        }
    }

    private static func builtInImporters() -> [any FileImporter] {
        [
            BuiltInFileImporter(
                descriptor: FileImportDescriptor(
                    id: "core.plain-text",
                    extensions: Array(plainTextExtensions).sorted(),
                    utTypes: [
                        UTType.plainText.identifier,
                        UTType.utf8PlainText.identifier,
                        UTType.commaSeparatedText.identifier,
                        UTType.json.identifier,
                        UTType.xml.identifier,
                        UTType.yaml.identifier,
                        UTType("public.python-script")?.identifier ?? "public.python-script",
                        UTType("public.swift-source")?.identifier ?? "public.swift-source",
                        UTType("com.netscape.javascript-source")?.identifier ?? "com.netscape.javascript-source",
                        UTType("public.shell-script")?.identifier ?? "public.shell-script",
                    ],
                    mimeTypes: [
                        "text/plain",
                        "text/csv",
                        "text/tab-separated-values",
                        "application/json",
                        "application/xml",
                        "application/x-yaml",
                        "application/toml",
                    ],
                    maxBytes: defaultMaxInputBytes,
                    source: .core,
                    outputMode: .normalizedText
                ),
                handler: parsePlainTextFamily
            ),
            BuiltInFileImporter(
                descriptor: FileImportDescriptor(
                    id: "core.rich-document",
                    extensions: ["doc", "docx", "html", "htm", "rtf", "rtfd"],
                    utTypes: [
                        UTType.rtf.identifier,
                        UTType.rtfd.identifier,
                        UTType.html.identifier,
                        UTType("org.openxmlformats.wordprocessingml.document")?.identifier
                            ?? "org.openxmlformats.wordprocessingml.document",
                        UTType("com.microsoft.word.doc")?.identifier ?? "com.microsoft.word.doc",
                    ],
                    mimeTypes: [
                        "application/msword",
                        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                        "application/rtf",
                        "text/html",
                    ],
                    maxBytes: defaultMaxInputBytes,
                    source: .core,
                    outputMode: .normalizedText
                ),
                handler: parseRichDocumentFamily
            ),
            BuiltInFileImporter(
                descriptor: FileImportDescriptor(
                    id: "core.pdf",
                    extensions: ["pdf"],
                    utTypes: [UTType.pdf.identifier],
                    mimeTypes: ["application/pdf"],
                    maxBytes: 50 * 1024 * 1024,
                    source: .core,
                    outputMode: .normalizedText
                ),
                handler: parsePDFWithFallback
            ),
        ]
    }

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

    private static func fileSize(for url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    private static func validate(url: URL, descriptor: FileImportDescriptor, fileSize: Int) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile != false else {
            throw FileImportError.invalidFilePath
        }
        if fileSize > descriptor.maxBytes {
            throw FileImportError.fileTooLarge(maxBytes: descriptor.maxBytes)
        }
    }

    private static func normalizeAttachments(
        _ attachments: [Attachment],
        fallbackFilename: String,
        fallbackFileSize: Int
    ) -> [Attachment] {
        attachments.compactMap { attachment in
            switch attachment.kind {
            case .image(let data):
                guard !data.isEmpty else { return nil }
                return .image(data)
            case .document(let filename, let content, let fileSize):
                let hasMeaningfulContent = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard hasMeaningfulContent else { return nil }
                return .document(
                    filename: filename.isEmpty ? fallbackFilename : filename,
                    content: truncate(content),
                    fileSize: fileSize > 0 ? fileSize : fallbackFileSize
                )
            }
        }
    }

    private static func truncate(_ content: String) -> String {
        guard content.count > maxParsedTextLength else { return content }
        return String(content.prefix(maxParsedTextLength))
            + "\n\n[Document truncated — exceeded \(maxParsedTextLength) character limit]"
    }

    private static func parsePlainTextFamily(url: URL) throws -> [Attachment] {
        let filename = url.lastPathComponent
        let fileSize = try fileSize(for: url)
        let content = try parsePlainText(url: url)
        return [.document(filename: filename, content: content, fileSize: fileSize)]
    }

    private static func parsePlainText(url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            if let data = try? Data(contentsOf: url),
                let str = String(data: data, encoding: .isoLatin1)
            {
                return str
            }
            throw FileImportError.readFailed(error.localizedDescription)
        }
    }

    private static func parseRichDocumentFamily(url: URL) throws -> [Attachment] {
        let filename = url.lastPathComponent
        let fileSize = try fileSize(for: url)
        let ext = url.pathExtension.lowercased()

        let type: NSAttributedString.DocumentType?
        switch ext {
        case "doc":
            type = .docFormat
        case "rtf", "rtfd":
            type = .rtf
        case "html", "htm":
            type = .html
        default:
            type = nil
        }

        let content = try parseRichDocument(url: url, type: type)
        return [.document(filename: filename, content: content, fileSize: fileSize)]
    }

    private static func parseRichDocument(url: URL, type: NSAttributedString.DocumentType?) throws -> String {
        do {
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let type {
                options[.documentType] = type
            }
            let attributed = try NSAttributedString(
                url: url,
                options: options,
                documentAttributes: nil
            )
            return attributed.string
        } catch {
            throw FileImportError.readFailed(error.localizedDescription)
        }
    }

    private static func parsePDFWithFallback(url: URL) throws -> [Attachment] {
        let filename = url.lastPathComponent
        let fileSize = try fileSize(for: url)

        guard let document = PDFDocument(url: url) else {
            throw FileImportError.readFailed("Could not open PDF")
        }

        let text = extractPDFText(from: document)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.document(filename: filename, content: text, fileSize: fileSize)]
        }

        let images = renderPDFPagesAsImages(document: document, maxPages: maxPDFImagePages)
        guard !images.isEmpty else {
            throw FileImportError.emptyContent
        }
        return images.map { .image($0) }
    }

    private static func extractPDFText(from document: PDFDocument) -> String {
        var pages: [String] = []
        for i in 0 ..< document.pageCount {
            guard let page = document.page(at: i), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                pages.append(text)
            }
        }
        return pages.joined(separator: "\n\n")
    }

    private static let maxPixelsPerPage = 4_000 * 4_000

    private static func renderPDFPagesAsImages(document: PDFDocument, maxPages: Int) -> [Data] {
        let pageCount = min(document.pageCount, maxPages)
        var images: [Data] = []
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        for i in 0 ..< pageCount {
            guard let page = document.page(at: i) else { continue }

            let bounds = page.bounds(for: .mediaBox)
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
            else {
                continue
            }

            context.setFillColor(CGColor.white)
            context.fill(CGRect(x: 0, y: 0, width: intWidth, height: intHeight))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)

            guard let cgImage = context.makeImage() else { continue }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: bounds.width, height: bounds.height))
            if let pngData = image.pngData() {
                images.append(pngData)
            }
        }

        return images
    }

    private static func decodePluginImportResponse(
        _ rawResponse: String,
        fallbackFilename: String,
        fallbackFileSize: Int
    ) throws -> [Attachment] {
        if let data = rawResponse.data(using: .utf8),
            let response = try? JSONDecoder().decode(PluginFileImportResponse.self, from: data)
        {
            return response.attachments.map {
                .document(
                    filename: $0.filename ?? fallbackFilename,
                    content: $0.content,
                    fileSize: $0.file_size ?? fallbackFileSize
                )
            }
        }

        let trimmed = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileImportError.pluginImportFailed("Plugin returned an empty response")
        }
        return [.document(filename: fallbackFilename, content: trimmed, fileSize: fallbackFileSize)]
    }

    private static func preferredMimeType(for url: URL, descriptor: FileImportDescriptor) -> String? {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
            let mimeType = contentType.preferredMIMEType
        {
            return mimeType
        }

        if let inferred = UTType(filenameExtension: url.pathExtension.lowercased()),
            let mimeType = inferred.preferredMIMEType
        {
            return mimeType
        }

        return descriptor.mimeTypes.first
    }

    private struct BuiltInFileImporter: FileImporter {
        let descriptor: FileImportDescriptor
        private let handler: @Sendable (URL) throws -> [Attachment]

        init(
            descriptor: FileImportDescriptor,
            handler: @escaping @Sendable (URL) throws -> [Attachment]
        ) {
            self.descriptor = descriptor
            self.handler = handler
        }

        func importFile(at url: URL) async throws -> [Attachment] {
            try handler(url)
        }
    }

    private struct PluginBackedFileImporter: FileImporter {
        let descriptor: FileImportDescriptor
        let plugin: ExternalPlugin
        let toolId: String

        func importFile(at url: URL) async throws -> [Attachment] {
            let fileSize = (try? FileImportService.fileSize(for: url)) ?? 0
            let request = PluginFileImportRequest(
                path: url.path,
                filename: url.lastPathComponent,
                file_extension: url.pathExtension.lowercased(),
                mime_type: FileImportService.preferredMimeType(for: url, descriptor: descriptor),
                max_bytes: descriptor.maxBytes,
                max_chars: FileImportService.maxParsedTextLength,
                output_mode: descriptor.outputMode.rawValue,
                output_schema_version: descriptor.outputSchemaVersion
            )
            let payload = try String(decoding: JSONEncoder().encode(request), as: UTF8.self)
            let response = try await plugin.invoke(
                type: "tool",
                id: toolId,
                payload: payload,
                agentId: WorkExecutionContext.currentAgentId
            )
            return try FileImportService.decodePluginImportResponse(
                response,
                fallbackFilename: url.lastPathComponent,
                fallbackFileSize: fileSize
            )
        }
    }

    private struct PluginFileImportRequest: Encodable {
        let path: String
        let filename: String
        let file_extension: String
        let mime_type: String?
        let max_bytes: Int
        let max_chars: Int
        let output_mode: String
        let output_schema_version: Int
    }

    private struct PluginFileImportResponse: Decodable {
        let attachments: [PluginImportedDocument]

        private enum CodingKeys: String, CodingKey {
            case attachments
            case documents
            case content
            case filename
            case file_size
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if let attachments = try container.decodeIfPresent([PluginImportedDocument].self, forKey: .attachments) {
                self.attachments = attachments
                return
            }

            if let attachments = try container.decodeIfPresent([PluginImportedDocument].self, forKey: .documents) {
                self.attachments = attachments
                return
            }

            if let content = try container.decodeIfPresent(String.self, forKey: .content) {
                self.attachments = [
                    PluginImportedDocument(
                        filename: try container.decodeIfPresent(String.self, forKey: .filename),
                        content: content,
                        file_size: try container.decodeIfPresent(Int.self, forKey: .file_size)
                    )
                ]
                return
            }

            throw DecodingError.dataCorruptedError(
                forKey: .attachments,
                in: container,
                debugDescription: "Expected attachments, documents, or content in importer response"
            )
        }
    }

    private struct PluginImportedDocument: Decodable {
        let filename: String?
        let content: String
        let file_size: Int?
    }
}
