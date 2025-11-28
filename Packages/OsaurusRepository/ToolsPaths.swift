//
//  ToolsPaths.swift
//  osaurus
//
//  Provides centralized path management for plugin storage, specifications, and state directories.
//

import Foundation

public enum ToolsPaths {
    public static func appSupportRoot() -> URL {
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
    }

    public static func toolsRootDirectory() -> URL {
        appSupportRoot().appendingPathComponent("Tools", isDirectory: true)
    }

    public static func pluginSpecsRoot() -> URL {
        appSupportRoot().appendingPathComponent("PluginSpecs", isDirectory: true)
    }

}
