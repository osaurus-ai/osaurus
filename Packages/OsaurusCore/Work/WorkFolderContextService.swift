//
//  WorkFolderContextService.swift
//  osaurus
//
//  Service for managing work folder context with security-scoped bookmarks,
//  project type detection, file tree generation, and git status.
//

import AppKit
import Foundation

// Lock-protected cache for the folder root path, accessible from any isolation domain.
// Lives outside the @MainActor class so the lock and storage are never actor-isolated.
// Concurrency safety is enforced manually via _folderRootPathLock.
private let _folderRootPathLock = NSLock()
private nonisolated(unsafe) var _folderCachedRootPath: URL?

/// Service for managing work folder context
@MainActor
public final class WorkFolderContextService: ObservableObject {
    public static let shared = WorkFolderContextService()

    @Published public private(set) var currentContext: WorkFolderContext? {
        didSet {
            _folderRootPathLock.withLock {
                _folderCachedRootPath = currentContext?.rootPath
            }
        }
    }
    @Published public private(set) var hasActiveFolder: Bool = false

    /// Thread-safe accessor for the current folder root path.
    /// Reads a lock-protected cache so callers never need to hop to MainActor.
    public nonisolated static var cachedRootPath: URL? {
        _folderRootPathLock.withLock { _folderCachedRootPath }
    }

    private let bookmarkKey = "WorkFolderContextBookmark"
    private var securityScopedResource: URL?

    private init() {
        loadSavedFolder()
    }

    // MARK: - Public API

