//
//  DistributedCacheVolumeTests.swift
//  OsaurusCoreTests
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct CacheDiskFactsTests {
    @Test func internalStartupDisk() {
        let facts = CacheDiskFacts.parse(DistributedFixtures.internalDisk)
        #expect(facts.volumeName == "Macintosh HD")
        #expect(facts.physicalDevice == "disk0s2", "APFS physical store, not the synthesized volume")
        #expect(facts.mediaName == nil, "empty MediaName is absent, not a name")
        #expect(facts.busProtocol == "Apple Fabric")
        #expect(facts.isInternal == true)
        #expect(facts.medium == .solidState)
        #expect(!facts.isNetwork)
    }

    @Test func externalThunderboltSSD() {
        let facts = CacheDiskFacts.parse(DistributedFixtures.externalDisk)
        #expect(facts.volumeName == "ModelSSD")
        #expect(facts.physicalDevice == "disk6s2")
        #expect(facts.busProtocol == "PCI-Express")
        #expect(facts.isInternal == false)
        #expect(facts.medium == .solidState)
    }

    @Test func missingAndMalformedFieldsStayUnknown() {
        let facts = CacheDiskFacts.parse([
            "SolidState": "yes", "Internal": 1 as Any, "APFSPhysicalStores": "disk0", "VolumeName": "  ",
        ])
        #expect(facts.medium == .unknown, "a non-Bool SolidState is not evidence of an SSD")
        #expect(facts.isInternal == nil)
        #expect(facts.physicalDevice == nil)
        #expect(facts.volumeName == nil)
        let empty = CacheDiskFacts.parse([:])
        #expect(empty.medium == .unknown && empty.isInternal == nil && empty.physicalDevice == nil)
    }

    @Test func rotationalAndDeviceLocationFallback() {
        let facts = CacheDiskFacts.parse([
            "SolidState": false, "DeviceLocation": "External", "DeviceIdentifier": "disk9s1",
        ])
        #expect(facts.medium == .rotational)
        #expect(facts.isInternal == false)
        #expect(facts.physicalDevice == "disk9s1")
    }

    @Test func networkVolumeIsFlagged() {
        #expect(CacheDiskFacts.parse(["FilesystemType": "smbfs"]).isNetwork)
        #expect(CacheDiskFacts.parse(["FilesystemType": "NFS"]).isNetwork)
        #expect(!CacheDiskFacts.parse(["FilesystemType": "apfs"]).isNetwork)
    }
}

