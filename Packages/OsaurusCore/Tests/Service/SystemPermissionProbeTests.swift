import Foundation
import Testing

@testable import OsaurusCore

struct SystemPermissionProbeTests {
    /// Hermetic sentinels resolved entirely under the injected temp home, so
    /// the probe's logic (existence filtering, fail-closed allSatisfy, the
    /// read-a-byte check) is exercised without touching the real machine-wide
    /// `/Library` TCC database. The default resource list, which anchors on
    /// that system database, is pinned separately below.
    static let testResources: [SystemPermissionProbe.FullDiskResource] = [
        .init(location: .home, path: "Library/Application Support/com.apple.TCC/TCC.db"),
        .init(location: .home, path: "Library/Messages/chat.db"),
    ]

    /// The false-positive fix for #2601: the probe must anchor on the SYSTEM
    /// TCC database (absolute, unconditionally FDA-gated), never the per-user
    /// one that some macOS versions let the user read without FDA.
    @Test func defaultResourcesAnchorOnSystemTCCDatabase() {
        let system = SystemPermissionProbe.defaultFullDiskResources.first {
            $0.location == .system
        }
        #expect(system?.path == "/Library/Application Support/com.apple.TCC/TCC.db")
        // The unreliable per-user TCC database must not be a sentinel.
        #expect(
            !SystemPermissionProbe.defaultFullDiskResources.contains {
                $0.location == .home && $0.path.contains("com.apple.TCC")
            }
        )
    }

    @Test func fullDiskAccessProbeDoesNotTreatReadableSafariDirectoryAsGrant() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        let safariDirectory = root.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: safariDirectory, withIntermediateDirectories: true)

        let granted = SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources)

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

        let granted = SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources)

        #expect(granted)
    }

    @Test func fullDiskAccessProbeReturnsFalseWhenProtectedFilesAreAbsent() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
    }

    /// Regression for GitHub #2523: on upgraded Macs a legacy, no longer
    /// TCC-protected `~/Library/Safari` file could be readable without any
    /// FDA grant. A stray readable file outside the sentinel set must not
    /// flip the probe to granted.
    @Test func fullDiskAccessProbeIgnoresStaleUnprotectedSafariFiles() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        let bookmarks = root.appendingPathComponent("Library/Safari/Bookmarks.plist")
        try FileManager.default.createDirectory(
            at: bookmarks.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: bookmarks)

        #expect(!SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
    }

    /// The probe fails closed: every sentinel file that exists must be
    /// readable. One readable file next to an unreadable one is what a
    /// partial / revoked grant looks like, not FDA.
    @Test func fullDiskAccessProbeRejectsWhenAnyExistingProtectedFileIsUnreadable() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        let readable = root.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        try FileManager.default.createDirectory(
            at: readable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: readable)

        let unreadable = root.appendingPathComponent("Library/Messages/chat.db")
        try FileManager.default.createDirectory(
            at: unreadable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: unreadable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: unreadable.path
        )
        defer {
            // Restore permissions so the temp-directory cleanup can delete it.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: unreadable.path
            )
        }

        #expect(!SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
    }

    /// The probe now READS a byte rather than only opening the handle, so a
    /// TCC-blocked read no longer reports a false grant (#2601). A genuinely
    /// empty-but-readable sentinel must still count as readable — reading it
    /// returns no bytes without throwing, and that must not be mistaken for a
    /// blocked read.
    @Test func fullDiskAccessProbeGrantsWhenProtectedFileIsEmptyButReadable() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        for relative in ["Library/Application Support/com.apple.TCC/TCC.db", "Library/Messages/chat.db"] {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }

        #expect(SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
    }

    @Test func fullDiskAccessProbeGrantsWhenEveryExistingProtectedFileIsReadable() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        for relative in ["Library/Application Support/com.apple.TCC/TCC.db", "Library/Messages/chat.db"] {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("test".utf8).write(to: url)
        }

        #expect(SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
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
