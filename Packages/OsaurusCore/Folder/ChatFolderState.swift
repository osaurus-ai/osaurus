//
//  ChatFolderState.swift
//  osaurus
//
//  Per-chat-session working-folder state. Each `ChatSession` owns one of
//  these; picking, refreshing, or clearing a folder affects ONLY that chat.
//  The state owns its security-scoped URL (balanced start/stop), the
//  persistable bookmark, and the built `FolderContext` used for prompt
//  composition and tool scoping.
//

import AppKit
import Foundation
import os.log

private let folderLog = Logger(subsystem: "ai.osaurus", category: "FolderState")

/// Session-scoped working-folder state. Replaces the old process-wide
/// `FolderContextService.currentContext` singleton state so concurrent chats
/// can each work against their own folder.
@MainActor
public final class ChatFolderState: ObservableObject {

    /// The built folder context for this chat, nil when no folder is active.
    @Published public private(set) var context: FolderContext? {
        didSet {
            Self.updateLiveRoot(for: ObjectIdentifier(self), path: context?.rootPath.standardizedFileURL.path)
        }
    }

    /// Security-scoped bookmark persisted with the owning chat session so the
    /// folder survives relaunch. Kept in lockstep with `context`.
    public private(set) var bookmark: Data?

    /// Last known display path (non-sensitive). Survives a stale bookmark so
    /// the UI/persistence can still show where the folder used to live.
    public private(set) var lastKnownPath: String?

    /// URL currently holding security-scoped access. Every successful
    /// `startAccessingSecurityScopedResource()` is balanced on clear,
    /// replacement, or deinit.
    private var securityScopedURL: URL?

    /// Monotonic guard so a slow restore/set can't clobber a newer one.
    private var generation = 0

    /// Fired after a USER-initiated mutation (`setFolder` / `clearFolder`)
    /// — never for persistence restores — so the owning session can mark
    /// itself dirty and save promptly. Without this, a folder picked
    /// mid-conversation is only persisted by the next turn/teardown save
    /// and is lost on a crash or force-quit.
    public var onFolderMutated: (() -> Void)?

