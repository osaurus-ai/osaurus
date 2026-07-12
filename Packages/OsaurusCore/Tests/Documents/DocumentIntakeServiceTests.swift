import Foundation
import Testing

@testable import OsaurusCore

@Suite("Document intake and provenance", .serialized)
struct DocumentIntakeServiceTests {
    @Test func previewAttachmentIdentityIsPathFreeAndCodable() async throws {
        let registry = DocumentFormatRegistry()
        registry.register(adapter: FixtureAdapter(formatId: "intake", extensions: ["intake"]))
        let service = DocumentIntakeService(studio: BusinessDocumentStudioService(registry: registry))
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private-report.intake")
        try Data("source bytes".utf8).write(to: url)

        let preview = try await service.prepare(url: url)
        let attachment = preview.attachment

        #expect(attachment.loadDocumentContent() == "parsed source bytes")
        #expect(attachment.verifiedDocumentContent() == "parsed source bytes")
        #expect(attachment.structuredDocumentMetadata?.provenance == preview.provenance)
        #expect(preview.provenance.sourceSHA256 == Attachment.sha256(Data("source bytes".utf8)))
        #expect(preview.provenance.stableSourceID.count == 64)

        let encoded = try JSONEncoder().encode(attachment)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(json.contains(root.path) == false)
        #expect(json.contains("private-report.intake"))
        let decoded = try JSONDecoder().decode(Attachment.self, from: encoded)
        #expect(decoded == attachment)
        #expect(decoded.verifiedDocumentContent() == "parsed source bytes")
    }

    @Test func parserCannotMutatePrivateCapturedSource() async throws {
        let registry = DocumentFormatRegistry()
        registry.register(adapter: MutatingFixtureAdapter())
        let service = DocumentIntakeService(studio: BusinessDocumentStudioService(registry: registry))
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mutable.mutating-intake")
        try Data("before".utf8).write(to: url)

        do {
            _ = try await service.prepare(url: url)
            Issue.record("Expected the parser's attempted write to the immutable capture to fail")
        } catch {
            #expect(try String(contentsOf: url, encoding: .utf8) == "before")
        }
    }

    @Test func replaceAndRestoreAttackCannotChangeParsedBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.restore-intake")
        let original = Data("trusted original".utf8)
        try original.write(to: url)
        let registry = DocumentFormatRegistry()
        registry.register(adapter: RestoreAttackAdapter(originalURL: url))
        let service = DocumentIntakeService(studio: BusinessDocumentStudioService(registry: registry))

        let preview = try await service.prepare(url: url)

