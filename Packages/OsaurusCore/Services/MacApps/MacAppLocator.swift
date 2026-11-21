//
//  MacAppLocator.swift
//  osaurus
//
//  Finds Mac apps by bundle id (LaunchServices) and lists the apps in the
//  standard app folders. Workflow setup uses it to check a declared app is
//  installed; the Architect's `workflow_discover` `apps` and the Mac App
//  automation's picker use the listing.
//

import AppKit
import Foundation

public struct InstalledMacApp: Equatable, Sendable, Identifiable {
    public var bundleID: String
    public var name: String
    public var url: URL
    public var version: String?

    public var id: String { bundleID.lowercased() }
}

public enum MacAppLocator {

    /// Folders the listing reads, each with its direct subfolders that are
    /// not apps (`/Applications/Utilities`, a vendor folder).
    public static var searchFolders: [URL] {
        var folders = ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications"]
            .map { URL(fileURLWithPath: $0) }
        folders.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        return folders
    }

    /// The installed app with this bundle id, or nil.
    public static func locate(bundleID: String) -> InstalledMacApp? {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return info(at: url)
            ?? InstalledMacApp(bundleID: id, name: url.deletingPathExtension().lastPathComponent, url: url)
    }

    public static func isInstalled(bundleID: String) -> Bool {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    /// Bundle id, display name, and version of the app at `url`.
    static func info(at url: URL) -> InstalledMacApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let localized = bundle.localizedInfoDictionary ?? [:]
        let plist = bundle.infoDictionary ?? [:]
        let name =
            (localized["CFBundleDisplayName"] as? String) ?? (plist["CFBundleDisplayName"] as? String)
            ?? (localized["CFBundleName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)
        return InstalledMacApp(bundleID: id, name: name, url: url, version: version)
    }

    /// Every app in `searchFolders`, by name, one per bundle id.
    public static func installedApps(in folders: [URL] = searchFolders) -> [InstalledMacApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [InstalledMacApp] = []
        func add(_ url: URL) {
            guard let app = info(at: url), seen.insert(app.id).inserted else { return }
            out.append(app)
        }
        for folder in folders {
            guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
            else { continue }
            for entry in entries {
                if entry.pathExtension == "app" {
                    add(entry)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                    let nested = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)
                {
                    nested.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Installed apps whose name or bundle id contains every word of
    /// `query`, best match first (exact name, then name prefix).
    public static func search(_ query: String, in apps: [InstalledMacApp], limit: Int = 10) -> [InstalledMacApp] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Array(apps.prefix(limit)) }
        let needle = words.joined(separator: " ")
        let matches = apps.filter { app in
            let haystack = (app.name + " " + app.bundleID).lowercased()
            return words.allSatisfy(haystack.contains)
        }
        func rank(_ app: InstalledMacApp) -> Int {
            let name = app.name.lowercased()
            if name == needle || app.bundleID.lowercased() == needle { return 0 }
            if name.hasPrefix(needle) { return 1 }
            return 2
        }
        return Array(matches.sorted { rank($0) < rank($1) }.prefix(limit))
    }
}
