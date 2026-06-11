//
//  FolderContextService.swift
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
public final class FolderContextService: ObservableObject {
    public static let shared = FolderContextService()

    @Published public private(set) var currentContext: FolderContext? {
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

    private let bookmarkKey = "FolderContextBookmark"
    private var securityScopedResource: URL?

    private init() {
        loadSavedFolder()
    }

    // MARK: - Public API

    /// Select a folder via NSOpenPanel, build context, and register tools
    @discardableResult
    public func selectFolder() async -> FolderContext? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = L("Select Working Directory")
        panel.message = L("Choose a folder for the AI to work with")
        panel.prompt = L("Select")

        guard await panel.beginModal() == .OK, let url = panel.url else {
            return nil
        }

        return await setFolder(url)
    }

    /// Set a folder programmatically and build context
    @discardableResult
    public func setFolder(_ url: URL) async -> FolderContext? {
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
            FolderToolManager.shared.registerFolderTools(for: context)

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

    // MARK: - Eval-harness activation (module-internal)

    /// Activate an already-built context as the process-wide folder
    /// context WITHOUT a security-scoped bookmark or persistence —
    /// used by `AgentLoopEvaluator` for combined sandbox + host-read
    /// cases, where `ToolRegistry.execute` resolves the read-only
    /// scope / secret policy / read bridge from `cachedRootPath`.
    /// Callers must already hold the evaluator's "no user folder
    /// session" guarantee and must pair with `deactivateEvalContext()`.
    func activateEvalContext(_ context: FolderContext) {
        currentContext = context
        hasActiveFolder = true
    }

    /// Reverse of `activateEvalContext` — clears the context without
    /// touching bookmarks, saved defaults, or tool registration (the
    /// evaluator owns its own registration lifecycle).
    func deactivateEvalContext() {
        currentContext = nil
        hasActiveFolder = false
    }

    /// Build context from a URL (assumes access is already granted)
    public func buildContext(from url: URL) async -> FolderContext {
        // The tree walk, manifest/context-file reads and extension scan are all
        // synchronous filesystem I/O. Run them off the main actor so picking a
        // large folder can't hang the UI.
        let (projectType, tree, manifest, isGitRepo, contextFiles, detectedExtensions) =
            await Task.detached(priority: .userInitiated) { [self] in
                let projectType = detectProjectType(url)
                let options = FileTreeOptions(
                    ignorePatterns: projectType.ignorePatterns
                )
                let tree = buildFileTree(url, options: options)
                let manifest = readManifest(url, projectType: projectType)
                let isGitRepo = checkIsGitRepo(url)
                let contextFiles = readContextFiles(url)
                let detectedExtensions = scanForKnownExtensions(
                    url,
                    ignorePatterns: projectType.ignorePatterns
                )
                return (projectType, tree, manifest, isGitRepo, contextFiles, detectedExtensions)
            }.value
        let gitStatus = isGitRepo ? await getGitStatus(url) : nil

        return FolderContext(
            rootPath: url,
            projectType: projectType,
            tree: tree,
            manifest: manifest,
            gitStatus: gitStatus,
            isGitRepo: isGitRepo,
            contextFiles: contextFiles,
            detectedFileExtensions: detectedExtensions
        )
    }

    // MARK: - Extension Scanner

    /// Hard limit on the number of filesystem entries the scanner will
    /// inspect before giving up. Picked a folder like `~/Downloads` should
    /// not pay for tens of thousands of `resourceValues` calls when the
    /// answer is "we already saw an .xlsx in the first 200 files".
    nonisolated private static let extensionScanMaxEntries: Int = 5_000

    /// Walk under `url` looking for files whose extension is in
    /// `FolderPluginHints.watchedExtensions`. Returns the set of matched
    /// extensions (lowercased, no leading dot). Early-exits the moment
    /// every watched extension has been seen — folders dominated by the
    /// "first match wins" case (e.g. a typical reports folder full of
    /// `.xlsx`) finish in a handful of `readdir` calls.
    ///
    /// `ignorePatterns` mirrors the file-tree builder so we don't dive
    /// into `.git` / `node_modules` / `.build` looking for spreadsheets
    /// that the agent would never see anyway. Hidden files are skipped
    /// for the same reason.
    nonisolated private func scanForKnownExtensions(
        _ url: URL,
        ignorePatterns: [String]
    ) -> Set<String> {
        let watched = FolderPluginHints.watchedExtensions
        guard !watched.isEmpty else { return [] }

        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var found: Set<String> = []
        var inspected = 0

        for case let fileURL as URL in enumerator {
            inspected += 1
            if inspected > Self.extensionScanMaxEntries { break }

            let name = fileURL.lastPathComponent
            if shouldIgnore(name, patterns: ignorePatterns) {
                enumerator.skipDescendants()
                continue
            }

            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }

            let ext = fileURL.pathExtension.lowercased()
            guard !ext.isEmpty, watched.contains(ext) else { continue }

            found.insert(ext)
            if found.count == watched.count { break }
        }

        return found
    }

