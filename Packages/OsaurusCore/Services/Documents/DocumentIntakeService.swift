//
//  DocumentIntakeService.swift
//  osaurus
//
//  Chat-native document intake: parse, inspect, establish path-free
//  provenance, then hand an immutable preview to the composer.
//

import CryptoKit
import Darwin
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

struct DocumentAttachmentIntakePreview: Sendable, Identifiable {
    let id = UUID()
    let filename: String
    let attachments: [Attachment]
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

    public func prepare(
        url: URL,
        sourceTrust: DocumentSecurityMetadata.SourceTrust = .unknown
    ) async throws -> DocumentIntakePreview {
        let limit = try studio.chatIntakeLimit(for: url)
        let captured = try Self.capture(url: url, maximumBytes: limit)
        let privateSource = try Self.materialize(captured, originalURL: url)
        defer { Self.removePrivateSource(privateSource) }
        return try await prepareCaptured(
            originalURL: url,
            privateURL: privateSource.fileURL,
            captured: captured,
            sourceTrust: sourceTrust
        )
    }

    private func prepareCaptured(
        originalURL: URL,
        privateURL: URL,
        captured: CapturedSource,
        sourceTrust: DocumentSecurityMetadata.SourceTrust
    ) async throws -> DocumentIntakePreview {
        try Task.checkCancellation()

        let parsed = try await studio.parse(url: privateURL)
        try Task.checkCancellation()
        let document = Self.restoringSourceFacts(
            parsed,
            originalURL: originalURL,
            captured: captured,
            sourceTrust: sourceTrust
        )
        let inspection = try studio.inspect(document)

        let provenance = Self.provenance(
            sourceDigest: captured.digest,
            content: Data(document.textFallback.utf8),
            trust: sourceTrust,
            inspectedAt: document.security.inspectedAt,
            modificationDate: captured.modificationDate
        )
        return DocumentIntakePreview(
            document: document,
            inspection: inspection,
            provenance: provenance
        )
    }

    func prepareForComposer(url: URL) async throws -> DocumentIntakePreparedResult {
        let trust = DocumentSecurityMetadata.SourceTrust.userSelectedLocalFile
        let limit = try studio.chatIntakeLimit(for: url)
        let captured = try Self.capture(url: url, maximumBytes: limit)
        let privateSource = try Self.materialize(captured, originalURL: url)
        defer { Self.removePrivateSource(privateSource) }
        if url.pathExtension.lowercased() == "pdf",
            let pageImages = try imageOnlyAttachments(
                originalURL: url,
                privateURL: privateSource.fileURL,
                captured: captured,
                sourceTrust: trust
            )
        {
            return .attachments(pageImages)
        }
        return .preview(
            try await prepareCaptured(
                originalURL: url,
                privateURL: privateSource.fileURL,
                captured: captured,
                sourceTrust: trust
            )
        )
    }

    /// Returns rendered page-image attachments only when the selected PDF has
    /// no text representation. The same bounded snapshot/digest contract used
    /// by structured intake protects this compatibility fallback.
    public func prepareImageOnlyPDFFallback(
        url: URL,
        sourceTrust: DocumentSecurityMetadata.SourceTrust = .unknown
    ) async throws -> [Attachment]? {
        guard url.pathExtension.lowercased() == "pdf" else { return nil }
        let limit = try studio.chatIntakeLimit(for: url)
        let captured = try Self.capture(url: url, maximumBytes: limit)
        let privateSource = try Self.materialize(captured, originalURL: url)
        defer { Self.removePrivateSource(privateSource) }
        return try imageOnlyAttachments(
            originalURL: url,
            privateURL: privateSource.fileURL,
            captured: captured,
            sourceTrust: sourceTrust
        )
    }

