//
//  DistributedCacheVolume.swift
//  osaurus
//
//  Where this Mac's SSD prompt cache actually lives. The panel shows the
//  configured runtime directory (shared Server cache settings, not a second
//  configuration), the volume and physical device behind it, and the quota the
//  runtime would enforce. A disconnected external disk is reported as missing,
//  never attributed to whatever volume happens to hold the parent directory.
//

import Foundation
import MLXLMCommon

/// Facts `diskutil info -plist` reports about the volume holding the cache.
struct CacheDiskFacts: Equatable, Sendable {
    enum Medium: Equatable, Sendable {
        case solidState
        case rotational
        case unknown
    }

    var volumeName: String?
    /// APFS physical store(s) (e.g. `disk5s2`), else the device identifier.
    var physicalDevice: String?
    var mediaName: String?
    var busProtocol: String?
    var isInternal: Bool?
    var isNetwork: Bool
    var medium: Medium
    var filesystem: String?

    /// Parses a `diskutil info -plist` dictionary. Absent or malformed fields
    /// stay nil/unknown; nothing is inferred from a neighbouring field.
    static func parse(_ info: [String: Any]) -> CacheDiskFacts {
        let stores = (info["APFSPhysicalStores"] as? [[String: Any]] ?? [])
            .compactMap { $0["APFSPhysicalStore"] as? String }
        let medium: Medium
        switch info["SolidState"] as? Bool {
        case true?: medium = .solidState
        case false?: medium = .rotational
        case nil: medium = .unknown
        }
        let internalFlag =
            (info["Internal"] as? Bool)
            ?? (info["DeviceLocation"] as? String).map { $0.lowercased() == "internal" }
        let filesystem = (info["FilesystemName"] as? String) ?? (info["FilesystemType"] as? String)
        let network = ["smbfs", "nfs", "afpfs", "webdav"].contains(
            (info["FilesystemType"] as? String ?? "").lowercased()
        )
        return CacheDiskFacts(
            volumeName: nonEmpty(info["VolumeName"] as? String),
            physicalDevice: stores.isEmpty
                ? nonEmpty(info["DeviceIdentifier"] as? String) : stores.joined(separator: ", "),
            mediaName: nonEmpty(info["MediaName"] as? String),
            busProtocol: nonEmpty(info["BusProtocol"] as? String),
            isInternal: internalFlag,
            isNetwork: network,
            medium: medium,
            filesystem: nonEmpty(filesystem)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Mount identity for a configured cache directory.
enum CacheLocationState: Equatable, Sendable {
    /// The directory exists on the volume its path names.
    case present
    /// Not created yet; the runtime would create it on `volumeRoot`.
    case notCreated(volumeRoot: String)
    /// The path names an external volume that is not mounted. Nothing would be
    /// written; the path's parent is NOT that volume.
    case volumeMissing(expectedMount: String)
    /// A path component is a symlink whose target does not exist.
    case danglingSymlink(link: String, target: String)
    case unreadable(String)
}

struct CacheVolumeReport: Equatable, Sendable {
    var configuredPath: String
    var resolvedPath: String
    /// Disk reuse is enabled in Server cache settings.
    var reuseEnabled: Bool
    var state: CacheLocationState
    var mountPoint: String?
    var disk: CacheDiskFacts?
    var totalBytes: Int64?
    var freeBytes: Int64?
    /// Payload bytes indexed by this cache root (same reader the quota uses).
    var usedBytes: Int64?
    /// Effective cap from the shared runtime quota policy.
    var quota: DiskCacheCapPolicy.Resolution?

    var directoryExists: Bool { state == .present }
}

enum CacheVolumeInspector {
    /// Lexical `.`/`..` normalisation. Deliberately not `standardizedFileURL`
    /// or `standardizingPath`: both strip a leading `/private`, turning
    /// `/private/var/…` back into `/var/…` — itself a symlink to
    /// `/private/var` — so a resolver built on them never terminates.
    static func lexicalComponents(_ path: String) -> [String] {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts
    }

    /// Resolves symlinks component by component, including dangling links,
    /// which `URL.resolvingSymlinksInPath()` leaves untouched. Returns the
    /// resolved path and, if one exists, the first dangling link (a link loop
    /// is reported as dangling once `maxHops` is exceeded).
    static func resolve(
        _ path: String,
        fileManager: FileManager = .default,
        maxHops: Int = 32
    ) -> (path: String, dangling: (link: String, target: String)?) {
        var pending = lexicalComponents(path)
        var resolved: [String] = []
        var hops = 0
        func joined(_ parts: [String]) -> String { "/" + parts.joined(separator: "/") }
        while !pending.isEmpty {
            let component = pending.removeFirst()
            let candidate = joined(resolved + [component])
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: candidate) else {
                resolved.append(component)
                continue
            }
            hops += 1
            let target = destination.hasPrefix("/") ? destination : joined(resolved) + "/" + destination
            let targetParts = lexicalComponents(target)
            if hops > maxHops || !fileManager.fileExists(atPath: joined(targetParts)) {
                return (joined(targetParts + pending), (candidate, destination))
            }
            // Re-resolve the target from the root: it may contain links too.
            resolved = []
            pending = targetParts + pending
        }
        return (joined(resolved), nil)
    }

    /// `/Volumes/<name>` when `path` lives under an external mount point.
    static func expectedExternalMount(for path: String) -> String? {
        let parts = lexicalComponents(path)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }

    /// Mount identity from facts already gathered: the nearest existing
    /// ancestor of the resolved path and the mount point of the volume holding
    /// that ancestor (nil when it could not be identified).
    static func classify(
        resolvedPath: String,
        dangling: (link: String, target: String)?,
        existingAncestor: String,
        ancestorMount: String?,
        expectedMountExists: Bool
    ) -> (state: CacheLocationState, mountPoint: String?) {
        let expected = expectedExternalMount(for: resolvedPath)
        if let dangling {
            // A symlink into an ejected /Volumes disk is the common case.
            if let expected, !expectedMountExists {
                return (.volumeMissing(expectedMount: expected), nil)
            }
            return (.danglingSymlink(link: dangling.link, target: dangling.target), nil)
        }
        guard let mount = ancestorMount else {
            return (.unreadable("Could not identify the volume for \(existingAncestor)"), nil)
        }
        // /Volumes/<name> must itself be the mount point. A leftover directory
        // of that name on the startup disk is not the external SSD.
        if let expected, mount != expected {
            return (.volumeMissing(expectedMount: expected), nil)
        }
        return (existingAncestor == resolvedPath ? .present : .notCreated(volumeRoot: mount), mount)
    }

    /// Gathers the facts for `classify` from the file system.
    static func locate(
        resolvedPath: String,
        dangling: (link: String, target: String)?,
        fileManager: FileManager = .default
    ) -> (state: CacheLocationState, mountPoint: String?) {
        var ancestor = resolvedPath
        while !fileManager.fileExists(atPath: ancestor), ancestor != "/" {
            ancestor = (ancestor as NSString).deletingLastPathComponent
            if ancestor.isEmpty { ancestor = "/" }
        }
        let expected = expectedExternalMount(for: resolvedPath)
        return classify(
            resolvedPath: resolvedPath,
            dangling: dangling,
            existingAncestor: ancestor,
            ancestorMount: dangling == nil ? volumeRoot(of: ancestor) : nil,
            expectedMountExists: expected.map { fileManager.fileExists(atPath: $0) } ?? false
        )
    }

    static func volumeRoot(of path: String) -> String? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey])
        return values?.volume?.standardizedFileURL.path
    }

    /// Full read-only inspection. Never creates the directory.
    static func inspect(
        configured directory: URL,
        reuseEnabled: Bool,
        cacheSettings: VMLXServerCacheSettings
    ) -> CacheVolumeReport {
        let (resolved, dangling) = resolve(directory.path)
        let (state, mount) = locate(resolvedPath: resolved, dangling: dangling)
        var report = CacheVolumeReport(
            configuredPath: directory.path,
            resolvedPath: resolved,
            reuseEnabled: reuseEnabled,
            state: state,
            mountPoint: mount
        )
        guard let mount else { return report }
        if let text = DiagnosticCommand.run("/usr/sbin/diskutil", ["info", "-plist", mount]).output,
            let info = try? PropertyListSerialization.propertyList(from: text, format: nil) as? [String: Any]
        {
            report.disk = CacheDiskFacts.parse(info)
        }
        let volume = DiskCacheVolumeSnapshot.read(directory: URL(fileURLWithPath: resolved))
        report.totalBytes = volume.totalBytes
        report.freeBytes = volume.freeBytes
        report.usedBytes = state == .present ? volume.ownBytes : 0
        report.quota = ModelRuntime.diskCacheCap(for: cacheSettings, directory: URL(fileURLWithPath: resolved))
        return report
    }
}