    // MARK: - Context Files

    /// Maximum total size for the loaded context block (~5K tokens). Big
    /// enough for a typical AGENTS.md / CLAUDE.md, small enough that it
    /// can't crowd out the rest of the system prompt.
    nonisolated private static let contextFileMaxChars = 20_000

    /// Search order for the project-level context file. First found wins —
    /// loading multiple would either confuse the model with conflicting
    /// guidance or balloon the static prefix and hurt KV-cache reuse.
    nonisolated private static let contextFileCandidates: [String] = [
        ".hermes.md", "HERMES.md",
        "AGENTS.md", "agents.md",
        "CLAUDE.md", "claude.md",
        ".cursorrules",
    ]

    /// Find and read the first present project-context file from `url`.
    /// Returns a pre-formatted `## <filename>\n\n<content>` block, truncated
    /// to `contextFileMaxChars`, or `nil` if no candidate exists.
    nonisolated private func readContextFiles(_ url: URL) -> String? {
        for name in Self.contextFileCandidates {
            let candidate = url.appendingPathComponent(name)
            guard let raw = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return "## \(name)\n\n\(Self.truncateContextContent(trimmed, label: name))"
        }
        return nil
    }

    /// Head + tail truncation with a `[truncated ...]` marker in the middle.
    /// 70% head / 20% tail — the head usually contains the most important
    /// framing (project intro, conventions) while the tail catches
    /// sign-off / configuration that often appears at the bottom.
    nonisolated private static func truncateContextContent(_ content: String, label: String) -> String {
        guard content.count > contextFileMaxChars else { return content }
        let headChars = Int(Double(contextFileMaxChars) * 0.7)
        let tailChars = Int(Double(contextFileMaxChars) * 0.2)
        let head = String(content.prefix(headChars))
        let tail = String(content.suffix(tailChars))
        let marker =
            "\n\n[truncated \(label): kept \(headChars)+\(tailChars) of \(content.count) chars]\n\n"
        return head + marker + tail
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
            FolderToolManager.shared.unregisterFolderTools()
        }

        // Folder change rotates the deterministic plugin-tool injection
        // set (xlsx in `~/reports`, none in a code repo). Drop every
        // cached preflight snapshot so the next turn rebuilds against
        // the new folder context instead of replaying the prior
        // folder's tools. Folder swaps are rare; losing mid-session
        // `capabilities_load` history across the process is an
        // acceptable cost vs the alternative of stale tool sets.
        Task { await SessionToolStateStore.shared.invalidateAll() }
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
                FolderToolManager.shared.registerFolderTools(for: context)
            }

        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    // MARK: - Project Type Detection

    nonisolated private func detectProjectType(_ url: URL) -> ProjectType {
        let fm = FileManager.default

        // Check for manifest files in order of specificity
        for projectType in ProjectType.allCases where projectType != .unknown {
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
    nonisolated private func shouldIgnore(_ name: String, patterns: [String]) -> Bool {
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

    nonisolated private func buildFileTree(_ url: URL, options: FileTreeOptions) -> String {
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
    nonisolated private func visibleChildCount(of url: URL, patterns: [String]) -> Int {
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
    nonisolated private func computeAdaptiveDepth(_ url: URL, options: FileTreeOptions) -> Int {
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
    nonisolated private func groupFilesByExtension(_ files: [URL]) -> [(ext: String, count: Int)] {
        var groups: [String: Int] = [:]
        for file in files {
            let ext = file.pathExtension.lowercased()
            let key = ext.isEmpty ? "other" : ".\(ext)"
            groups[key, default: 0] += 1
        }
        return groups.sorted { $0.value > $1.value }.map { (ext: $0.key, count: $0.value) }
    }

    nonisolated private func countContents(_ url: URL, patterns: [String]) -> (files: Int, dirs: Int) {
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

    nonisolated private func readManifest(_ url: URL, projectType: ProjectType) -> String? {
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

    nonisolated private func checkIsGitRepo(_ url: URL) -> Bool {
        let gitDir = url.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func getGitStatus(_ url: URL) async -> String? {
        do {
            let (output, _) = try await FolderToolHelpers.runGitCommand(
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
