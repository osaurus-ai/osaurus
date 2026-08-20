//
//  WriteKnowledgeToolTests.swift
//  OsaurusCoreTests — Knowledge
//
//  `write_knowledge` argument validation and result reporting.
//
//  The result envelope carries as much weight as the write itself: the reason
//  this tool exists instead of a proposal queue is that the agent must be able
//  to tell exactly what landed. osaurus#2439 was 24 hours of a model guessing
//  because it never could.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct WriteKnowledgeToolTests {

    private func documents(_ args: [String: Any]) -> WriteKnowledgeTool.DocumentsResult {
        WriteKnowledgeTool.documents(from: args, tool: "write_knowledge")
    }

    private func parsed(_ result: WriteKnowledgeTool.DocumentsResult)
        -> [WriteKnowledgeTool.PendingDocument]?
    {
        if case .success(let docs) = result { return docs }
        return nil
    }

    // MARK: - Arguments

    @Test func batchShapeParses() {
        let result = documents([
            "documents": [
                ["path": "a.md", "content": "A"],
                ["path": "b.md", "content": "B"],
            ]
        ])
        #expect(
            parsed(result) == [
                .init(path: "a.md", content: "A"),
                .init(path: "b.md", content: "B"),
            ]
        )
    }

    /// A model handed an array parameter reliably sends one of each shape.
    /// Rejecting the singular form costs a whole turn at ~1 tok/s to relearn a
    /// detail that changes nothing about what the user reviews.
    @Test func singularShapeIsAccepted() {
        let result = documents(["path": "solo.md", "content": "S"])
        #expect(parsed(result) == [.init(path: "solo.md", content: "S")])
    }

    @Test func emptyOrMissingDocumentsIsRejected() {
        for args in [[:], ["documents": []], ["rationale": "why"]] as [[String: Any]] {
            let envelope = try? #require(documents(args).failureEnvelope)
            #expect(envelope?.contains("No documents to write") == true)
        }
    }

    @Test func entryWithoutAPathIsRejected() {
        let result = documents(["documents": [["content": "orphaned"]]])
        #expect(result.failureEnvelope?.contains("non-empty `path`") == true)
    }

    /// Two entries for one path in a single approved batch means the user
    /// reviewed a diff the second write immediately invalidates.
    @Test func duplicatePathsInOneCallAreRejected() {
        let result = documents([
            "documents": [
                ["path": "a.md", "content": "first"],
                ["path": "a.md", "content": "second"],
            ]
        ])
        #expect(result.failureEnvelope?.contains("appears more than once") == true)
    }

    @Test func oversizedDocumentsAreRejectedWithTheirPath() {
        let huge = String(repeating: "x", count: WriteKnowledgeTool.maxContentBytes + 1)
        let result = documents(["documents": [["path": "big.md", "content": huge]]])
        let envelope = try? #require(result.failureEnvelope)
        #expect(envelope?.contains("big.md") == true)
        #expect(envelope?.contains("2MB") == true)
    }

    @Test func tooManyDocumentsInOneCallIsRejected() {
        let many = (0...WriteKnowledgeTool.maxDocumentsPerCall).map {
            ["path": "doc-\($0).md", "content": "x"]
        }
        let result = documents(["documents": many])
        #expect(result.failureEnvelope?.contains("exceeds the limit") == true)
    }

    /// The batch that motivated batching must fit in one call and one approval.
    @Test func aSixtyTwoDocumentImportFitsInOneCall() {
        let batch = (0 ..< 62).map { ["path": "doc-\($0).md", "content": "body"] }
        #expect(parsed(documents(["documents": batch]))?.count == 62)
    }

    // MARK: - Result reporting

    private let collection = KnowledgeCollection(name: "packaging", folderPath: "/tmp/pkg")

    @Test func successReportsEveryPathAndNamesTheVerificationStep() {
        let envelope = WriteKnowledgeTool.resultEnvelope(
            tool: "write_knowledge",
            collection: collection,
            written: [
                .init(relPath: "a.md", operation: .create, recordId: 1),
                .init(relPath: "b.md", operation: .replace, recordId: 2),
            ],
            failures: [],
            runId: "run-1"
        )
        #expect(ToolEnvelope.isSuccess(envelope))
        #expect(envelope.contains("1 created"))
        #expect(envelope.contains("1 replaced"))
        #expect(envelope.contains("a.md"))
        #expect(envelope.contains("b.md"))
        // The loop closure a proposal queue structurally cannot offer.
        #expect(envelope.contains("search_knowledge"))
    }

    /// Partial success must read as partial success. Collapsing it into one
    /// boolean is how an agent ends up reporting 62 documents loaded when 2
    /// landed.
    @Test func partialSuccessNamesWhatDidNotLand() {
        let envelope = WriteKnowledgeTool.resultEnvelope(
            tool: "write_knowledge",
            collection: collection,
            written: [.init(relPath: "ok.md", operation: .create, recordId: 1)],
            failures: [("bad.pdf", "not a markdown document")],
            runId: "run-1"
        )
        #expect(ToolEnvelope.isSuccess(envelope))
        #expect(envelope.contains("Not written (1)"))
        #expect(envelope.contains("bad.pdf"))
        #expect(envelope.contains("not a markdown document"))
    }

    /// One bad path must not discard the rest, but a batch where NOTHING
    /// landed is an error, not a success with a footnote.
    @Test func totalFailureIsAnError() {
        let envelope = WriteKnowledgeTool.resultEnvelope(
            tool: "write_knowledge",
            collection: collection,
            written: [],
            failures: [("a.md", "disk full"), ("b.md", "disk full")],
            runId: "run-1"
        )
        #expect(ToolEnvelope.isError(envelope))
        #expect(envelope.contains("Nothing was written"))
    }

    // MARK: - Gating

    /// Direct write's ONLY gate is the interactive modal, which an external
    /// caller cannot be shown.
    @Test func externalSurfacesAreDenied() {
        #expect(ToolRegistry.externallyDeniedToolNames.contains("write_knowledge"))
    }

    /// `propose_knowledge_update` could auto-approve unattended because a
    /// human still reviewed the draft afterwards. Direct write has no such
    /// downstream gate, so it must stall rather than write unseen.
    @Test func unattendedRunsMayNotAutoApproveIt() {
        #expect(!ToolRegistry.unattendedAutoApprovableToolNames.contains("write_knowledge"))
    }

    /// Write access follows the collection grant, not a separate role. The
    /// curator opt-in is what left an agent with grants unable to write and
    /// unable to explain why.
    @Test func reachesTheSchemaWithOrdinaryKnowledgeGrants() {
        #expect(SystemPromptComposer.knowledgeToolNames.contains("write_knowledge"))
        #expect(!SystemPromptComposer.knowledgeCuratorToolNames.contains("write_knowledge"))
    }

    @Test func asksForApprovalByDefault() {
        #expect(WriteKnowledgeTool().defaultPermissionPolicy == .ask)
    }
}

