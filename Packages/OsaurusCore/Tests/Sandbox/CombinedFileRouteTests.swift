import Foundation
import Testing

@testable import OsaurusCore

/// Unit coverage for the combined-mode file-path router. The unified
/// `file_*` read family routes by path: absolute `/workspace/...` paths
/// reach the Linux sandbox; everything else (relative or host-absolute)
/// stays on the read-only host workspace. This is the disambiguation the
/// model used to have to make by tool *name* (`file_*` vs `sandbox_*`).
@Suite
struct CombinedFileRouteTests {
    @Test("relative paths route to the host workspace")
    func relativeRoutesHost() {
        #expect(combinedFileRoute(path: ".") == .host)
        #expect(combinedFileRoute(path: "") == .host)
        #expect(combinedFileRoute(path: "src/app.py") == .host)
        #expect(combinedFileRoute(path: "./notes.txt") == .host)
    }

    @Test("host-absolute paths route to the host workspace")
    func hostAbsoluteRoutesHost() {
        #expect(combinedFileRoute(path: "/Users/me/Desktop") == .host)
        #expect(combinedFileRoute(path: "/Users/me/Desktop/todo.md") == .host)
        #expect(combinedFileRoute(path: "/Volumes/Data/file.csv") == .host)
    }

    @Test("/workspace paths route to the Linux sandbox")
    func workspaceRoutesSandbox() {
        #expect(combinedFileRoute(path: "/workspace/agents/me/notes.txt") == .sandbox)
        #expect(combinedFileRoute(path: "/workspace/shared/data.csv") == .sandbox)
        #expect(combinedFileRoute(path: "/workspace") == .sandbox)
    }

    @Test("non-workspace Linux roots stay on the host branch")
    func otherLinuxRootsRouteHost() {
        // The host tool resolves these against its root and rejects them;
        // the router only diverts `/workspace` to the sandbox so a stray
        // `/etc` doesn't silently hit the container.
        #expect(combinedFileRoute(path: "/etc/hosts") == .host)
        #expect(combinedFileRoute(path: "/tmp/scratch") == .host)
    }
}