        #expect(preview.document.textFallback == "parsed trusted original")
        #expect(preview.provenance.sourceSHA256 == Attachment.sha256(original))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func symbolicLinkSourceIsRejectedBeforeParsing() async throws {
        let registry = DocumentFormatRegistry()
        registry.register(adapter: FixtureAdapter(formatId: "intake", extensions: ["intake"]))
        let service = DocumentIntakeService(studio: BusinessDocumentStudioService(registry: registry))
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.intake")
        let link = root.appendingPathComponent("link.intake")
        try Data("source".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        await #expect(throws: DocumentIntakeError.sourceIsNotRegularFile) {
            _ = try await service.prepare(url: link)
        }
    }

    @Test(arguments: [
        ("oversized.txt", DocumentLimits.plainText),
        ("oversized.csv", Int64(DocumentParser.maxFileSize)),
        ("oversized.pptx", Int64(DocumentParser.maxFileSize)),
    ])
    func formatAwareCapRejectsBeforeHashingOrParsing(filename: String, limit: Int64) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(limit + 1))
        try handle.close()

        await #expect(throws: DocumentIntakeError.sourceTooLarge(limit)) {
            _ = try await DocumentIntakeService().prepare(url: url)
        }
    }

    @Test func imageOnlyPDFFallbackRejectsSymlinkBeforeParser() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("scan.pdf")
        let link = root.appendingPathComponent("scan-link.pdf")
        try Data("pdf".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let service = DocumentIntakeService(pdfFallbackParser: { _ in
            Issue.record("Parser must not run for a symbolic link")
            return [.image(Data([0x01]))]
        })

        await #expect(throws: DocumentIntakeError.sourceIsNotRegularFile) {
            _ = try await service.prepareImageOnlyPDFFallback(url: link)
        }
    }

    @Test func imageOnlyPDFFallbackParserCannotMutatePrivateCapture() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("scan.pdf")
        try Data("before".utf8).write(to: url)
        let service = DocumentIntakeService(pdfFallbackParser: { source in
            try Data("after mutation".utf8).write(to: source, options: .atomic)
            return [.image(Data([0x01, 0x02]))]
        })

        do {
            _ = try await service.prepareImageOnlyPDFFallback(url: url)
            Issue.record("Expected the PDF parser's attempted write to the immutable capture to fail")
        } catch {
            #expect(try String(contentsOf: url, encoding: .utf8) == "before")
        }
    }

    @Test func imageOnlyPDFReplaceAndRestoreAttackUsesCapturedBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("scan.pdf")
        let original = Data("trusted pdf".utf8)
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        try original.write(to: url)
        let service = DocumentIntakeService(pdfFallbackParser: { capturedURL in
            try Data("attacker replacement".utf8).write(to: url, options: .atomic)
            try original.write(to: url, options: .atomic)
            #expect(capturedURL != url)
            #expect(try Data(contentsOf: capturedURL) == original)
            return [.image(image)]
        })

        let attachments = try #require(try await service.prepareImageOnlyPDFFallback(url: url))
        let provenance = try #require(attachments.first?.structuredDocumentMetadata?.provenance)
        #expect(provenance.sourceSHA256 == Attachment.sha256(original))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func imageOnlyPDFFallbackCarriesPathFreeVerifiedProvenance() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private-scan.pdf")
        let source = Data("source pdf".utf8)
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        try source.write(to: url)
        let service = DocumentIntakeService(pdfFallbackParser: { _ in [.image(image)] })

        let attachments = try #require(try await service.prepareImageOnlyPDFFallback(url: url))
        let attachment = try #require(attachments.first)
        let provenance = try #require(attachment.structuredDocumentMetadata?.provenance)
        #expect(attachment.loadImageData() == image)
        #expect(provenance.sourceSHA256 == Attachment.sha256(source))
        #expect(provenance.contentSHA256 == Attachment.sha256(image))
        #expect(provenance.sourceTrust == .unknown)
        #expect(attachment.structuredDocumentMetadata?.representationFormatId == "pdf-page-image")

        let json = String(decoding: try JSONEncoder().encode(attachment), as: UTF8.self)
        #expect(json.contains(root.path) == false)
    }

    @Test func sourceTrustIsCallerOwnedAndNeverImplicitlyUpgraded() async throws {
        let registry = DocumentFormatRegistry()
        registry.register(adapter: FixtureAdapter(formatId: "intake", extensions: ["intake"]))
        let service = DocumentIntakeService(studio: BusinessDocumentStudioService(registry: registry))
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("trust.intake")
        try Data("trust".utf8).write(to: url)

        let unknown = try await service.prepare(url: url)
        let plugin = try await service.prepare(url: url, sourceTrust: .pluginProvided)
        let composer = try await service.prepareForComposer(url: url)

        #expect(unknown.provenance.sourceTrust == .unknown)
        #expect(unknown.document.security.sourceTrust == .unknown)
        #expect(plugin.provenance.sourceTrust == .pluginProvided)
        #expect(plugin.document.security.sourceTrust == .pluginProvided)
        guard case .preview(let composerPreview) = composer else {
            Issue.record("Expected a structured composer preview")
            return
        }
        #expect(composerPreview.provenance.sourceTrust == .userSelectedLocalFile)
        #expect(composerPreview.document.security.sourceTrust == .userSelectedLocalFile)
    }

    @Test func intakeAndConversionMessagesDoNotExposePathsOrRawErrors() {
        let secret = "/Users/alice/TopSecret/report.pdf"
        let raw = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Denied: \(secret)"])
        let intake = DocumentIntakeError.userFacingMessage(for: raw)
        let conversion = DocumentIntakeError.conversionMessage(for: raw)
        let studio = BusinessDocumentStudioError.writeFailed.localizedDescription

        #expect(intake.contains(secret) == false)
        #expect(intake.contains("Denied") == false)
        #expect(conversion.contains(secret) == false)
        #expect(conversion.contains("Denied") == false)
        #expect(studio.contains(secret) == false)
        #expect(studio.contains("Denied") == false)
    }

    @Test @MainActor func cancelledNonCooperativeParseCannotPublishStalePreview() async throws {
        let stale = try Self.makePreview(filename: "stale.txt", content: "stale")
        let coordinator = DocumentIntakeCoordinator { _ in
            try? await Task.sleep(for: .milliseconds(80))
            return stale
        }
        coordinator.enqueue([URL(fileURLWithPath: "/tmp/stale.txt")])
        coordinator.cancelAll()
        try await Task.sleep(for: .milliseconds(140))

        #expect(coordinator.preview == nil)
        #expect(coordinator.isPreparing == false)
    }

    @Test @MainActor func attachmentReceiptFiresOnlyAfterSuccessfulAttach() async throws {
        let ready = try Self.makePreview(filename: "ready.txt", content: "ready")
        var receipts = 0
        let coordinator = DocumentIntakeCoordinator { _ in ready }
        coordinator.enqueue(
            [URL(fileURLWithPath: "/tmp/ready.txt")],
            onAttached: { receipts += 1 }
        )
        try await Self.waitUntil { coordinator.preview != nil }

        _ = coordinator.attachCurrent()
        #expect(receipts == 0)
        coordinator.confirmCurrentAttachment()
        #expect(receipts == 1)

        coordinator.enqueue(
            [URL(fileURLWithPath: "/tmp/cancelled.txt")],
            onAttached: { receipts += 1 }
        )
        try await Self.waitUntil { coordinator.preview != nil }
        coordinator.skipCurrent()
        #expect(receipts == 1)
    }

    @Test @MainActor func failedAndCancelledPreparationDoNotConsumeAttachmentReceipt() async throws {
        var receipts = 0
        let failed = DocumentIntakeCoordinator(prepareResult: { _ in
            throw DocumentIntakeError.sourceReadFailed
        })
        failed.enqueue(
            [URL(fileURLWithPath: "/tmp/failed.txt")],
            onAttached: { receipts += 1 }
        )
        try await Self.waitUntil { failed.isPreparing == false }
        #expect(receipts == 0)

        let cancelled = DocumentIntakeCoordinator(prepareResult: { _ in
            try await Task.sleep(for: .seconds(1))
            return .attachments([.image(Data([0x01]))])
        })
        cancelled.enqueue(
            [URL(fileURLWithPath: "/tmp/cancelled.pdf")],
            onImmediateAttachments: { _ in receipts += 100 },
            onAttached: { receipts += 1 }
        )
        cancelled.cancelAll()
        try await Task.sleep(for: .milliseconds(30))
        #expect(receipts == 0)
    }

    @Test @MainActor func immediatePageImagesPublishThenConsumeAttachmentReceipt() async throws {
        var attached: [OsaurusCore.Attachment] = []
        var receipts = 0
        let page = Attachment.image(Data([0x89, 0x50]))
        let coordinator = DocumentIntakeCoordinator(prepareResult: { _ in .attachments([page]) })
        coordinator.enqueue(
            [URL(fileURLWithPath: "/tmp/scan.pdf")],
            onImmediateAttachments: { attached = $0 },
            onAttached: { receipts += 1 }
        )
        try await Self.waitUntil { coordinator.isPreparing == false }

        #expect(attached == [page])
        #expect(receipts == 1)
    }

    @Test func activeContentFactsSurviveAttachmentRoundTrip() async throws {
        let registry = DocumentFormatRegistry()
        registry.register(
            adapter: FixtureAdapter(
                formatId: "active",
                extensions: ["active"],
                activeContent: true
            )
        )
        let service = DocumentIntakeService(studio: BusinessDocumentStudioService(registry: registry))
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("macro.active")
        try Data("macro source".utf8).write(to: url)

        let preview = try await service.prepare(url: url)
        #expect(preview.inspection.security.hasActiveContent)
        #expect(preview.inspection.security.findings.contains { $0.kind == .macro })
        #expect(preview.attachment.structuredDocumentMetadata?.hasActiveContent == true)
        #expect(preview.attachment.structuredDocumentMetadata?.maximumSeverity == .high)
    }

    @Test func conversionRequiresExplicitOverwriteConsent() async throws {
        let preview = try Self.makePreview(filename: "notes.txt", content: "replacement")
        guard let option = preview.inspection.exportOptions.first(where: { $0.targetFormatId == "txt" }) else {
            Issue.record("missing text export option")
            return
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("converted.txt")
        try Data("original".utf8).write(to: output)
        let service = DocumentIntakeService()

        await #expect(throws: BusinessDocumentStudioError.self) {
            _ = try await service.convert(preview, option: option, to: output, allowOverwrite: false)
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == "original")

        _ = try await service.convert(preview, option: option, to: output, allowOverwrite: true)
        #expect(try String(contentsOf: output, encoding: .utf8) == "replacement")
    }

    private static func makePreview(filename: String, content: String) throws -> DocumentIntakePreview {
        let document = StructuredDocument(
            formatId: "plaintext",
            filename: filename,
            fileSize: Int64(content.utf8.count),
            representation: AnyStructuredRepresentation(
                formatId: "plaintext",
                underlying: PlainTextRepresentation(text: content)
            ),
            security: DocumentSecurityMetadata(
                inspectionStatus: .inspected,
                sourceTrust: .userSelectedLocalFile,
                formatId: "plaintext",
                fileExtension: "txt"
            ),
            textFallback: content
        )
        let inspection = try BusinessDocumentStudioService(registry: DocumentFormatRegistry()).inspect(document)
        let digest = Attachment.sha256(Data(content.utf8))
        return DocumentIntakePreview(
            document: document,
            inspection: inspection,
            provenance: DocumentAttachmentProvenance(
                sourceSHA256: digest,
                contentSHA256: digest,
                sourceTrust: .userSelectedLocalFile,
                inspectedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sourceModificationTime: Date(timeIntervalSince1970: 1_699_999_999),
                stableSourceID: Attachment.sha256(Data("stable:\(digest)".utf8))
            )
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-document-intake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private struct FixtureAdapter: DocumentFormatAdapter {
        let formatId: String
        let extensions: Set<String>
        var activeContent = false

        func canHandle(url: URL, uti: String?) -> Bool {
            extensions.contains(url.pathExtension.lowercased())
        }

        func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
            let source = try String(contentsOf: url, encoding: .utf8)
            let parsed = "parsed \(source)"
            let security = DocumentSecurityMetadata(
                inspectionStatus: .inspected,
                sourceTrust: .userSelectedLocalFile,
                formatId: formatId,
                fileExtension: url.pathExtension,
                activeContentTypes: activeContent ? [.macro] : [],
                findings: activeContent
                    ? [DocumentSecurityFinding(kind: .macro, severity: .high, message: "Macro content detected.")]
                    : []
            )
            return StructuredDocument(
                formatId: formatId,
                filename: url.lastPathComponent,
                fileSize: Int64(Data(source.utf8).count),
                representation: AnyStructuredRepresentation(
                    formatId: formatId,
                    underlying: PlainTextRepresentation(text: parsed)
                ),
                security: security,
                textFallback: parsed
            )
        }
    }

    private struct MutatingFixtureAdapter: DocumentFormatAdapter {
        let formatId = "mutating-intake"
        let extensions: Set<String> = ["mutating-intake"]

        func canHandle(url: URL, uti: String?) -> Bool { true }

        func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
            try Data("after mutation".utf8).write(to: url, options: .atomic)
            return StructuredDocument(
                formatId: formatId,
                filename: url.lastPathComponent,
                fileSize: 14,
                representation: AnyStructuredRepresentation(
                    formatId: formatId,
                    underlying: PlainTextRepresentation(text: "parsed")
                ),
                textFallback: "parsed"
            )
        }
    }

    private struct RestoreAttackAdapter: DocumentFormatAdapter {
        let formatId = "restore-intake"
        let extensions: Set<String> = ["restore-intake"]
        let originalURL: URL

        func canHandle(url: URL, uti: String?) -> Bool { true }

        func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
            let original = try Data(contentsOf: originalURL)
            try Data("attacker replacement".utf8).write(to: originalURL, options: .atomic)
            try original.write(to: originalURL, options: .atomic)
            let captured = try String(contentsOf: url, encoding: .utf8)
            return StructuredDocument(
                formatId: formatId,
                filename: url.lastPathComponent,
                fileSize: Int64(captured.utf8.count),
                representation: AnyStructuredRepresentation(
                    formatId: formatId,
                    underlying: PlainTextRepresentation(text: captured)
                ),
                textFallback: "parsed \(captured)"
            )
        }
    }
}
