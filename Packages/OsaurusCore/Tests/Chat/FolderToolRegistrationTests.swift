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

    /// Register folder tools for a synthetic context, run `body`, then
    /// unregister. The tool inits only stash `rootPath`; they don't stat
    /// or open the directory at register time, so a non-existent path is
    /// safe here.
    private func withRegisteredFolderTools(
        projectType: ProjectType = .unknown,
        isGitRepo: Bool = false,
        body: (FolderToolManager) -> Void
    ) {
        let manager = FolderToolManager.shared
        let context = FolderContext(
            rootPath: URL(fileURLWithPath: "/tmp/osaurus-folder-tool-test-\(UUID().uuidString)"),
            projectType: projectType,
            tree: "",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: isGitRepo
        )
        manager.registerFolderTools(for: context)
        defer { manager.unregisterFolderTools() }
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

    /// Sanity: the rest of the core set still rides along.
    @Test("file_* core tools are loaded for unknown-project folders")
    func coreFileToolsLoadedForUnknownProject() {
        withRegisteredFolderTools { manager in
            for name in ["file_tree", "file_read", "file_write", "file_edit", "file_search"] {
                #expect(
                    manager.folderToolNames.contains(name),
                    "`\(name)` missing from folder core set. Live names: \(manager.folderToolNames)"
                )
            }
        }
    }
}
