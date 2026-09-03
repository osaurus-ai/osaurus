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

    /// The real sentinels are SQLite databases; the probe now requires this
    /// exact header, so a genuine grant reads it while a TCC-blocked read
    /// (throwing OR returning empty/garbage) does not.
    static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    /// Write a valid SQLite-header sentinel at `relative` under `root`.
    @discardableResult
    static func writeSentinel(_ relative: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sqliteHeader.write(to: url)
        return url
    }

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
        try Self.sqliteHeader.write(to: tccDatabase)

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
        try Self.sqliteHeader.write(to: readable)

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

    /// Regression for GitHub #2613: on macOS 15.7.9 a TCC-blocked read can
    /// return EOF/empty instead of throwing, so "opened and read without an
    /// error" still reported a false grant even after the open→read fix. The
    /// real sentinels (TCC.db / chat.db) are SQLite databases that always
    /// begin with the SQLite header, so an empty read must count as NOT
    /// granted — otherwise a blocked-as-empty read is mistaken for access.
    @Test func fullDiskAccessProbeRejectsWhenProtectedFileIsEmpty() throws {
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

        #expect(!SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
    }

    /// A readable file whose bytes are NOT the SQLite header (a stale or
    /// TCC-substituted file) must not flip the probe to granted. This closes
    /// the same #2613 class where a non-throwing read of the wrong content was
    /// treated as access.
    @Test func fullDiskAccessProbeRejectsReadableNonSQLiteContent() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        for relative in ["Library/Application Support/com.apple.TCC/TCC.db", "Library/Messages/chat.db"] {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("not a sqlite database at all".utf8).write(to: url)
        }

        #expect(!SystemPermissionProbe.fullDiskAccessGranted(homeDirectory: root, resources: Self.testResources))
    }

    /// A genuine grant reads the real SQLite header from every existing
    /// sentinel and reports granted.
    @Test func fullDiskAccessProbeGrantsWhenSentinelsHaveSQLiteHeader() throws {
        let root = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.writeSentinel("Library/Application Support/com.apple.TCC/TCC.db", under: root)
        try Self.writeSentinel("Library/Messages/chat.db", under: root)

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
