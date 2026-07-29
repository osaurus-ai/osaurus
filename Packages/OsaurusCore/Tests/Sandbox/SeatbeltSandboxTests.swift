import Foundation
import Testing

@testable import OsaurusCore

/// Unit coverage for the Seatbelt (`sandbox-exec`) fallback backend used
/// on macOS versions before 26. Pins the pieces that must not drift:
/// backend selection never picks Seatbelt on Tahoe+, the generated
/// profile is deny-by-default with the right write grants, "proxy"
/// network mode fails closed, and the `/workspace` → host path rewrite
/// only touches whole path components.
@Suite
struct SeatbeltSandboxTests {

    // MARK: - Backend selection

    @Test("seatbelt is never selected on macOS 26 or later")
    func backendSelectionRespectsTahoe() {
        guard ProcessInfo.processInfo.environment["OSAURUS_FORCE_SEATBELT"] != "1" else {
            #expect(SandboxBackend.current == .seatbelt)
            return
        }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if major >= 26 {
            #expect(SandboxBackend.current == .virtualMachine)
        } else {
            #expect(SandboxBackend.current == .seatbelt)
        }
    }

    // MARK: - Backend-branched prompt / flag surface

    @Test("system prompt sandbox framing matches the active backend")
    func promptFramingMatchesBackend() {
        let heading = SystemPromptTemplates.sandboxSectionHeading
        let full = SystemPromptTemplates.sandbox(home: "/workspace/agents/a")
        let compact = SystemPromptTemplates.sandbox(home: "/workspace/agents/a", compact: true)
        if SandboxBackend.current == .seatbelt {
            #expect(heading == "## macOS sandbox environment")
            for prompt in [full, compact] {
                // The model must not be told it's on Alpine, or offered
                // a package manager that doesn't exist on this backend.
                #expect(!prompt.contains("Alpine"))
                #expect(!prompt.contains("`apk`"))
                #expect(prompt.contains("macOS"))
            }
        } else {
            #expect(heading == "## Linux sandbox environment")
            #expect(full.contains("Alpine Linux"))
            #expect(compact.contains("Alpine Linux"))
        }
    }

    @Test("plugin authoring guide only offers apk dependencies on the vm backend")
    func pluginGuideDependenciesBullet() {
        let guide = SystemPromptTemplates.pluginCreatorInstructions
        if SandboxBackend.current == .seatbelt {
            #expect(!guide.contains("Alpine packages"))
            #expect(guide.contains("NOT supported"))
        } else {
            #expect(guide.contains("Alpine packages (`apk add`)"))
        }
    }

    @Test("bridge migration banner never fires on the seatbelt backend")
    func bridgeMigrationFlagFailsClosedOnSeatbelt() {
        // Only meaningful to pin on Seatbelt: the VM-side value depends on
        // the persisted config's provisioned-version stamp.
        guard SandboxBackend.current == .seatbelt else { return }
        #expect(SandboxBridgeMigrationFlag.needsRestart == false)
    }

    // MARK: - Profile generation

    @Test("profile is deny-by-default and grants workspace + temp writes")
    func profileShape() {
        let profile = SeatbeltSandbox.profile(
            workspaceRoot: "/Users/me/.osaurus/container/workspace",
            tempDir: "/tmp/osaurus-seatbelt",
            network: .allowed
        )
        #expect(profile.hasPrefix("(version 1)\n(deny default)"))
        #expect(profile.contains("(subpath \"/Users/me/.osaurus/container/workspace\")"))
        #expect(profile.contains("(subpath \"/tmp/osaurus-seatbelt\")"))
        #expect(profile.contains("(allow network*)"))
        // No blanket home-directory read grant.
        #expect(!profile.contains("(subpath \"/Users\")"))
    }

    @Test("network none denies network in the profile")
    func profileDeniesNetwork() {
        let profile = SeatbeltSandbox.profile(
            workspaceRoot: "/w", tempDir: "/t", network: .denied)
        #expect(profile.contains("(deny network*)"))
        #expect(!profile.contains("(allow network*)"))
    }

    @Test("proxy allowlist mode fails closed to no network")
    func proxyModeFailsClosed() {
        #expect(SeatbeltSandbox.NetworkPolicy.from(configNetwork: "outbound") == .allowed)
        #expect(SeatbeltSandbox.NetworkPolicy.from(configNetwork: "none") == .denied)
        // Seatbelt can't enforce a domain allowlist — it must not silently
        // widen "proxy" to unrestricted egress.
        #expect(SeatbeltSandbox.NetworkPolicy.from(configNetwork: "proxy") == .denied)
    }

    @Test("profile paths with quotes are escaped")
    func profileEscaping() {
        #expect(SeatbeltSandbox.escapeProfilePath(#"/a/"b"/c"#) == #"/a/\"b\"/c"#)
        #expect(SeatbeltSandbox.escapeProfilePath(#"/a\b"#) == #"/a\\b"#)
    }

    // MARK: - Path mapping

    private let root = "/Users/me/.osaurus/container/workspace"

    @Test("guest workspace paths map to the host workspace")
    func mapsWorkspacePaths() {
        #expect(
            SeatbeltPathMapper.mapToHost("cat /workspace/agents/a/notes.txt", workspaceRoot: root)
                == "cat \(root)/agents/a/notes.txt")
        #expect(SeatbeltPathMapper.mapToHost("ls /workspace", workspaceRoot: root) == "ls \(root)")
        #expect(
            SeatbeltPathMapper.mapToHost("cd /workspace && ls /workspace/shared", workspaceRoot: root)
                == "cd \(root) && ls \(root)/shared")
    }

    @Test("non-workspace tokens are left untouched")
    func leavesOtherPathsAlone() {
        #expect(
            SeatbeltPathMapper.mapToHost("ls /workspaces/other", workspaceRoot: root)
                == "ls /workspaces/other")
        #expect(
            SeatbeltPathMapper.mapToHost("ls foo/workspace/bar", workspaceRoot: root)
                == "ls foo/workspace/bar")
        #expect(
            SeatbeltPathMapper.mapToHost("echo no paths here", workspaceRoot: root)
                == "echo no paths here")
    }

    @Test("trailing slash on the host root does not double up")
    func trailingSlashRoot() {
        #expect(
            SeatbeltPathMapper.mapToHost("/workspace/x", workspaceRoot: root + "/")
                == "\(root)/x")
    }

    @Test("env values are mapped")
    func mapsEnvValues() {
        let mapped = SeatbeltPathMapper.mapEnvToHost(
            ["HOME": "/workspace/agents/a", "LANG": "C"], workspaceRoot: root)
        #expect(mapped["HOME"] == "\(root)/agents/a")
        #expect(mapped["LANG"] == "C")
    }
}
