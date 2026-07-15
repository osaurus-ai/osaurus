import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Pins the seeding contract of the hermetic run storage
/// (`EvalBootstrap.seedHostSnapshots`): the isolated root shares only the
/// host resources an eval must see, and never in a way that lets a run
/// mutate the user's real files.
///
///   - `config/chat.json` and `config/sandbox.json` are COPIES — a write an
///     eval triggers (provision stamps, executed configure tools) lands in
///     the throwaway copy, so the user's context files stay pristine.
///   - `Tools/` (installed plugins) and `cache/external-models.json` are
///     read-only shares via SYMLINK; deleting the isolated root removes the
///     link, never the target.
///   - `container/` is a symlink to the host-global sandbox VM runtime —
///     the one deliberate isolation exception (VM boot costs minutes and
///     the container is shared with the host app).
@MainActor
struct EvalBootstrapHostSnapshotTests {
    private func makeRealRoot() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("host-snapshot-real-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: root.appendingPathComponent("Tools", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: root.appendingPathComponent("container", isDirectory: true),
            withIntermediateDirectories: true
        )
        try #"{"coreModelName":"test-model"}"#.write(
            to: config.appendingPathComponent("chat.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"setupComplete":true}"#.write(
            to: config.appendingPathComponent("sandbox.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: cache.appendingPathComponent("external-models.json"),
            atomically: true,
            encoding: .utf8
        )
        // Live user context that must NEVER be shared into the eval root.
        try fm.createDirectory(
            at: root.appendingPathComponent("agents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: root.appendingPathComponent("memory", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeIsolatedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-snapshot-isolated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func isSymlink(_ url: URL) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func isRegularFile(_ url: URL) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.type] as? FileAttributeType) == .typeRegular
    }

    @Test func configSnapshotsAreCopiesNotSymlinks() throws {
        let fm = FileManager.default
        let real = try makeRealRoot()
        let isolated = try makeIsolatedRoot()
        defer {
            try? fm.removeItem(at: real)
            try? fm.removeItem(at: isolated)
        }

        EvalBootstrap.seedHostSnapshots(realRoot: real, isolatedRoot: isolated, symlinkTools: false)

        let chatCopy = isolated.appendingPathComponent("config/chat.json")
        let sandboxCopy = isolated.appendingPathComponent("config/sandbox.json")
        #expect(isRegularFile(chatCopy))
        #expect(isRegularFile(sandboxCopy))

        // Mutating the copy must leave the user's real file untouched.
        try "MUTATED-BY-EVAL".write(to: sandboxCopy, atomically: true, encoding: .utf8)
        let realSandbox = try String(
            contentsOf: real.appendingPathComponent("config/sandbox.json"),
            encoding: .utf8
        )
        #expect(realSandbox == #"{"setupComplete":true}"#)
    }

    @Test func readOnlySharesAreSymlinks() throws {
        let fm = FileManager.default
        let real = try makeRealRoot()
        let isolated = try makeIsolatedRoot()
        defer {
            try? fm.removeItem(at: real)
            try? fm.removeItem(at: isolated)
        }

        EvalBootstrap.seedHostSnapshots(realRoot: real, isolatedRoot: isolated, symlinkTools: true)

        let tools = isolated.appendingPathComponent("Tools")
        let manifest = isolated.appendingPathComponent("cache/external-models.json")
        let container = isolated.appendingPathComponent("container")
        #expect(isSymlink(tools))
        #expect(isSymlink(manifest))
        #expect(isSymlink(container))
        #expect(
            try fm.destinationOfSymbolicLink(atPath: container.path)
                == real.appendingPathComponent("container", isDirectory: true).path
        )

        // Deleting the isolated root must remove the links, never the
        // shared host targets — the cleanup/orphan-sweep safety property.
        try fm.removeItem(at: isolated)
        #expect(fm.fileExists(atPath: real.appendingPathComponent("Tools").path))
        #expect(fm.fileExists(atPath: real.appendingPathComponent("container").path))
        #expect(fm.fileExists(atPath: real.appendingPathComponent("cache/external-models.json").path))
    }

    @Test func toolsSymlinkIsGatedOnPluginLoading() throws {
        let fm = FileManager.default
        let real = try makeRealRoot()
        let isolated = try makeIsolatedRoot()
        defer {
            try? fm.removeItem(at: real)
            try? fm.removeItem(at: isolated)
        }

        EvalBootstrap.seedHostSnapshots(realRoot: real, isolatedRoot: isolated, symlinkTools: false)

        #expect(!fm.fileExists(atPath: isolated.appendingPathComponent("Tools").path))
    }

    @Test func userContextIsNeverShared() throws {
        let fm = FileManager.default
        let real = try makeRealRoot()
        let isolated = try makeIsolatedRoot()
        defer {
            try? fm.removeItem(at: real)
            try? fm.removeItem(at: isolated)
        }

        EvalBootstrap.seedHostSnapshots(realRoot: real, isolatedRoot: isolated, symlinkTools: true)

        // Live user-context stores start empty in the isolated root: eval
        // fixtures write fresh files there, never into the real root.
        #expect(!fm.fileExists(atPath: isolated.appendingPathComponent("agents").path))
        #expect(!fm.fileExists(atPath: isolated.appendingPathComponent("memory").path))
        #expect(!fm.fileExists(atPath: isolated.appendingPathComponent("chat-history").path))
        #expect(!fm.fileExists(atPath: isolated.appendingPathComponent("methods").path))
        #expect(!fm.fileExists(atPath: isolated.appendingPathComponent("scheduler.sqlite").path))
    }

    @Test func missingHostFilesAreSkippedGracefully() throws {
        let fm = FileManager.default
        // A bare real root (fresh machine, nothing provisioned yet).
        let real = fm.temporaryDirectory
            .appendingPathComponent("host-snapshot-bare-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let isolated = try makeIsolatedRoot()
        defer {
            try? fm.removeItem(at: real)
            try? fm.removeItem(at: isolated)
        }

        EvalBootstrap.seedHostSnapshots(realRoot: real, isolatedRoot: isolated, symlinkTools: true)

        #expect(!fm.fileExists(atPath: isolated.appendingPathComponent("Tools").path))
        #expect(!fm.fileExists(atPath: isolated.appendingPathComponent("container").path))
        #expect(!fm.fileExists(atPath: isolated.appendingPathComponent("config/chat.json").path))
        #expect(!fm.fileExists(atPath: isolated.appendingPathComponent("config/sandbox.json").path))
    }
}
