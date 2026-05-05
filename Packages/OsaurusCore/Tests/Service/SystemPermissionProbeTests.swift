import Foundation
import Testing

@testable import OsaurusCore

struct SystemPermissionProbeTests {
    @Test func fullDiskAccessProbeDoesNotTreatReadableSafariDirectoryAsGrant() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        let safariDirectory = root.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: safariDirectory, withIntermediateDirectories: true)

        let granted = SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root)

        #expect(!granted)
    }

    @Test func fullDiskAccessProbeRequiresReadableProtectedFile() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        let tccDatabase = root.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        try FileManager.default.createDirectory(
            at: tccDatabase.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: tccDatabase)

        let granted = SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root)

        #expect(granted)
    }

    @Test func fullDiskAccessProbeReturnsFalseWhenProtectedFilesAreAbsent() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root))
    }

    @Test func screenRecordingProbeUsesCoreGraphicsPreflightResult() {
        #expect(SystemPermissionProbe.screenRecordingGranted(preflight: { true }))
        #expect(!SystemPermissionProbe.screenRecordingGranted(preflight: { false }))
    }

    private func makeTemporaryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-permission-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