/// `delete_knowledge` and, above all, the guarantee that no blanket grant can
/// ever cover it.
///
/// osaurus#2439 asked "delete all of them" and got a confident report of 62
/// documents removed from a collection that never held them, while the real
/// source survived to be re-found hours later. Deletion is the operation that
/// most needs a human looking at the actual paths.
@Suite
struct DeleteKnowledgeToolTests {

    private func paths(_ args: [String: Any]) -> WriteKnowledgeTool.DocumentsResult {
        DeleteKnowledgeTool.paths(from: args, tool: "delete_knowledge")
    }

    private func parsed(_ result: WriteKnowledgeTool.DocumentsResult) -> [String]? {
        if case .success(let docs) = result { return docs.map(\.path) }
        return nil
    }

    // MARK: - Per-call approval

    /// The invariant this tool exists to protect. A lease taken for a bulk
    /// WRITE must not silently authorize removal later in the same run.
    @Test func approvalCanNeverBePreGranted() {
        #expect(DeleteKnowledgeTool().requiresApprovalEveryCall)
        // Writing may be leased; deleting may not. The asymmetry is the point.
        #expect((WriteKnowledgeTool() as Any) is PerCallApprovalTool == false)
    }

    @Test func asksForApprovalByDefault() {
        #expect(DeleteKnowledgeTool().defaultPermissionPolicy == .ask)
    }

