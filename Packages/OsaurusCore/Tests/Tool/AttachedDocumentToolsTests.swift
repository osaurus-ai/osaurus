//
//  AttachedDocumentToolsTests.swift
//  osaurus
//
//  Verifies that large attached documents remain searchable and readable
//  through the incremental retrieval tools instead of being reduced to the
//  prompt preview only.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AttachedDocumentToolsTests {

    @MainActor
    @Test func registerIfNeeded_exposesAttachedDocumentToolSpecs() {
        AttachedDocumentTools.registerIfNeeded()

        let specs = ToolRegistry.shared.specs(forTools: AttachedDocumentTools.toolNames)
        #expect(specs.count == AttachedDocumentTools.toolNames.count)
        #expect(specs.contains(where: { $0.function.name == "search_attached_documents" }))
        #expect(specs.contains(where: { $0.function.name == "read_attached_document" }))
    }

    @Test func searchAndReadExposeContentBeyondPromptPreview() async throws {
        let repeatedPrefix = String(repeating: "intro filler ", count: 260)
        let marker = "needle-phrase-314159"
        let content =
            repeatedPrefix
            + "\nSection A\n"
            + String(repeating: "middle filler ", count: 120)
            + "\n\(marker) appears deep in the file.\n"
            + String(repeating: "tail filler ", count: 160)
        let attachment = Attachment.document(
            filename: "deep-context.txt",
            content: content,
            fileSize: content.utf8.count
        )

        let references = await AttachedDocumentStore.shared.register(attachments: [attachment])
        #expect(references.count == 1)
        #expect(references[0].preview.contains(marker) == false)

        let searchTool = SearchAttachedDocumentsTool()
        let searchResult = try await searchTool.execute(
            argumentsJSON:
                "{\"attachment_ids\":[\"\(attachment.id.uuidString)\"],\"query\":\"\(marker)\",\"max_results\":2}"
        )
        #expect(searchResult.contains("matching attached-document excerpt"))
        #expect(searchResult.contains(attachment.id.uuidString))
        #expect(searchResult.contains(marker))

        let hits = await AttachedDocumentStore.shared.search(
            attachmentIds: [attachment.id.uuidString],
            query: marker,
            maxResults: 2
        )
        let hit = try #require(hits.first)
        #expect(hit.chunkIndex > 1)

        let readTool = ReadAttachedDocumentTool()
        let readResult = try await readTool.execute(
            argumentsJSON:
                "{\"attachment_id\":\"\(attachment.id.uuidString)\",\"chunk_index\":\(hit.chunkIndex)}"
        )
        #expect(readResult.contains("chunk \(hit.chunkIndex)/\(hit.chunkCount)"))
        #expect(readResult.contains(marker))
        #expect(readResult.contains("appears deep in the file"))
    }

    @Test func readAttachedDocumentRejectsMissingChunk() async throws {
        let tool = ReadAttachedDocumentTool()
        let result = try await tool.execute(argumentsJSON: "{\"attachment_id\":\"missing\",\"chunk_index\":0}")
        #expect(result.contains("chunk_index"))
        #expect(result.contains("positive integer"))
    }

    @Test func searchAcceptsMangledAttachmentIdArraysFromLocalToolCalls() async throws {
        let marker = "needled-deep-271828"
        let content =
            String(repeating: "preface filler ", count: 180)
            + "\n\(marker) appears in the middle.\n"
            + String(repeating: "tail filler ", count: 120)
        let attachment = Attachment.document(
            filename: "mangled-id.txt",
            content: content,
            fileSize: content.utf8.count
        )

        _ = await AttachedDocumentStore.shared.register(attachments: [attachment])

        let tool = SearchAttachedDocumentsTool()
        let result = try await tool.execute(
            argumentsJSON:
                "{\"attachment_ids\":\"[<|\\\"|>\(attachment.id.uuidString)<|\\\"|>]\",\"query\":\"\(marker)\"}"
        )

        #expect(result.contains(marker))
        #expect(result.contains(attachment.id.uuidString))
    }

    @Test func buildPromptContext_onlyUsesRepresentativeFallbackWhenExplicitlyAllowed() async {
        let content =
            String(repeating: "conversation context ", count: 220)
            + "\nCarola says buen viaje and asks how you are.\n"
            + String(repeating: "more context ", count: 180)
        let attachment = Attachment.document(
            filename: "history.txt",
            content: content,
            fileSize: content.utf8.count
        )

        _ = await AttachedDocumentStore.shared.register(attachments: [attachment])

        let withoutFallback = await AttachedDocumentStore.shared.buildPromptContext(
            attachmentIds: [attachment.id.uuidString],
            query: "   ",
            maxResults: 3,
            maxTotalCharacters: 2_400,
            allowFallback: false
        )
        let withFallback = await AttachedDocumentStore.shared.buildPromptContext(
            attachmentIds: [attachment.id.uuidString],
            query: "   ",
            maxResults: 3,
            maxTotalCharacters: 2_400,
            allowFallback: true
        )

        #expect(withoutFallback.isEmpty)
        #expect(withFallback.contains("<attached_document_context>"))
    }

    @Test func buildPromptContext_suppressesFallbackForMultiProfileDocuments() async {
        let content = """
            MICHAEL MEDING
            EXECUTIVE SUMMARY
            AREAS OF EXPERTISE
            RELEVANT EXPERIENCE
            LANGUAGES
            LOS AZULES · ROLE AND RESPONSIBILITIES
            VOLVER

            EMILIO MIRANDA
            EXECUTIVE SUMMARY
            AREAS OF EXPERTISE
            RELEVANT EXPERIENCE
            LANGUAGES
            LOS AZULES · ROLE AND RESPONSIBILITIES
            VOLVER

            MARK NOTHAFT
            EXECUTIVE SUMMARY
            AREAS OF EXPERTISE
            RELEVANT EXPERIENCE
            LANGUAGES
            LOS AZULES · ROLE AND RESPONSIBILITIES
            VOLVER
            """
        let attachment = Attachment.document(
            filename: "Consolidated Resumes.pdf",
            content: content,
            fileSize: content.utf8.count
        )

        _ = await AttachedDocumentStore.shared.register(attachments: [attachment])

        let promptContext = await AttachedDocumentStore.shared.buildPromptContext(
            attachmentIds: [attachment.id.uuidString],
            query: "please recheck",
            maxResults: 3,
            maxTotalCharacters: 2_400,
            allowFallback: true
        )

        #expect(promptContext.isEmpty)
    }
}
