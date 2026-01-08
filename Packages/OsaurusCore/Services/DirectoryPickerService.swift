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

    // MARK: - Static Cache for Bookmark URL
    // Caches the resolved bookmark URL to avoid expensive IPC calls.
    // Bookmark resolution involves sync IPC with scopedBookmarksAgent (1+ second blocks).
    private static nonisolated let cacheLock = NSLock()
    private static nonisolated(unsafe) var cachedBookmarkURL: URL?
    private static nonisolated(unsafe) var cacheInitialized = false

    nonisolated private static func invalidateCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedBookmarkURL = nil
        cacheInitialized = false
    }

    /// Get or resolve the cached bookmark URL
    nonisolated private static func getCachedBookmarkURL() -> URL? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        // Return cached value if already initialized
        if cacheInitialized {
            return cachedBookmarkURL
        }

        // Resolve bookmark once and cache
        cacheInitialized = true
        guard let bookmarkData = UserDefaults.standard.data(forKey: "ModelDirectoryBookmark") else {
            cachedBookmarkURL = nil
            return nil
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if !isStale {
                cachedBookmarkURL = url
                return url
            }
        } catch {
            // Bookmark invalid
        }

        cachedBookmarkURL = nil
        return nil
    }

    /// Update the cached bookmark URL directly (call after successful save)
    nonisolated private static func updateCache(with url: URL) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedBookmarkURL = url
        cacheInitialized = true
    }

    private init() {
        loadSavedDirectory()
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
                // Bookmark is stale, need to recreate it
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
                Self.invalidateCache()
                return
            }

            // Start accessing the security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                print("Failed to start accessing security-scoped resource")
                return
            }

            selectedDirectory = url
            securityScopedResource = url
            hasValidDirectory = true

            // Populate the static cache with the resolved URL
            Self.updateCache(with: url)

        } catch {
            print("Failed to resolve security-scoped bookmark: \(error)")
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            Self.invalidateCache()
        }
    }

    /// Present directory picker and save selection
    @MainActor func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Models Directory"
        panel.message = "Select a directory where MLX models will be stored"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        saveDirectory(url)
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

    /// Get the default models directory (without user bookmark)
    nonisolated static func defaultModelsDirectory() -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["OSU_MODELS_DIR"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let newDefault = homeURL.appendingPathComponent("MLXModels")
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let oldDefault = documentsPath.appendingPathComponent("MLXModels")
        if fileManager.fileExists(atPath: newDefault.path) { return newDefault }
        if fileManager.fileExists(atPath: oldDefault.path) { return oldDefault }
        return newDefault
    }

    /// Nonisolated static resolver that respects the saved bookmark when present.
    /// Falls back to env var and defaults when no valid bookmark exists.
    /// Uses cached bookmark URL to avoid expensive IPC calls on every access.
    nonisolated static func effectiveModelsDirectory() -> URL {
        // Use cached bookmark URL to avoid expensive IPC
        if let cachedURL = getCachedBookmarkURL() {
            return cachedURL
        }

        // Fallback precedence matches instance property
        return defaultModelsDirectory()
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
    }

    deinit {
        securityScopedResource?.stopAccessingSecurityScopedResource()
    }
}
