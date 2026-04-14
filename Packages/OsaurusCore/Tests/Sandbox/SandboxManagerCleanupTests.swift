import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SandboxManagerCleanupTests {
    private let manager = SandboxManager.shared

    @Test
    func cleanupAfterFailure_removesStaleContainerDirectory() async throws {
        let staleDir = await manager.staleContainerDir
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
        #expect(FileManager.default.fileExists(atPath: staleDir.path))

        await manager.cleanupAfterFailure()

        #expect(!FileManager.default.fileExists(atPath: staleDir.path))
    }

    @Test
    func cleanupAfterFailure_stopsBridgeServer() async throws {
        let socketPath = OsaurusPaths.container()
            .appendingPathComponent("test-bridge.sock").path
        try OsaurusPaths.ensureExists(OsaurusPaths.container())
        try await HostAPIBridgeServer.shared.start(socketPath: socketPath)
        #expect(await HostAPIBridgeServer.shared.isRunning)

        await manager.cleanupAfterFailure()

        #expect(await !HostAPIBridgeServer.shared.isRunning)
    }

    @Test
    func cleanupAfterFailure_setsStatusToStopped() async throws {
        await MainActor.run { SandboxManager.State.shared.status = .starting }

        await manager.cleanupAfterFailure()

        let status = await manager.refreshStatus()
        #expect(status == .stopped || status == .notProvisioned)
    }

    @Test
    func cleanupAfterFailure_isIdempotent() async throws {
        // Running cleanup twice should not crash or leave bad state,
        // even when there's nothing to clean up.
        await manager.cleanupAfterFailure()
        await manager.cleanupAfterFailure()

        let status = await manager.refreshStatus()
        #expect(status == .stopped || status == .notProvisioned)
    }
}
