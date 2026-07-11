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

    @Test func zipPreservesTextBackedDocumentExtension() async throws {
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
                .appendingPathComponent("notes.md")
            let markdown = try String(contentsOf: exportedMarkdown, encoding: .utf8)

            #expect(FileManager.default.fileExists(atPath: exportedDocument.path))
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
                .appendingPathComponent("attachment")
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
}
