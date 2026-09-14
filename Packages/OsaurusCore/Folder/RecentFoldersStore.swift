//
//  RecentFoldersStore.swift
//  osaurus
//
//  Process-wide list of the folders the user most recently attached as a
//  working folder, so the composer and agent editor can offer them instead of
//  sending the user through the open panel for the same few folders again
//  and again. Every explicit pick (chat folder chip, agent editor Working
//  Folder row, project folder) records here; agent/project defaults being
//  adopted by a fresh chat do NOT, since those were recorded when picked.
//

import Foundation
import os.log

private let recentLog = Logger(subsystem: "ai.osaurus", category: "RecentFolders")

@MainActor
public final class RecentFoldersStore: ObservableObject {
    public static let shared = RecentFoldersStore()

    /// One remembered folder. The security-scoped bookmark is kept beside the
    /// path so the folder can be re-opened without a fresh open-panel grant;
    /// the path alone is the fallback when the bookmark has gone stale.
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public let path: String
        public let bookmark: Data?

        public var id: String { path }
        /// String-only: `URL(fileURLWithPath:)` stats the path to decide whether
        /// it is a directory, which is filesystem I/O on whatever thread renders
        /// the row (a network volume could stall it).
        public var name: String { (path as NSString).lastPathComponent }

        public init(path: String, bookmark: Data?) {
            self.path = path
            self.bookmark = bookmark
        }
    }

    /// Most recent first.
    @Published public private(set) var entries: [Entry] = []

    public static let limit = 5
    private static let defaultsKey = "RecentWorkingFolders"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.load(from: defaults)
    }

    // MARK: - Mutation

    /// Move (or insert) a folder to the front of the list. Callers pass an
    /// already-standardized path; only trailing slashes are trimmed here, with
    /// pure string work so nothing touches the filesystem on the main actor.
    public func record(path: String, bookmark: Data?) {
        let normalized = Self.trimTrailingSlashes(path)
        guard !normalized.isEmpty else { return }
        var next = entries.filter { $0.path != normalized }
        next.insert(Entry(path: normalized, bookmark: bookmark), at: 0)
        if next.count > Self.limit { next = Array(next.prefix(Self.limit)) }
        guard next != entries else { return }
        entries = next
        save()
    }

    /// Forget one folder (the row's remove affordance, or a folder that no
    /// longer resolves).
    public func remove(path: String) {
        let before = entries.count
        entries.removeAll { $0.path == path }
        guard entries.count != before else { return }
        save()
    }

    /// Drop entries whose directory is gone. The existence checks are
    /// filesystem I/O (possibly on a network volume), so they run detached
    /// and apply on the main actor when done. Called when a recents list
    /// appears so a deleted folder disappears rather than failing on pick.
    public func pruneMissing() {
        let snapshot = entries
        guard !snapshot.isEmpty else { return }
        Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                snapshot.filter { !Self.directoryExists(at: $0.path) }.map(\.path)
            }.value
            guard let self, !missing.isEmpty else { return }
            for path in missing { self.remove(path: path) }
        }
    }

    // MARK: - Resolution

    /// Resolve an entry to a URL the chat can adopt. Prefers the stored
    /// security-scoped bookmark; falls back to the plain path when the
    /// bookmark is stale but the directory still exists. Bookmark resolution
    /// is synchronous IPC, so it runs off the main actor.
    public nonisolated static func resolveURL(for entry: Entry) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            if let bookmark = entry.bookmark,
                let url = FolderContextService.resolveSecurityScopedURL(from: bookmark)
            {
                return url
            }
            guard directoryExists(at: entry.path) else { return nil }
            return URL(fileURLWithPath: entry.path, isDirectory: true)
        }.value
    }

    private nonisolated static func trimTrailingSlashes(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    private nonisolated static func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            recentLog.error("failed to save recent folders: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Test hook: clear persisted state.
    func _resetForTesting() {
        entries = []
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
