//
//  DirectoryPickerService.swift
//  osaurus
//
//  Created by Kamil Andrusz on 8/22/25.
//

import Foundation
import SwiftUI

/// Service for managing user-selected directory access with security-scoped bookmarks
final class DirectoryPickerService: ObservableObject {
    static let shared = DirectoryPickerService()
    
    @Published var selectedDirectory: URL?
    @Published var hasValidDirectory: Bool = false
    
    private let bookmarkKey = "ModelDirectoryBookmark"
    private var securityScopedResource: URL?
    
    // Thread-safe access to the effective directory
    private let directoryQueue = DispatchQueue(label: "com.dinoki.osaurus.directory-access", attributes: .concurrent)
    
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
            let url = try URL(resolvingBookmarkData: bookmarkData,
                            options: .withSecurityScope,
                            relativeTo: nil,
                            bookmarkDataIsStale: &isStale)
            
            if isStale {
                // Bookmark is stale, need to recreate it
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
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
            
        } catch {
            print("Failed to resolve security-scoped bookmark: \(error)")
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
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
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)
            
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
            
        } catch {
            print("Failed to create security-scoped bookmark: \(error)")
        }
    }
    
    /// Get the effective models directory (user-selected or default)
    /// This method is thread-safe for use from any context
    var effectiveModelsDirectory: URL {
        return directoryQueue.sync {
            // Check UserDefaults directly for the bookmark
            if let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) {
                do {
                    var isStale = false
                    let url = try URL(resolvingBookmarkData: bookmarkData,
                                    options: .withSecurityScope,
                                    relativeTo: nil,
                                    bookmarkDataIsStale: &isStale)
                    
                    if !isStale {
                        return url
                    }
                } catch {
                    // Bookmark invalid, fall through to default
                }
            }
            
            // Fall back to default sandbox-safe location
            let documentsPath = FileManager.default.urls(for: .documentDirectory,
                                                         in: .userDomainMask).first!
            return documentsPath.appendingPathComponent("MLXModels")
        }
    }
    
    /// Reset directory selection
    @MainActor func resetDirectory() {
        securityScopedResource?.stopAccessingSecurityScopedResource()
        securityScopedResource = nil
        selectedDirectory = nil
        hasValidDirectory = false
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }
    
    deinit {
        securityScopedResource?.stopAccessingSecurityScopedResource()
    }
}