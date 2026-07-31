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
}

#endif
