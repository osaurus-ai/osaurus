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

    /// The stale-flag bullet must cover USER-REPORTED changes, not just
    /// self-discovered rot — a small model holding an "update the doc"
    /// request and no edit tool otherwise punts instead of filing the
    /// ticket (live-observed with Ornith-1.0-9B, 2026-07-15).
    @Test func updateRequestsRouteToStaleFlag() {
        let text = SystemPromptTemplates.knowledgeGuidance(collections: [
            KnowledgeGrantDescriptor(name: "Docs", summary: "Product docs.")
        ])
        #expect(text.contains("asks you to update"))
        #expect(text.contains("cannot edit collection documents"))
    }

    @Test func curatorLineOnlyForCurators() {
        let grants = [KnowledgeGrantDescriptor(name: "Docs", summary: "Product docs.")]
        let plain = SystemPromptTemplates.knowledgeGuidance(collections: grants)
        let curator = SystemPromptTemplates.knowledgeGuidance(
            collections: grants, curator: true)
        #expect(!plain.contains("`propose_knowledge_update`"))
        #expect(curator.contains("`propose_knowledge_update`"))
        #expect(curator.contains("`flag_knowledge_stale`"))
    }

    /// Compact-prompt models only ever see the FIRST sentence of a tool
    /// description (`oneLineToolDescription`, ≤180 chars). The stale-flag
    /// tool's routing rule — update request ⇒ file a ticket — must
    /// therefore fit inside that first sentence, or small models lose it
    /// entirely (live-observed with Ornith-1.0-9B, 2026-07-15).
    @Test func staleFlagRoutingSurvivesFirstSentenceTruncation() {
        let description = FlagKnowledgeStaleTool().description
        let firstSentence = String(
            description[..<(description.range(of: ". ")?.lowerBound ?? description.endIndex)])
        #expect(firstSentence.count <= 180)
        #expect(firstSentence.contains("update request"))
        #expect(firstSentence.contains("cannot be edited"))
    }

    @Test func grantDescriptorSlicesCollection() {
        let collection = KnowledgeCollection(
            name: "Docs", summary: "Product docs.", folderPath: "/tmp/docs")
        let descriptor = collection.grantDescriptor
        #expect(descriptor.name == "Docs")
        #expect(descriptor.summary == "Product docs.")
    }
}
