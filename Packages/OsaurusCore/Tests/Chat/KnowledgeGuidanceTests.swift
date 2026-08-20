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
    @Test func updateRequestsRouteToWriteKnowledge() {
        let text = Self.guidance()
        #expect(text.contains("`write_knowledge`"))
        #expect(text.contains("`delete_knowledge`"))
        // Both of these were true of the old architecture and are false now.
        #expect(!text.contains("cannot edit collection documents"))
        #expect(!text.contains("propose_knowledge_update"))
    }

    /// Tickets survive, for the case they were always right for: drift the
    /// agent NOTICES but is not being asked to fix. That is a note to a
    /// human, not the route for an update request.
    @Test func staleFlagIsScopedToUnaskedDrift() {
        let text = Self.guidance()
        #expect(text.contains("`flag_knowledge_stale`"))
        #expect(text.contains("not the current task"))
    }

    /// One batched call per task, not one call per document. The 62-document
    /// import is the shape that has to survive.
    @Test func guidanceInsistsOnOneBatchedCall() {
        #expect(Self.guidance().contains("one call is one approval"))
    }

    /// A write lands immediately, so the model must verify instead of
    /// assuming. Reporting unverified work is what made osaurus#2439 take a
    /// day.
    @Test func guidanceRequiresVerifyingAWrite() {
        let text = Self.guidance()
        #expect(text.contains("Confirm with `search_knowledge`"))
        #expect(text.contains("never report work you have not verified"))
    }

    /// Still true, and still load-bearing: having a real write path does not
    /// make a sandbox file a knowledge document. This is the line that stops
    /// the model improvising a destination when something goes wrong.
    @Test func sandboxWritesAreStillNeverKnowledgeDocuments() {
        let text = Self.guidance()
        #expect(text.contains("NEVER creates a knowledge document"))
        #expect(text.contains("it is not an indexing delay"))
    }

    private static func guidance() -> String {
        SystemPromptTemplates.knowledgeGuidance(collections: [
            KnowledgeGrantDescriptor(name: "Docs", summary: "Product docs.")
        ])
    }

    /// Compact-prompt models only ever see the FIRST sentence of a tool
    /// description (`oneLineToolDescription`, ≤180 chars), so the routing
    /// rule has to fit inside it or small models lose it entirely
    /// (live-observed with Ornith-1.0-9B, 2026-07-15).
    ///
    /// The rule INVERTED when the corpus became writable: it used to be
    /// "update request ⇒ file a ticket" because nothing could edit a
    /// document. Now a ticket is only for drift nobody asked about, and the
    /// first sentence has to say so, or every update request goes back
    /// through a queue that no longer leads anywhere.
    @Test func staleFlagRoutingSurvivesFirstSentenceTruncation() {
        let description = FlagKnowledgeStaleTool().description
        let firstSentence = String(
            description[..<(description.range(of: ". ")?.lowerBound ?? description.endIndex)])
        #expect(firstSentence.count <= 180)
        #expect(firstSentence.contains("NOT the current task"))
        #expect(!firstSentence.contains("cannot be edited"))
    }

    /// The redirect to the real write path has to be in the description too,
    /// since a model reaching for this tool on an update request needs to be
    /// sent somewhere.
    @Test func staleFlagPointsAtTheWritePath() {
        #expect(FlagKnowledgeStaleTool().description.contains("`write_knowledge`"))
    }

    @Test func grantDescriptorSlicesCollection() {
        let collection = KnowledgeCollection(
            name: "Docs", summary: "Product docs.", folderPath: "/tmp/docs")
        let descriptor = collection.grantDescriptor
        #expect(descriptor.name == "Docs")
        #expect(descriptor.summary == "Product docs.")
    }
}
