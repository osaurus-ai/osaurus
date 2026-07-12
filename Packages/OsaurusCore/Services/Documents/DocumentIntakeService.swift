//
//  DocumentIntakeService.swift
//  osaurus
//
//  Chat-native document intake: parse, inspect, establish path-free
//  provenance, then hand an immutable preview to the composer.
//

import CryptoKit
import Foundation

public struct DocumentIntakePreview: Sendable, Identifiable {
    public let id: UUID
    public let document: StructuredDocument
    public let inspection: BusinessDocumentStudioInspection
    public let provenance: DocumentAttachmentProvenance

    public init(
        id: UUID = UUID(),
        document: StructuredDocument,
        inspection: BusinessDocumentStudioInspection,
        provenance: DocumentAttachmentProvenance
    ) {
        self.id = id
        self.document = document
        self.inspection = inspection
        self.provenance = provenance
    }

    public var attachment: Attachment {
        .structuredDocument(document, provenance: provenance)
    }
}

enum DocumentIntakePreparedResult: Sendable {
    case preview(DocumentIntakePreview)
    case attachments([Attachment])
}

public enum DocumentIntakeError: LocalizedError, Equatable {
    case sourceIsNotRegularFile
    case sourceChangedDuringInspection
    case sourceTooLarge(Int64)
    case sourceReadFailed

    public var errorDescription: String? {
        switch self {
        case .sourceIsNotRegularFile:
            return "The selected document is not a regular file."
        case .sourceChangedDuringInspection:
            return "The document changed while it was being inspected. Select it again to review the current version."
        case .sourceTooLarge(let limit):
            return "The document exceeds the \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) intake limit."
        case .sourceReadFailed:
            return "Could not read the selected document safely."
        }
    }

    public static func userFacingMessage(for error: Error) -> String {
        if let intake = error as? DocumentIntakeError {
            return intake.errorDescription ?? "Document intake failed."
        }
        if let studio = error as? BusinessDocumentStudioError {
            return studio.errorDescription ?? "Document intake failed."
        }
        return "The document could not be inspected safely."
    }

    public static func conversionMessage(for error: Error) -> String {
        if let studio = error as? BusinessDocumentStudioError {
            return studio.errorDescription ?? "Document conversion failed."
        }
        return "Document conversion failed. Check destination permissions and try again."
    }
}

public struct DocumentIntakeService: Sendable {
    private let studio: BusinessDocumentStudioService
    private let pdfFallbackParser: @Sendable (URL) throws -> [Attachment]

    public init(studio: BusinessDocumentStudioService = BusinessDocumentStudioService()) {
        self.studio = studio
        self.pdfFallbackParser = { try DocumentParser.parseAll(url: $0) }
    }

    init(
        studio: BusinessDocumentStudioService = BusinessDocumentStudioService(),
        pdfFallbackParser: @escaping @Sendable (URL) throws -> [Attachment]
    ) {
        self.studio = studio
        self.pdfFallbackParser = pdfFallbackParser
    }

    public func prepare(url: URL) async throws -> DocumentIntakePreview {
        let limit = try studio.chatIntakeLimit(for: url)
        let before = try Self.snapshot(url: url, maximumBytes: limit)
        let sourceDigest = try Self.digest(url: url, maximumBytes: limit)
        try Task.checkCancellation()

        let document = try await studio.parse(url: url)
        try Task.checkCancellation()
        let inspection = try studio.inspect(document)

        let after = try Self.snapshot(url: url, maximumBytes: limit)
        let afterDigest = try Self.digest(url: url, maximumBytes: limit)
        guard before == after, sourceDigest == afterDigest else {
            throw DocumentIntakeError.sourceChangedDuringInspection
        }

        let provenance = Self.provenance(
            sourceDigest: sourceDigest,
            content: Data(document.textFallback.utf8),
            trust: document.security.sourceTrust,
            inspectedAt: document.security.inspectedAt,
            modificationDate: before.modificationDate
        )
        return DocumentIntakePreview(
            document: document,
            inspection: inspection,
            provenance: provenance
        )
    }

    func prepareForComposer(url: URL) async throws -> DocumentIntakePreparedResult {
        if let pageImages = try await prepareImageOnlyPDFFallback(url: url) {
            return .attachments(pageImages)
        }
        return .preview(try await prepare(url: url))
    }

    /// Returns rendered page-image attachments only when the selected PDF has
    /// no text representation. The same bounded snapshot/digest contract used
    /// by structured intake protects this compatibility fallback.
    public func prepareImageOnlyPDFFallback(url: URL) async throws -> [Attachment]? {
        guard url.pathExtension.lowercased() == "pdf" else { return nil }
        let limit = try studio.chatIntakeLimit(for: url)
        let before = try Self.snapshot(url: url, maximumBytes: limit)
        let sourceDigest = try Self.digest(url: url, maximumBytes: limit)
        try Task.checkCancellation()
        let attachments = try pdfFallbackParser(url)
        try Task.checkCancellation()

        let after = try Self.snapshot(url: url, maximumBytes: limit)
        let afterDigest = try Self.digest(url: url, maximumBytes: limit)
        guard before == after, sourceDigest == afterDigest else {
            throw DocumentIntakeError.sourceChangedDuringInspection
        }
        guard !attachments.isEmpty, attachments.allSatisfy(\.isImage) else { return nil }
        let inspectedAt = Date()
        return try attachments.map { attachment in
            guard let imageBytes = attachment.unverifiedImageData() else {
                throw DocumentIntakeError.sourceReadFailed
            }
            let provenance = Self.provenance(
                sourceDigest: sourceDigest,
                content: imageBytes,
                trust: .userSelectedLocalFile,
                inspectedAt: inspectedAt,
                modificationDate: before.modificationDate
            )
            return Attachment(
                id: attachment.id,
                kind: attachment.kind,
                structuredDocumentMetadata: StructuredDocumentAttachmentMetadata(
                    formatId: "pdf",
                    representationFormatId: "pdf-page-image",
                    filename: url.lastPathComponent,
                    fileSize: before.size,
                    createdAt: inspectedAt,
                    fileExtension: "pdf",
                    documentKind: .pdf,
                    inspectionStatus: .partiallyInspected,
                    provenance: provenance
                )
            )
        }
    }