    private func imageOnlyAttachments(
        originalURL: URL,
        privateURL: URL,
        captured: CapturedSource,
        sourceTrust: DocumentSecurityMetadata.SourceTrust
    ) throws -> [Attachment]? {
        try Task.checkCancellation()
        let attachments = try pdfFallbackParser(privateURL)
        try Task.checkCancellation()

        guard !attachments.isEmpty, attachments.allSatisfy(\.isImage) else { return nil }
        let inspectedAt = Date()
        return try attachments.map { attachment in
            guard let imageBytes = attachment.unverifiedImageData() else {
                throw DocumentIntakeError.sourceReadFailed
            }
            let provenance = Self.provenance(
                sourceDigest: captured.digest,
                content: imageBytes,
                trust: sourceTrust,
                inspectedAt: inspectedAt,
                modificationDate: captured.modificationDate
            )
            return Attachment(
                id: attachment.id,
                kind: attachment.kind,
                structuredDocumentMetadata: StructuredDocumentAttachmentMetadata(
                    formatId: "pdf",
                    representationFormatId: "pdf-page-image",
                    filename: originalURL.lastPathComponent,
                    fileSize: captured.size,
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

    private struct CapturedSource: Sendable {
        let data: Data
        let size: Int64
        let modificationDate: Date?
        let digest: String
    }

    private struct PrivateSource {
        let directoryURL: URL
        let fileURL: URL
    }

    private static func capture(url: URL, maximumBytes: Int64) throws -> CapturedSource {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw DocumentIntakeError.sourceIsNotRegularFile }
            throw DocumentIntakeError.sourceReadFailed
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var facts = stat()
        guard Darwin.fstat(descriptor, &facts) == 0 else {
            try? handle.close()
            throw DocumentIntakeError.sourceReadFailed
        }
        guard facts.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            throw DocumentIntakeError.sourceIsNotRegularFile
        }
        guard facts.st_size <= maximumBytes else {
            try? handle.close()
            throw DocumentIntakeError.sourceTooLarge(maximumBytes)
        }

        do {
            defer { try? handle.close() }
            var bytes = Data()
            bytes.reserveCapacity(Int(max(0, facts.st_size)))
            var hasher = SHA256()
            var total: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                total += Int64(chunk.count)
                guard total <= maximumBytes else { throw DocumentIntakeError.sourceTooLarge(maximumBytes) }
                bytes.append(chunk)
                hasher.update(data: chunk)
            }
            let modified = Date(
                timeIntervalSince1970: TimeInterval(facts.st_mtimespec.tv_sec)
                    + TimeInterval(facts.st_mtimespec.tv_nsec) / 1_000_000_000
            )
            return CapturedSource(
                data: bytes,
                size: total,
                modificationDate: modified,
                digest: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
        } catch let error as DocumentIntakeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DocumentIntakeError.sourceReadFailed
        }
    }

    private static func materialize(_ captured: CapturedSource, originalURL: URL) throws -> PrivateSource {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-document-intake-\(UUID().uuidString)", isDirectory: true)
        let filename = Attachment.redactedFilename(from: originalURL.lastPathComponent)
        let file = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try captured.data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            return PrivateSource(directoryURL: directory, fileURL: file)
        } catch {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
            throw DocumentIntakeError.sourceReadFailed
        }
    }

    private static func removePrivateSource(_ source: PrivateSource) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: source.directoryURL.path
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.fileURL.path)
        try? FileManager.default.removeItem(at: source.directoryURL)
    }

    private static func restoringSourceFacts(
        _ document: StructuredDocument,
        originalURL: URL,
        captured: CapturedSource,
        sourceTrust: DocumentSecurityMetadata.SourceTrust
    ) -> StructuredDocument {
        let security = document.security
        let correctedSecurity = DocumentSecurityMetadata(
            inspectionStatus: security.inspectionStatus,
            sourceTrust: sourceTrust,
            formatId: security.formatId,
            fileExtension: security.fileExtension,
            uti: security.uti,
            declaredMimeType: security.declaredMimeType,
            sha256: captured.digest,
            isEncrypted: security.isEncrypted,
            activeContentTypes: security.activeContentTypes,
            externalReferences: security.externalReferences,
            findings: security.findings,
            inspectedAt: security.inspectedAt
        )
        return StructuredDocument(
            formatId: document.formatId,
            filename: originalURL.lastPathComponent,
            fileSize: captured.size,
            representation: document.representation,
            structure: document.structure,
            security: correctedSecurity,
            textFallback: document.textFallback,
            createdAt: document.createdAt
        )
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
            sourceTrust: trust,
            inspectedAt: inspectedAt,
            sourceModificationTime: modificationDate,
            stableSourceID: stableID
        )
    }
}

@MainActor
final class DocumentIntakeCoordinator: ObservableObject {
    @Published private(set) var preview: DocumentIntakePreview?
    @Published private(set) var attachmentPreview: DocumentAttachmentIntakePreview?
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
    private var currentOnImmediateAttachments: (([Attachment]) -> Void)?
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

    func confirmCurrentAttachments() {
        guard let attachments = attachmentPreview?.attachments else { return }
        currentOnImmediateAttachments?(attachments)
        currentOnAttached?()
        attachmentPreview = nil
        currentOnImmediateAttachments = nil
        currentOnAttached = nil
        advanceAfterDismissal()
    }

    func skipCurrent() {
        guard preview != nil || attachmentPreview != nil else { return }
        preview = nil
        attachmentPreview = nil
        currentOnImmediateAttachments = nil
        currentOnAttached = nil
        advanceAfterDismissal()
    }

    func cancelAll() {
        generation = UUID()
        task?.cancel()
        task = nil
        pendingRequests.removeAll()
        preview = nil
        attachmentPreview = nil
        currentOnImmediateAttachments = nil
        currentOnAttached = nil
        isPreparing = false
        errorMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    private func startNextIfNeeded() {
        guard preview == nil, attachmentPreview == nil, task == nil, !pendingRequests.isEmpty else { return }
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
                    self.attachmentPreview = DocumentAttachmentIntakePreview(
                        filename: pending.url.lastPathComponent,
                        attachments: attachments
                    )
                    currentOnImmediateAttachments = pending.onImmediateAttachments
                    currentOnAttached = pending.onAttached
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
            if preview == nil, attachmentPreview == nil { startNextIfNeeded() }
        }
    }

    private func advanceAfterDismissal() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.startNextIfNeeded()
        }
    }
}
