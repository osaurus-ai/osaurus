//
//  AtFileMenu.swift
//  osaurus
//
//  Backing logic for the CLI-like "@" filesystem menu in the chat input.
//  Typing @ opens a completion popup that browses the filesystem. Queries are
//  resolved in a hybrid way: relative queries resolve against the active work
//  folder when one is set, otherwise against the user's home directory;
//  absolute (/...) and tilde (~...) queries are honoured directly.
//
//  All enumeration here is synchronous filesystem I/O and MUST be invoked off
//  the main actor (see FloatingInputCard's debounced listing task) so browsing
//  large directories can't trip the app-hang watchdog.
//

import Foundation

/// A single row in the "@" file menu.
public struct AtFileItem: Identifiable, Equatable, Sendable {
    public let name: String
    /// Absolute path on disk.
    public let path: String
    public let isDirectory: Bool

    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// Pure resolver + directory lister for the "@" file menu. Stateless; every
/// method is a plain `static` (the type is not actor-isolated) so callers can
/// run them from a detached task without hopping onto the main actor.
public enum AtFileMenu {
    /// Upper bound on rows handed to the popup so a huge directory can't blow
    /// up the list or the sort.
    public static let maxResults = 50

    /// Split a raw `@` query (the text after '@', which may contain '/') into
    /// the directory to enumerate and the partial leaf name to filter by.
    ///
    /// - Parameters:
    ///   - query: text typed after `@`, e.g. "" , "~/Doc", "src/", "/etc/ho".
    ///   - rootPath: the active work folder; relative queries resolve against
    ///     it, falling back to the home directory when nil.
    public static func resolve(query: String, rootPath: URL?) -> (dir: URL, filter: String) {
        let expanded: String
        if query.hasPrefix("/") {
            expanded = query
        } else if query.hasPrefix("~") {
            expanded = (query as NSString).expandingTildeInPath
        } else {
            let root = rootPath ?? URL(fileURLWithPath: NSHomeDirectory())
            expanded = query.isEmpty ? root.path : root.appendingPathComponent(query).path
        }

        // A trailing slash (or an empty query) means "list this directory";
        // otherwise the final path component is a partial name to filter by.
        if query.isEmpty || query.hasSuffix("/") {
            return (URL(fileURLWithPath: expanded, isDirectory: true), "")
        }
        let url = URL(fileURLWithPath: expanded)
        return (url.deletingLastPathComponent(), url.lastPathComponent)
    }

    /// Enumerate the directory implied by `query`, filtered by its partial leaf
    /// name. Directories sort before files, then case-insensitive alphabetical.
    ///
    /// Synchronous, blocking filesystem I/O — call from off the main actor.
    public static func list(query: String, rootPath: URL?) -> [AtFileItem] {
        let (dir, filter) = resolve(query: query, rootPath: rootPath)
        let lowerFilter = filter.lowercased()

        // Show dotfiles only once the user starts typing a leading dot.
        let options: FileManager.DirectoryEnumerationOptions =
            filter.hasPrefix(".") ? [] : [.skipsHiddenFiles]

        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: options
            )
        else { return [] }

        var items: [AtFileItem] = []
        items.reserveCapacity(entries.count)
        for url in entries {
            let name = url.lastPathComponent
            if !lowerFilter.isEmpty && !name.lowercased().hasPrefix(lowerFilter) { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            items.append(AtFileItem(name: name, path: url.path, isDirectory: isDir))
        }

        items.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        if items.count > maxResults {
            return Array(items.prefix(maxResults))
        }
        return items
    }
}
