//
//  ChatSessionExporterTests.swift
//  osaurusTests
//
//  Regression coverage for chat export attachment recovery and redaction.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatSessionExporterTests {
    @Test func markdownRedactsAttachmentFilenamesToBasename() {
        let session = ChatSessionData(
            title: "Export",
            turns: [
                ChatTurnData(
                    role: .user,
                    content: "",
                    attachments: [
                        Attachment.document(
                            filename: "/Users/mmeding/private/assessment.txt",
                            content: "rubric",
                            fileSize: 6
                        )
                    ]
                )
            ]
        )

        let markdown = ChatSessionExporter.markdown(for: session)

        #expect(markdown.contains("document: assessment.txt"))
        #expect(markdown.contains("/Users/mmeding") == false)
        #expect(markdown.contains("private") == false)
    }

    @Test func markdownRedactsWindowsAndUNCPaths() {
        let session = ChatSessionData(
            title: "Export",
            turns: [
                ChatTurnData(
                    role: .user,
                    content: "",
                    attachments: [
                        Attachment.document(
                            filename: #"C:\Users\Alice\private\assessment.txt"#,
                            content: "rubric",
                            fileSize: 6
                        ),
                        Attachment.audio(
                            Data([0x01]),
                            format: "wav",
                            filename: #"\\server\share\private\voice.wav"#
                        ),
                    ]
                )
            ]
        )

        let markdown = ChatSessionExporter.markdown(for: session)

        #expect(markdown.contains("assessment.txt"))
        #expect(markdown.contains("voice.wav"))
        #expect(markdown.contains("Alice") == false)
        #expect(markdown.contains("server") == false)
        #expect(markdown.contains("private") == false)
    }

    @Test func zipRemapsInlineExtractedDocumentTextToTxt() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-text-tests-\(UUID().uuidString)"
            )
            let unzipRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-text-unzip-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: unzipRoot, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: unzipRoot)
            }

            let attachment = Attachment.document(
                filename: "/Users/mmeding/private/notes.md",
                content: "# Notes\n",
                fileSize: 8
            )
            let session = ChatSessionData(
                title: "Notes Export",
                turns: [
                    ChatTurnData(role: .user, content: "", attachments: [attachment])
                ]
            )
            let zipURL = root.appendingPathComponent("export.zip")

            try await ChatSessionExporter.writeZip(session: session, to: zipURL)
            try await FileManager.default.unzipItem(at: zipURL, to: unzipRoot)

            let exportedMarkdown = unzipRoot
                .appendingPathComponent("Notes Export", isDirectory: true)
                .appendingPathComponent("chat.md")
            let exportedDocument = unzipRoot
                .appendingPathComponent("Notes Export", isDirectory: true)
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent("notes.txt")
            let markdown = try String(contentsOf: exportedMarkdown, encoding: .utf8)

            #expect(FileManager.default.fileExists(atPath: exportedDocument.path))
            #expect(
                FileManager.default.fileExists(
                    atPath: exportedDocument.deletingLastPathComponent().appendingPathComponent("notes.md").path
                ) == false
            )
            #expect(markdown.contains("document: notes.md"))
            #expect(markdown.contains("/Users/mmeding") == false)
        }
    }

    @Test func zipSanitizesDotDotBasenameAfterPathRedaction() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-dotdot-tests-\(UUID().uuidString)"
            )
            let unzipRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-dotdot-unzip-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: unzipRoot, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: unzipRoot)
            }

            let attachment = Attachment.document(
                filename: "/Users/mmeding/..",
                content: "kept inside attachment dir",
                fileSize: 26
            )
            let session = ChatSessionData(
                title: "/Users/mmeding/..",
                turns: [
                    ChatTurnData(role: .user, content: "", attachments: [attachment])
                ]
            )
            let zipURL = root.appendingPathComponent("export.zip")

            try await ChatSessionExporter.writeZip(session: session, to: zipURL)
            try await FileManager.default.unzipItem(at: zipURL, to: unzipRoot)

            let exportedMarkdown = unzipRoot
                .appendingPathComponent("attachment", isDirectory: true)
                .appendingPathComponent("chat.md")
            let exportedAttachment = unzipRoot
                .appendingPathComponent("attachment", isDirectory: true)
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent("attachment.txt")
            let allPaths = try FileManager.default.subpathsOfDirectory(atPath: unzipRoot.path)

            #expect(FileManager.default.fileExists(atPath: exportedMarkdown.path))
            #expect(FileManager.default.fileExists(atPath: exportedAttachment.path))
            #expect(allPaths.contains("../chat.md") == false)
            #expect(allPaths.contains { $0 == "." || $0 == ".." } == false)
        }
    }

    @Test func zipExportsDocumentRefAsRecoveredTextWithoutPrivatePath() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-tests-\(UUID().uuidString)"
            )
            let unzipRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-unzip-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: unzipRoot, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            StorageKeyManager.shared._setKeyForTesting(
                SymmetricKey(data: Data(repeating: 0x46, count: 32))
            )
            defer {
                OsaurusPaths.overrideRoot = nil
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: unzipRoot)
                StorageKeyManager.shared.wipeCache()
            }

            let body = "A,B\n1,2\n"
            let hash = try AttachmentBlobStore.write(Data(body.utf8))
            let attachment = Attachment(
                kind: .documentRef(
                    filename: "/Users/mmeding/private/budget.xlsx",
                    hash: hash,
                    fileSize: body.utf8.count
                )
            )
            let session = ChatSessionData(
                title: "Quarterly Export",
                turns: [
                    ChatTurnData(role: .user, content: "", attachments: [attachment])
                ]
            )
            let zipURL = root.appendingPathComponent("export.zip")

            try await ChatSessionExporter.writeZip(session: session, to: zipURL)
            try await FileManager.default.unzipItem(at: zipURL, to: unzipRoot)

            let exportedDocument = unzipRoot
                .appendingPathComponent("Quarterly Export", isDirectory: true)
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent("budget.txt")
            let exportedMarkdown = unzipRoot
                .appendingPathComponent("Quarterly Export", isDirectory: true)
                .appendingPathComponent("chat.md")
            let exportedText = try String(contentsOf: exportedDocument, encoding: .utf8)
            let markdown = try String(contentsOf: exportedMarkdown, encoding: .utf8)
            let allPaths = try FileManager.default.subpathsOfDirectory(atPath: unzipRoot.path)

            #expect(exportedText == body)
            #expect(markdown.contains("document: budget.xlsx"))
            #expect(markdown.contains("/Users/mmeding") == false)
            #expect(allPaths.contains { $0.contains("mmeding") } == false)
            #expect(allPaths.contains { $0.contains("private") } == false)
            #expect(allPaths.contains { $0.hasSuffix("budget.xlsx") } == false)
        }
    }

    @Test func zipWritesPathFreeProvenanceManifestAndRecordsMissingBlobs() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-provenance-\(UUID().uuidString)"
            )
            let unzipRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-provenance-unzip-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: unzipRoot, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            StorageKeyManager.shared._setKeyForTesting(
                SymmetricKey(data: Data(repeating: 0x47, count: 32))
            )
            defer {
                OsaurusPaths.overrideRoot = nil
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: unzipRoot)
                StorageKeyManager.shared.wipeCache()
            }

            let body = "verified body"
            let digest = Attachment.sha256(Data(body.utf8))
            let provenance = DocumentAttachmentProvenance(
                sourceSHA256: Attachment.sha256(Data("source body".utf8)),
                contentSHA256: digest,
                sourceTrust: .userSelectedLocalFile,
                inspectedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sourceModificationTime: Date(timeIntervalSince1970: 1_699_999_900),
                stableSourceID: Attachment.sha256(Data("stable source".utf8))
            )
            let metadata = StructuredDocumentAttachmentMetadata(
                formatId: "plaintext",
                representationFormatId: "plaintext",
                filename: "report.txt",
                fileSize: Int64(body.utf8.count),
                createdAt: Date(),
                provenance: provenance
            )
            let validHash = try AttachmentBlobStore.write(Data(body.utf8))
            let valid = Attachment(
                kind: .documentRef(
                    filename: "/Users/alice/Secret/report.txt",
                    hash: validHash,
                    fileSize: body.utf8.count
                ),
                structuredDocumentMetadata: metadata
            )
            let missing = Attachment(
                kind: .documentRef(
                    filename: "/Users/alice/Secret/missing.txt",
                    hash: String(repeating: "0", count: 64),
                    fileSize: 12
                ),
                structuredDocumentMetadata: metadata
            )
            let session = ChatSessionData(
                title: "Provenance Export",
                turns: [ChatTurnData(role: .user, content: "", attachments: [valid, missing])]
            )
            let zipURL = root.appendingPathComponent("export.zip")

            try await ChatSessionExporter.writeZip(session: session, to: zipURL)
            try await FileManager.default.unzipItem(at: zipURL, to: unzipRoot)
            let manifestURL = unzipRoot
                .appendingPathComponent("Provenance Export", isDirectory: true)
                .appendingPathComponent("provenance.json")
            let exportedDocumentURL = unzipRoot
                .appendingPathComponent("Provenance Export", isDirectory: true)
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent("report.txt")
            let data = try Data(contentsOf: manifestURL)
            let exportedDocument = try Data(contentsOf: exportedDocumentURL)
            let manifest = try JSONDecoder.iso8601.decode(
                ChatSessionExporter.AttachmentProvenanceManifest.self,
                from: data
            )
            let raw = String(decoding: data, as: UTF8.self)

            #expect(manifest.schemaVersion == 1)
            #expect(manifest.attachments.count == 2)
            #expect(manifest.attachments[0].availability == .verified)
            #expect(manifest.attachments[0].exportedFilename == "report.txt")
            #expect(manifest.attachments[0].provenance == provenance)
            #expect(Attachment.sha256(exportedDocument) == provenance.contentSHA256)
            #expect(manifest.attachments[1].availability == .missing)
            #expect(manifest.attachments[1].exportedFilename == nil)
            #expect(raw.contains("/Users/alice") == false)
            #expect(raw.contains("Secret") == false)
        }
    }

    @Test func zipNeverExportsDocumentContentThatFailsProvenanceVerification() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-integrity-\(UUID().uuidString)"
            )
            let unzipRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-integrity-unzip-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: unzipRoot, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: unzipRoot)
            }

            let expected = "verified original"
            let mutated = "mutated after inspection"
            let provenance = DocumentAttachmentProvenance(
                sourceSHA256: Attachment.sha256(Data("source".utf8)),
                contentSHA256: Attachment.sha256(Data(expected.utf8)),
                sourceTrust: .userSelectedLocalFile,
                inspectedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sourceModificationTime: nil,
                stableSourceID: Attachment.sha256(Data("stable".utf8))
            )
            let attachment = Attachment(
                kind: .document(filename: "report.txt", content: mutated, fileSize: mutated.utf8.count),
                structuredDocumentMetadata: StructuredDocumentAttachmentMetadata(
                    formatId: "plaintext",
                    representationFormatId: "plaintext",
                    filename: "report.txt",
                    fileSize: Int64(mutated.utf8.count),
                    createdAt: Date(),
                    provenance: provenance
                )
            )
            let session = ChatSessionData(
                title: "Integrity Export",
                turns: [ChatTurnData(role: .user, content: "", attachments: [attachment])]
            )
            let zipURL = root.appendingPathComponent("export.zip")

            try await ChatSessionExporter.writeZip(session: session, to: zipURL)
            try await FileManager.default.unzipItem(at: zipURL, to: unzipRoot)
            let bundle = unzipRoot.appendingPathComponent("Integrity Export", isDirectory: true)
            let manifest = try JSONDecoder.iso8601.decode(
                ChatSessionExporter.AttachmentProvenanceManifest.self,
                from: Data(contentsOf: bundle.appendingPathComponent("provenance.json"))
            )
            let attachmentDirectory = bundle.appendingPathComponent("attachments", isDirectory: true)
            let exportedFiles = try FileManager.default.contentsOfDirectory(atPath: attachmentDirectory.path)

            #expect(manifest.attachments.first?.availability == .integrityFailed)
            #expect(manifest.attachments.first?.exportedFilename == nil)
            #expect(exportedFiles.isEmpty)
        }
    }

    @Test func zipVerifiesPageImageBytesAgainstProvenanceBeforeExport() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-image-integrity-\(UUID().uuidString)"
            )
            let unzipRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-export-image-integrity-unzip-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: unzipRoot, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: unzipRoot)
            }

            let verifiedBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x10])
            let mutatedBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x20])
            let provenance = DocumentAttachmentProvenance(
                sourceSHA256: Attachment.sha256(Data("source pdf".utf8)),
                contentSHA256: Attachment.sha256(verifiedBytes),
                sourceTrust: .userSelectedLocalFile,
                inspectedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sourceModificationTime: nil,
                stableSourceID: Attachment.sha256(Data("stable source".utf8))
            )
            func page(_ bytes: Data) -> OsaurusCore.Attachment {
                Attachment(
                    kind: .image(bytes),
                    structuredDocumentMetadata: StructuredDocumentAttachmentMetadata(
                        formatId: "pdf",
                        representationFormatId: "pdf-page-image",
                        filename: "scan.pdf",
                        fileSize: 512,
                        createdAt: Date(),
                        provenance: provenance
                    )
                )
            }
            let session = ChatSessionData(
                title: "Page Image Integrity",
                turns: [
                    ChatTurnData(
                        role: .user,
                        content: "",
                        attachments: [page(verifiedBytes), page(mutatedBytes)]
                    )
                ]
            )
            let zipURL = root.appendingPathComponent("export.zip")

            try await ChatSessionExporter.writeZip(session: session, to: zipURL)
            try await FileManager.default.unzipItem(at: zipURL, to: unzipRoot)
            let bundle = unzipRoot.appendingPathComponent("Page Image Integrity", isDirectory: true)
            let manifest = try JSONDecoder.iso8601.decode(
                ChatSessionExporter.AttachmentProvenanceManifest.self,
                from: Data(contentsOf: bundle.appendingPathComponent("provenance.json"))
            )
            let exportedName = try #require(manifest.attachments[0].exportedFilename)
            let exportedBytes = try Data(
                contentsOf: bundle.appendingPathComponent("attachments").appendingPathComponent(exportedName)
            )

            #expect(manifest.attachments[0].availability == .verified)
            #expect(Attachment.sha256(exportedBytes) == provenance.contentSHA256)
            #expect(exportedBytes == verifiedBytes)
            #expect(manifest.attachments[1].availability == .integrityFailed)
            #expect(manifest.attachments[1].exportedFilename == nil)
        }
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
