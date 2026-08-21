//
//  KnowledgeWritePreviewTests.swift
//  OsaurusCoreTests — Knowledge
//
//  The manifest the approval modal renders for a pending knowledge write.
//
//  Everything about moving consent to call time rests on this being honest:
//  the operation shown must be what would actually happen, not what the model
//  claimed; a path that cannot be applied must be visible BEFORE approval
//  rather than failing halfway through an approved batch; and truncation must
//  be admitted rather than implying the reader saw the whole document.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct KnowledgeWritePreviewTests {

    /// A real folder on disk: the builder resolves create vs replace by
    /// reading it, so an in-memory fixture would test nothing.
    private func withCollection(
        _ body: (KnowledgeCollection, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-knowledge-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = KnowledgeCollection(name: "packaging", folderPath: root.path)
        try body(collection, root)
    }

    private func seed(_ root: URL, _ relPath: String, _ content: String) throws {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }

    // MARK: - Operation resolution

    /// The agent does not get to declare create vs replace. A model that
    /// believes it is creating a fresh document while silently clobbering an
    /// existing one is exactly the osaurus#2439 failure, and the modal has to
    /// show the truth.
    @Test func operationIsResolvedFromDiskNotFromTheCall() throws {
        try withCollection { collection, root in
            try seed(root, "existing.md", "# Existing\n\nold body\n")

            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [
                    ("existing.md", "# Existing\n\nnew body\n"),
                    ("brand-new.md", "# New\n"),
                ],
                isDelete: false,
                rationale: "refresh"
            )

            #expect(preview.entries.count == 2)
            #expect(preview.entries[0].operation == .replace)
            #expect(preview.entries[1].operation == .create)
            #expect(preview.replaceCount == 1)
            #expect(preview.createCount == 1)
        }
    }

    @Test func replaceCarriesADiffAgainstWhatIsOnDisk() throws {
        try withCollection { collection, root in
            try seed(root, "a.md", "line one\nline two\n")

            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("a.md", "line one\nline CHANGED\n")],
                isDelete: false,
                rationale: ""
            )

            let entry = try #require(preview.entries.first)
            #expect(entry.diff.contains("-line two"))
            #expect(entry.diff.contains("+line CHANGED"))
            #expect(entry.addedLines == 1)
            #expect(entry.removedLines == 1)
        }
    }

    /// A brand-new one-line file is `+1 -0`, never `+1 -1`. An empty side has
    /// zero lines, not one empty line.
    @Test func createCountsNoPhantomRemoval() throws {
        try withCollection { collection, _ in
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("new.md", "only line\n")],
                isDelete: false,
                rationale: ""
            )
            let entry = try #require(preview.entries.first)
            #expect(entry.operation == .create)
            #expect(entry.removedLines == 0)
        }
    }

    // MARK: - Deletes

    @Test func deleteShowsTheContentThatWouldBeLost() throws {
        try withCollection { collection, root in
            try seed(root, "doomed.md", "a\nb\nc\n")

            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("doomed.md", "")],
                isDelete: true,
                rationale: "wrong version"
            )

            let entry = try #require(preview.entries.first)
            #expect(entry.operation == .delete)
            #expect(entry.deletedContent == "a\nb\nc\n")
            #expect(entry.isValid)
            #expect(preview.deleteCount == 1)
        }
    }

    /// Deleting something that is not there is surfaced before approval,
    /// not as a mid-batch error afterwards.
    @Test func deletingAMissingDocumentIsFlaggedUpFront() throws {
        try withCollection { collection, _ in
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("ghost.md", "")],
                isDelete: true,
                rationale: ""
            )
            let entry = try #require(preview.entries.first)
            #expect(!entry.isValid)
            #expect(entry.problem == "No document at this path.")
            #expect(preview.invalidCount == 1)
        }
    }

    // MARK: - Invalid entries

    /// A partly-invalid batch must be visible in the manifest. Approving and
    /// then discovering half the paths were rejected is the shape of failure
    /// this whole change exists to remove.
    @Test func unappliableEntriesAppearInTheManifestWithTheirReason() throws {
        try withCollection { collection, _ in
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [
                    ("fine.md", "ok"),
                    ("../escape.md", "nope"),
                    ("manual.pdf", "nope"),
                ],
                isDelete: false,
                rationale: ""
            )

            #expect(preview.entries.count == 3)
            #expect(preview.entries[0].isValid)
            #expect(!preview.entries[1].isValid)
            #expect(!preview.entries[2].isValid)
            #expect(preview.entries[1].problem?.contains("outside the collection") == true)
            #expect(preview.entries[2].problem?.contains("not a markdown document") == true)
            #expect(preview.invalidCount == 2)
            #expect(preview.summary.contains("2 cannot be applied"))
        }
    }

    // MARK: - Truncation

    /// Scrolling a 2MB diff is not reviewing. The cap is fine; pretending the
    /// whole document was shown is not.
    @Test func oversizedDiffsAreCappedAndSaySo() throws {
        try withCollection { collection, root in
            try seed(root, "big.md", String(repeating: "old line\n", count: 8000))

            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("big.md", String(repeating: "new line\n", count: 8000))],
                isDelete: false,
                rationale: ""
            )

            let entry = try #require(preview.entries.first)
            // Capped by `WorkspaceWriteSafety` (80 lines / 12K chars), the same
            // cap the chat diff-card uses, so both surfaces agree.
            #expect(entry.diffTruncated)
            #expect(entry.diff.count < 20_000)
        }
    }

    /// A delete has no diff, so its content needs its own bound. Without one a
    /// 62-document delete of large files lands whole in the modal.
    @Test func deletePreviewIsCapped() throws {
        try withCollection { collection, root in
            let huge = String(repeating: "x", count: 60_000)
            try seed(root, "huge.md", huge)

            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("huge.md", "")],
                isDelete: true,
                rationale: ""
            )
            let entry = try #require(preview.entries.first)
            #expect(
                entry.deletedContent.count
                    == KnowledgeWritePreviewBuilder.maxDeletePreviewCharacters
            )
        }
    }

    /// No entry may carry a full document for a create or replace: the diff is
    /// the rendering, and duplicating prior + new content per entry would put
    /// well over 100MB behind the 62-document batch that motivated batching in
    /// the first place.
    @Test func createAndReplaceEntriesCarryNoFullDocumentText() throws {
        try withCollection { collection, root in
            let big = String(repeating: "line\n", count: 50_000)
            try seed(root, "replaced.md", big)

            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("replaced.md", big + "tail\n"), ("created.md", big)],
                isDelete: false,
                rationale: ""
            )

            for entry in preview.entries {
                #expect(entry.deletedContent.isEmpty)
                // Only the capped diff survives onto the entry.
                #expect(entry.diff.count < 20_000)
            }
        }
    }

    // MARK: - Summary

    @Test func summaryReadsAsASentence() throws {
        try withCollection { collection, root in
            try seed(root, "replaced.md", "old")
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("replaced.md", "new"), ("added.md", "x")],
                isDelete: false,
                rationale: ""
            )
            #expect(preview.summary == "2 documents in \"packaging\": 1 new, 1 replaced.")
            // UI copy convention: no em dashes.
            #expect(!preview.summary.contains("—"))
        }
    }

    @Test func singleDocumentSummaryIsSingular() throws {
        try withCollection { collection, _ in
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("one.md", "x")],
                isDelete: false,
                rationale: ""
            )
            #expect(preview.summary == "1 document in \"packaging\": 1 new.")
        }
    }

    // MARK: - Argument parsing

    @Test func batchArgumentsParse() throws {
        try withCollection { collection, _ in
            let json = """
                {"collection":"packaging","rationale":"import the 4.1 docs",
                 "documents":[{"path":"a.md","content":"A"},{"path":"b.md","content":"B"}]}
                """
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                argumentsJSON: json,
                isDelete: false
            )
            #expect(preview.entries.map(\.relPath) == ["a.md", "b.md"])
            #expect(preview.rationale == "import the 4.1 docs")
        }
    }

    /// A model handed an array parameter reliably sends one of each shape.
    /// Rejecting the singular form would surface as an unexplained modal
    /// failure rather than a write.
    @Test func singularArgumentShapeIsAccepted() throws {
        try withCollection { collection, _ in
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                argumentsJSON: #"{"path":"solo.md","content":"S"}"#,
                isDelete: false
            )
            #expect(preview.entries.map(\.relPath) == ["solo.md"])
            #expect(preview.entries.first?.operation == .create)
        }
    }

    @Test func deleteArgumentsAcceptPathsArrayAndSinglePath() throws {
        try withCollection { collection, root in
            try seed(root, "x.md", "x")
            try seed(root, "y.md", "y")

            let many = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                argumentsJSON: #"{"paths":["x.md","y.md"],"rationale":"stale"}"#,
                isDelete: true
            )
            #expect(many.entries.map(\.relPath) == ["x.md", "y.md"])
            #expect(many.deleteCount == 2)

            let one = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                argumentsJSON: #"{"path":"x.md"}"#,
                isDelete: true
            )
            #expect(one.entries.map(\.relPath) == ["x.md"])
        }
    }

    // MARK: - Destructive rewrites

    /// The data loss this caught in live testing. Asked to change one sentence
    /// in every section of a 120-section catalogue, the model returned two
    /// sections. The write was accepted as a routine "1 replaced" and 118
    /// sections were destroyed, because the diff is capped at 80 lines long
    /// before the scale of the deletion becomes visible.
    @Test func aReplacementThatGutsTheDocumentIsFlagged() throws {
        try withCollection { collection, root in
            let catalogue = (1 ... 120)
                .map { "## ALERT-\($0)\n\nFires when subsystem \($0) trips.\n" }
                .joined(separator: "\n")
            try seed(root, "alerts.md", "# Alert Catalogue\n\n" + catalogue)

            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("alerts.md", "# Alert Catalogue\n\n## ALERT-1\n\nFires.\n")],
                isDelete: false,
                rationale: ""
            )
            let entry = try #require(preview.entries.first)
            let warning = try #require(entry.warnings.first { $0.contains("removing about") })
            #expect(warning.contains("lines"))
            // And it must say the diff is not showing the whole deletion,
            // because that is precisely why this slipped through.
            #expect(warning.contains("does not show everything being deleted"))
        }
    }

    /// Exact before/after counts, so a capped diff cannot understate the
    /// change. The +/- pair is derived from the SHOWN fragment.
    @Test func lineCountsReflectTheWholeDocumentNotTheShownDiff() throws {
        try withCollection { collection, root in
            try seed(root, "big.md", String(repeating: "old line\n", count: 500))
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("big.md", "just one line\n")],
                isDelete: false,
                rationale: ""
            )
            let entry = try #require(preview.entries.first)
            #expect(entry.priorLineCount == 500)
            #expect(entry.newLineCount == 1)
            // The capped diff cannot have carried 500 removals.
            #expect(entry.removedLines < entry.priorLineCount)
        }
    }

    /// An ordinary edit is not a gutting, and must stay quiet.
    @Test func aNormalEditIsNotFlaggedAsGutting() throws {
        try withCollection { collection, root in
            let body = (1 ... 40).map { "Line \($0)" }.joined(separator: "\n")
            try seed(root, "a.md", body + "\n")
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("a.md", body.replacingOccurrences(of: "Line 7", with: "Line SEVEN") + "\n")],
                isDelete: false,
                rationale: ""
            )
            #expect(preview.entries.first?.warnings.isEmpty == true)
        }
    }

    /// A short document has no meaningful ratio, so trimming it is not
    /// treated as destruction.
    @Test func shrinkingATinyDocumentIsNotFlagged() throws {
        try withCollection { collection, root in
            try seed(root, "tiny.md", "one\ntwo\nthree\nfour\n")
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("tiny.md", "one\n")],
                isDelete: false,
                rationale: ""
            )
            let gutted = preview.entries.first?.warnings.contains { $0.contains("removing about") }
            #expect(gutted != true)
        }
    }

    // MARK: - Content normalization
    //
    // Read-then-rewrite is the primary use of `write_knowledge`, and both of
    // these were observed live during end-to-end testing on Ornith-1.0-9B.

    /// `read_knowledge` frames a document with a `[Collection] path` header
    /// plus `title:`/`type:`/`tags:` lines. Models copy it verbatim into the
    /// replacement, which would land above the real body.
    @Test func leakedReadFramingIsStrippedBeforeItReachesTheDiff() throws {
        try withCollection { collection, root in
            try seed(root, "a.md", "old\n")
            let leaked = """
                [kb-test] a.md
                title: How to Deploy
                type: guide
                tags: packaging,psadt

                # How to Deploy

                Real body.
                """
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("a.md", leaked)],
                isDelete: false,
                rationale: ""
            )
            let entry = try #require(preview.entries.first)
            #expect(!entry.diff.contains("[kb-test] a.md"))
            #expect(entry.diff.contains("+# How to Deploy"))
        }
    }

    /// A document body that legitimately opens with a bracket link must not be
    /// mistaken for the framing header.
    @Test func ordinaryContentIsNotMistakenForFraming() {
        let refDef = "[docs]: https://example.com\n\nSee the docs."
        #expect(KnowledgeWriteService.strippingReadPreamble(refDef) == refDef)
        let heading = "# Title\n\nBody."
        #expect(KnowledgeWriteService.strippingReadPreamble(heading) == heading)
        let frontmatter = "---\ntype: guide\n---\n\n# Title"
        #expect(KnowledgeWriteService.strippingReadPreamble(frontmatter) == frontmatter)
    }

    /// The variant the stripper cannot catch: frontmatter keys written with no
    /// `---` fences at all. The parser treats them as body text, so the
    /// document silently loses its type and tags and stops answering filtered
    /// searches. Reported on the card rather than auto-corrected, because
    /// rewriting content behind the approved diff would break the promise that
    /// the card shows what lands.
    @Test func unfencedFrontmatterIsFlaggedOnTheEntry() throws {
        try withCollection { collection, _ in
            let unfenced = """
                # PSAppDeployToolkit v2 Notes
                type: guide
                tags: packaging,psadt

                Body text.
                """
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("intro.md", unfenced)],
                isDelete: false,
                rationale: ""
            )
            let entry = try #require(preview.entries.first)
            let warning = try #require(entry.warnings.first)
            #expect(warning.contains("type"))
            #expect(warning.contains("tags"))
            #expect(warning.contains("--- fences"))
            // A caution, not a blocker: the write is still valid.
            #expect(entry.isValid)
        }
    }

    /// The loss the live test actually produced. `read_knowledge` returns the
    /// BODY with the `---` block already stripped, so a model that reads a
    /// document and writes it back drops its frontmatter entirely and the
    /// document stops matching type and tag filters. Warned about, not merged
    /// in silently, so the approved diff stays the truth about what lands.
    @Test func replacingAwayExistingFrontmatterIsFlagged() throws {
        try withCollection { collection, root in
            try seed(
                root, "a.md",
                "---\ntitle: How to Deploy\ntype: guide\ndescription: d\ntags: packaging\n---\n\n# How to Deploy\n\nv3.\n"
            )
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("a.md", "# How to Deploy\n\nv4.1.\n")],
                isDelete: false,
                rationale: ""
            )
            let entry = try #require(preview.entries.first)
            let warning = try #require(entry.warnings.first { $0.contains("loses its") })
            for facet in ["title", "type", "description", "tags"] {
                #expect(warning.contains(facet))
            }
            // Still a valid write: the user may genuinely mean it.
            #expect(entry.isValid)
        }
    }

    /// Carrying the frontmatter across is the correct rewrite and must be
    /// silent.
    @Test func replacementThatKeepsFrontmatterIsNotFlagged() throws {
        try withCollection { collection, root in
            try seed(root, "a.md", "---\ntitle: T\ntype: guide\n---\n\n# T\n\nv3.\n")
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("a.md", "---\ntitle: T\ntype: guide\n---\n\n# T\n\nv4.1.\n")],
                isDelete: false,
                rationale: ""
            )
            #expect(preview.entries.first?.warnings.isEmpty == true)
        }
    }

    /// A brand-new document has nothing to lose, so no frontmatter warning.
    @Test func createWithoutFrontmatterIsNotFlaggedForLoss() throws {
        try withCollection { collection, _ in
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("new.md", "# New\n\nBody.\n")],
                isDelete: false,
                rationale: ""
            )
            #expect(preview.entries.first?.warnings.isEmpty == true)
        }
    }

    @Test func properlyFencedFrontmatterIsNotFlagged() throws {
        try withCollection { collection, _ in
            let fenced = "---\ntitle: Fine\ntype: guide\n---\n\n# Fine\n\nBody."
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                documents: [("ok.md", fenced)],
                isDelete: false,
                rationale: ""
            )
            #expect(preview.entries.first?.warnings.isEmpty == true)
        }
    }

    /// Prose that happens to contain a colon key, or a fenced code example,
    /// must not trip the warning.
    @Test func frontmatterKeysDeepInProseAreNotFlagged() {
        let prose = "# Guide\n\nSet the field as follows.\n\n```yaml\ntype: guide\n```\n"
        #expect(KnowledgeWriteService.unfencedFrontmatterKeys(prose) == nil)
    }

    // MARK: - Consent integrity

    /// The card must show what the tool will RECEIVE, not what the model
    /// literally typed.
    ///
    /// `ToolRegistry` runs the permission gate BEFORE schema coercion, and
    /// coercion upgrades a stringified array into a real one. Without
    /// coercing here too, a model sending `documents` as a JSON string (a
    /// routine small-model slip) produced a card reading "This call could not
    /// be read" while the very same call went on to write every document.
    /// Approving a manifest of nothing and getting a batch of files defeats
    /// the entire point of moving consent to call time.
    @Test func stringifiedArgumentsAreCoercedForThePreview() throws {
        try withCollection { collection, _ in
            let json = #"{"documents":"[{\"path\":\"a.md\",\"content\":\"A\"}]"}"#

            // What the old build showed: unreadable.
            let uncoerced = KnowledgeWritePreviewBuilder.build(
                collection: collection, argumentsJSON: json, isDelete: false
            )
            #expect(uncoerced.parseError != nil)

            // What the tool actually receives, and so what the card must show.
            let coerced = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                argumentsJSON: json,
                isDelete: false,
                schema: WriteKnowledgeTool().parameters
            )
            #expect(coerced.parseError == nil)
            #expect(coerced.entries.map(\.relPath) == ["a.md"])
        }
    }

    /// Same hole on the destructive side: a stringified `paths` array would
    /// have deleted documents the card never listed.
    @Test func stringifiedDeletePathsAreCoercedForThePreview() throws {
        try withCollection { collection, root in
            try seed(root, "doomed.md", "bye\n")
            let json = #"{"paths":"[\"doomed.md\"]","rationale":"stale"}"#

            let coerced = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                argumentsJSON: json,
                isDelete: true,
                schema: DeleteKnowledgeTool().parameters
            )
            #expect(coerced.parseError == nil)
            #expect(coerced.entries.map(\.relPath) == ["doomed.md"])
            #expect(coerced.deleteCount == 1)
        }
    }

    /// Whatever the card renders, the tool's own parser must agree with it,
    /// or the two can drift apart again as either side changes.
    @Test func previewAndToolAgreeOnTheSameCoercedArguments() throws {
        try withCollection { collection, _ in
            let json = #"{"documents":"[{\"path\":\"a.md\",\"content\":\"A\"},{\"path\":\"b.md\",\"content\":\"B\"}]"}"#
            let preview = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                argumentsJSON: json,
                isDelete: false,
                schema: WriteKnowledgeTool().parameters
            )

            // The tool sees arguments already coerced by the registry.
            let coerced = SchemaValidator.coerceArguments(
                try #require(
                    JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]),
                against: try #require(WriteKnowledgeTool().parameters)
            )
            let parsed = WriteKnowledgeTool.documents(
                from: try #require(coerced as? [String: Any]), tool: "write_knowledge")
            guard case .success(let documents) = parsed else {
                Issue.record("tool rejected arguments the card accepted")
                return
            }
            #expect(preview.entries.map(\.relPath) == documents.map(\.path))
        }
    }

    /// The modal must render something for every call. "This could not be
    /// read" is itself a reason to deny, so a parse failure is a preview
    /// state rather than a thrown error.
    @Test func unreadableArgumentsBecomeAVisibleParseError() throws {
        try withCollection { collection, _ in
            let broken = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                argumentsJSON: "not json at all",
                isDelete: false
            )
            #expect(broken.parseError != nil)
            #expect(broken.summary == "This call could not be read.")

            let empty = KnowledgeWritePreviewBuilder.build(
                collection: collection,
                argumentsJSON: #"{"rationale":"nothing here"}"#,
                isDelete: false
            )
            #expect(empty.parseError == "No documents named in this call.")
        }
    }
}
