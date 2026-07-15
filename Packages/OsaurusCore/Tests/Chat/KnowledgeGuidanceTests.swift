//
//  KnowledgeGuidanceTests.swift
//  OsaurusCoreTests — Knowledge
//
//  The `## Knowledge` system-prompt block. Pins the pure renderer
//  `SystemPromptTemplates.knowledgeGuidance(collections:)`: every granted
//  collection's name reaches the prose, the summary rides alongside it as
//  the domain affordance (or is cleanly omitted when blank), and the
//  retrieval nudge names the tools the schema actually carries. The
//  composer-side gate (schema-resolved knowledge tools + non-empty grant
//  list) lives with the other schema-gated section tests.
//

import Foundation
import Testing

@testable import OsaurusCore

struct KnowledgeGuidanceTests {

    @Test func rendersNameAndSummaryPerGrant() {
        let text = SystemPromptTemplates.knowledgeGuidance(collections: [
            KnowledgeGrantDescriptor(
                name: "Dinoco Handbook",
                summary: "Café menu, prices, staff policies, and FAQ."
            ),
            KnowledgeGrantDescriptor(name: "Style Guide", summary: "Writing standards."),
        ])
        #expect(text.hasPrefix("## Knowledge"))
        #expect(text.contains("**Dinoco Handbook** — Café menu, prices, staff policies, and FAQ."))
        #expect(text.contains("**Style Guide** — Writing standards."))
    }

    @Test func blankSummaryOmitsDash() {
        let text = SystemPromptTemplates.knowledgeGuidance(collections: [
            KnowledgeGrantDescriptor(name: "Notes", summary: "   ")
        ])
        #expect(text.contains("- **Notes**\n"))
        #expect(!text.contains("**Notes** —"))
    }

    @Test func retrievalNudgeNamesTheTools() {
        let text = SystemPromptTemplates.knowledgeGuidance(collections: [
            KnowledgeGrantDescriptor(name: "Docs", summary: "Product docs.")
        ])
        #expect(text.contains("`search_knowledge`"))
        #expect(text.contains("`read_knowledge`"))
        #expect(text.contains("`flag_knowledge_stale`"))
    }

    @Test func grantDescriptorSlicesCollection() {
        let collection = KnowledgeCollection(
            name: "Docs", summary: "Product docs.", folderPath: "/tmp/docs")
        let descriptor = collection.grantDescriptor
        #expect(descriptor.name == "Docs")
        #expect(descriptor.summary == "Product docs.")
    }
}