    @Test func externalSurfacesAreDenied() {
        #expect(ToolRegistry.externallyDeniedToolNames.contains("delete_knowledge"))
    }

    /// No downstream human gate exists for a direct delete, so an unattended
    /// run must stall rather than destroy documents unseen.
    @Test func unattendedRunsMayNotAutoApproveIt() {
        #expect(!ToolRegistry.unattendedAutoApprovableToolNames.contains("delete_knowledge"))
    }

    @Test func reachesTheSchemaWithOrdinaryKnowledgeGrants() {
        #expect(SystemPromptComposer.knowledgeToolNames.contains("delete_knowledge"))
    }

    // MARK: - Arguments

    @Test func pathsArrayParses() {
        #expect(parsed(paths(["paths": ["a.md", "b.md"]])) == ["a.md", "b.md"])
    }

    @Test func singularPathIsAccepted() {
        #expect(parsed(paths(["path": "solo.md"])) == ["solo.md"])
    }

    @Test func blankAndMissingPathsAreRejected() {
        for args in [[:], ["paths": []], ["paths": ["", "   "]]] as [[String: Any]] {
            #expect(paths(args).failureEnvelope?.contains("No paths to delete") == true)
        }
    }

    @Test func duplicatePathsAreRejected() {
        #expect(
            paths(["paths": ["a.md", "a.md"]]).failureEnvelope?
                .contains("appears more than once") == true
        )
    }

    @Test func tooManyPathsInOneCallIsRejected() {
        let many = (0...DeleteKnowledgeTool.maxPathsPerCall).map { "doc-\($0).md" }
        #expect(paths(["paths": many]).failureEnvelope?.contains("exceeds the limit") == true)
    }

    // MARK: - Result reporting

    private let collection = KnowledgeCollection(name: "packaging", folderPath: "/tmp/pkg")

    /// The result must name what is gone AND that it is recoverable, because
    /// approving a delete at a glance is only defensible if undo is real.
    @Test func successNamesEveryPathAndTheRestorePath() {
        let envelope = DeleteKnowledgeTool.resultEnvelope(
            tool: "delete_knowledge",
            collection: collection,
            removed: [
                .init(relPath: "old/a.md", operation: .delete, recordId: 1),
                .init(relPath: "old/b.md", operation: .delete, recordId: 2),
            ],
            failures: []
        )
        #expect(ToolEnvelope.isSuccess(envelope))
        #expect(envelope.contains("old/a.md"))
        #expect(envelope.contains("old/b.md"))
        #expect(envelope.contains("restorable from the Knowledge tab"))
        #expect(envelope.contains("search_knowledge"))
    }

    @Test func partialDeletionNamesWhatSurvived() {
        let envelope = DeleteKnowledgeTool.resultEnvelope(
            tool: "delete_knowledge",
            collection: collection,
            removed: [.init(relPath: "gone.md", operation: .delete, recordId: 1)],
            failures: [("ghost.md", "No document at ghost.md in this collection.")]
        )
        #expect(ToolEnvelope.isSuccess(envelope))
        #expect(envelope.contains("Not deleted (1)"))
        #expect(envelope.contains("ghost.md"))
    }

    /// Reporting a deletion that did not happen is the exact failure from the
    /// original session, so nothing-removed is an error.
    @Test func deletingNothingIsAnError() {
        let envelope = DeleteKnowledgeTool.resultEnvelope(
            tool: "delete_knowledge",
            collection: collection,
            removed: [],
            failures: [("ghost.md", "No document at ghost.md in this collection.")]
        )
        #expect(ToolEnvelope.isError(envelope))
        #expect(envelope.contains("Nothing was deleted"))
    }
}