struct CacheLocationTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distributed-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // realpath, not resolvingSymlinksInPath: the latter strips /private.
        let real = try #require(realpath(url.path, nil))
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    @Test func systemSymlinkedRootsResolveInsteadOfLooping() {
        // /var, /tmp and /etc are links into /private; standardizing a path
        // strips /private again, which used to loop until the hop limit and
        // report every cache folder under them as a dangling link.
        #expect(CacheVolumeInspector.resolve("/var").path == "/private/var")
        #expect(CacheVolumeInspector.resolve("/var").dangling == nil)
        let tmp = CacheVolumeInspector.resolve("/tmp/osaurus-not-created/cache")
        #expect(tmp.path == "/private/tmp/osaurus-not-created/cache")
        #expect(tmp.dangling == nil)
        #expect(CacheVolumeInspector.resolve("/private/var/../var/./folders").path == "/private/var/folders")
    }

    @Test func lexicalNormalisationKeepsPrivate() {
        #expect(CacheVolumeInspector.lexicalComponents("/private/var//x/./y/../z") == ["private", "var", "x", "z"])
        #expect(CacheVolumeInspector.lexicalComponents("/..") == [])
    }

    @Test func externalMountIsDerivedFromVolumesPaths() {
        #expect(CacheVolumeInspector.expectedExternalMount(for: "/Volumes/Work/cache/x") == "/Volumes/Work")
        #expect(CacheVolumeInspector.expectedExternalMount(for: "/Volumes/Work") == "/Volumes/Work")
        #expect(CacheVolumeInspector.expectedExternalMount(for: "/Volumes") == nil)
        #expect(CacheVolumeInspector.expectedExternalMount(for: "/Users/me/.osaurus/cache") == nil)
    }

    @Test func mountedExternalDirectoryIsPresent() {
        let result = CacheVolumeInspector.classify(
            resolvedPath: "/Volumes/Work/cache",
            dangling: nil,
            existingAncestor: "/Volumes/Work/cache",
            ancestorMount: "/Volumes/Work",
            expectedMountExists: true
        )
        #expect(result.state == .present)
        #expect(result.mountPoint == "/Volumes/Work")
    }

    @Test func notCreatedOnMountedExternalVolume() {
        let result = CacheVolumeInspector.classify(
            resolvedPath: "/Volumes/Work/cache",
            dangling: nil,
            existingAncestor: "/Volumes/Work",
            ancestorMount: "/Volumes/Work",
            expectedMountExists: true
        )
        #expect(result.state == .notCreated(volumeRoot: "/Volumes/Work"))
    }

    @Test func ejectedVolumeIsMissingNotTheStartupDisk() {
        // The nearest existing ancestor is /Volumes on the startup disk.
        let result = CacheVolumeInspector.classify(
            resolvedPath: "/Volumes/Work/cache",
            dangling: nil,
            existingAncestor: "/Volumes",
            ancestorMount: "/",
            expectedMountExists: false
        )
        #expect(result.state == .volumeMissing(expectedMount: "/Volumes/Work"))
        #expect(result.mountPoint == nil, "no volume facts or quota may be attributed to /")
    }

    @Test func leftoverMountpointDirectoryIsNotTheExternalSSD() {
        // /Volumes/Work exists as a plain folder on the startup disk.
        let result = CacheVolumeInspector.classify(
            resolvedPath: "/Volumes/Work/cache",
            dangling: nil,
            existingAncestor: "/Volumes/Work/cache",
            ancestorMount: "/",
            expectedMountExists: true
        )
        #expect(result.state == .volumeMissing(expectedMount: "/Volumes/Work"))
    }

    @Test func danglingSymlinkIntoEjectedVolumeIsMissingVolume() {
        let result = CacheVolumeInspector.classify(
            resolvedPath: "/Volumes/Work/cache",
            dangling: ("/Users/me/cache", "/Volumes/Work/cache"),
            existingAncestor: "/Users/me",
            ancestorMount: nil,
            expectedMountExists: false
        )
        #expect(result.state == .volumeMissing(expectedMount: "/Volumes/Work"))
    }

    @Test func danglingSymlinkElsewhereIsReportedAsSuch() {
        let result = CacheVolumeInspector.classify(
            resolvedPath: "/private/gone/cache",
            dangling: ("/Users/me/cache", "/private/gone/cache"),
            existingAncestor: "/Users/me",
            ancestorMount: nil,
            expectedMountExists: false
        )
        #expect(result.state == .danglingSymlink(link: "/Users/me/cache", target: "/private/gone/cache"))
    }

    @Test func unidentifiableVolumeIsUnreadable() {
        let result = CacheVolumeInspector.classify(
            resolvedPath: "/x/y",
            dangling: nil,
            existingAncestor: "/x",
            ancestorMount: nil,
            expectedMountExists: false
        )
        guard case .unreadable = result.state else {
            Issue.record("expected unreadable, got \(result.state)")
            return
        }
    }

    @Test func resolveFollowsSymlinksIncludingRelative() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("abs").path,
            withDestinationPath: real.path
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("rel").path,
            withDestinationPath: "real"
        )

        let absolute = CacheVolumeInspector.resolve(root.appendingPathComponent("abs/sub").path)
        #expect(absolute.path == real.appendingPathComponent("sub").path)
        #expect(absolute.dangling == nil)
        let relative = CacheVolumeInspector.resolve(root.appendingPathComponent("rel/cache").path)
        #expect(relative.path == real.path)
    }

    @Test func resolveReportsDanglingLinkAndKeepsTheTail() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = "/Volumes/osaurus-test-\(UUID().uuidString)/cache"
        let link = root.appendingPathComponent("cache").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: missing)
        let resolved = CacheVolumeInspector.resolve(link + "/kv")
        #expect(resolved.path == missing + "/kv")
        #expect(resolved.dangling?.link == link)
        #expect(resolved.dangling?.target == missing)
        let located = CacheVolumeInspector.locate(resolvedPath: resolved.path, dangling: resolved.dangling)
        #expect(
            located.state == .volumeMissing(expectedMount: CacheVolumeInspector.expectedExternalMount(for: missing)!)
        )
    }

    @Test func resolveStopsOnSymlinkLoops() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("a").path,
            withDestinationPath: root.appendingPathComponent("b").path
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("b").path,
            withDestinationPath: root.appendingPathComponent("a").path
        )
        let resolved = CacheVolumeInspector.resolve(root.appendingPathComponent("a/x").path, maxHops: 8)
        #expect(resolved.dangling != nil, "a loop must terminate and be reported, not spin")
    }

    @Test func inspectExistingTemporaryDirectoryUsesSharedQuotaPolicy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = VMLXServerCacheSettings()
        settings.blockDisk.maxSizePercent = 1
        let report = CacheVolumeInspector.inspect(configured: root, reuseEnabled: true, cacheSettings: settings)
        #expect(report.state == .present)
        #expect(report.directoryExists)
        #expect(report.mountPoint != nil)
        #expect(report.usedBytes == 0, "no cache_index.db means no indexed payload")
        let quota = try #require(report.quota)
        #expect(quota == ModelRuntime.diskCacheCap(for: settings, directory: root))
        #expect(quota.rule == .explicitPercent)
        #expect(report.disk?.medium != nil)
        #expect(report.freeBytes != nil && report.totalBytes != nil)
    }

    @Test func inspectNeverCreatesTheDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("not/yet", isDirectory: true)
        let report = CacheVolumeInspector.inspect(
            configured: target,
            reuseEnabled: true,
            cacheSettings: VMLXServerCacheSettings()
        )
        guard case .notCreated = report.state else {
            Issue.record("expected notCreated, got \(report.state)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(report.usedBytes == 0)
    }

    @Test func inspectMissingVolumeReportsNoVolumeFacts() {
        let path = URL(fileURLWithPath: "/Volumes/osaurus-absent-\(UUID().uuidString)/cache")
        let report = CacheVolumeInspector.inspect(
            configured: path,
            reuseEnabled: true,
            cacheSettings: VMLXServerCacheSettings()
        )
        #expect(report.state == .volumeMissing(expectedMount: path.deletingLastPathComponent().path))
        #expect(report.disk == nil && report.quota == nil && report.freeBytes == nil && report.usedBytes == nil)
    }
}
