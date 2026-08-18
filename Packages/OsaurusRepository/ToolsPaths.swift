//
//  ToolsPaths.swift
//  osaurus
//
//  Path management for plugin storage and specifications.
//  Mirrors OsaurusPaths.root() for use in the OsaurusRepository package.
//

import Foundation

public enum ToolsPaths {
    /// Optional root directory override for tests
    private static let overrideRootLock = NSLock()
    nonisolated(unsafe) private static var overrideRootStorage: URL?
    public static var overrideRoot: URL? {
        get {
            overrideRootLock.lock()
            defer { overrideRootLock.unlock() }
            return overrideRootStorage
        }
        set {
            overrideRootLock.lock()
            overrideRootStorage = newValue
            overrideRootLock.unlock()
        }
    }

    /// The root data directory for Osaurus: `~/.osaurus/`
    public static func root() -> URL {
        ProcessDataRootPolicy.resolvedRoot(
            overrideRoot: overrideRoot,
            defaultRoot: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".osaurus", isDirectory: true)
        )
    }

    /// Tools directory (plugins)
    /// `~/.osaurus/Tools/`
    public static func toolsRootDirectory() -> URL {
        root().appendingPathComponent("Tools", isDirectory: true)
    }

    /// Plugin specifications directory
    /// `~/.osaurus/PluginSpecs/`
    public static func pluginSpecsRoot() -> URL {
        root().appendingPathComponent("PluginSpecs", isDirectory: true)
    }

    /// Ensures a directory exists, creating it if necessary
    /// - Parameter url: The directory URL to ensure exists
    public static func ensureExists(_ url: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
