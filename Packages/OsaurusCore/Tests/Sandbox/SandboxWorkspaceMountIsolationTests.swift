//
//  SandboxWorkspaceMountIsolationTests.swift
//  osaurusTests
//
//  Pins the load-bearing invariant for combined sandbox + host-read mode:
//  the sandbox mounts ONLY its own Osaurus-owned workspace, never the
//  user's selected folder. The whole security argument of combined mode
//  is "shell cannot touch host files because there is no host mount" — if
//  the workspace mount source ever became the folder root, the boundary
//  would silently collapse. `SandboxManager.validatedWorkspaceMountSource`
//  is the single chokepoint these tests guard.
//

#if os(macOS)

    import Foundation
    import Testing

    @testable import OsaurusCore

    @Suite
    struct SandboxWorkspaceMountIsolationTests {

        /// The mount source returned for the sandbox is always the
        /// Osaurus-owned container workspace, not a host folder — even when
        /// several concurrent chats have different folders selected.
        @Test func returnsContainerWorkspaceUnchanged() {
            let workspace = OsaurusPaths.containerWorkspace().path
            let resolved = SandboxManager.validatedWorkspaceMountSource(
                workspace: workspace,
                folderRoots: [
                    "/Users/example/some-project",
                    "/Users/example/another-project",
                ]
            )
            #expect(resolved == workspace)
        }

        /// No live folder roots (no chat has a folder selected) is the
        /// common case and must pass through untouched.
        @Test func noFolderRootsPassesThrough() {
            let workspace = OsaurusPaths.containerWorkspace().path
            let resolved = SandboxManager.validatedWorkspaceMountSource(
                workspace: workspace,
                folderRoots: []
            )
            #expect(resolved == workspace)
        }

        /// The real container workspace path is never equal to a typical
        /// host folder root, so combined mode can never accidentally mount
        /// the user's repo. This is the invariant the precondition in
        /// `validatedWorkspaceMountSource` enforces at runtime.
        @Test func containerWorkspaceDiffersFromHostFolderRoots() {
            let workspace = OsaurusPaths.containerWorkspace().standardizedFileURL.path
            let sampleFolderRoots = [
                "/Users/example/some-project",
                NSTemporaryDirectory(),
                FileManager.default.homeDirectoryForCurrentUser.path,
            ]
            for root in sampleFolderRoots {
                let normalizedRoot = URL(fileURLWithPath: root).standardized.path
                #expect(workspace != normalizedRoot)
            }
        }
    }

#endif
