//
//  DirectoryPickerService.swift
//  osaurus
//
//  Created by Kamil Andrusz on 8/22/25.
//

import Foundation
import SwiftUI

/// Service for managing user-selected directory access with security-scoped bookmarks
@MainActor
final class DirectoryPickerService: ObservableObject {
    static let shared = DirectoryPickerService()

    @Published var selectedDirectory: URL?
    @Published var hasValidDirectory: Bool = false

    private let bookmarkKey = "ModelDirectoryBookmark"
    private var securityScopedResource: URL?

    // MARK: - Bookmark URL Cache (in-memory, avoids expensive IPC)
    private static nonisolated let cacheLock = NSLock()
    private static nonisolated(unsafe) var cachedBookmarkURL: URL?
    private static nonisolated(unsafe) var cacheInitialized = false

    /// Memoized result of `defaultModelsDirectory()`. Resolving the default
    /// location scans `~/MLXModels` and the legacy `~/Documents/MLXModels` for
    /// visible contents, so without this cache every SwiftUI body that touched
    /// a model's `isVLM`/`isDownloaded` (which resolve through here when no
    /// bookmark is set) paid for a fresh directory enumeration per row, on the
    /// main thread, during layout. Cleared alongside the bookmark cache.
    private static nonisolated(unsafe) var cachedDefaultDirectory: URL?

    nonisolated private static func invalidateCache() {
        cacheLock.lock()
        cachedBookmarkURL = nil
        cachedDefaultDirectory = nil
        cacheInitialized = false
        cacheLock.unlock()
    }

    nonisolated private static func getCachedBookmarkURL() -> URL? {
        cacheLock.lock()
        if cacheInitialized {
            let result = cachedBookmarkURL
            cacheLock.unlock()
            return result
        }

        cacheInitialized = true
        guard let bookmarkData = UserDefaults.standard.data(forKey: "ModelDirectoryBookmark") else {
            cachedBookmarkURL = nil
            cacheLock.unlock()
            return nil
        }

        var isStale = false
        // Try security-scoped resolution first
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale {
            cachedBookmarkURL = url
            cacheLock.unlock()
            return url
        }

        // Fallback: resolve without security scope (works for non-sandboxed apps
        // when the security-scoped bookmark becomes stale, e.g. after volume remount)
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            cachedBookmarkURL = url
            cacheLock.unlock()
            return url
        }