    public func convert(
        _ preview: DocumentIntakePreview,
        option: BusinessDocumentStudioExportOption,
        to destination: URL,
        allowOverwrite: Bool
    ) async throws -> BusinessDocumentStudioExportResult {
        guard option.canExport else {
            throw BusinessDocumentStudioError.unsupportedExport(
                sourceFormatId: preview.document.formatId,
                targetFormatId: option.targetFormatId
            )
        }
        try Task.checkCancellation()
        let result = try await studio.export(
            preview.document,
            as: option.targetFormatId,
            to: destination,
            policy: BusinessDocumentStudioExportPolicy(allowOverwrite: allowOverwrite)
        )
        try Task.checkCancellation()
        return result
    }

    private struct SourceSnapshot: Equatable {
        let size: Int64
        let modificationDate: Date?
    }

    private static func snapshot(url: URL, maximumBytes: Int64) throws -> SourceSnapshot {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DocumentIntakeError.sourceIsNotRegularFile
        }
        let size = Int64(values.fileSize ?? 0)
        guard size <= maximumBytes else { throw DocumentIntakeError.sourceTooLarge(maximumBytes) }
        return SourceSnapshot(size: size, modificationDate: values.contentModificationDate)
    }

    private static func digest(url: URL, maximumBytes: Int64) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var total: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                total += Int64(chunk.count)
                guard total <= maximumBytes else { throw DocumentIntakeError.sourceTooLarge(maximumBytes) }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch let error as DocumentIntakeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DocumentIntakeError.sourceReadFailed
        }
    }

    private static func provenance(
        sourceDigest: String,
        content: Data,
        trust: DocumentSecurityMetadata.SourceTrust,
        inspectedAt: Date,
        modificationDate: Date?
    ) -> DocumentAttachmentProvenance {
        let stableID = Attachment.sha256(Data("osaurus-document-source-v1:\(sourceDigest)".utf8))
        return DocumentAttachmentProvenance(
            sourceSHA256: sourceDigest,
            contentSHA256: Attachment.sha256(content),
            sourceTrust: trust == .unknown ? .userSelectedLocalFile : trust,
            inspectedAt: inspectedAt,
            sourceModificationTime: modificationDate,
            stableSourceID: stableID
        )
    }
}

@MainActor
final class DocumentIntakeCoordinator: ObservableObject {
    @Published private(set) var preview: DocumentIntakePreview?
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?

    private struct PendingRequest {
        let url: URL
        let onImmediateAttachments: ([Attachment]) -> Void
        let onAttached: (() -> Void)?
    }

    private var pendingRequests: [PendingRequest] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var currentOnAttached: (() -> Void)?
    private let prepare: @Sendable (URL) async throws -> DocumentIntakePreparedResult

    init(service: DocumentIntakeService = DocumentIntakeService()) {
        self.prepare = { try await service.prepareForComposer(url: $0) }
    }

    init(prepare: @escaping @Sendable (URL) async throws -> DocumentIntakePreview) {
        self.prepare = { .preview(try await prepare($0)) }
    }

    init(prepareResult: @escaping @Sendable (URL) async throws -> DocumentIntakePreparedResult) {
        self.prepare = prepareResult
    }

    func enqueue(
        _ urls: [URL],
        onImmediateAttachments: @escaping ([Attachment]) -> Void = { _ in },
        onAttached: (() -> Void)? = nil
    ) {
        errorMessage = nil
        pendingRequests.append(
            contentsOf: urls.map {
                PendingRequest(
                    url: $0,
                    onImmediateAttachments: onImmediateAttachments,
                    onAttached: onAttached
                )
            }
        )
        startNextIfNeeded()
    }

    func attachCurrent() -> Attachment? {
        let attachment = preview?.attachment
        preview = nil
        return attachment
    }

    func confirmCurrentAttachment() {
        currentOnAttached?()
        currentOnAttached = nil
        advanceAfterDismissal()
    }

    func skipCurrent() {
        guard preview != nil else { return }
        preview = nil
        currentOnAttached = nil
        advanceAfterDismissal()
    }

    func cancelAll() {
        generation = UUID()
        task?.cancel()
        task = nil
        pendingRequests.removeAll()
        preview = nil
        currentOnAttached = nil
        isPreparing = false
        errorMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    private func startNextIfNeeded() {
        guard preview == nil, task == nil, !pendingRequests.isEmpty else { return }
        let pending = pendingRequests.removeFirst()
        let request = UUID()
        generation = request
        isPreparing = true
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await prepare(pending.url)
                guard !Task.isCancelled, generation == request else { return }
                switch result {
                case .preview(let preview):
                    self.preview = preview
                    currentOnAttached = pending.onAttached
                case .attachments(let attachments):
                    pending.onImmediateAttachments(attachments)
                    pending.onAttached?()
                }
            } catch is CancellationError {
                // Cancellation is user intent, not an error toast.
            } catch {
                guard generation == request else { return }
                errorMessage = DocumentIntakeError.userFacingMessage(for: error)
            }
            guard generation == request else { return }
            task = nil
            isPreparing = false
            if preview == nil { startNextIfNeeded() }
        }
    }

    private func advanceAfterDismissal() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.startNextIfNeeded()
        }
    }
}
