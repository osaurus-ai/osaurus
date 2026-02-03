//
//  AgentFolderContextService.swift
//  osaurus
//
//  Service for managing agent folder context with security-scoped bookmarks,
//  project type detection, file tree generation, and git status.
//

import AppKit
import Foundation

/// Service for managing agent folder context
@MainActor
public final class AgentFolderContextService: ObservableObject {
    public static let shared = AgentFolderContextService()

    @Published public private(set) var currentContext: AgentFolderContext?
    @Published public private(set) var hasActiveFolder: Bool = false

    private let bookmarkKey = "AgentFolderContextBookmark"
    private var securityScopedResource: URL?

    private init() {
        loadSavedFolder()
    }

    // MARK: - Public API

    /// Select a folder via NSOpenPanel, build context, and register tools
    @discardableResult
    public func selectFolder() async -> AgentFolderContext? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Working Directory"
        panel.message = "Choose a folder for the agent to work with"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        return await setFolder(url)
    }

    /// Set a folder programmatically and build context
    @discardableResult
    public func setFolder(_ url: URL) async -> AgentFolderContext? {
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
            AgentToolManager.shared.registerFolderTools(for: context)

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
    public func buildContext(from url: URL) async -> AgentFolderContext {
        let projectType = detectProjectType(url)
        let options = AgentFileTreeOptions(
            ignorePatterns: projectType.ignorePatterns
        )
        let tree = buildFileTree(url, options: options)
        let manifest = readManifest(url, projectType: projectType)
        let isGitRepo = checkIsGitRepo(url)
        let gitStatus = isGitRepo ? getGitStatus(url) : nil

        return AgentFolderContext(
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
            AgentToolManager.shared.unregisterFolderTools()
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
                AgentToolManager.shared.registerFolderTools(for: context)
            }

        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    // MARK: - Project Type Detection

    private func detectProjectType(_ url: URL) -> AgentProjectType {
        let fm = FileManager.default

        // Check for manifest files in order of specificity
        for projectType in AgentProjectType.allCases where projectType != .unknown {
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

    private func buildFileTree(_ url: URL, options: AgentFileTreeOptions) -> String {
        var result = ""
        var fileCount = 0
        let maxFiles = options.maxFiles

        func shouldIgnore(_ name: String, patterns: [String]) -> Bool {
            for pattern in patterns {
                if pattern.contains("*") {
                    // Simple wildcard matching
                    let regex = pattern.replacingOccurrences(of: ".", with: "\\.")
                        .replacingOccurrences(of: "*", with: ".*")
                    if let _ = name.range(of: "^\(regex)$", options: .regularExpression) {
                        return true
                    }
                } else if name == pattern {
                    return true
                }
            }
            return false
        }

        func traverse(_ currentURL: URL, depth: Int, prefix: String) {
            guard depth <= options.maxDepth else { return }
            guard fileCount < maxFiles else { return }

            let fm = FileManager.default
            guard
                let contents = try? fm.contentsOfDirectory(
                    at: currentURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { return }

            // Sort: directories first, then files, both alphabetically
            let sorted = contents.sorted { a, b in
                let aIsDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let bIsDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if aIsDir != bIsDir { return aIsDir }
                return a.lastPathComponent.lowercased() < b.lastPathComponent.lowercased()
            }

            for (index, item) in sorted.enumerated() {
                guard fileCount < maxFiles else {
                    if options.summarizeAboveThreshold {
                        result += "\(prefix)... (truncated, >\(maxFiles) files)\n"
                    }
                    return
                }

                let name = item.lastPathComponent
                if shouldIgnore(name, patterns: options.ignorePatterns) {
                    continue
                }

                let isLast = index == sorted.count - 1
                let connector = isLast ? "└── " : "├── "
                let childPrefix = isLast ? "    " : "│   "

                let isDirectory =
                    (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                if isDirectory {
                    // Count items in directory for summary
                    let subContents =
                        (try? fm.contentsOfDirectory(
                            at: item,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        )) ?? []

                    let visibleContents = subContents.filter {
                        !shouldIgnore($0.lastPathComponent, patterns: options.ignorePatterns)
                    }

                    if depth == options.maxDepth || visibleContents.count > 50 {
                        // Summarize large or deep directories
                        let (files, dirs) = countContents(item, patterns: options.ignorePatterns)
                        result += "\(prefix)\(connector)\(name)/     (\(files) files, \(dirs) folders)\n"
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

        result = "./\n"
        traverse(url, depth: 1, prefix: "")

        return result
    }

    private func countContents(_ url: URL, patterns: [String]) -> (files: Int, dirs: Int) {
        let fm = FileManager.default
        var files = 0
        var dirs = 0

        func shouldIgnore(_ name: String) -> Bool {
            for pattern in patterns {
                if pattern.contains("*") {
                    let regex = pattern.replacingOccurrences(of: ".", with: "\\.")
                        .replacingOccurrences(of: "*", with: ".*")
                    if let _ = name.range(of: "^\(regex)$", options: .regularExpression) {
                        return true
                    }
                } else if name == pattern {
                    return true
                }
            }
            return false
        }

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
            if shouldIgnore(name) {
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

    private func readManifest(_ url: URL, projectType: AgentProjectType) -> String? {
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

    private func getGitStatus(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--short", "--branch"]
        process.currentDirectoryURL = url

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            // Truncate if too long
            if let output = output, output.count > 2000 {
                return String(output.prefix(2000)) + "\n... (truncated)"
            }

            return output
        } catch {
            return nil
        }
    }

    deinit {
        securityScopedResource?.stopAccessingSecurityScopedResource()
    }
}
