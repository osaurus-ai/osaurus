//
//  FolderToolRegistrationTests.swift
//
//  Pin the folder-mode tool registration matrix. The folder-section
//  prompt names `shell_run` unconditionally as the way to do
//  `mv` / `cp` / `rm` / `mkdir`. Before this test, `shell_run` was only
//  registered when `FolderContext.projectType != .unknown`, so a folder
//  picked from `~/Desktop/Presentations` (no Package.swift / package.json
//  / etc.) advertised `shell_run` in the prompt while leaving it out of
//  the schema — the model would either invent the tool (fails fast with
//  a `toolNotFound` envelope) or apologise to the user.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct FolderToolRegistrationTests {

    /// Ensure the canonical folder-tool registration, run `body`, then
    /// unregister via the test seam. Registration is per-process and
    /// root-free now — tool bodies resolve the root from the TaskLocal
    /// execution scope, so no synthetic `FolderContext` is needed here.
    private func withRegisteredFolderTools(
        body: (FolderToolManager) -> Void
    ) {
        let manager = FolderToolManager.shared
        manager.ensureFolderToolsRegistered()
        defer { manager._unregisterAllForTesting() }
        body(manager)
    }

    /// `shell_run` must be in the resolved schema for every folder mount,
    /// regardless of whether a project type was detected.
    @Test("shell_run is always-loaded for unknown-project folders")
    func shellRunLoadedForUnknownProject() {
        withRegisteredFolderTools { manager in
            #expect(
                manager.folderToolNames.contains("shell_run"),
                "`shell_run` is missing from the folder schema for an unknown-project folder. The folder prompt names it unconditionally; the registration matrix must follow. Live names: \(manager.folderToolNames)"
            )
        }
    }

    /// Sanity: the rest of the core set still rides along. `file_tree` is
    /// intentionally absent — `file_read` lists directories now.
    @Test("file_* core tools are loaded for unknown-project folders")
    func coreFileToolsLoadedForUnknownProject() {
        withRegisteredFolderTools { manager in
            for name in ["file_read", "file_write", "file_edit", "file_search"] {
                #expect(
                    manager.folderToolNames.contains(name),
                    "`\(name)` missing from folder core set. Live names: \(manager.folderToolNames)"
                )
            }
            #expect(
                !manager.folderToolNames.contains("file_tree"),
                "`file_tree` was merged into `file_read` and must not be registered. Live names: \(manager.folderToolNames)"
            )
        }
    }
}
