import Foundation
import Testing

@testable import OsaurusCore

#if os(macOS)

@Suite
struct SandboxLegacyRootfsCleanupTests {
    private func makeContainerDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-legacy-rootfs-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("osaurus-sandbox")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func failedBootCleanupKeepsPrePodRootfs() throws {
        let dir = try makeContainerDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let legacy = dir.appendingPathComponent("rootfs.ext4")
        try Data("guest packages".utf8).write(to: legacy)
        try Data("log".utf8).write(to: dir.appendingPathComponent("bootlog.log"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("state"), withIntermediateDirectories: true)

        try SandboxManager.removeContainerStateKeepingLegacyRootfs(at: dir)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining == ["rootfs.ext4"])
        #expect(try Data(contentsOf: legacy) == Data("guest packages".utf8))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)
        #expect(siblings == ["osaurus-sandbox"])
    }

    @Test func failedBootCleanupWithoutLegacyRootfsRemovesDirectory() throws {
        let dir = try makeContainerDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try Data("log".utf8).write(to: dir.appendingPathComponent("bootlog.log"))

        try SandboxManager.removeContainerStateKeepingLegacyRootfs(at: dir)

        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}

#endif