    /// Select a folder via NSOpenPanel, build context, and register tools
    @discardableResult
    public func selectFolder() async -> WorkFolderContext? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Working Directory"
        panel.message = "Choose a folder for the AI to work with"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        return await setFolder(url)
    }

    /// Set a folder programmatically and build context
    @discardableResult
    public func setFolder(_ url: URL) async -> WorkFolderContext? {
        // Stop accessing previous resource
        clearFolderInternal(unregisterTools: true)

        do {
            // Create security-scoped bookmark
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            // Save bookmark to UserDefaults
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)

            guard url.startAccessingSecurityScopedResource() else { return nil }

            securityScopedResource = url

            // Build context
            let context = await buildContext(from: url)
            currentContext = context
            hasActiveFolder = true

            // Register folder tools
            WorkToolManager.shared.registerFolderTools(for: context)

            return context

        } catch {
            return nil
        }
    }

    /// Clear the current folder and unregister tools
    public func clearFolder() {
        clearFolderInternal(unregisterTools: true)
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// Build context from a URL (assumes access is already granted)
    public func buildContext(from url: URL) async -> WorkFolderContext {
        let projectType = detectProjectType(url)
        let options = WorkFileTreeOptions(
            ignorePatterns: projectType.ignorePatterns
        )
        let tree = buildFileTree(url, options: options)
        let manifest = readManifest(url, projectType: projectType)
        let isGitRepo = checkIsGitRepo(url)
        let gitStatus = isGitRepo ? await getGitStatus(url) : nil

        return WorkFolderContext(
            rootPath: url,
            projectType: projectType,
            tree: tree,
            manifest: manifest,
            gitStatus: gitStatus,
            isGitRepo: isGitRepo
        )
    }

    /// Refresh the current context (rebuild tree, git status, etc.)
    public func refreshContext() async {
        guard let url = securityScopedResource else { return }
        let context = await buildContext(from: url)
        currentContext = context
    }

    // MARK: - Private Implementation

    private func clearFolderInternal(unregisterTools: Bool) {
        securityScopedResource?.stopAccessingSecurityScopedResource()
        securityScopedResource = nil
        currentContext = nil
        hasActiveFolder = false

        if unregisterTools {
            WorkToolManager.shared.unregisterFolderTools()
        }
    }

    /// Load previously saved folder from security-scoped bookmark
    private func loadSavedFolder() {
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
                return
            }

            guard url.startAccessingSecurityScopedResource() else { return }

            securityScopedResource = url

            // Build context asynchronously (already on MainActor)
            Task {
                let context = await buildContext(from: url)
                self.currentContext = context
                self.hasActiveFolder = true
                WorkToolManager.shared.registerFolderTools(for: context)
            }

        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    // MARK: - Project Type Detection

    private func detectProjectType(_ url: URL) -> WorkProjectType {
        let fm = FileManager.default

        // Check for manifest files in order of specificity
        for projectType in WorkProjectType.allCases where projectType != .unknown {
            for manifestFile in projectType.manifestFiles {
                let manifestPath = url.appendingPathComponent(manifestFile)
                if fm.fileExists(atPath: manifestPath.path) {
                    return projectType
                }
            }
        }

        return .unknown
    }

    // MARK: - File Tree Building

    /// Check if a filename matches any ignore pattern (wildcard or exact)
    private func shouldIgnore(_ name: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if pattern.contains("*") {
                let regex = pattern.replacingOccurrences(of: ".", with: "\\.")
                    .replacingOccurrences(of: "*", with: ".*")
                if name.range(of: "^\(regex)$", options: .regularExpression) != nil {
                    return true
                }
            } else if name == pattern {
                return true
            }
        }
        return false
    }

    private func buildFileTree(_ url: URL, options: WorkFileTreeOptions) -> String {
        // Adaptive depth: inspect top-level item count to choose depth automatically.
        // This prevents bloated trees for broad directories like ~/Downloads (2000+ files)
        // while preserving full detail for well-structured projects (e.g., a Swift package).
        let adaptiveMaxDepth = computeAdaptiveDepth(url, options: options)
        var adaptiveOptions = options
        adaptiveOptions.maxDepth = adaptiveMaxDepth

        var result = ""
        var fileCount = 0
        let maxFiles = adaptiveOptions.maxFiles
        let patterns = adaptiveOptions.ignorePatterns

        func traverse(_ currentURL: URL, depth: Int, prefix: String) {
            guard depth <= adaptiveOptions.maxDepth else { return }
            guard fileCount < maxFiles else { return }

            let fm = FileManager.default
            guard
                let contents = try? fm.contentsOfDirectory(
                    at: currentURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { return }

            // Filter out ignored items first
            let visible = contents.filter {
                !shouldIgnore($0.lastPathComponent, patterns: patterns)
            }

            // Sort: directories first, then files, both alphabetically
            let sorted = visible.sorted { a, b in
                let aIsDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let bIsDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if aIsDir != bIsDir { return aIsDir }
                return a.lastPathComponent.lowercased() < b.lastPathComponent.lowercased()
            }

            // Separate directories and files
            let directories = sorted.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            }
            let files = sorted.filter {
                !((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            }

            // If this level has > 50 visible files, use extension-grouped summary
            if files.count > 50 {
                // List directories individually
                for (index, dir) in directories.enumerated() {
                    guard fileCount < maxFiles else { break }
                    let name = dir.lastPathComponent
                    let isLastOverall = index == directories.count - 1 && files.isEmpty
                    let connector = isLastOverall ? "└── " : "├── "
                    let childPrefix = isLastOverall ? "    " : "│   "

                    let visibleSubCount = visibleChildCount(of: dir, patterns: patterns)

                    if depth == adaptiveOptions.maxDepth || visibleSubCount > 50 {
                        let (f, d) = countContents(dir, patterns: patterns)
                        result += "\(prefix)\(connector)\(name)/     (\(f) files, \(d) folders)\n"
                    } else {
                        result += "\(prefix)\(connector)\(name)/\n"
                        traverse(dir, depth: depth + 1, prefix: prefix + childPrefix)
                    }
                }

                // Render extension-grouped summary for files
                let groups = groupFilesByExtension(files)
                for (groupIndex, group) in groups.enumerated() {
                    let isLast = groupIndex == groups.count - 1
                    let connector = isLast ? "└── " : "├── "
                    result += "\(prefix)\(connector)\(group.count) \(group.ext) files\n"
                }
                result += "\(prefix)    (\(files.count) files total)\n"
                fileCount += files.count

            } else {
                // Standard per-item listing
                for (index, item) in sorted.enumerated() {
                    guard fileCount < maxFiles else {
                        if adaptiveOptions.summarizeAboveThreshold {
                            result += "\(prefix)... (truncated, >\(maxFiles) files)\n"
                        }
                        return
                    }

                    let name = item.lastPathComponent
                    let isLast = index == sorted.count - 1
                    let connector = isLast ? "└── " : "├── "
                    let childPrefix = isLast ? "    " : "│   "

                    let isDirectory =
                        (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                    if isDirectory {
                        let visibleSubCount = visibleChildCount(of: item, patterns: patterns)

                        if depth == adaptiveOptions.maxDepth || visibleSubCount > 50 {
                            let (f, d) = countContents(item, patterns: patterns)
                            result +=
                                "\(prefix)\(connector)\(name)/     (\(f) files, \(d) folders)\n"
                        } else {
                            result += "\(prefix)\(connector)\(name)/\n"
                            traverse(item, depth: depth + 1, prefix: prefix + childPrefix)
                        }
                    } else {
                        result += "\(prefix)\(connector)\(name)\n"
                        fileCount += 1
                    }
                }
            }
        }

        result = "./\n"
        traverse(url, depth: 1, prefix: "")

        return result
    }

    /// Count visible (non-ignored) children of a directory
    private func visibleChildCount(of url: URL, patterns: [String]) -> Int {
        let subContents =
            (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        return subContents.filter { !shouldIgnore($0.lastPathComponent, patterns: patterns) }.count
    }

    /// Compute adaptive max depth based on top-level item count.
    /// Well-structured projects (<=50 top-level items): depth 3 (full detail)
    /// Medium directories (51-200): depth 2
    /// Broad flat directories (>200, e.g. Downloads): depth 1 + extension grouping
    private func computeAdaptiveDepth(_ url: URL, options: WorkFileTreeOptions) -> Int {
        let visibleCount = visibleChildCount(of: url, patterns: options.ignorePatterns)

        if visibleCount <= 50 {
            return min(options.maxDepth, 3)
        } else if visibleCount <= 200 {
            return min(options.maxDepth, 2)
        } else {
            return min(options.maxDepth, 1)
        }
    }

    /// Group files by extension for dense directory summaries
    private func groupFilesByExtension(_ files: [URL]) -> [(ext: String, count: Int)] {
        var groups: [String: Int] = [:]
        for file in files {
            let ext = file.pathExtension.lowercased()
            let key = ext.isEmpty ? "other" : ".\(ext)"
            groups[key, default: 0] += 1
        }
        return groups.sorted { $0.value > $1.value }.map { (ext: $0.key, count: $0.value) }
    }

    private func countContents(_ url: URL, patterns: [String]) -> (files: Int, dirs: Int) {
        let fm = FileManager.default
        var files = 0
        var dirs = 0

        guard
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return (0, 0)
        }

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if shouldIgnore(name, patterns: patterns) {
                enumerator.skipDescendants()
                continue
            }

            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                dirs += 1
            } else {
                files += 1
            }

            // Limit enumeration for performance
            if files + dirs > 10000 {
                break
            }
        }

        return (files, dirs)
    }

    // MARK: - Manifest Reading

    private func readManifest(_ url: URL, projectType: WorkProjectType) -> String? {
        guard let manifestFile = projectType.primaryManifest else { return nil }

        let manifestURL = url.appendingPathComponent(manifestFile)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }

        do {
            let content = try String(contentsOf: manifestURL, encoding: .utf8)
            // Truncate if too long
            if content.count > 5000 {
                return String(content.prefix(5000)) + "\n... (truncated)"
            }
            return content
        } catch {
            return nil
        }
    }

    // MARK: - Git Integration

    private func checkIsGitRepo(_ url: URL) -> Bool {
        let gitDir = url.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func getGitStatus(_ url: URL) async -> String? {
        do {
            let (output, _) = try await WorkFolderToolHelpers.runGitCommand(
                arguments: ["status", "--short", "--branch"],
                in: url
            )

            // Truncate if too long
            if output.count > 2000 {
                return String(output.prefix(2000)) + "\n... (truncated)"
            }

            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }

    deinit {
        securityScopedResource?.stopAccessingSecurityScopedResource()
    }
}
