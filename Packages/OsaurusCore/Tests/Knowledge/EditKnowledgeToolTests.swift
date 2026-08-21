//
//  EditKnowledgeToolTests.swift
//  OsaurusCoreTests — Knowledge
//
//  `edit_knowledge` exists because whole-document replacement cannot edit a
//  large document at all.
//
//  A 14.5KB file is already around a small local model's output token cap, so
//  asking it to restate the document to change one repeated phrase does not
//  merely run slowly — it truncates, and the truncated text then REPLACES the
//  original. Observed live: a 120 section catalogue came back with 6 sections
//  and the other 114 were destroyed, reported as a routine "1 replaced".
//
//  These tests pin the substitution semantics. The safety properties around
//  them (approval card, write log, revert) are inherited from the write path
//  and covered there.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct EditKnowledgeToolTests {

    private typealias Edit = KnowledgeWriteService.KnowledgeEdit

    private func apply(_ edits: [Edit], to content: String) -> Result<
        String, KnowledgeWriteService.KnowledgeEditFailure
    > {
        KnowledgeWriteService.applyEdits(edits, to: content)
    }

    // MARK: - The case that motivated the tool

    /// The 120 section catalogue, edited by sending ~60 bytes instead of
    /// 14.5KB. Nothing outside the substitution can be lost, because nothing
    /// outside it is ever regenerated.
    @Test func aSweepingEditTouchesEveryOccurrenceAndKeepsEverythingElse() throws {
        let catalogue =
            "---\ntitle: Alert Catalogue\ntype: reference\n---\n\n# Alert Catalogue\n\n"
            + (1 ... 120)
            .map { "## ALERT-\($0)\n\nFires. First response: check the dashboard.\n" }
            .joined(separator: "\n")

        let result = try apply(
            [Edit(find: "check the dashboard", replace: "check the runbook first", all: true)],
            to: catalogue
        ).get()

        #expect(result.components(separatedBy: "check the runbook first").count - 1 == 120)
        #expect(!result.contains("check the dashboard"))
        // Every section, and the frontmatter, survive untouched.
        #expect(result.components(separatedBy: "## ALERT-").count - 1 == 120)
        #expect(result.hasPrefix("---\ntitle: Alert Catalogue"))
    }

    // MARK: - Match discipline

    /// Editing the wrong occurrence of an ambiguous string is the silent
    /// corruption this is meant to prevent, so a non-unique match is an error
    /// rather than a guess at which one was meant.
    @Test func anAmbiguousMatchIsRejectedRatherThanGuessed() {
        let content = "alpha\nbeta\nalpha\n"
        guard case .failure(let failure) = apply([Edit(find: "alpha", replace: "gamma")], to: content)
        else {
            Issue.record("an ambiguous find must not be applied")
            return
        }
        #expect(failure == .ambiguous(find: "alpha", matches: 2))
        #expect(failure.message.contains("appears 2 times"))
        // The message has to name both ways out.
        #expect(failure.message.contains("more surrounding text"))
        #expect(failure.message.contains("`all`"))
    }

    @Test func anUnmatchedFindIsRejected() {
        guard case .failure(let failure) = apply(
            [Edit(find: "nowhere", replace: "x")], to: "hello\n")
        else {
            Issue.record("a find that matches nothing must fail")
            return
        }
        #expect(failure == .notFound(find: "nowhere"))
        #expect(failure.message.contains("exactly as written"))
    }

    @Test func anEmptyFindIsRejected() {
        guard case .failure(let failure) = apply([Edit(find: "", replace: "x")], to: "hello")
        else {
            Issue.record("an empty find would match everywhere")
            return
        }
        #expect(failure == .emptyFind)
    }

    /// A long `find` is excerpted in the error so the message stays readable,
    /// but must still identify what failed.
    @Test func failureMessagesExcerptLongFinds() {
        let long = String(repeating: "x", count: 200)
        guard case .failure(let failure) = apply([Edit(find: long, replace: "")], to: "y") else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.message.count < 200)
        #expect(failure.message.contains("…"))
    }

    // MARK: - Sequencing

    /// Edits apply in order, so a later one sees the result of an earlier one.
    @Test func editsApplyInOrder() throws {
        let result = try apply(
            [
                Edit(find: "one", replace: "two"),
                Edit(find: "two", replace: "three"),
            ],
            to: "one\n"
        ).get()
        #expect(result == "three\n")
    }

    /// Multi-line finds are how a model targets a whole section precisely.
    @Test func multiLineFindsWork() throws {
        let content = "# Doc\n\n## Step 4\n\nAnnounce it.\n"
        let result = try apply(
            [Edit(find: "## Step 4\n\nAnnounce it.", replace: "## Step 4\n\nAnnounce it.\n\n## Step 5\n\nVerify lag.")],
            to: content
        ).get()
        #expect(result.contains("## Step 5"))
        #expect(result.contains("## Step 4"))
    }

    /// An empty `replace` is a deletion, which is legitimate.
    @Test func emptyReplaceDeletesTheMatch() throws {
        let result = try apply([Edit(find: "remove me\n", replace: "")], to: "keep\nremove me\n").get()
        #expect(result == "keep\n")
    }

    /// One failed edit means NOTHING is written: the caller gets the error and
    /// the document is untouched, so a partially applied batch is impossible.
    @Test func aFailedEditAbandonsTheWholeBatch() {
        let content = "alpha\nbeta\n"
        let result = apply(
            [
                Edit(find: "alpha", replace: "gamma"),
                Edit(find: "nowhere", replace: "x"),
            ],
            to: content
        )
        guard case .failure = result else {
            Issue.record("a batch containing a bad edit must fail as a whole")
            return
        }
    }

    // MARK: - Arguments

    private func edits(_ args: [String: Any]) -> EditKnowledgeTool.EditsResult {
        EditKnowledgeTool.edits(from: args, tool: "edit_knowledge")
    }

    @Test func editsArrayParses() {
        let result = edits([
            "edits": [
                ["find": "a", "replace": "b"],
                ["find": "c", "replace": "d", "all": true],
            ]
        ])
        guard case .success(let parsed) = result else {
            Issue.record("valid edits were rejected")
            return
        }
        #expect(parsed == [Edit(find: "a", replace: "b"), Edit(find: "c", replace: "d", all: true)])
    }

    /// A model handed an array parameter reliably sends one of each shape.
    @Test func singularFindReplaceIsAccepted() {
        guard case .success(let parsed) = edits(["find": "a", "replace": "b"]) else {
            Issue.record("singular shape rejected")
            return
        }
        #expect(parsed == [Edit(find: "a", replace: "b")])
    }

    @Test func missingOrEmptyEditsAreRejected() {
        for args in [[:], ["edits": []], ["rationale": "why"]] as [[String: Any]] {
            #expect(edits(args).failureEnvelope?.contains("No edits to apply") == true)
        }
    }

    /// Past a point an edit list is a rewrite in disguise, and should go
    /// through the path where the whole document is reviewed.
    @Test func tooManyEditsIsRejectedAndPointsAtWriteKnowledge() {
        let many = (0...EditKnowledgeTool.maxEditsPerCall).map {
            ["find": "f\($0)", "replace": "r"]
        }
        let envelope = edits(["edits": many]).failureEnvelope
        #expect(envelope?.contains("exceeds the limit") == true)
        #expect(envelope?.contains("write_knowledge") == true)
    }

    // MARK: - Gating

    @Test func asksForApprovalAndIsDeniedExternally() {
        #expect(EditKnowledgeTool().defaultPermissionPolicy == .ask)
        #expect(ToolRegistry.externallyDeniedToolNames.contains("edit_knowledge"))
        #expect(!ToolRegistry.unattendedAutoApprovableToolNames.contains("edit_knowledge"))
    }

    /// Its argument contract lives in property descriptions, which first-turn
    /// compaction strips unless the tool is exempt.
    @Test func argumentContractSurvivesBootstrapCompaction() {
        let compact = SystemPromptComposer.forcedCompactBootstrapSpec(
            EditKnowledgeTool().asOpenAITool()
        )
        #expect(compact.function.parameters == EditKnowledgeTool().asOpenAITool().function.parameters)
        #expect(SystemPromptComposer.knowledgeToolNames.contains("edit_knowledge"))
    }
}
