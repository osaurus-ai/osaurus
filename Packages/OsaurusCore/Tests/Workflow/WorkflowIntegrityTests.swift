//
//  WorkflowIntegrityTests.swift
//  OsaurusCoreTests
//
//  An installed workflow's file edited outside Osaurus blocks in setup
//  until it is reviewed and installed again; ordinary saves do not clear
//  the flag.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct WorkflowIntegrityTests {

    private func isolated(_ body: @MainActor @Sendable () async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let root = WF.tempDir()
            OsaurusPaths.overrideRoot = root
            TemplateStore.shared.reload()
            InstalledWorkflowStore.shared.reload()
            defer {
                InstalledWorkflowStore.shared.resetForTesting()
                OsaurusPaths.overrideRoot = nil
                TemplateStore.shared.reload()
                try? FileManager.default.removeItem(at: root)
            }
            try await body()
        }
    }

    @Test
    func integrityCheck_recordsOnFirstLoad_flagsChangesAndStrangers_prunesRemoved() {
        let a = UUID(), b = UUID(), gone = UUID()
        let first = InstalledWorkflowStore.integrityCheck([(a, Data("a".utf8))], recorded: nil)
        #expect(first.modified.isEmpty)
        #expect(first.updated == [a: InstalledWorkflowStore.contentHash(Data("a".utf8))])

        let recorded = [a: InstalledWorkflowStore.contentHash(Data("a".utf8)), gone: "x"]
        let later = InstalledWorkflowStore.integrityCheck(
            [(a, Data("a-edited".utf8)), (b, Data("new".utf8))], recorded: recorded)
        #expect(later.modified == [a, b])
        #expect(later.updated == [a: recorded[a]!])
    }

    @Test
    func editedFile_blocksRuns_untilInstalledAgainFromSetup() async throws {
        try await isolated {
            let store = InstalledWorkflowStore.shared
            let template = WF.template(WF.intake())
            let installed = try store.install(template, bindings: InstallBindings())
            #expect(store.modifiedOutsideApp.isEmpty)
            #expect(!SetupChecker.check(installed).blocking.contains { $0.kind == .integrity })

            // Something outside Osaurus rewrites the step instructions.
            let url = InstalledWorkflowStore.fileURL(installed.id)
            let text = try String(contentsOf: url, encoding: .utf8)
            try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
            store.reload()
            #expect(store.modifiedOutsideApp == [installed.id])
            let flagged = try #require(store.workflow(id: installed.id))
            #expect(SetupChecker.check(flagged).blocking.contains { $0.kind == .integrity })

            // An ordinary save keeps the flag.
            store.setNeedsSetup(true, id: installed.id)
            #expect(store.modifiedOutsideApp == [installed.id])

            // Installing again from setup is the review.
            _ = try store.install(template, bindings: InstallBindings())
            #expect(store.modifiedOutsideApp.isEmpty)
            store.reload()
            #expect(store.modifiedOutsideApp.isEmpty)
        }
    }

    @Test
    func aWorkflowFileOsaurusNeverWrote_isFlagged() async throws {
        try await isolated {
            let store = InstalledWorkflowStore.shared
            _ = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            let dropped = InstalledWorkflow(template: WF.template(WF.intake(), name: "Dropped"), bindings: InstallBindings())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(dropped).write(to: InstalledWorkflowStore.fileURL(dropped.id))
            store.reload()
            #expect(store.modifiedOutsideApp == [dropped.id])
            store.delete(id: dropped.id)
            #expect(store.modifiedOutsideApp.isEmpty)
        }
    }
}