    public init() {}

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        Self.updateLiveRoot(for: ObjectIdentifier(self), path: nil)
    }

    // MARK: - Derived state

    public var hasActiveFolder: Bool { context != nil }

    /// Root of the active folder, nil when none is selected.
    public var rootPath: URL? { context?.rootPath }

    // MARK: - Selection

    /// Open the system folder picker and set the chosen folder on this chat.
    /// Pass the owning chat window so the picker presents as a sheet attached
    /// to it — a detached panel has to fight the (floating-capable) chat
    /// panel for key status and z-order, which flickers; a sheet can't, and
    /// it makes visually obvious WHICH chat the folder is being attached to.
    /// Falls back to a detached panel when no window is available.
    @discardableResult
    public func selectFolder(from window: NSWindow? = nil) async -> FolderContext? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L("Select Working Directory")
        panel.message = L("Choose a folder for the AI to work with")
        panel.prompt = L("Select")

        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.beginModal()
        }
        guard response == .OK, let url = panel.url else {
            return nil
        }
        return await setFolder(url)
    }

    /// Set a folder programmatically: mint a security-scoped bookmark, start
    /// access, and build the context. Replaces any previous folder on this
    /// chat only.
    @discardableResult
    public func setFolder(_ url: URL) async -> FolderContext? {
        generation += 1
        let myGeneration = generation

        // Creating a security-scoped bookmark does synchronous IPC and can
        // stall for seconds; keep it off the main actor so it doesn't trip
        // the app-hang watchdog.
        let bookmarkData: Data
        do {
            bookmarkData = try await Task.detached(priority: .userInitiated) {
                try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }.value
        } catch {
            return nil
        }

        guard generation == myGeneration else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }

        let built = await FolderContextService.shared.buildContext(from: url)
        guard generation == myGeneration else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }

        releaseCurrentScope()
        securityScopedURL = url
        bookmark = bookmarkData
        lastKnownPath = url.standardizedFileURL.path
        // Folder tools register lazily on first mount anywhere in the
        // process; their bodies resolve the root per execution scope.
        FolderToolManager.shared.ensureFolderToolsRegistered()
        context = built
        onFolderMutated?()
        return built
    }

    /// Clear this chat's folder and release security-scoped access.
    public func clearFolder() {
        generation += 1
        releaseCurrentScope()
        let hadFolder = bookmark != nil || context != nil || lastKnownPath != nil
        bookmark = nil
        lastKnownPath = nil
        context = nil
        // Only a real clear counts as a mutation — `reset()` and restores
        // call this on already-empty state and must not dirty the session.
        if hadFolder {
            onFolderMutated?()
        }
    }

    /// Rebuild the context (tree, git status, …) for the current folder.
    public func refreshContext() async {
        guard let url = securityScopedURL else { return }
        let myGeneration = generation
        let built = await FolderContextService.shared.buildContext(from: url)
        guard generation == myGeneration else { return }
        context = built
    }

    // MARK: - Persistence round-trip

    /// Snapshot for `ChatSessionData` persistence.
    public var persistedBookmark: Data? { bookmark }
    public var persistedPath: String? { lastKnownPath ?? context?.rootPath.standardizedFileURL.path }

    /// In-flight restore, exposed so the send path can wait for a folder
    /// that is still resolving (e.g. immediately after a session switch or
    /// app launch) instead of silently composing folder-less. Awaiting a
    /// completed task returns instantly; each new restore replaces it.
    public private(set) var pendingRestore: Task<FolderContext?, Never>?

    /// Restore folder state from persisted session data. Fire-and-forget:
    /// resolution happens off the main actor and applies when done (unless a
    /// newer set/clear/restore superseded it). The generation is claimed
    /// synchronously HERE — not when the spawned task gets scheduled — so a
    /// later `restoreAndWait` (e.g. an explicit dispatch bookmark) always
    /// supersedes this restore even if this task hasn't started yet.
    public func restore(bookmark: Data?, path: String?) {
        generation += 1
        let myGeneration = generation
        pendingRestore = Task {
            await self.performRestore(bookmark: bookmark, path: path, generation: myGeneration)
        }
    }

    /// Restore folder state and wait for the context build. Returns the
    /// restored context, or nil when there is no bookmark, the bookmark is
    /// stale, or access could not be started.
    @discardableResult
    public func restoreAndWait(bookmark bookmarkData: Data?, path: String?) async -> FolderContext? {
        generation += 1
        let myGeneration = generation
        let task = Task {
            await self.performRestore(bookmark: bookmarkData, path: path, generation: myGeneration)
        }
        pendingRestore = task
        return await task.value
    }

    /// The folder context this chat should compose with, waiting for an
    /// in-flight restore first. Returns immediately when a context is
    /// already built or no restore is pending.
    public func contextWaitingForRestore() async -> FolderContext? {
        if let context { return context }
        if let pendingRestore { return await pendingRestore.value }
        return nil
    }

    /// Shared restore body. `generation` was claimed by the caller at
    /// request time; if a newer set/clear/restore claimed the counter since,
    /// this restore is stale and must not touch any state.
    private func performRestore(
        bookmark bookmarkData: Data?,
        path: String?,
        generation myGeneration: Int
    ) async -> FolderContext? {
        guard generation == myGeneration else { return nil }
        releaseCurrentScope()
        context = nil
        bookmark = bookmarkData
        lastKnownPath = path

        guard let bookmarkData else {
            // Path-only restore: a dispatch (e.g. an orchestrator-created
            // Watcher) can carry a plain folder path with no picker bookmark.
            // No security scope to start/stop for a plain path, so
            // `securityScopedURL` stays nil.
            //
            // Readability is checked HERE because `buildContext` cannot fail:
            // (Scope note: `isReadableFile` is access(2)/POSIX bits; a
            // TCC-managed folder can still pass it and fail only at
            // open/readdir, so this catches missing/deleted/POSIX-unreadable
            // dirs — the TCC costume may need a deeper probe if observed.)
            // an unreadable, TCC-denied, or deleted directory yields a
            // plausible context with an EMPTY tree, and the run then reports
            // "the monitored folder is empty" over a folder that has files —
            // the live Watcher failure, recurring in a new costume for every
            // protected location. (An earlier comment claimed buildContext
            // fails and we fall through to nil; that fallback was
            // unreachable.) Returning nil is honest: the caller can then say
            // the folder could not be read instead of running over a lie.
            guard let path, !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue,
                FileManager.default.isReadableFile(atPath: url.path)
            else {
                folderLog.error(
                    "path-only restore: '\(url.path, privacy: .public)' is missing, not a directory, or unreadable (TCC?) — returning nil instead of an empty-tree context"
                )
                return nil
            }
            let built = await FolderContextService.shared.buildContext(from: url)
            guard generation == myGeneration else { return nil }
            lastKnownPath = url.standardizedFileURL.path
            FolderToolManager.shared.ensureFolderToolsRegistered()
            context = built
            return built
        }

        // Resolving a security-scoped bookmark does synchronous IPC to the
        // scoped-bookmarks agent; keep it off the main actor.
        let resolved: URL? = await Task.detached(priority: .userInitiated) {
            FolderContextService.resolveSecurityScopedURL(from: bookmarkData)
        }.value

        guard generation == myGeneration else { return nil }
        guard let url = resolved else {
            // Stale bookmark (folder moved/deleted): drop it, keep the
            // display path so persistence/UI can still say what it was.
            bookmark = nil
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }

        let built = await FolderContextService.shared.buildContext(from: url)
        guard generation == myGeneration else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        securityScopedURL = url
        lastKnownPath = url.standardizedFileURL.path
        FolderToolManager.shared.ensureFolderToolsRegistered()
        context = built
        return built
    }

    private func releaseCurrentScope() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    // MARK: - Legacy global-bookmark migration

    private static let legacyBookmarkKey = "FolderContextBookmark"
    private static var legacyAdoptionResolved = false

    /// One-time migration of the pre-per-chat global folder bookmark: the
    /// first eligible (non-Default-agent) chat opened after the update adopts
    /// the legacy folder, then the global key is deleted. It is never used as
    /// a default for any other chat.
    public func adoptLegacyGlobalBookmarkIfNeeded() {
        guard !Self.legacyAdoptionResolved else { return }
        guard bookmark == nil, context == nil else { return }
        Self.legacyAdoptionResolved = true
        guard let data = UserDefaults.standard.data(forKey: Self.legacyBookmarkKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.legacyBookmarkKey)
        restore(bookmark: data, path: nil)
    }

    /// Test seam: reset the once-per-process legacy adoption latch.
    static func _resetLegacyAdoptionForTesting() {
        legacyAdoptionResolved = false
    }

    // MARK: - Live root registry (process diagnostics / sandbox tripwire)

    /// Roots of every live chat folder in the process, lock-protected so
    /// non-main paths (sandbox boot tripwire) can read without an actor hop.
    nonisolated private static let liveRootsLock = NSLock()
    nonisolated(unsafe) private static var liveRoots: [ObjectIdentifier: String] = [:]

    /// Distinct roots of every live chat folder in the process. Used by the
    /// sandbox boot tripwire to assert the workspace mount is never any
    /// chat's user folder.
    public nonisolated static var liveRootPaths: [String] {
        liveRootsLock.lock()
        defer { liveRootsLock.unlock() }
        return Array(Set(liveRoots.values))
    }

    private nonisolated static func updateLiveRoot(for key: ObjectIdentifier, path: String?) {
        liveRootsLock.lock()
        defer { liveRootsLock.unlock() }
        if let path {
            liveRoots[key] = path
        } else {
            liveRoots.removeValue(forKey: key)
        }
    }
}
