//
//  ToolsPaths.swift
//  osaurus
//
//  Provides centralized path management for plugin storage, specifications, and state directories.
//  NOTE: This file delegates to OsaurusPaths for consistency. Maintained for backward compatibility.
//

import Foundation

public enum ToolsPaths {
    /// The canonical bundle identifier for Osaurus
    public static let bundleId = "com.dinoki.osaurus"

    /// Optional root directory override for tests
    /// Note: nonisolated(unsafe) since this is only set during test setup before any concurrent access
    public nonisolated(unsafe) static var overrideRoot: URL?

    public static func appSupportRoot() -> URL {
        if let override = overrideRoot {
            return override
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
    }

    /// Tools directory (plugins)
    /// `~/Library/Application Support/com.dinoki.osaurus/Tools/`
    public static func toolsRootDirectory() -> URL {
        appSupportRoot().appendingPathComponent("Tools", isDirectory: true)
    }

    /// Plugin specifications directory
    /// `~/Library/Application Support/com.dinoki.osaurus/PluginSpecs/`
    public static func pluginSpecsRoot() -> URL {
        appSupportRoot().appendingPathComponent("PluginSpecs", isDirectory: true)
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
