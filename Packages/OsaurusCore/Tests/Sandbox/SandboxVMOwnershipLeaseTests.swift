import Foundation
import Testing
import Darwin

@testable import OsaurusCore

#if os(macOS)

@Suite(.serialized)
struct SandboxVMOwnershipLeaseTests {
    @Test func contentionReportsOwningProcessAndReleaseAllowsNextOwner() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-vm-lease-test-\(UUID().uuidString).lock"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try SandboxVMOwnershipLease.acquire(at: url)
        let owner = try #require(SandboxVMOwnershipLease.readOwner(at: url))
        #expect(owner.pid == getpid())
        #expect(!owner.processName.isEmpty)

        do {
            _ = try SandboxVMOwnershipLease.acquire(at: url)
            Issue.record("a second owner should not acquire the vmnet lease")
        } catch let conflict as SandboxVMOwnershipLease.OwnershipConflict {
            #expect(conflict.owner?.pid == getpid())
            #expect(conflict.localizedDescription.contains("PID \(getpid())"))
        }

        first.release()
        let second = try SandboxVMOwnershipLease.acquire(at: url)
        second.release()
    }

    /// Hold the lock on a raw descriptor (as another process would) and
    /// publish a foreign owner record so the waiting acquire cannot
    /// short-circuit on "owner is this process".
    private func holdForeignLock(at url: URL, pid: Int32, quitting: Bool = false) throws -> Int32 {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let owner = SandboxVMOwnershipLease.Owner(
            pid: pid,
            processName: "osaurus-old",
            executablePath: nil,
            acquiredAt: "2026-01-01T00:00:00Z",
            quittingSince: quitting ? "2026-01-01T00:00:01Z" : nil
        )
        let data = try JSONEncoder().encode(owner)
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        return fd
    }

    @Test func waitingAcquireSucceedsWhenOwnerReleasesBeforeDeadline() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-vm-lease-wait-\(UUID().uuidString).lock"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        // PID 1 is launchd: alive for the whole test, never us.
        let fd = try holdForeignLock(at: url, pid: 1)
        let releaser = Task {
            try await Task.sleep(nanoseconds: 200_000_000)
            _ = flock(fd, LOCK_UN)
            Darwin.close(fd)
        }

        let started = Date()
        let lease = try await SandboxVMOwnershipLease.acquire(
            at: url,
            waitingUpTo: 5,
            pollInterval: 0.05,
            isProcessAlive: { _ in true }
        )
        let elapsed = Date().timeIntervalSince(started)
        lease.release()
        try await releaser.value

        // Waited for the release rather than failing fast. No upper bound
        // beyond the 5 s deadline itself (a slower wait would have thrown
        // `OwnershipConflict` above): under a fully parallel full-suite run
        // the releaser's 200 ms sleep has been observed to take >4 s to be
        // scheduled, which is scheduler load, not lease behaviour.
        #expect(elapsed >= 0.15)
        let owner = try #require(SandboxVMOwnershipLease.readOwner(at: url))
        #expect(owner.pid == getpid())
    }

    @Test func waitingAcquireSurfacesConflictWhenLiveOwnerNeverReleases() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-vm-lease-hold-\(UUID().uuidString).lock"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let fd = try holdForeignLock(at: url, pid: 1)
        defer {
            _ = flock(fd, LOCK_UN)
            Darwin.close(fd)
        }

        let started = Date()
        do {
            _ = try await SandboxVMOwnershipLease.acquire(
                at: url,
                waitingUpTo: 0.4,
                pollInterval: 0.05,
                isProcessAlive: { _ in true }
            )
            Issue.record("a live owner that never releases must surface a conflict")
        } catch let conflict as SandboxVMOwnershipLease.OwnershipConflict {
            #expect(conflict.owner?.pid == 1)
            #expect(conflict.localizedDescription.contains("osaurus-old"))
        }
        #expect(Date().timeIntervalSince(started) >= 0.35)
    }

    @Test func waitingAcquireDoesNotWaitOnItself() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-vm-lease-self-\(UUID().uuidString).lock"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try SandboxVMOwnershipLease.acquire(at: url)
        defer { first.release() }

        let started = Date()
        do {
            _ = try await SandboxVMOwnershipLease.acquire(at: url, waitingUpTo: 5)
            Issue.record("a leaked in-process lock must be surfaced, not waited on")
        } catch let conflict as SandboxVMOwnershipLease.OwnershipConflict {
            #expect(conflict.owner?.pid == getpid())
        }
        // Fails fast: no polling against our own lock.
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func defaultIsProcessAlive_distinguishesLiveAndDeadPids() {
        #expect(SandboxVMOwnershipLease.defaultIsProcessAlive(getpid()))
        #expect(SandboxVMOwnershipLease.defaultIsProcessAlive(1))
        #expect(!SandboxVMOwnershipLease.defaultIsProcessAlive(0))
        #expect(!SandboxVMOwnershipLease.defaultIsProcessAlive(-1))
    }

    @Test func ownerStateClassifiesEveryHolderShape() {
        typealias Lease = SandboxVMOwnershipLease
        let me: Int32 = 500
        let owner = Lease.Owner(pid: 42, processName: "osaurus", executablePath: nil, acquiredAt: "")
        let app = Lease.Holder(pid: 42, path: "/Applications/Osaurus.app/Contents/MacOS/osaurus")
        let child = Lease.Holder(pid: 77, path: "/usr/local/bin/node")
        let alive: (Int32) -> Bool = { _ in true }
        let dead: (Int32) -> Bool = { _ in false }

        #expect(Lease.ownerState(owner: owner, holders: [app], currentPID: me, isProcessAlive: alive) == .osaurusAlive)
        // An inherited descriptor in a non-Osaurus child keeps the lock held.
        #expect(Lease.ownerState(owner: owner, holders: [child], currentPID: me, isProcessAlive: dead) == .otherAlive)
        #expect(Lease.ownerState(owner: owner, holders: [], currentPID: me, isProcessAlive: dead) == .ownerDeadLockHeld)
        #expect(Lease.ownerState(owner: owner, holders: [], currentPID: me, isProcessAlive: alive) == .osaurusAlive)
        #expect(Lease.ownerState(owner: nil, holders: [], currentPID: me, isProcessAlive: alive) == .unknown)
        let leaked = Lease.Owner(pid: me, processName: "osaurus", executablePath: nil, acquiredAt: "")
        #expect(Lease.ownerState(owner: leaked, holders: [], currentPID: me, isProcessAlive: alive) == .current)
        #expect(Set(Lease.OwnerState.allCases.map(\.rawValue)) == ["self", "osaurus_alive", "other_alive", "owner_dead_lock_held", "unknown"])
    }

    @Test func childProcessesDoNotInheritTheLease() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-vm-lease-cloexec-\(UUID().uuidString).lock"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let lease = try SandboxVMOwnershipLease.acquire(at: url)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }

        let holders = SandboxVMOwnershipLease.holders(of: url).map(\.pid)
        #expect(holders.contains(getpid()))
        #expect(!holders.contains(child.processIdentifier))
        lease.release()
        #expect(SandboxVMOwnershipLease.isAvailable(at: url))
    }

    @Test func availabilityProbeReflectsTheLock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-vm-lease-probe-\(UUID().uuidString).lock"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(SandboxVMOwnershipLease.isAvailable(at: url))
        let fd = try holdForeignLock(at: url, pid: 1)
        #expect(!SandboxVMOwnershipLease.isAvailable(at: url))
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
        #expect(SandboxVMOwnershipLease.isAvailable(at: url))
    }

    /// An owner that marked itself quitting is waited on past the normal
    /// deadline; the relaunched app gets the VM instead of `vmnet_in_use`.
    @Test func quittingOwnerIsWaitedOnPastTheNormalDeadline() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-vm-lease-quitting-\(UUID().uuidString).lock"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let fd = try holdForeignLock(at: url, pid: 1, quitting: true)
        let releaser = Task {
            try await Task.sleep(nanoseconds: 800_000_000)
            _ = flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        let lease = try await SandboxVMOwnershipLease.acquire(
            at: url, waitingUpTo: 0.2, pollInterval: 0.05, isProcessAlive: { _ in true })
        lease.release()
        try await releaser.value
    }

    @Test func markCurrentOwnerQuittingOnlyTouchesItsOwnRecord() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-vm-lease-mark-\(UUID().uuidString).lock"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let lease = try SandboxVMOwnershipLease.acquire(at: url)
        #expect(SandboxVMOwnershipLease.readOwner(at: url)?.quittingSince == nil)
        SandboxVMOwnershipLease.markCurrentOwnerQuitting(at: url)
        let marked = try #require(SandboxVMOwnershipLease.readOwner(at: url))
        #expect(marked.pid == getpid())
        #expect(marked.quittingSince != nil)
        lease.release()

        let fd = try holdForeignLock(at: url, pid: 1)
        defer {
            _ = flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        SandboxVMOwnershipLease.markCurrentOwnerQuitting(at: url)
        #expect(SandboxVMOwnershipLease.readOwner(at: url)?.quittingSince == nil)
    }

    @Test func classifyConflictSeesTheProcessHoldingTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-vm-lease-holders-\(UUID().uuidString).lock"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let lease = try SandboxVMOwnershipLease.acquire(at: url)
        let held = SandboxVMOwnershipLease.classifyConflict(at: url)
        #expect(held.holders.contains { $0.pid == getpid() })
        #expect(held.state == .current)

        lease.release()
        #expect(!SandboxVMOwnershipLease.holders(of: url).contains { $0.pid == getpid() })
    }
}

#endif
