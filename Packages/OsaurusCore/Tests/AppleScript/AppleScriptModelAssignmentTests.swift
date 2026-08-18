//
//  AppleScriptModelAssignmentTests.swift
//  osaurus
//
//  "Model assignment doesn't take": an AppleScript model assigned in
//  Settings was honored only when its repo id carried a curated prefix
//  (`OsaurusAI/Osaurus-AppleScript-` / `JANGQ-AI/AppleScript-`). Any other
//  installed bundle fell through to `models.first(where: isInstalled)` — the
//  run proceeded on a model the user never chose, with no error anywhere.
//
//  `resolveAssignment` now separates the three outcomes so an explicit
//  assignment is either honored (when installed) or REPORTED (when not),
//  and only the unassigned case takes the curated automatic pick.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AppleScriptModelAssignmentTests {
    @Test("an assigned but uninstalled model is reported, never silently swapped")
    func assignedButMissingIsReported() {
        let assigned = "SomeOrg/Definitely-Not-Installed-AppleScript-Model"
        #expect(
            AppleScriptModelCatalog.resolveAssignment(preferred: assigned)
                == .assignedButNotInstalled(assigned))
        // The compatibility shim maps that to nil rather than to another
        // model — a caller that ignores the distinction still cannot run the
        // wrong model.
        #expect(AppleScriptModelCatalog.resolveInstalledModelId(preferred: assigned) == nil)
    }

    @Test("blank or whitespace assignment falls through to automatic selection")
    func blankAssignmentUsesAutomatic() {
        // No curated model is installed in the test environment, so automatic
        // selection has nothing to offer — the point is that a blank string is
        // treated as "unassigned", not as a missing assignment.
        #expect(AppleScriptModelCatalog.resolveAssignment(preferred: "   ") == .noneInstalled)
        #expect(AppleScriptModelCatalog.resolveAssignment(preferred: nil) == .noneInstalled)
    }

    @Test("an installed bundle resolves by explicit assignment regardless of repo prefix")
    func installedNonPrefixedModelResolves() async {
        await OsaurusTestGlobals.withPathsLock {
            let fm = FileManager.default
            let manifestRoot = fm.temporaryDirectory.appendingPathComponent(
                "osaurus-applescript-assign-manifest-\(UUID().uuidString)", isDirectory: true)
            let modelsRoot = fm.temporaryDirectory.appendingPathComponent(
                "osaurus-applescript-assign-models-\(UUID().uuidString)", isDirectory: true)
            // Deliberately NOT one of the AppleScript repo prefixes: this is
            // the shape the old gate dropped.
            let assignedId = "JANGQ-AI/Ornith-1.0-9B-JANG_6M"
            let bundle = modelsRoot.appendingPathComponent(assignedId, isDirectory: true)

            let previousRoot = OsaurusPaths.overrideRoot
            let previousOverride = ExternalModelLocator.testRootsOverride
            OsaurusPaths.overrideRoot = manifestRoot
            ExternalModelLocator.invalidateInMemory()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                ExternalModelLocator.testRootsOverride = previousOverride
                ExternalModelLocator.invalidateInMemory()
                try? fm.removeItem(at: manifestRoot)
                try? fm.removeItem(at: modelsRoot)
            }

            try? fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            try? Data("{}".utf8).write(to: bundle.appendingPathComponent("config.json"))
            try? Data("{}".utf8).write(to: bundle.appendingPathComponent("tokenizer.json"))
            try? Data("w".utf8).write(to: bundle.appendingPathComponent("model.safetensors"))

            ExternalModelLocator.testRootsOverride = [
                (root: modelsRoot, source: .customModelFolder)
            ]
            ExternalModelLocator.rescan()

            #expect(
                AppleScriptModelCatalog.resolveAssignment(preferred: assignedId)
                    == .resolved(assignedId))
            // Still never an AUTOMATIC pick: the curated-only rule for the
            // unassigned case is unchanged.
            #expect(AppleScriptModelCatalog.resolveAssignment(preferred: nil) == .noneInstalled)
        }
    }
}