        cachedBookmarkURL = nil
        cacheLock.unlock()
        return nil
    }

    nonisolated private static func updateCache(with url: URL) {
        cacheLock.lock()
        cachedBookmarkURL = url
        cacheInitialized = true
        cacheLock.unlock()
    }

    private init() {
        loadSavedDirectory()
        SystemMonitorService.shared.updateStoragePath(Self.effectiveModelsDirectory().path)
    }

    /// Load previously saved directory from security-scoped bookmark
    private func loadSavedDirectory() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                // Bookmark is stale (e.g. volume remounted), try without security scope
                if let fallbackURL = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    selectedDirectory = fallbackURL
                    hasValidDirectory = true
                    Self.updateCache(with: fallbackURL)
                } else {
                    UserDefaults.standard.removeObject(forKey: bookmarkKey)
                    Self.invalidateCache()
                }
                return
            }

            // Start accessing the security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                print("Failed to start accessing security-scoped resource, using URL directly")
                selectedDirectory = url
                hasValidDirectory = true
                Self.updateCache(with: url)
                return
            }

            selectedDirectory = url
            securityScopedResource = url
            hasValidDirectory = true

            // Populate the static cache with the resolved URL
            Self.updateCache(with: url)

        } catch {
            print("Failed to resolve security-scoped bookmark: \(error), trying without scope")
            // Fallback: resolve without security scope for non-sandboxed apps
            var fallbackStale = false
            if let fallbackURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &fallbackStale
            ) {
                selectedDirectory = fallbackURL
                hasValidDirectory = true
                Self.updateCache(with: fallbackURL)
            } else {
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
                Self.invalidateCache()
            }
        }
    }

    /// Present directory picker and save selection
    @MainActor func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L("Choose Models Directory")
        panel.message = L("Select a directory where MLX models will be stored")

        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else {
                return
            }

            saveDirectory(url)
        }
    }

    /// Save directory selection from SwiftUI file picker
    @MainActor func saveDirectoryFromFilePicker(_ url: URL) {
        // For security-scoped resources from file picker, we need to start accessing first
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to access security-scoped resource from file picker")
            return
        }

        saveDirectory(url)
    }

    /// Save directory selection with security-scoped bookmark
    private func saveDirectory(_ url: URL) {
        // Stop accessing previous resource
        securityScopedResource?.stopAccessingSecurityScopedResource()

        do {
            // Create security-scoped bookmark
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            // Save bookmark to UserDefaults
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)

            // Start accessing the new resource
            guard url.startAccessingSecurityScopedResource() else {
                print("Failed to start accessing newly selected directory")
                return
            }

            selectedDirectory = url
            securityScopedResource = url
            hasValidDirectory = true

            // Update the static cache with the new URL
            Self.updateCache(with: url)
            notifyModelsDirectoryChanged()

        } catch {
            print("Failed to create security-scoped bookmark: \(error)")
        }
    }

    /// Get the effective models directory (user-selected or default)
    /// This method is thread-safe for use from any context.
    /// Uses cached bookmark URL to avoid expensive IPC calls on every access.
    nonisolated var effectiveModelsDirectory: URL {
        // Use the static method which leverages the cache
        return Self.effectiveModelsDirectory()
    }

    /// Whether a directory exists and holds at least one visible entry.
    /// Hidden bookkeeping files (`.DS_Store`, etc.) don't count, so a
    /// folder that only ever held a `.DS_Store` reads as empty. Used to
    /// prefer a populated models location over an empty one.
    nonisolated private static func directoryHasVisibleContents(_ url: URL) -> Bool {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return false }
        return !entries.isEmpty
    }

    /// Get the default models directory (without user bookmark).
    ///
    /// Memoized: the underlying resolution enumerates two candidate folders to
    /// prefer a populated location, which is too expensive to repeat on every
    /// access (model-list rendering can ask hundreds of times per frame). The
    /// answer only changes when the directory is reset, which clears the cache.
    nonisolated static func defaultModelsDirectory() -> URL {
        cacheLock.lock()
        if let cached = cachedDefaultDirectory {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let resolved = resolveDefaultModelsDirectory()

        cacheLock.lock()
        cachedDefaultDirectory = resolved
        cacheLock.unlock()
        return resolved
    }

    /// Compute the default models directory by scanning the candidate folders.
    /// Callers should go through `defaultModelsDirectory()` so the result is
    /// cached; this performs the filesystem work on every invocation.
    nonisolated private static func resolveDefaultModelsDirectory() -> URL {
        let fileManager = FileManager.default
        if let override = modelsDirectoryEnvironmentOverride() {
            return override
        }
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let newDefault = homeURL.appendingPathComponent("MLXModels")
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let oldDefault = documentsPath.appendingPathComponent("MLXModels")

        // Prefer a location that actually holds models. A newer build (or
        // the directory picker) can leave an empty `~/MLXModels` behind,
        // which used to shadow a populated legacy `~/Documents/MLXModels`
        // and make already-downloaded models look missing after an update.
        if directoryHasVisibleContents(newDefault) { return newDefault }
        if directoryHasVisibleContents(oldDefault) { return oldDefault }

        // Neither holds models — keep the historical preference order:
        // an existing (if empty) new default, then legacy, then new default.
        if fileManager.fileExists(atPath: newDefault.path) { return newDefault }
        if fileManager.fileExists(atPath: oldDefault.path) { return oldDefault }
        return newDefault
    }

    /// Nonisolated static resolver that respects the saved bookmark when present.
    /// Falls back to env var and defaults when no valid bookmark exists.
    /// Uses cached bookmark URL to avoid expensive IPC calls on every access.
    nonisolated static func effectiveModelsDirectory() -> URL {
        // Test/live-proof runs may need to point at a specific model root even
        // when the user's app has a saved bookmark. Treat an explicit env
        // override as stronger than persisted UI state so probes are
        // deterministic and do not accidentally scan a stale volume.
        if let override = modelsDirectoryEnvironmentOverride() {
            return override
        }

        // Use cached bookmark URL to avoid expensive IPC
        if let cachedURL = getCachedBookmarkURL() {
            return cachedURL
        }

        // Fallback precedence matches instance property
        return defaultModelsDirectory()
    }

    nonisolated private static func modelsDirectoryEnvironmentOverride() -> URL? {
        guard
            let raw = ProcessInfo.processInfo.environment["OSU_MODELS_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Reset directory selection
    @MainActor func resetDirectory() {
        securityScopedResource?.stopAccessingSecurityScopedResource()
        securityScopedResource = nil
        selectedDirectory = nil
        hasValidDirectory = false
        UserDefaults.standard.removeObject(forKey: bookmarkKey)

        // Invalidate the static cache
        Self.invalidateCache()
        notifyModelsDirectoryChanged()
    }

    /// Notify the rest of the app that the models directory changed so local models are rescanned.
    private func notifyModelsDirectoryChanged() {
        ModelManager.invalidateLocalModelsCache()
        SystemMonitorService.shared.updateStoragePath(Self.effectiveModelsDirectory().path)
        NotificationCenter.default.post(name: .localModelsChanged, object: nil)
    }

    deinit {
        securityScopedResource?.stopAccessingSecurityScopedResource()
    }
}
