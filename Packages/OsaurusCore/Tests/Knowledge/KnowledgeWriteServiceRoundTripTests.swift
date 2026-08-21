//
//  KnowledgeWriteServiceRoundTripTests.swift
//  OsaurusCoreTests — Knowledge
//
//  End-to-end: write / delete / revert against a real collection folder, a
//  real write log, and a real index.
//
//  Everything else in this feature is tested one layer up (argument parsing,
//  the preview manifest, log queries) — all of which passed while a type
//  mismatch in `delete_knowledge`'s execute loop reached a build. These tests
//  exercise the layer that actually moves bytes on disk, so a regression in
//  the mutation or the undo shows up as a failing test rather than as a
//  collection nobody can restore.
//
//  Runs under `OsaurusPaths.overrideRoot` so `.shared` databases open inside a
//  temp directory: the write log, the index, and the collection store are all
//  the production singletons, just pointed somewhere disposable.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct KnowledgeWriteServiceRoundTripTests {

    // MARK: - Write

    @Test func writeCreatesTheFileAndLogsACreate() async throws {
        try await withCollection { collection, folder in
            let outcome = try await KnowledgeWriteService.shared.write(
                collection: collection,
                relPath: "guides/deploy.md",
                content: "# Deploy\n\nStep one.\n",
                runId: "run-1",
                createdBy: "agent-1",
                rationale: "import"
            )

            #expect(outcome.operation == .create)
            let onDisk = try String(
                contentsOf: folder.appendingPathComponent("guides/deploy.md"), encoding: .utf8)
            #expect(onDisk == "# Deploy\n\nStep one.\n")

            let record = try #require(
                KnowledgeWriteLogDatabase.shared.record(id: outcome.recordId))
            #expect(record.operation == .create)
            // Nothing existed before, so there is nothing to restore TO.
            #expect(record.priorContent.isEmpty)
            #expect(record.resultContentHash == KnowledgeWriteService.sha256Hex(onDisk))
        }
    }

    @Test func writeOverExistingFileLogsTheReplacedContent() async throws {
        try await withCollection { collection, folder in
            try seed(folder, "a.md", "original\n")

            let outcome = try await KnowledgeWriteService.shared.write(
                collection: collection, relPath: "a.md", content: "replaced\n",
                runId: "run-1", createdBy: "agent-1", rationale: "fix"
            )

            #expect(outcome.operation == .replace)
            let record = try #require(
                KnowledgeWriteLogDatabase.shared.record(id: outcome.recordId))
            // The WHOLE prior document: a revert must not depend on the
            // current file still being what the agent left behind.
            #expect(record.priorContent == "original\n")
        }
    }

    // MARK: - Revert

    @Test func revertingAReplaceRestoresTheExactPriorBytes() async throws {
        try await withCollection { collection, folder in
            try seed(folder, "a.md", "original\n")
            let outcome = try await KnowledgeWriteService.shared.write(
                collection: collection, relPath: "a.md", content: "agent version\n",
                runId: "run-1", createdBy: "agent-1", rationale: "fix"
            )

            try await KnowledgeWriteService.shared.revert(recordId: outcome.recordId)

            let restored = try String(
                contentsOf: folder.appendingPathComponent("a.md"), encoding: .utf8)
            #expect(restored == "original\n")
            #expect(KnowledgeWriteLogDatabase.shared.record(id: outcome.recordId)?.isReverted == true)
        }
    }

    /// Reverting a create deletes the file: there was nothing there before.
    @Test func revertingACreateRemovesTheFile() async throws {
        try await withCollection { collection, folder in
            let outcome = try await KnowledgeWriteService.shared.write(
                collection: collection, relPath: "new.md", content: "body\n",
                runId: "run-1", createdBy: "agent-1", rationale: "add"
            )
            try await KnowledgeWriteService.shared.revert(recordId: outcome.recordId)
            #expect(
                !FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("new.md").path))
        }
    }

    @Test func deleteRemovesTheFileAndRevertBringsItBack() async throws {
        try await withCollection { collection, folder in
            try seed(folder, "doomed.md", "keep me\n")

            let outcome = try await KnowledgeWriteService.shared.delete(
                collection: collection, relPath: "doomed.md",
                runId: "run-1", createdBy: "agent-1", rationale: "wrong version"
            )
            #expect(outcome.operation == .delete)
            #expect(
                !FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("doomed.md").path))

            try await KnowledgeWriteService.shared.revert(recordId: outcome.recordId)
            let restored = try String(
                contentsOf: folder.appendingPathComponent("doomed.md"), encoding: .utf8)
            #expect(restored == "keep me\n")
        }
    }

    // MARK: - Guards

    /// The guard that stops undoing an agent from also undoing a human.
    @Test func revertRefusesWhenTheFileChangedAfterTheWrite() async throws {
        try await withCollection { collection, folder in
            try seed(folder, "a.md", "original\n")
            let outcome = try await KnowledgeWriteService.shared.write(
                collection: collection, relPath: "a.md", content: "agent version\n",
                runId: "run-1", createdBy: "agent-1", rationale: "fix"
            )
            // Somebody edits it afterwards.
            try seed(folder, "a.md", "human edit\n")

            await #expect(throws: KnowledgeWriteError.self) {
                try await KnowledgeWriteService.shared.revert(recordId: outcome.recordId)
            }
            let untouched = try String(
                contentsOf: folder.appendingPathComponent("a.md"), encoding: .utf8)
            #expect(untouched == "human edit\n")

            // `force` is the deliberate override.
            try await KnowledgeWriteService.shared.revert(recordId: outcome.recordId, force: true)
            let forced = try String(
                contentsOf: folder.appendingPathComponent("a.md"), encoding: .utf8)
            #expect(forced == "original\n")
        }
    }

    @Test func revertingTwiceIsRejected() async throws {
        try await withCollection { collection, _ in
            let outcome = try await KnowledgeWriteService.shared.write(
                collection: collection, relPath: "a.md", content: "x\n",
                runId: "run-1", createdBy: "agent-1", rationale: "add"
            )
            try await KnowledgeWriteService.shared.revert(recordId: outcome.recordId)
            await #expect(throws: KnowledgeWriteError.self) {
                try await KnowledgeWriteService.shared.revert(recordId: outcome.recordId)
            }
        }
    }

    @Test func writingOutsideTheCollectionIsRefusedBeforeAnythingIsLogged() async throws {
        try await withCollection { collection, _ in
            await #expect(throws: KnowledgeWriteError.self) {
                _ = try await KnowledgeWriteService.shared.write(
                    collection: collection, relPath: "../escape.md", content: "x",
                    runId: "run-1", createdBy: "agent-1", rationale: "nope"
                )
            }
            // A refused write must leave no record behind.
            let history = try KnowledgeWriteLogDatabase.shared.records(
                collectionId: collection.id.uuidString)
            #expect(history.isEmpty)
        }
    }

    // MARK: - Run revert

    /// The affordance that matters after a bad import: take the whole batch
    /// back in one action, best-effort per document.
    @Test func revertRunRestoresEveryDocumentInTheBatch() async throws {
        try await withCollection { collection, folder in
            try seed(folder, "existing.md", "before\n")
            for (path, content) in [
                ("existing.md", "after\n"), ("added-1.md", "one\n"), ("added-2.md", "two\n"),
            ] {
                _ = try await KnowledgeWriteService.shared.write(
                    collection: collection, relPath: path, content: content,
                    runId: "import", createdBy: "agent-1", rationale: "bulk"
                )
            }

            let failures = await KnowledgeWriteService.shared.revertRun(runId: "import")
            #expect(failures.isEmpty)

            let restored = try String(
                contentsOf: folder.appendingPathComponent("existing.md"), encoding: .utf8)
            #expect(restored == "before\n")
            for created in ["added-1.md", "added-2.md"] {
                #expect(
                    !FileManager.default.fileExists(
                        atPath: folder.appendingPathComponent(created).path))
            }
            #expect(try KnowledgeWriteLogDatabase.shared.records(runId: "import").isEmpty)
        }
    }

    /// One run writing the same path twice must unwind newest-first, or the
    /// restore lands the intermediate version instead of the original.
    @Test func revertRunUnwindsRepeatedWritesInReverseOrder() async throws {
        try await withCollection { collection, folder in
            try seed(folder, "a.md", "v0\n")
            for content in ["v1\n", "v2\n"] {
                _ = try await KnowledgeWriteService.shared.write(
                    collection: collection, relPath: "a.md", content: content,
                    runId: "import", createdBy: "agent-1", rationale: "bulk"
                )
            }

            let failures = await KnowledgeWriteService.shared.revertRun(runId: "import")
            #expect(failures.isEmpty)
            let restored = try String(
                contentsOf: folder.appendingPathComponent("a.md"), encoding: .utf8)
            #expect(restored == "v0\n")
        }
    }

    // MARK: - Harness

    /// A real collection registered with `KnowledgeManager`, inside a temp
    /// root so every `.shared` store lands somewhere disposable.
    private func withCollection(
        _ body: (KnowledgeCollection, URL) async throws -> Void
    ) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-knowledge-rt-\(UUID().uuidString)")
            let folder = root.appendingPathComponent("collection")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                KnowledgeWriteLogDatabase.shared.close()
                KnowledgeDatabase.shared.close()
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
                try? FileManager.default.removeItem(at: root)
            }
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            StorageKeyManager.shared.wipeCache()

            // `revert` resolves the collection through KnowledgeManager, so it
            // has to be REGISTERED, not just constructed.
            let created = await KnowledgeManager.shared.create(
                name: "packaging", folderPath: folder.path)

            // Deregistered inline rather than in a `defer` + detached Task:
            // KnowledgeManager is process-global, so a fire-and-forget cleanup
            // could still be pending when the next test builds its own
            // collection list. Errors propagate after the cleanup runs.
            do {
                try await body(created, folder)
            } catch {
                await MainActor.run { KnowledgeManager.shared.delete(id: created.id) }
                throw error
            }
            await MainActor.run { KnowledgeManager.shared.delete(id: created.id) }
        }
    }

    private func seed(_ folder: URL, _ relPath: String, _ content: String) throws {
        let url = folder.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
}
