import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Regression pins for the isolated-root leak (20260702 optimization-loop
/// marathon): every eval process creates a throwaway `osaurus-evals-<uuid>`
/// root under `temporaryDirectory`, and with the KV regime override each one
/// grows a ~10 GB `cache/kv_v2`. Nothing ever deleted them — watchdog trips
/// `_exit` (skipping atexit by design) and kills skip teardown too — so a
/// marathon leaked 11 roots / ~100 GB and drove free disk to 11 GiB, which
/// is exactly the disk-pressure regime that collapsed decode speed on the
/// `compaction-stress` lane. The sweep collects roots whose owner pid is
/// dead while never touching live neighbors (parallel remote lane).
@MainActor
struct EvalBootstrapOrphanSweepTests {
    /// A pid far above Darwin's PID_MAX (99999): `kill(pid, 0)` is ESRCH.
    private static let deadPid: Int32 = 999_999_999

    private func makeSandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRoot(
        in sandbox: URL,
        name: String,
        ownerPid: Int32?
    ) throws -> URL {
        let root = sandbox.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Give every root a payload so removal is proven recursive.
        try "payload".write(
            to: root.appendingPathComponent("cache.bin"),
            atomically: true,
            encoding: .utf8
        )
        if let ownerPid {
            try String(ownerPid).write(
                to: root.appendingPathComponent(EvalBootstrap.ownerPidMarkerName),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }

    @Test func deadOwnerRootIsCollected() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let orphan = try makeRoot(
            in: sandbox,
            name: "osaurus-evals-dead",
            ownerPid: Self.deadPid
        )

        EvalBootstrap.sweepOrphanedIsolatedRoots(in: sandbox)

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func liveOwnerRootIsKept() throws {
        // The parallel remote lane: a sibling eval process is mid-run. Its
        // pid (here: our own) is alive, so its root must survive the sweep.
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let live = try makeRoot(
            in: sandbox,
            name: "osaurus-evals-live",
            ownerPid: ProcessInfo.processInfo.processIdentifier
        )

        EvalBootstrap.sweepOrphanedIsolatedRoots(in: sandbox)

        #expect(FileManager.default.fileExists(atPath: live.path))
    }

    @Test func markerlessRootIsKeptUntilStale() throws {
        // Pre-marker binaries leave no pid file. Liveness is unknowable, so
        // a young root is kept (could be a live old-binary run) and only a
        // >24h-old one is collected (no eval run lasts that long).
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let markerless = try makeRoot(
            in: sandbox,
            name: "osaurus-evals-markerless",
            ownerPid: nil
        )

        EvalBootstrap.sweepOrphanedIsolatedRoots(in: sandbox)
        #expect(FileManager.default.fileExists(atPath: markerless.path))

        let later = Date().addingTimeInterval(EvalBootstrap.markerlessRootMaxAge + 60)
        EvalBootstrap.sweepOrphanedIsolatedRoots(in: sandbox, now: later)
        #expect(!FileManager.default.fileExists(atPath: markerless.path))
    }

    @Test func unrelatedEntriesAreNeverTouched() throws {
        // The sweep runs against the shared system temp dir in production;
        // it must only ever consider the `osaurus-evals-` namespace.
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let unrelatedDir = try makeRoot(
            in: sandbox,
            name: "some-other-tool-workdir",
            ownerPid: Self.deadPid
        )
        let unrelatedFile = sandbox.appendingPathComponent("osaurus-evals.log")
        try "not a directory root".write(to: unrelatedFile, atomically: true, encoding: .utf8)

        let later = Date().addingTimeInterval(EvalBootstrap.markerlessRootMaxAge + 60)
        EvalBootstrap.sweepOrphanedIsolatedRoots(in: sandbox, now: later)

        #expect(FileManager.default.fileExists(atPath: unrelatedDir.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }
}
