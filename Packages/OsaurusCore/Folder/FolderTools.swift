//
//  FolderTools.swift
//  osaurus
//
//  Folder-context tools for file operations, code editing, and git
//  integration. Registered by FolderToolManager whenever a working folder
//  is selected; agents use them to operate directly on the host folder.
//

import Darwin
import Foundation

// MARK: - Tool Errors

enum FolderToolError: LocalizedError {
    case invalidArguments(String)
    case pathOutsideRoot(String)
    case fileNotFound(String)
    case directoryNotFound(String)
    case operationFailed(String)
    /// File at `path` is binary (or otherwise not decodable as text).
    /// `ext` is the lowercased file extension when available; `detail`
    /// is a structured reason the envelope mapper folds into the model-
    /// facing message so the agent sees a single non-retryable signal
    /// instead of opaque `NSCocoaError` text.
    case binaryContent(path: String, ext: String?, detail: BinaryDetail)

    /// Sub-classification on `binaryContent`. Each case carries a tailored
    /// pivot hint (`pivotHint`) so the model gets a concrete next step
    /// instead of a generic "this is binary" message.
    enum BinaryDetail: Sendable {
        /// First-chunk NUL-byte sniff matched.
        case nulByte
        /// Bytes weren't valid UTF-8.
        case decodeFailed
        /// `DocumentParser` returned an image-only PDF (no text layer).
        case imageOnlyPdf
        /// The file is an image (`.png` / `.jpg` / ...); `file_read`
        /// returns text only and cannot surface pixels.
        case image
        /// `DocumentParser` threw `.readFailed` / `.unsupportedFormat` /
        /// `.fileTooLarge`.
        case parseFailed

        var pivotHint: String? {
            switch self {
            case .imageOnlyPdf:
                return
                    "The PDF has no extractable text layer (likely scanned images); use an OCR tool via shell_run."
            case .image:
                return
                    "This is an image file; file_read returns text only. Attach the image to chat or use an OCR / vision tool to read it."
            case .parseFailed:
                return
                    "The document couldn't be parsed — it may be encrypted, password-protected, or malformed."
            case .nulByte, .decodeFailed:
                return nil
            }
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): return "Invalid arguments: \(msg)"
        case .pathOutsideRoot(let path): return "Path is outside working directory: \(path)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .directoryNotFound(let path): return "Directory not found: \(path)"
        case .operationFailed(let msg): return "Operation failed: \(msg)"
        case .binaryContent(let path, let ext, _):
            if let ext, !ext.isEmpty {
                return "Binary content at \(path) (.\(ext))"
            }
            return "Binary content at \(path)"
        }
    }
}

// MARK: - Tool Helpers

/// Shared utilities for folder tools
enum FolderToolHelpers {
    /// Resolve a tool's `path` argument under the working folder.
    /// Accepts a relative path under root (e.g. `src/app.py`) or an
    /// absolute path that lives inside root (e.g. `/Users/x/proj/src/app.py`
    /// when root is `/Users/x/proj`). After `..`/`.` standardisation the
    /// resolved path must equal root or be a strict child (`root + "/"`)
    /// so traversal and sibling directories like `<root>-other` cannot slip
    /// through a substring match.
    static func resolvePath(_ relativePath: String, rootPath: URL) throws -> URL {
        let rootStandardized = rootPath.standardized.path
        let resolvedURL: URL
        if relativePath.hasPrefix("/") {
            let absStandardized = URL(fileURLWithPath: relativePath).standardized.path
            let isWithinRoot =
                absStandardized == rootStandardized
                || absStandardized.hasPrefix(rootStandardized + "/")
            guard isWithinRoot else {
                throw FolderToolError.invalidArguments(
                    "path must be relative to the working directory or absolute under it "
                        + "(got '\(relativePath)'). Pass just the file or directory name — "
                        + "e.g. 'README.md' or 'src/app.py'."
                )
            }
            resolvedURL = URL(fileURLWithPath: absStandardized)
        } else {
            resolvedURL = rootPath.appendingPathComponent(relativePath).standardized
        }
        let isWithinRoot =
            resolvedURL.path == rootStandardized
            || resolvedURL.path.hasPrefix(rootStandardized + "/")
        guard isWithinRoot else {
            throw FolderToolError.pathOutsideRoot(relativePath)
        }

        // Symlink-safe containment: the lexical check above only resolves
        // `..` / `.`, so a symlink *inside* the root (e.g. `notes.txt ->
        // ~/.ssh/id_rsa`) would pass it and then be followed out of scope
        // on read. Resolve symlinks on both the target and the root and
        // re-check. `resolvingSymlinksInPath()` resolves existing
        // components (and macOS firmlinks like `/tmp` -> `/private/tmp`),
        // leaving not-yet-created trailing components intact — so a new
        // file under a real directory still passes, while a symlink whose
        // real target escapes the root is rejected. Both sides are
        // resolved so the firmlink rewrite can't cause a false mismatch.
        let realRoot = rootPath.resolvingSymlinksInPath().standardized.path
        let realResolved = resolvedURL.resolvingSymlinksInPath().standardized.path
        let isWithinRealRoot =
            realResolved == realRoot
            || realResolved.hasPrefix(realRoot + "/")
        guard isWithinRealRoot else {
            throw FolderToolError.pathOutsideRoot(relativePath)
        }
        return resolvedURL
    }

    /// Parse JSON arguments to dictionary
    static func parseArguments(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw FolderToolError.invalidArguments("Failed to parse JSON")
        }
        return dict
    }

    /// Detect project type from root path
    static func detectProjectType(_ url: URL) -> ProjectType {
        let fm = FileManager.default
        for projectType in ProjectType.allCases where projectType != .unknown {
            for manifestFile in projectType.manifestFiles
            where fm.fileExists(atPath: url.appendingPathComponent(manifestFile).path) {
                return projectType
            }
        }
        return .unknown
    }

    /// Convert a filename glob (`*` / `?` wildcards) into an anchored regex
    /// with every OTHER regex metacharacter escaped. The old conversion only
    /// escaped `.` and rewrote `*`, so a pattern containing `+ ( [ {` became
    /// a broken (or wrong) regex that silently matched nothing.
    static func globToRegex(_ pattern: String) -> String {
        let body = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return "^\(body)$"
    }

    /// Root-relative display path for `url`, symlink-safe. FileManager
    /// enumerators return REAL paths (`/private/var/...`) even when the
    /// root handle was created through a symlink/firmlink (`/var/...`,
    /// `/tmp/...`), so a naive `hasPrefix(root.path)` misses and callers
    /// used to fall back to `lastPathComponent` — silently flattening
    /// `src/client.py` to `client.py`. The model then feeds that wrong
    /// path into its next tool call and gets "File not found" for a file
    /// the search itself just reported. Resolve symlinks on BOTH sides
    /// before prefix-matching; fall back to the basename only when the
    /// url genuinely isn't under the root.
    static func displayPath(for url: URL, under rootPath: URL) -> String {
        let root = rootPath.standardized.path
        let path = url.standardized.path
        if path == root { return "." }
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        let realRoot = rootPath.resolvingSymlinksInPath().standardized.path
        let realPath = url.resolvingSymlinksInPath().standardized.path
        if realPath == realRoot { return "." }
        if realPath.hasPrefix(realRoot + "/") {
            return String(realPath.dropFirst(realRoot.count + 1))
        }
        return url.lastPathComponent
    }

    /// Check if pattern matches filename
    static func matchesPattern(_ name: String, pattern: String) -> Bool {
        if pattern.contains("*") {
            return name.range(of: globToRegex(pattern), options: .regularExpression) != nil
        }
        return name == pattern
    }

    /// Check if name should be ignored based on patterns
    static func shouldIgnore(_ name: String, patterns: [String]) -> Bool {
        patterns.contains { matchesPattern(name, pattern: $0) }
    }

    /// Run a process and wait for completion asynchronously without blocking the main thread.
    /// The termination handler is set before running to avoid race conditions.
    static func runProcessAsync(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Run a git command and return the output.
    /// A 30-second timeout prevents indefinite hangs (e.g. credential prompts, network issues).
    static func runGitCommand(
        arguments: [String],
        in directory: URL,
        timeout: Int = 30
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Set up timeout to terminate hung git processes
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            if process.isRunning {
                process.terminate()
            }
        }

        defer {
            timeoutTask.cancel()
        }

        try await runProcessAsync(process)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (output, process.terminationStatus)
    }

    // MARK: - Combined-mode secret denylist

    /// Extensions whose files are treated as secret material (private
    /// keys, certs with keys, keystores). Lowercased, no leading dot.
    private static let secretExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "keystore", "jks",
    ]

    /// Exact basenames that are secret regardless of extension.
    private static let secretBasenames: Set<String> = [
        ".npmrc", ".netrc", "credentials", ".pypirc", ".dockercfg",
    ]

    /// Suffixes on a `.env` family file that are conventionally NON-secret
    /// (templates / samples) and therefore allowed even under refusal.
    private static let envAllowedSuffixes: [String] = [
        ".example", ".sample", ".template", ".dist",
    ]

    /// True when the current execution is combined sandbox + host-read
    /// mode (`ChatExecutionContext.hostReadOnlyScope` set) and secret
    /// reads are not explicitly allowed for the session. Plain folder
    /// mode (scope `nil`) is always `false`, so its behavior is unchanged.
    private static var secretRefusalActive: Bool {
        ChatExecutionContext.hostReadOnlyScope != nil
            && !ChatExecutionContext.allowHostSecretReads
    }

    /// Whether `fileURL` points at a file that should be refused in
    /// combined read-only mode. Checks the basename, extension, and the
    /// path components so a key under `.ssh/` or `.aws/` is caught even
    /// when its own name looks innocuous. Single source of truth shared
    /// by `file_read` (including its directory listing) and `file_search`.
    static func isSecretPath(fileURL: URL) -> Bool {
        let lowerName = fileURL.lastPathComponent.lowercased()
        let ext = fileURL.pathExtension.lowercased()

        // `.git/config` and `.aws/`, `.ssh/`, `.gnupg/` directory contents
        // routinely carry tokens / private keys.
        let components = fileURL.pathComponents
        let secretDirs: Set<String> = [".aws", ".ssh", ".gnupg"]
        if !secretDirs.isDisjoint(with: Set(components.map { $0.lowercased() })) {
            return true
        }
        if components.count >= 2 {
            let tail = components.suffix(2).map { $0.lowercased() }
            if tail == [".git", "config"] { return true }
        }

        if secretBasenames.contains(lowerName) { return true }

        // SSH/GPG private keys: `id_rsa`, `id_ed25519`, etc. — but allow
        // the matching `.pub` public keys.
        if lowerName.hasPrefix("id_"), ext != "pub" { return true }

        // `.env` family: refuse `.env` and `.env.<anything>` except
        // template/sample suffixes.
        if lowerName == ".env" { return true }
        if lowerName.hasPrefix(".env.") {
            return !envAllowedSuffixes.contains { lowerName.hasSuffix($0) }
        }

        // Public keys (`*.pub`) are safe; secret extensions otherwise.
        if ext == "pub" { return false }
        if secretExtensions.contains(ext) { return true }

        return false
    }

    /// True when `fileURL` must be refused for the current execution
    /// because the combined-mode secret denylist is active and the file
    /// is classified secret. Convenience combiner used by the read tools.
    static func shouldRefuseSecret(fileURL: URL) -> Bool {
        secretRefusalActive && isSecretPath(fileURL: fileURL)
    }

    /// The shared `rejected` envelope returned when a read tool refuses a
    /// secret file in combined mode. `tool` names the refusing tool so
    /// the model-facing message is attributed correctly.
    static func secretRefusalEnvelope(relativePath: String, tool: String) -> String {
        ToolEnvelope.failure(
            kind: .rejected,
            message:
                "Refused to read '\(relativePath)': secret files (.env, private keys, "
                + "credentials) are blocked in read-only sandbox mode to prevent leaking "
                + "secrets into the sandbox. This is not retryable.",
            tool: tool,
            retryable: false
        )
    }

    // MARK: - Filename search matching

    /// True when a filename pattern contains glob metacharacters (`*` / `?`).
    /// Shared by the host and sandbox `target:"files"` routes so both decide
    /// substring-vs-glob identically: a bare word is a case-insensitive
    /// substring, a pattern with wildcards is a case-insensitive glob.
    static func patternHasGlobMetacharacters(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    // MARK: - Search traversal guards

    /// Build-artifact directories pruned during a recursive host search.
    /// Deliberately conservative: only directories that never hold user
    /// documents, so pruning can't hide real files in a home/Desktop-rooted
    /// workspace. Hidden dirs (`.git`, `.build`, `.venv`, …) are already
    /// dropped by `.skipsHiddenFiles`; this catches the non-hidden ones.
    static let prunedSearchDirectories: Set<String> = ["node_modules", "Pods", "DerivedData"]

    /// Maximum number of filesystem entries a single host search pulls from
    /// the enumerator before stopping and reporting truncation. A
    /// deterministic worst-case traversal bound so a low/zero-match query
    /// over a huge tree can't walk the entire subtree (and blow past the
    /// registry's 120s wall-clock cap with no results). Filename matching at
    /// this count is sub-second; content reads stay separately bounded by
    /// `maxContentSearchFileBytes` + the binary-extension skip.
    static let maxSearchEntriesVisited = 20_000

    /// Shared prune step for a recursive host search enumerator. When
    /// `fileURL` is a directory, prunes build-artifact subtrees (via
    /// `skipDescendants()`) and returns true so the caller skips it; returns
    /// false for regular files so the caller proceeds to match/read them.
    static func pruneSearchDirectory(
        _ fileURL: URL,
        isDirectory: Bool,
        enumerator: FileManager.DirectoryEnumerator?
    ) -> Bool {
        guard isDirectory else { return false }
        if prunedSearchDirectories.contains(fileURL.lastPathComponent) {
            enumerator?.skipDescendants()
        }
        return true
    }

    /// Cancellation + visit-budget gate for one search enumerator step,
    /// shared by both host search loops. Throws `CancellationError` when the
    /// surrounding task is cancelled (so a timed-out search stops instead of
    /// walking on as a background zombie), counts the visited entry, and
    /// returns false once `limit` is exceeded so the caller can stop and mark
    /// the result truncated.
    static func searchStepWithinBudget(visited: inout Int, limit: Int) throws -> Bool {
        try Task.checkCancellation()
        visited += 1
        return visited <= limit
    }

    /// Per-file size cap for a content search. Files larger than this are
    /// skipped before being read into memory, so a workspace full of large
    /// media / data files doesn't load each one only to fail UTF-8 decode.
    static let maxContentSearchFileBytes = 2 * 1024 * 1024

    /// Extensions skipped by a content search before any read: obvious
    /// binary/media/archive/office-binary types that can't yield a useful
    /// text substring match. The UTF-8 decode `nil`-skip remains the backstop.
    static let contentSearchSkippedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "heic", "ico", "icns",
        "mov", "mp4", "m4v", "avi", "mkv", "webm",
        "mp3", "wav", "aac", "m4a", "flac", "ogg",
        "zip", "gz", "tar", "tgz", "bz2", "xz", "7z", "rar", "dmg",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "numbers", "pages",
        "bin", "exe", "dll", "so", "dylib", "o", "a", "class", "wasm",
    ]
}

// MARK: - Core Tools

// MARK: File Tree Tool

struct FileTreeTool: OsaurusTool {
    let name = "file_tree"
    let description =
        "List the directory structure of the working directory or a subdirectory. Use this (rather "
        + "than a shell `ls` / `tree`) to inspect the working directory layout. Returns a tree view of "
        + "files and folders. Skips hidden files and truncates at 300 files."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional relative path to list (default: root). Use '.' for current directory."
                ),
            ]),
            "max_depth": .object([
                "type": .string("integer"),
                "description": .string("Maximum depth to traverse (default: 3)"),
            ]),
        ]),
        "required": .array([]),
    ])

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        // `path` is optional (defaults to root). Coercion already drops
        // empty-string fillers, so a missing or absent value cleanly
        // falls back to ".".
        let relativePath = (args["path"] as? String) ?? "."
        let maxDepth = coerceInt(args["max_depth"]) ?? 3

        // Combined mode: an absolute `/workspace/...` path is the Linux
        // sandbox, not the host workspace — serve it from the sandbox
        // bridge so this one tool lists either filesystem by path.
        if combinedFileRoute(path: relativePath) == .sandbox,
            let bridge = ChatExecutionContext.sandboxReadBridge
        {
            return try await sandboxBridgeList(bridge, path: relativePath, maxDepth: maxDepth)
        }

        let targetURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw FolderToolError.directoryNotFound(relativePath)
        }

        return ToolEnvelope.success(tool: name, text: buildTree(targetURL, maxDepth: maxDepth))
    }

    /// Render a directory tree for `targetURL` (already resolved and known
    /// to be a directory). Shared with `file_read`, which lists directories
    /// under the unified read tool — the path argument decides file vs
    /// directory, so this struct is now an internal lister, not a
    /// separately-registered tool.
    func treeText(for targetURL: URL, maxDepth: Int) -> String {
        buildTree(targetURL, maxDepth: maxDepth)
    }

    /// Structured directory listing for `targetURL` (already resolved and
    /// known to be a directory). Returns entries whose `path` is relative to
    /// the working root, so the model can copy a `path` field straight into
    /// the next `file_read` call instead of parsing a glyph tree. Honors the
    /// same ignore/secret/cap rules as `buildTree`. `truncated` is true when
    /// the file cap or a per-directory file cap dropped entries.
    func entries(for targetURL: URL, maxDepth: Int) -> (entries: [[String: Any]], truncated: Bool) {
        var out: [[String: Any]] = []
        var fileCount = 0
        var truncated = false
        let maxFiles = Self.maxFiles
        let maxFilesPerDir = Self.maxFilesPerDir
        let ignorePatterns = FolderToolHelpers.detectProjectType(rootPath).ignorePatterns

        func relativePath(_ url: URL) -> String {
            FolderToolHelpers.displayPath(for: url, under: rootPath)
        }

        func traverse(_ currentURL: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            let fm = FileManager.default
            guard
                let contents = try? fm.contentsOfDirectory(
                    at: currentURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { return }

            let sorted = contents.sorted { a, b in
                let aIsDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let bIsDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if aIsDir != bIsDir { return aIsDir }
                return a.lastPathComponent.lowercased() < b.lastPathComponent.lowercased()
            }

            var filesShownHere = 0
            for item in sorted {
                guard fileCount < maxFiles else {
                    truncated = true
                    return
                }
                let name = item.lastPathComponent
                if FolderToolHelpers.shouldIgnore(name, patterns: ignorePatterns) { continue }
                if FolderToolHelpers.shouldRefuseSecret(fileURL: item) { continue }

                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    out.append(["name": name, "path": relativePath(item), "type": "directory"])
                    if depth < maxDepth {
                        traverse(item, depth: depth + 1)
                    }
                } else {
                    if filesShownHere >= maxFilesPerDir {
                        truncated = true
                        continue
                    }
                    out.append(["name": name, "path": relativePath(item), "type": "file"])
                    filesShownHere += 1
                    fileCount += 1
                }
            }
        }

        traverse(targetURL, depth: 1)
        return (out, truncated)
    }

    /// File-count ceiling — caps how many leaf files the tree enumerates.
    private static let maxFiles = 300
    /// Character ceiling for the rendered tree. A wide/deep layout (many
    /// directories, which don't count toward `maxFiles`) can still bloat the
    /// retained context across every later request, so cap the raw output too.
    private static let maxOutputChars = ToolOutputCaps.tree
    /// Per-directory file ceiling. A flat media folder (hundreds of
    /// screenshots) is collapsed past this so the listing — and the retained
    /// context on every later turn — stays readable. Directories are never
    /// collapsed; the full folder structure is always shown.
    private static let maxFilesPerDir = 20

    private func buildTree(_ url: URL, maxDepth: Int) -> String {
        var result = "./\n"
        var fileCount = 0
        var truncated = false
        let maxFiles = Self.maxFiles
        let maxChars = Self.maxOutputChars
        let maxFilesPerDir = Self.maxFilesPerDir
        let ignorePatterns = FolderToolHelpers.detectProjectType(rootPath).ignorePatterns

        func traverse(_ currentURL: URL, depth: Int, prefix: String) {
            guard depth <= maxDepth else { return }

            let fm = FileManager.default
            guard
                let contents = try? fm.contentsOfDirectory(
                    at: currentURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { return }

            let sorted = contents.sorted { a, b in
                let aIsDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let bIsDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if aIsDir != bIsDir { return aIsDir }
                return a.lastPathComponent.lowercased() < b.lastPathComponent.lowercased()
            }

            // Directories sort first, so files form a contiguous tail; track
            // how many files this directory has shown to collapse the rest.
            var filesShownHere = 0
            var filesCollapsedHere = 0
            for (index, item) in sorted.enumerated() {
                guard fileCount < maxFiles, result.count < maxChars else {
                    truncated = true
                    return
                }

                let name = item.lastPathComponent
                if FolderToolHelpers.shouldIgnore(name, patterns: ignorePatterns) { continue }

                // Combined-mode secret denylist: don't even disclose the
                // names of secret files in the tree. Inert in plain folder
                // mode. Directories are never classified secret, so this
                // only prunes individual files.
                if FolderToolHelpers.shouldRefuseSecret(fileURL: item) { continue }

                let isLast = index == sorted.count - 1
                let connector = isLast ? "└── " : "├── "
                let childPrefix = isLast ? "    " : "│   "
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                if isDir {
                    result += "\(prefix)\(connector)\(name)/\n"
                    if depth < maxDepth {
                        traverse(item, depth: depth + 1, prefix: prefix + childPrefix)
                    }
                } else {
                    if filesShownHere >= maxFilesPerDir {
                        filesCollapsedHere += 1
                        continue
                    }
                    result += "\(prefix)\(connector)\(name)\n"
                    filesShownHere += 1
                    fileCount += 1
                }
            }
            // Collapsed files are the directory's trailing entries, so the
            // summary is its last visual child (`└──`).
            if filesCollapsedHere > 0 {
                result += "\(prefix)└── ... +\(filesCollapsedHere) more files\n"
            }
        }

        traverse(url, depth: 1, prefix: "")
        if truncated {
            result +=
                "... (truncated at \(maxFiles) files / \(maxChars) chars — "
                + "narrow the view with `path` or a smaller `max_depth`)\n"
        }
        return result
    }
}

// MARK: File Read Tool

struct FileReadTool: OsaurusTool {
    let name = "file_read"
    let description =
        "Read a file's contents, or list a directory's contents — the path decides. Files return text "
        + "with `N|` line-number prefixes (text-extractable documents — PDF, Word, PowerPoint, RTF, HTML — "
        + "and a bounded XLSX preview are supported; binaries are not); bound large reads with "
        + "start_line/end_line, tail_lines, or max_chars. Directories return a listing; bound with "
        + "max_depth. Example: {\"path\": \"src/app.py\", \"start_line\": 1, \"end_line\": 120}"
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path to the file from the working directory"),
            ]),
            "max_depth": .object([
                "type": .string("integer"),
                "description": .string("Optional directory listing depth when path is a directory (default: 3)"),
            ]),
            "sheet_name": .object([
                "type": .string("string"),
                "description": .string("Optional XLSX worksheet name to preview"),
            ]),
            "start_line": .object([
                "type": .string("integer"),
                "description": .string("Optional start line number or XLSX row number (1-indexed, inclusive)"),
            ]),
            "end_line": .object([
                "type": .string("integer"),
                "description": .string("Optional end line number or XLSX row number (1-indexed, inclusive)"),
            ]),
            "tail_lines": .object([
                "type": .string("integer"),
                "description": .string(
                    "Optional: read the last N lines instead of a range (useful for logs)"
                ),
            ]),
            "max_chars": .object([
                "type": .string("integer"),
                "description": .string("Optional cap on returned characters after line selection"),
            ]),
            "max_rows": .object([
                "type": .string("integer"),
                "description": .string("Optional XLSX preview row cap per sheet (default 8, max 50)"),
            ]),
            "max_columns": .object([
                "type": .string("integer"),
                "description": .string("Optional XLSX preview column cap per row (default 8, max 30)"),
            ]),
        ]),
        "required": .array([.string("path")]),
    ])

    private let rootPath: URL
    private let documentRegistry: DocumentFormatRegistry

    init(rootPath: URL, documentRegistry: DocumentFormatRegistry = .shared) {
        self.rootPath = rootPath
        self.documentRegistry = documentRegistry
    }

    /// Maximum characters for file_read output to prevent context window exhaustion.
    /// Tiered against shell_run / git_diff via `ToolOutputCaps`.
    private static let maxOutputChars = ToolOutputCaps.fileRead

    /// Maximum raw bytes read for plain text / source / CSV before
    /// decoding. Rich documents and XLSX previews have their own adapter
    /// limits; this cap protects the raw path from loading a huge file
    /// just to emit a 15K-character preview.
    private static let rawReadByteLimit = 5 * 1024 * 1024

    /// Chunk size for bounded raw reads. Keeps peak transient allocation
    /// modest while avoiding tiny syscall loops.
    private static let rawReadChunkBytes = 64 * 1024

    /// First-chunk byte budget for the NUL-byte binary sniff. Catches
    /// off-extension binaries whose UTF-8 decode happens to succeed by
    /// luck. Matches the size most editors / `file(1)` use for the same
    /// heuristic.
    private static let binarySniffBytes = 4096

    private struct LoadedFileContent {
        let text: String
        let rawRead: RawReadMetadata?
    }

    private struct RawReadMetadata {
        let bytesRead: Int
        let byteLimit: Int
        let fileSize: Int64?
        let truncatedByByteLimit: Bool
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "relative path under the working folder (e.g. `src/app.py`)",
            tool: name
        )
        guard case .value(let relativePath) = pathReq else {
            return pathReq.failureEnvelope ?? ""
        }

        // Combined mode: an absolute `/workspace/...` path is the Linux
        // sandbox — serve it from the sandbox bridge, translating the
        // host `start_line`/`end_line` range to the sandbox convention.
        // A directory path falls back to a listing inside the bridge
        // (detected via the "Is a directory" read error).
        if combinedFileRoute(path: relativePath) == .sandbox,
            let bridge = ChatExecutionContext.sandboxReadBridge
        {
            return try await sandboxBridgeRead(
                bridge,
                path: relativePath,
                startLine: max(coerceInt(args["start_line"]) ?? 0, 0),
                endLine: max(coerceInt(args["end_line"]) ?? 0, 0),
                tailLines: max(coerceInt(args["tail_lines"]) ?? 0, 0),
                maxChars: max(coerceInt(args["max_chars"]) ?? 0, 0),
                maxDepth: max(coerceInt(args["max_depth"]) ?? 0, 0)
            )
        }

        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        // Combined sandbox + host-read mode: refuse secret files even
        // though they live inside the scoped workspace. The read channel
        // is the agent-as-bridge surface, so a poisoned README or a
        // steered instruction shouldn't be able to pull `.env` / private
        // keys / credentials into context and exfiltrate them via the
        // sandbox. Plain folder mode is unaffected (the gate is inert
        // when no read-only host scope is bound). Shared with
        // `file_search` so the denylist can't be bypassed by switching
        // tools.
        if FolderToolHelpers.shouldRefuseSecret(fileURL: fileURL) {
            return FolderToolHelpers.secretRefusalEnvelope(relativePath: relativePath, tool: name)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw FolderToolError.fileNotFound(relativePath)
        }

        // A directory path lists rather than reads (the path carries the
        // decision — no separate `file_tree` tool to mis-select). Reuse the
        // internal tree lister, honoring `max_depth`, but stamp the
        // envelope as `file_read` since that's the only file tool now.
        if isDirectory.boolValue {
            let maxDepth = coerceInt(args["max_depth"]) ?? 3
            let listing = FileTreeTool(rootPath: rootPath).entries(for: fileURL, maxDepth: maxDepth)
            return ToolEnvelope.listing(
                tool: name,
                path: relativePath,
                entries: listing.entries,
                truncated: listing.truncated
            )
        }

        let sheetName: String?
        if args.keys.contains("sheet_name") {
            let sheetReq = requireString(
                args,
                "sheet_name",
                expected: "worksheet name in the XLSX workbook",
                tool: name
            )
            guard case .value(let parsedSheetName) = sheetReq else {
                return sheetReq.failureEnvelope ?? ""
            }
            sheetName = parsedSheetName
        } else {
            sheetName = nil
        }

        if let workbookPreview = try await workbookPreviewIfAvailable(
            fileURL: fileURL,
            relativePath: relativePath,
            sheetName: sheetName,
            args: args
        ) {
            return ToolEnvelope.success(tool: name, text: workbookPreview)
        }

        let ext = fileURL.pathExtension.lowercased()
        let content = try await loadFileContent(
            url: fileURL,
            relativePath: relativePath,
            ext: ext
        )
        let lines = content.text.components(separatedBy: .newlines)

        // `tail_lines` (last N lines, for logs) overrides an explicit
        // start/end range; `max_chars` optionally tightens the per-call
        // character cap below the hard `maxOutputChars` ceiling.
        let tailLines = max(coerceInt(args["tail_lines"]) ?? 0, 0)
        let maxChars = max(coerceInt(args["max_chars"]) ?? 0, 0)
        let startLine: Int
        let endLine: Int
        if tailLines > 0 {
            endLine = lines.count
            startLine = max(1, lines.count - tailLines + 1)
        } else {
            startLine = coerceInt(args["start_line"]) ?? 1
            endLine = coerceInt(args["end_line"]) ?? lines.count
        }
        let validStart = max(1, min(startLine, lines.count))
        let validEnd = max(validStart, min(endLine, lines.count))
        let charCap = maxChars > 0 ? min(maxChars, Self.maxOutputChars) : Self.maxOutputChars

        var output = ""
        var lastLineIncluded = validStart - 1
        var outputTruncated = false
        // Line cut mid-way by the char cap. Tracked separately so it is
        // never counted as "included": treating the cut line as complete
        // made the truncation notice (and `end_line`) overstate what the
        // model actually saw by one line.
        var partialLine: Int? = nil
        for i in (validStart - 1) ..< validEnd {
            // Gutter format is `N|content` with NO space after the pipe:
            // everything after the first `|` is byte-exact file content.
            // The earlier `N| content` form made a leading gutter space
            // indistinguishable from real leading whitespace — models
            // (gemma-4-12B live, grok-4.3 historically) copied it into
            // `file_write` content / `file_edit` old_string and corrupted
            // whitespace or whiffed the match.
            let line = String(format: "%6d|%@\n", i + 1, lines[i])
            if output.count + line.count > charCap {
                let remaining = charCap - output.count
                if remaining > 0 {
                    output += String(line.prefix(remaining))
                    partialLine = i + 1
                }
                outputTruncated = true
                break
            }
            output += line
            lastLineIncluded = i + 1
        }

        if output.isEmpty {
            return ToolEnvelope.success(tool: name, text: "(empty file)")
        }

        // If truncated, inform the model and suggest using line ranges
        if outputTruncated || lastLineIncluded < validEnd {
            let totalLabel = Self.lineCountLabel(lines.count, rawRead: content.rawRead)
            if let partialLine {
                output +=
                    "\n... (truncated mid-line: line \(partialLine) is only PARTIALLY shown; complete lines end at \(lastLineIncluded) of \(totalLabel) — use start_line/end_line for specific ranges)"
            } else {
                output +=
                    "\n... (truncated at \(lastLineIncluded) of \(totalLabel) lines — use start_line/end_line for specific ranges)"
            }
        }
        if let rawRead = content.rawRead, rawRead.truncatedByByteLimit {
            output +=
                "\n... (raw read capped at \(Self.formatByteCount(Int64(rawRead.bytesRead)))"
                + " of \(Self.formatByteCount(rawRead.fileSize ?? Int64(rawRead.bytesRead)))"
                + " before full-file load; split the file or use a format-specific reader for later content)"
        }

        let text: String
        if validStart > 1 || validEnd < lines.count || content.rawRead?.truncatedByByteLimit == true {
            let totalLines = Self.lineCountLabel(lines.count, rawRead: content.rawRead)
            // When the char cap cut the FIRST line mid-way there is no
            // complete line at all — say so instead of an inverted range.
            let endLabel =
                lastLineIncluded >= validStart
                ? "\(lastLineIncluded)" : "\(validStart) (partial)"
            text = "Lines \(validStart)-\(endLabel) of \(totalLines):\n" + output
        } else {
            text = output
        }
        var result: [String: Any] = [
            "kind": "file",
            "text": text,
            // Self-describing gutter contract, carried WITH the payload:
            // models (gemma-4-12B live) have read `     1|41` as "first
            // number is 1" when the only explanation lived back in the
            // tool schema. One short field per read is cheaper than one
            // wrong-answer retry loop.
            "line_format": "each line is `<line number>|<content>`; content starts after the first `|`",
            "path": relativePath,
            "start_line": validStart,
            "end_line": lastLineIncluded,
            "total_lines": lines.count,
            "total_lines_exact": content.rawRead?.truncatedByByteLimit != true,
            "truncated": outputTruncated || lastLineIncluded < validEnd
                || content.rawRead?.truncatedByByteLimit == true,
        ]
        // The numbered gutter cannot express whether the file's last line is
        // terminated — a byte-exact reconstruction (backup copies, `equals`
        // contracts) needs to know if a final `\n` belongs at the end
        // (observed live: a model rebuilt a config from the gutter text and
        // dropped the trailing newline, failing a byte-for-byte check by one
        // byte). Only stated when the read actually reached the end of file.
        if content.rawRead?.truncatedByByteLimit != true {
            result["ends_with_newline"] = content.text.hasSuffix("\n")
        }
        if let partialLine {
            result["partial_line"] = partialLine
        }
        if let rawRead = content.rawRead {
            result["bytes_read"] = rawRead.bytesRead
            result["byte_limit"] = rawRead.byteLimit
            result["raw_bytes_truncated"] = rawRead.truncatedByByteLimit
            if let fileSize = rawRead.fileSize {
                result["file_size"] = fileSize
            }
        }
        return ToolEnvelope.success(
            tool: name,
            result: result
        )
    }

    /// Pull text out of the file at `url`, throwing `binaryContent` when
    /// the file is not text or text-extractable. Three branches:
    ///   - images are refused outright (this tool returns text only);
    ///   - text-extractable documents (PDF, Word, PowerPoint, RTF, HTML,
    ///     …) go through `DocumentParser`, which routes through
    ///     `DocumentFormatRegistry` and PDFKit / `NSAttributedString`;
    ///   - plain text / source / CSV / unknown extensions read raw bytes,
    ///     NUL-sniff the first 4KB, then UTF-8 decode. The raw path keeps
    ///     line-numbering and `start_line`/`end_line` semantics, and the
    ///     byte-first ordering catches binaries whose UTF-8 prefix happens
    ///     to be valid by coincidence.
    private func loadFileContent(
        url: URL,
        relativePath: String,
        ext: String
    ) async throws -> LoadedFileContent {
        // Text-only tool: never try to surface image pixels.
        if DocumentParser.isImageFile(url: url) {
            throw Self.binaryError(path: relativePath, ext: ext, detail: .image)
        }

        if Self.shouldExtractViaParser(url: url, ext: ext) {
            return LoadedFileContent(
                text: try await extractRichDocumentText(
                    url: url,
                    relativePath: relativePath,
                    ext: ext
                ),
                rawRead: nil
            )
        }

        return try await Task.detached(priority: .userInitiated) {
            try Self.loadBoundedRawText(
                url: url,
                relativePath: relativePath,
                ext: ext
            )
        }.value
    }

    /// Whether `url` should be routed through `DocumentParser` for text
    /// extraction rather than read as raw bytes. Plain-text / source /
    /// CSV extensions stay on the raw path (so line ranges keep working);
    /// every other format the document infrastructure can parse — PDF,
    /// Word, PowerPoint, RTF, HTML, etc. — is extracted. Lazily registers
    /// the built-in adapters (idempotent) so `canParse` sees formats like
    /// PPTX even on entry points that didn't bootstrap at launch, mirroring
    /// `workbookAdapter(for:)`.
    private static func shouldExtractViaParser(url: URL, ext: String) -> Bool {
        if DocumentParser.isPlainTextExtension(ext) { return false }
        DocumentAdaptersBootstrap.registerBuiltIns()
        return DocumentParser.canParse(url: url)
    }

    /// Run `DocumentParser.parse(url:)` on a detached task so the
    /// parser's internal `runBlocking` semaphore can't starve the
    /// cooperative thread pool. Matches the production pattern in
    /// `FloatingInputCard`.
    private func extractRichDocumentText(
        url: URL,
        relativePath: String,
        ext: String
    ) async throws -> String {
        let attachment: Attachment
        do {
            attachment = try await Task.detached(priority: .userInitiated) {
                try DocumentParser.parse(url: url)
            }.value
        } catch let err as DocumentParser.ParseError {
            switch err {
            case .emptyContent:
                // Empty rich doc — surface as empty string; downstream
                // slicing produces the same "(empty)" output the plain-
                // text path would for a zero-byte `.txt`.
                return ""
            case .unsupportedFormat, .readFailed, .fileTooLarge:
                throw Self.binaryError(path: relativePath, ext: ext, detail: .parseFailed)
            }
        }
        if case .document(_, let text, _) = attachment.kind {
            return text
        }
        // Image-only PDF (DocumentParser falls back to per-page image
        // attachments). We can't surface those through file_read — emit
        // the binary envelope so the model pivots instead of retrying.
        throw Self.binaryError(path: relativePath, ext: ext, detail: .imageOnlyPdf)
    }

    private static func loadBoundedRawText(
        url: URL,
        relativePath: String,
        ext: String
    ) throws -> LoadedFileContent {
        let fileSize: Int64? = {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
                return nil
            }
            return Int64(size)
        }()
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FolderToolError.operationFailed(
                "Could not read '\(relativePath)': \(error.localizedDescription)"
            )
        }
        defer { try? handle.close() }

        var data = Data()
        let reserve = min(Self.rawReadByteLimit, Int(fileSize ?? Int64(Self.rawReadByteLimit)))
        data.reserveCapacity(max(0, reserve))

        var bytesRead = 0
        do {
            while bytesRead < Self.rawReadByteLimit {
                try Task.checkCancellation()
                let remaining = Self.rawReadByteLimit - bytesRead
                let count = min(Self.rawReadChunkBytes, remaining)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                data.append(chunk)
                bytesRead += chunk.count
                if chunk.count < count { break }
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw FolderToolError.operationFailed(
                "Could not read '\(relativePath)': \(error.localizedDescription)"
            )
        }

        if data.prefix(Self.binarySniffBytes).contains(0) {
            throw binaryError(path: relativePath, ext: ext, detail: .nulByte)
        }

        let truncatedByByteLimit: Bool
        if let fileSize {
            truncatedByByteLimit = Int64(data.count) < fileSize
        } else {
            truncatedByByteLimit = data.count >= Self.rawReadByteLimit
        }
        let decoded = try decodeUTF8(
            data,
            allowTrailingScalarTrim: truncatedByByteLimit,
            relativePath: relativePath,
            ext: ext
        )

        return LoadedFileContent(
            text: decoded.text,
            rawRead: RawReadMetadata(
                bytesRead: decoded.bytesUsed,
                byteLimit: Self.rawReadByteLimit,
                fileSize: fileSize,
                truncatedByByteLimit: truncatedByByteLimit
            )
        )
    }

    private static func decodeUTF8(
        _ data: Data,
        allowTrailingScalarTrim: Bool,
        relativePath: String,
        ext: String
    ) throws -> (text: String, bytesUsed: Int) {
        let maxTrim = allowTrailingScalarTrim ? min(3, data.count) : 0
        for trim in 0 ... maxTrim {
            let candidate: Data
            if trim == 0 {
                candidate = data
            } else {
                candidate = Data(data.dropLast(trim))
            }
            if let text = String(data: candidate, encoding: .utf8) {
                return (text, candidate.count)
            }
        }
        throw binaryError(path: relativePath, ext: ext, detail: .decodeFailed)
    }

    /// Construct a `binaryContent` error, normalising an empty extension
    /// to `nil` so the envelope mapper doesn't emit a bare `(.)` label.
    private static func binaryError(
        path: String,
        ext: String,
        detail: FolderToolError.BinaryDetail
    ) -> FolderToolError {
        .binaryContent(
            path: path,
            ext: ext.isEmpty ? nil : ext,
            detail: detail
        )
    }

    private static func lineCountLabel(_ count: Int, rawRead: RawReadMetadata?) -> String {
        guard rawRead?.truncatedByByteLimit == true else { return "\(count)" }
        return "at least \(count) scanned"
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        let mib = 1024 * 1024
        if bytes >= Int64(mib), bytes % Int64(mib) == 0 {
            return "\(bytes / Int64(mib)) MiB (\(bytes) bytes)"
        }
        return "\(bytes) bytes"
    }

    private func workbookPreviewIfAvailable(
        fileURL: URL,
        relativePath: String,
        sheetName: String?,
        args: [String: Any]
    ) async throws -> String? {
        guard let adapter = workbookAdapter(for: fileURL) else { return nil }
        let document = try await adapter.parse(
            url: fileURL,
            sizeLimit: DocumentLimits.limit(forFormatId: adapter.formatId)
        )
        guard let workbook = document.representation.underlying as? Workbook else {
            throw FolderToolError.operationFailed(
                "Registered adapter '\(adapter.formatId)' did not produce a workbook representation."
            )
        }
        if let sheetName, !workbook.sheets.contains(where: { $0.name == sheetName }) {
            throw FolderToolError.operationFailed("Workbook has no sheet named '\(sheetName)'.")
        }

        let maxRows = Self.clamped(coerceInt(args["max_rows"]), fallback: 8, lower: 1, upper: 50)
        let maxColumns = Self.clamped(coerceInt(args["max_columns"]), fallback: 8, lower: 1, upper: 30)
        let startRow = max(1, coerceInt(args["start_line"]) ?? 1)
        let endRow = max(startRow, coerceInt(args["end_line"]) ?? Int.max)

        return Self.renderWorkbookPreview(
            document: document,
            workbook: workbook,
            relativePath: relativePath,
            sheetName: sheetName,
            startRow: startRow,
            endRow: endRow,
            maxRows: maxRows,
            maxColumns: maxColumns
        )
    }

    private func workbookAdapter(for fileURL: URL) -> (any DocumentFormatAdapter)? {
        var adapter = documentRegistry.adapter(for: fileURL)
        if adapter == nil, documentRegistry === DocumentFormatRegistry.shared {
            DocumentAdaptersBootstrap.registerBuiltIns(registry: documentRegistry)
            adapter = documentRegistry.adapter(for: fileURL)
        }

        guard adapter?.formatId.lowercased() == "xlsx" else { return nil }
        return adapter
    }

    private static func renderWorkbookPreview(
        document: StructuredDocument,
        workbook: Workbook,
        relativePath: String,
        sheetName: String?,
        startRow: Int,
        endRow: Int,
        maxRows: Int,
        maxColumns: Int
    ) -> String {
        let sheets = selectedSheets(in: workbook, sheetName: sheetName)
        let sheetNames = workbook.sheets.map(\.name)
        let formulaCount = workbook.sheets.reduce(0) { total, sheet in
            total
                + sheet.rows.reduce(0) { rowTotal, row in
                    rowTotal + row.cells.filter { $0.formula != nil }.count
                }
        }

        var lines: [String] = [
            "Workbook: \(relativePath)",
            "Format: \(document.formatId) (\(document.fileSize) bytes)",
            "Sheets: \(workbook.sheets.count) — \(boundedList(sheetNames, limit: 20))",
            "Formula cells: \(formulaCount)",
            securityLine(for: document.security),
            "",
        ]

        let previewSheets = sheetName == nil ? Array(sheets.prefix(3)) : sheets
        for sheet in previewSheets {
            appendPreview(
                for: sheet,
                startRow: startRow,
                endRow: endRow,
                maxRows: maxRows,
                maxColumns: maxColumns,
                lines: &lines
            )
        }

        if sheetName == nil, sheets.count > previewSheets.count {
            lines.append("")
            lines.append(
                "... \(sheets.count - previewSheets.count) more sheet(s); pass sheet_name to focus the preview."
            )
        }

        return truncatePreview(lines.joined(separator: "\n"))
    }

    private static func appendPreview(
        for sheet: Workbook.Sheet,
        startRow: Int,
        endRow: Int,
        maxRows: Int,
        maxColumns: Int,
        lines: inout [String]
    ) {
        let rowsInRange = sheet.rows.filter { $0.number >= startRow && $0.number <= endRow }
        let visibleRows = Array(rowsInRange.prefix(maxRows))
        let cellCount = sheet.rows.reduce(0) { $0 + $1.cells.count }
        let formulaCount = sheet.rows.reduce(0) { rowTotal, row in
            rowTotal + row.cells.filter { $0.formula != nil }.count
        }
        let maxColumn = sheet.rows.flatMap(\.cells).map(\.columnNumber).max() ?? 0

        lines.append("Sheet \(sheet.index + 1): \(sheet.name)")
        lines.append(
            "Rows: \(sheet.rows.count), columns: \(maxColumn), cells: \(cellCount), formulas: \(formulaCount)"
        )
        if !sheet.mergedRanges.isEmpty {
            lines.append("Merged ranges: \(boundedList(sheet.mergedRanges.map(\.reference), limit: 12))")
        }

        guard !visibleRows.isEmpty else {
            lines.append("Preview: no rows in requested range \(startRow)-\(endRow).")
            lines.append("")
            return
        }

        lines.append("Preview rows \(visibleRows.first?.number ?? startRow)-\(visibleRows.last?.number ?? startRow):")
        for row in visibleRows {
            let cells = row.cells.sorted { $0.columnNumber < $1.columnNumber }
            let visibleCells = cells.prefix(maxColumns).map(formatCell)
            var line = "  row \(row.number): " + visibleCells.joined(separator: " | ")
            if cells.count > maxColumns {
                line += " | ... \(cells.count - maxColumns) more cell(s)"
            }
            lines.append(line)
        }
        if rowsInRange.count > visibleRows.count {
            lines.append("... \(rowsInRange.count - visibleRows.count) more row(s) in this range.")
        }
        lines.append("")
    }

    private static func selectedSheets(in workbook: Workbook, sheetName: String?) -> [Workbook.Sheet] {
        guard let sheetName else { return workbook.sheets }
        return workbook.sheets.filter { $0.name == sheetName }
    }

    private static func formatCell(_ cell: Workbook.Cell) -> String {
        var value = cell.value.fallbackText
        value = value.replacingOccurrences(of: "\n", with: "\\n")
        value = value.replacingOccurrences(of: "\t", with: " ")
        if value.isEmpty { value = "<empty>" }
        if let formula = cell.formula {
            return "\(cell.reference)=\(value) [=\(formula)]"
        }
        return "\(cell.reference)=\(value)"
    }

    private static func securityLine(for security: DocumentSecurityMetadata) -> String {
        var parts = ["inspection=\(security.inspectionStatus.rawValue)"]
        if !security.activeContentTypes.isEmpty {
            let active = security.activeContentTypes.map(\.rawValue).sorted().joined(separator: ",")
            parts.append("active=\(active)")
        }
        if let maximumSeverity = security.maximumSeverity {
            parts.append("max_severity=\(maximumSeverity.rawValue)")
        }

        let notableFindings = security.findings
            .filter { $0.kind != .unsupportedFeature || $0.severity > .informational }
            .prefix(3)
            .map { finding in
                if let count = finding.metadata["count"] {
                    return "\(finding.kind.rawValue)(\(count))"
                }
                return finding.kind.rawValue
            }
        if !notableFindings.isEmpty {
            parts.append("findings=\(notableFindings.joined(separator: ","))")
        }
        return "Security: " + parts.joined(separator: "; ")
    }

    private static func boundedList(_ values: [String], limit: Int) -> String {
        guard !values.isEmpty else { return "(none)" }
        let prefix = values.prefix(limit).joined(separator: ", ")
        if values.count > limit {
            return prefix + ", ... \(values.count - limit) more"
        }
        return prefix
    }

    private static func truncatePreview(_ text: String) -> String {
        guard text.count > maxOutputChars else { return text }
        return String(text.prefix(maxOutputChars)) + "\n... (truncated workbook preview)"
    }

    private static func clamped(_ value: Int?, fallback: Int, lower: Int, upper: Int) -> Int {
        min(max(value ?? fallback, lower), upper)
    }
}

// MARK: File Write Tool

struct FileWriteTool: OsaurusTool, PermissionedTool {
    let name = "file_write"
    let description =
        "Create a new UTF-8 text file or overwrite an existing text file with the provided content. "
        + "Parent directories are created automatically. You MUST provide the file contents in the "
        + "`content` parameter. Pass `dry_run: true` to preview the diff and risk warnings without "
        + "writing. Not for structured `.xlsx` / `.pdf` / `.pptx` outputs — write text formats such "
        + "as CSV/TSV/Markdown instead. "
        + "Example: {\"path\": \"notes/summary.md\", \"content\": \"# Summary\\n...\"}"
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path for the file"),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string(
                    "Content to write to the file"
                ),
            ]),
            "dry_run": .object([
                "type": .string("boolean"),
                "description": .string(
                    "Preview the write, diff, and risk warnings without modifying the filesystem (default: false)"
                ),
            ]),
        ]),
        "required": .array([.string("path"), .string("content")]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "relative path under the working folder (e.g. `src/app.py`)",
            tool: name
        )
        guard case .value(let relativePath) = pathReq else {
            return pathReq.failureEnvelope ?? ""
        }

        // `content: ""` is legitimate (truncate-to-zero), so allow empty.
        let contentReq = requireString(
            args,
            "content",
            expected: "string of file contents (use `\"\"` for an empty file)",
            tool: name,
            allowEmpty: true
        )
        guard case .value(let content) = contentReq else {
            return contentReq.failureEnvelope ?? ""
        }
        let dryRun = coerceBool(args["dry_run"]) ?? false

        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        if let rejected = WorkspaceWriteSafety.structuredTextWriteRejection(
            path: relativePath,
            fileExtension: fileURL.pathExtension.lowercased(),
            toolName: name
        ) {
            return rejected
        }

        let previousContent: String?
        switch WorkspaceWriteSafety.existingText(
            at: fileURL,
            relativePath: relativePath,
            toolName: name
        ) {
        case .success(let content):
            previousContent = content
        case .failureEnvelope(let envelope):
            return envelope
        }

        let parentDir = fileURL.deletingLastPathComponent()
        let createsParentDirectories = !FileManager.default.fileExists(atPath: parentDir.path)
        var preview = WorkspaceWriteSafety.preview(
            path: relativePath,
            previousContent: previousContent,
            proposedContent: content,
            operation: name,
            dryRun: dryRun,
            createsParentDirectories: createsParentDirectories,
            fileURL: fileURL
        )
        if dryRun {
            return ToolEnvelope.success(
                tool: name,
                result: preview.payload,
                warnings: preview.warnings
            )
        }

        // Create parent directories if needed
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Write content
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        if let sessionId = ChatExecutionContext.currentSessionId {
            let operation = FileOperation(
                type: previousContent == nil ? .create : .write,
                path: relativePath,
                previousContent: previousContent,
                sessionId: sessionId,
                batchId: ChatExecutionContext.currentBatchId
            )
            await FileOperationLog.shared.log(operation)
            preview.payload["operation_id"] = operation.id.uuidString
        }
        return ToolEnvelope.success(
            tool: name,
            result: preview.payload,
            warnings: preview.warnings
        )
    }
}

// MARK: - Coding Tools
//
// `file_move`, `file_copy`, `file_delete`, `dir_create` were dropped in
// favour of `shell_run` (`mv`, `cp`, `rm`, `mkdir`) so the model has one
// tool to learn for filesystem mutations rather than four. Removal also
// trims the schema by ~1KB tokens per turn.

// MARK: File Edit Tool

struct FileEditTool: OsaurusTool, PermissionedTool {
    let name = "file_edit"
    let description =
        "Edit a file by replacing specific text. `old_string` must uniquely match exactly one "
        + "location in the file — include surrounding context lines if needed to ensure uniqueness. "
        + "Copy the RAW file text only: never include the `N|` line-number prefixes shown in "
        + "`file_read` output. Fails if `old_string` is not found or matches multiple locations. "
        + "Pass `dry_run: true` to preview the diff without modifying the file. "
        + "Example: {\"path\": \"config.py\", \"old_string\": \"debug = True\", \"new_string\": \"debug = False\"}"
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path to the file"),
            ]),
            "old_string": .object([
                "type": .string("string"),
                "description": .string(
                    "The exact text to find and replace (must uniquely match one location in the file)"
                ),
            ]),
            "new_string": .object([
                "type": .string("string"),
                "description": .string(
                    "The replacement text"
                ),
            ]),
            "dry_run": .object([
                "type": .string("boolean"),
                "description": .string(
                    "Preview the edit and diff without modifying the filesystem (default: false)"
                ),
            ]),
        ]),
        "required": .array([.string("path"), .string("old_string"), .string("new_string")]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "relative path under the working folder (e.g. `src/app.py`)",
            tool: name
        )
        guard case .value(let relativePath) = pathReq else {
            return pathReq.failureEnvelope ?? ""
        }

        // Empty `old_string` is ambiguous — `requireString` (default
        // `allowEmpty: false`) rejects it with a pointed envelope that
        // matches the sandbox in-place edit (`sandbox_write_file`).
        let oldReq = requireString(
            args,
            "old_string",
            expected: "non-empty exact text that uniquely matches one location in the file",
            tool: name
        )
        guard case .value(let oldString) = oldReq else {
            return oldReq.failureEnvelope ?? ""
        }

        // Empty `new_string` is the supported delete-the-match form.
        let newReq = requireString(
            args,
            "new_string",
            expected: "replacement text (use `\"\"` to delete the match)",
            tool: name,
            allowEmpty: true
        )
        guard case .value(let newString) = newReq else {
            return newReq.failureEnvelope ?? ""
        }
        let dryRun = coerceBool(args["dry_run"]) ?? false

        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        if let rejected = WorkspaceWriteSafety.structuredTextWriteRejection(
            path: relativePath,
            fileExtension: fileURL.pathExtension.lowercased(),
            toolName: name
        ) {
            return rejected
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FolderToolError.fileNotFound(relativePath)
        }

        // Capture pre-edit contents for the operation log (undo support).
        let originalContent: String
        switch WorkspaceWriteSafety.existingText(
            at: fileURL,
            relativePath: relativePath,
            toolName: name
        ) {
        case .success(let content):
            originalContent = content ?? ""
        case .failureEnvelope(let envelope):
            return envelope
        }
        var content = originalContent

        guard let range = content.range(of: oldString) else {
            let diagnosis = Self.noMatchDiagnosis(oldString: oldString, content: content)
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Could not find `old_string` in \(relativePath). \(diagnosis)",
                field: "old_string",
                expected: "exact non-empty text present once in the target file",
                tool: name
            )
        }

        let matches = content.ranges(of: oldString)
        if matches.count > 1 {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Found \(matches.count) matches for `old_string` in \(relativePath); include more surrounding context to identify one location.",
                field: "old_string",
                expected: "exact text that matches exactly one location",
                tool: name
            )
        }

        content.replaceSubrange(range, with: newString)
        var preview = WorkspaceWriteSafety.preview(
            path: relativePath,
            previousContent: originalContent,
            proposedContent: content,
            operation: name,
            dryRun: dryRun,
            createsParentDirectories: false,
            fileURL: fileURL
        )
        if dryRun {
            return ToolEnvelope.success(
                tool: name,
                result: preview.payload,
                warnings: preview.warnings
            )
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Log for undo parity with `file_write`. Skipped when no session.
        if let sid = ChatExecutionContext.currentSessionId {
            let operation = FileOperation(
                type: .fileEdit,
                path: relativePath,
                previousContent: originalContent,
                sessionId: sid,
                batchId: ChatExecutionContext.currentBatchId
            )
            await FileOperationLog.shared.log(operation)
            preview.payload["operation_id"] = operation.id.uuidString
        }

        return ToolEnvelope.success(
            tool: name,
            result: preview.payload,
            warnings: preview.warnings
        )
    }

    /// Truthful diagnosis for a 0-match `old_string`, computed against the
    /// already-loaded file content. The generic "make sure it matches"
    /// message left models re-issuing the identical failing call (observed
    /// live: grok-4.3 copied the leading space from `file_read`'s `N| `
    /// line-number formatting into `old_string` and repeated the same edit
    /// until the iteration cap). Three checks, cheapest signal first:
    ///   1. `N|` line-number prefixes pasted from `file_read` output.
    ///   2. A whitespace-only mismatch — the trimmed lines match a unique
    ///      region of the file; quote the exact file bytes to copy.
    ///   3. A closest-line anchor — quote the real file line most similar
    ///      to the first non-empty `old_string` line.
    /// All hints quote VERBATIM file content (never invented text), so the
    /// recovery path stays honest.
    static func noMatchDiagnosis(oldString: String, content: String) -> String {
        let fallback = "Make sure it exactly matches the file content."
        let oldLines = oldString.components(separatedBy: "\n")

        // 1. Line-number prefix contamination (`   42|item 042 ...`).
        let prefixPattern = #"^\s*\d+\|"#
        if oldLines.contains(where: { $0.range(of: prefixPattern, options: .regularExpression) != nil }) {
            return "Your `old_string` contains `N|` line-number prefixes from file_read output — "
                + "those prefixes are display metadata, not file content. Copy the raw file text only."
        }

        let contentLines = content.components(separatedBy: "\n")
        let trimmedOldLines = oldLines.map { $0.trimmingCharacters(in: .whitespaces) }

        // 2. Whitespace-only mismatch: the trimmed old_string lines match a
        // unique consecutive run of trimmed file lines. Quote the exact
        // file bytes for that region so the model can copy them verbatim.
        if !trimmedOldLines.allSatisfy({ $0.isEmpty }), trimmedOldLines.count <= contentLines.count {
            let trimmedContentLines = contentLines.map { $0.trimmingCharacters(in: .whitespaces) }
            var matchStarts: [Int] = []
            for start in 0 ... (trimmedContentLines.count - trimmedOldLines.count) {
                if Array(trimmedContentLines[start ..< start + trimmedOldLines.count]) == trimmedOldLines {
                    matchStarts.append(start)
                    if matchStarts.count > 1 { break }
                }
            }
            if matchStarts.count == 1, let start = matchStarts.first {
                let exact = contentLines[start ..< start + trimmedOldLines.count]
                    .joined(separator: "\n")
                return "Found text differing only in whitespace at line \(start + 1). "
                    + "The exact file content there is:\n\(Self.boundedQuote(exact))\n"
                    + "Use that exact text (including its whitespace) as `old_string`."
            }
        }

        // 2b. Blank-line-count drift: same as check 2 but comparing only the
        // NON-empty trimmed lines. Models routinely collapse a `\n\n\n` run
        // to `\n\n` (observed live: a model normalized two blank lines
        // between functions to one and re-issued the identical failing edit
        // until its budget ran out, because check 2 requires equal line
        // counts and check 3's single-line anchor was useless). On a unique
        // match, quote the true file region — including its real blank
        // lines — verbatim.
        let oldNonEmpty = trimmedOldLines.filter { !$0.isEmpty }
        if oldNonEmpty.count >= 2 {
            // Indices of non-empty file lines, in file order.
            var fileNonEmpty: [(index: Int, text: String)] = []
            for (index, line) in contentLines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { fileNonEmpty.append((index, trimmed)) }
            }
            if oldNonEmpty.count <= fileNonEmpty.count {
                var matchStarts: [Int] = []
                for start in 0 ... (fileNonEmpty.count - oldNonEmpty.count) {
                    var all = true
                    for offset in 0 ..< oldNonEmpty.count
                    where fileNonEmpty[start + offset].text != oldNonEmpty[offset] {
                        all = false
                        break
                    }
                    if all {
                        matchStarts.append(start)
                        if matchStarts.count > 1 { break }
                    }
                }
                if matchStarts.count == 1, let start = matchStarts.first {
                    let firstLine = fileNonEmpty[start].index
                    let lastLine = fileNonEmpty[start + oldNonEmpty.count - 1].index
                    let exact = contentLines[firstLine ... lastLine].joined(separator: "\n")
                    return "Found the same non-blank lines at line \(firstLine + 1), but the "
                        + "blank lines between them differ from your `old_string`. The exact "
                        + "file content there is:\n\(Self.boundedQuote(exact))\n"
                        + "Use that exact text (including its blank lines) as `old_string`."
                }
            }
        }

        // 3. Closest-line anchor: score every file line against the first
        // non-empty trimmed old_string line (containment either way, or
        // shared prefix — cheap but catches the common "the line changed
        // after the model last read it" case) and quote the best one when
        // it is similar enough to be a plausible anchor.
        if let needle = trimmedOldLines.first(where: { !$0.isEmpty }), needle.count >= 4 {
            let needleLower = needle.lowercased()
            var best: (index: Int, line: String, score: Int)?
            for (index, line) in contentLines.enumerated() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty else { continue }
                let lineLower = trimmedLine.lowercased()
                let score: Int
                if lineLower.contains(needleLower) || needleLower.contains(lineLower) {
                    score = min(needle.count, trimmedLine.count)
                } else {
                    score = zip(needleLower, lineLower).prefix(while: { $0 == $1 }).count
                }
                if score > (best?.score ?? 0) { best = (index, line, score) }
            }
            let minScore = max(4, needle.count / 2)
            if let best, best.score >= minScore {
                return "The closest matching line in the file is line \(best.index + 1):\n"
                    + "\(Self.boundedQuote(best.line))\n"
                    + "Compare it against your `old_string` — they differ. \(fallback)"
            }
        }

        return fallback
    }

    /// Cap a quoted file excerpt so a pathological match can't inflate the
    /// error envelope. Quotes are verbatim up to the cap.
    private static func boundedQuote(_ text: String, cap: Int = 600) -> String {
        guard text.count > cap else { return text }
        return String(text.prefix(cap)) + "… (excerpt truncated)"
    }
}

// MARK: File Operation History Tool

struct FileOperationHistoryTool: OsaurusTool {
    let name = "file_operation_history"
    let description =
        "Show recent file writes/edits made by this chat session. Use this before undo/review "
        + "or after multi-file work to inspect what changed. Optional `path` filters to one file."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Optional relative file path to filter history"),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Maximum entries to return (default: 20, max: 100)"),
            ]),
        ]),
        "required": .array([]),
    ])

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let sessionId = ChatExecutionContext.currentSessionId, !sessionId.isEmpty else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "`file_operation_history` requires an active chat session.",
                tool: name,
                retryable: false
            )
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let rawPath = args["path"] as? String
        let pathFilter: String?
        if let rawPath {
            let resolvedURL = try FolderToolHelpers.resolvePath(rawPath, rootPath: rootPath)
            pathFilter = Self.relativePath(for: resolvedURL, rootPath: rootPath)
        } else {
            pathFilter = nil
        }

        let limit = min(max(coerceInt(args["limit"]) ?? 20, 1), 100)
        let operations = await FileOperationLog.shared.operations(for: sessionId)
        let filtered =
            pathFilter.map { path in
                operations.filter { $0.path == path || $0.destinationPath == path }
            } ?? operations
        let recent = Array(filtered.suffix(limit).reversed())
        let entries = recent.map(WorkspaceWriteSafety.operationHistoryEntry)
        var payload: [String: Any] = [
            "kind": "file_operation_history",
            "session_id": sessionId,
            "entries": entries,
            "operation_count": filtered.count,
            "returned_count": entries.count,
            "limit": limit,
        ]
        if let pathFilter {
            payload["path"] = pathFilter
        }

        let warnings =
            filtered.count > limit
            ? ["History truncated to the \(limit) most recent matching operations."]
            : nil
        return ToolEnvelope.success(tool: name, result: payload, warnings: warnings)
    }

    fileprivate static func relativePath(for url: URL, rootPath: URL) -> String {
        FolderToolHelpers.displayPath(for: url, under: rootPath)
    }
}

// MARK: File Undo Tool

struct FileUndoTool: OsaurusTool, PermissionedTool {
    let name = "file_undo"
    let description =
        "Revert file operations made by this chat session. With no arguments it undoes the most "
        + "recent operation; pass `operation_id` (from `file_operation_history` or a write "
        + "result) to undo one specific operation, or `path` to revert every logged operation "
        + "on one file. If both are given, `operation_id` wins (path is checked against that "
        + "operation's file). Only operations whose history entry shows `can_undo: true` can "
        + "be reverted. Check `file_operation_history` first when unsure what would be undone."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "operation_id": .object([
                "type": .string("string"),
                "description": .string(
                    "ID of one specific operation to undo (from `file_operation_history`)"
                ),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Relative file path: undo ALL logged operations on this file, newest first"
                ),
            ]),
        ]),
        "required": .array([]),
    ])

    var requirements: [String] { [] }
    /// Mutates the working folder — same gate class as `file_write`.
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let sessionId = ChatExecutionContext.currentSessionId, !sessionId.isEmpty else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "`file_undo` requires an active chat session.",
                tool: name,
                retryable: false
            )
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let operationIdRaw = (args["operation_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPath = (args["path"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let undone: [FileOperation]
            if let operationIdRaw, !operationIdRaw.isEmpty {
                guard let operationId = UUID(uuidString: operationIdRaw) else {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "`operation_id` is not a valid operation ID.",
                        field: "operation_id",
                        expected: "UUID from `file_operation_history`",
                        tool: name
                    )
                }
                // Both args together are fine when they AGREE — models
                // routinely echo the path alongside the id (observed live:
                // gemma-4-12B sent `{"operation_id": …, "path":
                // "CHANGELOG.md"}`, got the old "not both" rejection, and
                // spiralled into a blind rewrite instead of the undo).
                // Only an actual DISAGREEMENT is ambiguous and refused.
                if let rawPath, !rawPath.isEmpty {
                    let target = try? FolderToolHelpers.resolvePath(rawPath, rootPath: rootPath)
                    let relative = target.map {
                        FileOperationHistoryTool.relativePath(for: $0, rootPath: rootPath)
                    }
                    let op = await FileOperationLog.shared
                        .operations(for: sessionId)
                        .first(where: { $0.id == operationId })
                    if let op, let relative, op.path != relative, op.destinationPath != relative {
                        return ToolEnvelope.failure(
                            kind: .invalidArgs,
                            message:
                                "`operation_id` \(operationIdRaw) is an operation on "
                                + "`\(op.path)`, not `\(relative)`. Pass just the "
                                + "`operation_id`, or just `path` to undo all "
                                + "operations on that file.",
                            field: "path",
                            expected: "arguments that refer to the same file",
                            tool: name
                        )
                    }
                }
                let op = try await FileOperationLog.shared.undo(
                    sessionId: sessionId,
                    operationId: operationId
                )
                undone = op.map { [$0] } ?? []
            } else if let rawPath, !rawPath.isEmpty {
                let resolvedURL = try FolderToolHelpers.resolvePath(rawPath, rootPath: rootPath)
                let relative = FileOperationHistoryTool.relativePath(
                    for: resolvedURL,
                    rootPath: rootPath
                )
                undone = try await FileOperationLog.shared.undoFile(
                    sessionId: sessionId,
                    path: relative
                )
                if undone.isEmpty {
                    return ToolEnvelope.failure(
                        kind: .notFound,
                        message:
                            "No logged operations found for `\(relative)` in this session — nothing to undo.",
                        field: "path",
                        tool: name
                    )
                }
            } else {
                let op = try await FileOperationLog.shared.undoLast(sessionId: sessionId)
                guard let op else {
                    return ToolEnvelope.failure(
                        kind: .notFound,
                        message: "No logged file operations in this session — nothing to undo.",
                        tool: name
                    )
                }
                undone = [op]
            }
            let entries = undone.map(WorkspaceWriteSafety.operationHistoryEntry)
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "kind": "file_undo",
                    "undone_count": undone.count,
                    "undone": entries,
                ] as [String: Any]
            )
        } catch let error as FileUndoError {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: error.localizedDescription,
                tool: name
            )
        }
    }
}

// MARK: File Search Tool

struct FileSearchTool: OsaurusTool {
    let name = "file_search"
    let description =
        "Search files in the working directory. With `target=\"content\"` (default) it finds text by "
        + "case-insensitive substring match, returning matching lines with file paths and line numbers. "
        + "With `target=\"files\"` it finds files by name (case-insensitive substring, e.g. `q4` matches "
        + "`q4_sales_report.xlsx`; use `*`/`?` for a glob like `*.swift`). "
        + "Example: {\"pattern\": \"TODO\", \"path\": \"src\", \"file_pattern\": \"*.py\"}"
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "pattern": .object([
                "type": .string("string"),
                "description": .string(
                    "When `target=\"content\"`: text to find (case-insensitive substring). "
                        + "When `target=\"files\"`: filename to find (case-insensitive substring, e.g. "
                        + "`q4`; use `*`/`?` for a glob like `*.swift`, `test_*`)."
                ),
            ]),
            "target": .object([
                "type": .string("string"),
                "enum": .array([.string("content"), .string("files")]),
                "description": .string(
                    "`content` searches inside file bodies; `files` finds files by name. Default: `content`."
                ),
                "default": .string("content"),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional directory or file path to search in (default: entire working directory)"
                ),
            ]),
            "file_pattern": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional file name pattern to restrict a content search (e.g., '*.swift'). "
                        + "Ignored when `target=\"files\"` — use `pattern` directly."
                ),
            ]),
            "max_results": .object([
                "type": .string("integer"),
                "description": .string("Maximum number of results to return (default: 50)"),
            ]),
        ]),
        "required": .array([.string("pattern")]),
    ])

    private let rootPath: URL
    /// Entries pulled from the enumerator before a search stops and reports
    /// truncation. Defaults to the shared budget; injectable so tests can
    /// exercise the bound without creating tens of thousands of files.
    private let maxEntriesVisited: Int

    init(rootPath: URL, maxEntriesVisited: Int = FolderToolHelpers.maxSearchEntriesVisited) {
        self.rootPath = rootPath
        self.maxEntriesVisited = maxEntriesVisited
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let patternReq = requireString(
            args,
            "pattern",
            expected: "search text (case-insensitive substring, e.g. `TODO`)",
            tool: name
        )
        guard case .value(let pattern) = patternReq else {
            return patternReq.failureEnvelope ?? ""
        }

        let searchPath = (args["path"] as? String) ?? "."
        let filePattern = args["file_pattern"] as? String
        // Clamp to the shared ceiling — an unclamped `max_results: 100000`
        // over a big tree is a one-call context bomb.
        let maxResults = min(max(coerceInt(args["max_results"]) ?? 50, 1), ToolOutputCaps.searchMaxResults)
        let target = (args["target"] as? String)?.lowercased() ?? "content"

        // Combined mode: an absolute `/workspace/...` path is the Linux
        // sandbox — search it via the sandbox bridge (content or files).
        if combinedFileRoute(path: searchPath) == .sandbox,
            let bridge = ChatExecutionContext.sandboxReadBridge
        {
            return try await sandboxBridgeSearch(
                bridge,
                pattern: pattern,
                path: searchPath,
                target: target,
                filePattern: filePattern,
                maxResults: maxResults
            )
        }

        let searchURL = try FolderToolHelpers.resolvePath(searchPath, rootPath: rootPath)

        // `target="files"`: filename find (no content read). Mirrors
        // `sandbox_search_files(target:"files")` so the unified family can
        // locate files by name on either filesystem. The tool does the
        // deterministic search mechanics (broaden-on-empty) and returns ALL
        // candidates as structured `entries[]`; which match satisfies the
        // request is the model's judgement, never auto-picked here.
        if target == "files" {
            let found = try searchFilesByName(root: searchURL, query: pattern, maxResults: maxResults)
            return filesSearchEnvelope(originalQuery: pattern, found: found)
        }

        var results: [String] = []
        var totalMatches = 0
        // Files the search never looked inside (binary extension, over the
        // size cap, or undecodable). Counted so "No matches" can't silently
        // mean "the file you care about was skipped".
        var skippedFiles = 0

        // Determine if searching a file or directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchURL.path, isDirectory: &isDirectory)
        else {
            throw FolderToolError.fileNotFound(searchPath)
        }

        // Combined-mode secret denylist (shared with `file_read`). A
        // single-file search targeting a secret (`path:".env"`) would
        // otherwise leak its contents line-by-line and bypass both the
        // `file_read` refusal and the directory hidden-file filter, so
        // refuse it outright. Directory searches skip secret files
        // per-entry below instead of failing the whole call.
        if !isDirectory.boolValue, FolderToolHelpers.shouldRefuseSecret(fileURL: searchURL) {
            return FolderToolHelpers.secretRefusalEnvelope(relativePath: searchPath, tool: name)
        }

        var budgetTruncated = false

        if isDirectory.boolValue {
            // Search directory recursively
            let enumerator = FileManager.default.enumerator(
                at: searchURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var visited = 0
            while let fileURL = enumerator?.nextObject() as? URL {
                guard totalMatches < maxResults else { break }
                guard
                    try FolderToolHelpers.searchStepWithinBudget(
                        visited: &visited,
                        limit: maxEntriesVisited
                    )
                else {
                    budgetTruncated = true
                    break
                }

                let resourceValues = try? fileURL.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey,
                ])
                if FolderToolHelpers.pruneSearchDirectory(
                    fileURL,
                    isDirectory: resourceValues?.isDirectory == true,
                    enumerator: enumerator
                ) {
                    continue
                }
                guard resourceValues?.isRegularFile == true else { continue }

                // Combined-mode secret denylist: never return contents of
                // a non-hidden secret (`server.pem`, `id_rsa`, …). `.env`
                // and other dotfiles are already excluded by
                // `.skipsHiddenFiles`; this catches the rest.
                if FolderToolHelpers.shouldRefuseSecret(fileURL: fileURL) {
                    continue
                }

                // Check file pattern (proper glob → regex conversion: all
                // metacharacters escaped, so `*.+(test)*` can't silently
                // become a regex that matches nothing).
                if let pattern = filePattern {
                    let regex = FolderToolHelpers.globToRegex(pattern)
                    if fileURL.lastPathComponent.range(of: regex, options: .regularExpression)
                        == nil
                    {
                        continue
                    }
                }

                // Search file
                switch searchFile(fileURL, pattern: pattern, maxResults: maxResults - totalMatches) {
                case .matches(let matches):
                    results.append(contentsOf: matches)
                    totalMatches += matches.count
                case .skipped:
                    skippedFiles += 1
                }
            }
        } else {
            // Search single file
            switch searchFile(searchURL, pattern: pattern, maxResults: maxResults) {
            case .matches(let matches):
                results.append(contentsOf: matches)
                totalMatches = matches.count
            case .skipped:
                skippedFiles += 1
            }
        }

        if results.isEmpty {
            // Mode correction (deterministic, no NL parsing): a content search
            // that finds nothing is the classic "wanted files, grepped bodies"
            // mistake. Run the files-mode search; if it finds candidates,
            // return them so the reasonable-but-wrong `target` succeeds at the
            // model's actual intent. Only fires on empty content, so it never
            // overrides a real content hit.
            let fallback = try searchFilesByName(root: searchURL, query: pattern, maxResults: maxResults)
            if !fallback.entries.isEmpty {
                let note =
                    "(no content matches for '\(pattern)'; showing files named like '\(fallback.matchedQuery)')"
                return ToolEnvelope.search(
                    tool: name,
                    query: fallback.matchedQuery,
                    entries: fallback.entries,
                    truncated: fallback.truncated,
                    warnings: fallback.truncated ? [note, Self.searchBudgetWarning] : [note]
                )
            }
            let skippedNote = Self.skippedFilesNote(skippedFiles)
            var base = "No matches found for '\(pattern)'"
            if let skippedNote { base += "\n\n(\(skippedNote))" }
            if budgetTruncated { base += Self.budgetTruncationNote }
            var warnings: [String] = []
            if let skippedNote { warnings.append(skippedNote) }
            if budgetTruncated { warnings.append(Self.searchBudgetWarning) }
            return ToolEnvelope.success(
                tool: name,
                text: base,
                warnings: warnings.isEmpty ? nil : warnings
            )
        }

        var output = "Found \(totalMatches) match(es):\n\n"
        var body = results.joined(separator: "\n")

        // Character backstop independent of the result-count clamp: a few
        // hundred very long matched lines can outweigh the count limit.
        var charTruncated = false
        if body.count > ToolOutputCaps.fileSearch {
            body = String(body.prefix(ToolOutputCaps.fileSearch))
            charTruncated = true
        }
        output += body

        // Truncation/skip state is ALSO carried as structured `warnings` on
        // the envelope (mirroring files-mode `ToolEnvelope.search`), so the
        // harness and scorers can branch on it without parsing prose.
        var warnings: [String] = []
        if charTruncated {
            let note =
                "Output truncated at \(ToolOutputCaps.fileSearch) chars; narrow the `path`, "
                + "tighten the pattern, or add a `file_pattern` filter."
            output += "\n\n(\(note))"
            warnings.append(note)
        } else if totalMatches >= maxResults {
            let note = "Results truncated at \(maxResults)."
            output += "\n\n(\(note))"
            warnings.append(note)
        } else if budgetTruncated {
            output += Self.budgetTruncationNote
            warnings.append(Self.searchBudgetWarning)
        }
        if let skippedNote = Self.skippedFilesNote(skippedFiles) {
            output += "\n\n(\(skippedNote))"
            warnings.append(skippedNote)
        }

        return ToolEnvelope.success(
            tool: name,
            text: output,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }

    /// Human/structured note for files the content search never read.
    /// Returns nil when nothing was skipped.
    private static func skippedFilesNote(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let mb = FolderToolHelpers.maxContentSearchFileBytes / (1024 * 1024)
        return
            "\(count) file(s) skipped (binary or >\(mb)MB) — their contents were not searched."
    }

    /// Appended when a search stops at `maxEntriesVisited` rather than from
    /// running out of matches, so the model knows the result is incomplete
    /// because the tree was too large — and what to do about it.
    private static let budgetTruncationNote =
        "\n\n(search stopped after scanning the entry limit; narrow the `path` "
        + "or use a more specific pattern)"

    /// One files-mode search pass: collect basename matches under `root`
    /// (recursive, hidden + secret files skipped, build-artifact dirs pruned)
    /// as structured `{name, path, type}` entries. A bare pattern is a
    /// case-insensitive substring of the basename; a pattern with `*`/`?` is a
    /// case-insensitive glob anchored to the full basename. Mirrors the
    /// sandbox `find … -iname` behaviour. `truncated` is true when the walk
    /// stopped at the visit budget rather than from running out of matches.
    private func collectFileMatches(root: URL, glob: String, maxResults: Int) throws
        -> (entries: [[String: Any]], truncated: Bool)
    {
        let regexBody =
            NSRegularExpression.escapedPattern(for: glob)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        let regex =
            FolderToolHelpers.patternHasGlobMetacharacters(glob) ? "^\(regexBody)$" : regexBody

        var entries: [[String: Any]] = []
        var budgetTruncated = false
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var visited = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            guard entries.count < maxResults else { break }
            guard
                try FolderToolHelpers.searchStepWithinBudget(
                    visited: &visited,
                    limit: maxEntriesVisited
                )
            else {
                budgetTruncated = true
                break
            }
            let resourceValues = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey,
            ])
            if FolderToolHelpers.pruneSearchDirectory(
                fileURL,
                isDirectory: resourceValues?.isDirectory == true,
                enumerator: enumerator
            ) {
                continue
            }
            guard resourceValues?.isRegularFile == true else { continue }
            if FolderToolHelpers.shouldRefuseSecret(fileURL: fileURL) { continue }
            let entryName = fileURL.lastPathComponent
            let relativePath = FolderToolHelpers.displayPath(for: fileURL, under: rootPath)
            // A query carrying a path separator ("orders/", "src/main.py")
            // can never match a basename — match it against the relative
            // path instead (observed live: a model searched the perfectly
            // reasonable "orders/", got zero hits for three existing files,
            // and asked the user instead of finishing the task).
            let haystack = glob.contains("/") ? relativePath : entryName
            guard haystack.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
            else { continue }
            entries.append(["name": entryName, "path": relativePath, "type": "file"])
        }
        return (entries, budgetTruncated)
    }

    /// The result of a files-mode search after any broadening: the candidate
    /// entries, the query actually matched (post-broaden), whether the walk
    /// hit the visit budget, and an optional human note describing broadening.
    private struct FileSearchOutcome {
        let entries: [[String: Any]]
        let matchedQuery: String
        let truncated: Bool
        let note: String?
    }

    /// Files-mode search with bounded broaden-on-empty. Runs the query as
    /// given; if it finds nothing AND the query has multiple tokens, retries
    /// with the longest token, then the next-longest — at most 2 retries —
    /// returning the first non-empty candidate set. The tokenizer is dumb on
    /// purpose (length-sorted alphanumeric tokens); no natural-language
    /// cleverness. Never decides which match the user meant.
    private func searchFilesByName(root: URL, query: String, maxResults: Int) throws
        -> FileSearchOutcome
    {
        let first = try collectFileMatches(root: root, glob: query, maxResults: maxResults)
        let empty = FileSearchOutcome(
            entries: [],
            matchedQuery: query,
            truncated: first.truncated,
            note: nil
        )
        if !first.entries.isEmpty {
            return FileSearchOutcome(
                entries: first.entries,
                matchedQuery: query,
                truncated: first.truncated,
                note: nil
            )
        }

        let tokens = Self.broadeningTokens(query)
        guard tokens.count > 1 else { return empty }
        for token in tokens.prefix(2) where token != query {
            let broadened = try collectFileMatches(root: root, glob: token, maxResults: maxResults)
            if !broadened.entries.isEmpty {
                return FileSearchOutcome(
                    entries: broadened.entries,
                    matchedQuery: token,
                    truncated: broadened.truncated,
                    note: "(no match for '\(query)'; broadened to '\(token)')"
                )
            }
        }
        return empty
    }

    /// Split a filename query into distinctive tokens for broaden-on-empty,
    /// longest first (the distinctive token is usually the longest). Splits on
    /// whitespace / `_` / `-` / `.` and drops tokens with no alphanumerics
    /// (so a bare `*` never becomes a broaden target).
    private static func broadeningTokens(_ query: String) -> [String] {
        let separators = CharacterSet(charactersIn: " \t\n_-.")
        return query.components(separatedBy: separators)
            .filter { token in token.contains(where: { $0.isLetter || $0.isNumber }) }
            .sorted { $0.count > $1.count }
    }

    /// Wrap a files-mode search outcome into a `kind:"search"` envelope. On a
    /// non-empty result the candidates are returned for the model to pick
    /// among; on empty (after any broadening) it returns no candidates plus a
    /// steer to list the parent directory or ask the user — the tool never
    /// guesses which file was meant.
    private func filesSearchEnvelope(originalQuery: String, found: FileSearchOutcome) -> String {
        if found.entries.isEmpty {
            let steer =
                "No files matched '\(originalQuery)'. List the parent directory with `file_read` "
                + "to see what's there, or ask the user which file they mean."
            return ToolEnvelope.search(
                tool: name,
                query: originalQuery,
                entries: [],
                truncated: found.truncated,
                warnings: found.truncated ? [steer, Self.searchBudgetWarning] : [steer]
            )
        }
        var warnings: [String] = []
        if let note = found.note { warnings.append(note) }
        if found.truncated { warnings.append(Self.searchBudgetWarning) }
        return ToolEnvelope.search(
            tool: name,
            query: found.matchedQuery,
            entries: found.entries,
            truncated: found.truncated,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }

    /// Warning-array form of `budgetTruncationNote` (no leading newlines) for
    /// the structured `search` envelope.
    private static let searchBudgetWarning =
        "Search stopped after scanning the entry limit; results may be incomplete — narrow the "
        + "`path` or use a more specific token."

    /// Outcome of attempting a content search of one file. `skipped` is
    /// distinct from "searched and found nothing" so the caller can COUNT
    /// skips — otherwise "No matches" silently lies about files that were
    /// never looked at.
    enum ContentSearchFileOutcome {
        /// File was searched; the array may be empty (no hits).
        case matches([String])
        /// File was never searched: binary extension, over the size cap,
        /// or not decodable as UTF-8.
        case skipped
    }

    private func searchFile(_ url: URL, pattern: String, maxResults: Int) -> ContentSearchFileOutcome {
        // Skip obvious binaries by extension and any file over the size cap
        // before loading it into memory; the UTF-8 decode below is the final
        // backstop for misnamed or unexpectedly-large text.
        if FolderToolHelpers.contentSearchSkippedExtensions.contains(
            url.pathExtension.lowercased()
        ) {
            return .skipped
        }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > FolderToolHelpers.maxContentSearchFileBytes
        {
            return .skipped
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return .skipped }

        let relativePath = FolderToolHelpers.displayPath(for: url, under: rootPath)

        let lines = content.components(separatedBy: .newlines)
        var matches: [String] = []

        for (index, line) in lines.enumerated() {
            guard matches.count < maxResults else { break }

            if line.localizedCaseInsensitiveContains(pattern) {
                let lineNum = index + 1
                matches.append("\(relativePath):\(lineNum): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        return .matches(matches)
    }
}

// MARK: Shell Run Tool

struct ShellRunTool: OsaurusTool, PermissionedTool {
    let name = "shell_run"
    let description =
        "Run a shell command in the working directory. **Reserve this for builds, tests, "
        + "git, processes, network calls, and filesystem mutations (`mv`/`cp`/`rm`/`mkdir`).** "
        + "For file IO, search, edit, write, and directory listing, prefer the dedicated "
        + "`file_*` tools. This action requires approval. Long-running commands stream their "
        + "output live to the chat and the user can press [Terminate] at any time. Output is "
        + "truncated to 10,000 characters (head + tail kept). No built-in timeout: pass "
        + "`timeout: <seconds>` (1-3600) ONLY if you want a hard idle ceiling (kill the "
        + "process if no output for N seconds). Avoid `2>/dev/null` in pipelines — pipefail "
        + "is on and suppressing stderr will trigger an empty-output warning."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "command": .object([
                "type": .string("string"),
                "description": .string("The shell command to execute"),
            ]),
            "timeout": .object([
                "type": .string("integer"),
                "description": .string(
                    "Optional idle timeout in seconds. Kills the process if it produces no "
                        + "output for this many seconds. Omit to run to completion (the user "
                        + "terminates from the chat card if needed)."
                ),
            ]),
        ]),
        "required": .array([.string("command")]),
    ])

    var requirements: [String] { ["permission:shell"] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    /// Streaming exec opts out of the registry's wall-clock cap. Long
    /// commands rely on the user's [Terminate] button + the optional
    /// `timeout` (idle ceiling) as the safety net.
    var bypassRegistryTimeout: Bool { true }

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let cmdReq = requireString(
            args,
            "command",
            expected: "shell command string (e.g. `ls -la`)",
            tool: name
        )
        guard case .value(let command) = cmdReq else {
            return cmdReq.failureEnvelope ?? ""
        }

        // Optional idle ceiling; nil = run forever (user terminates).
        // Clamped to 1...3600s — `0`/negative is treated as omitted (the
        // model almost certainly meant "no timeout", and an instant-kill
        // watchdog would terminate every command before its first byte),
        // and anything above an hour is capped. When the model passed no
        // timeout at all, a headless surface may supply a default via
        // `ChatExecutionContext.defaultShellIdleTimeout` (there is no
        // [Terminate] button on those surfaces).
        let requestedTimeout = Self.clampIdleTimeout(coerceInt(args["timeout"]))
        let idleTimeout: TimeInterval? =
            requestedTimeout ?? ChatExecutionContext.defaultShellIdleTimeout

        // Pre-exec undo planning: simple `mv`/`cp`/`rm`/`mkdir` forms are
        // captured into the same operation log as `file_write`/`file_edit`
        // (an `rm` target's content only exists BEFORE the command runs).
        // Unparseable mutation commands surface a "not in the undo log"
        // warning instead of a silent gap.
        let mutationPlan = ShellMutationLog.plan(command: command, rootPath: rootPath)

        // `set -o pipefail` wrapping so a real upstream pipeline
        // failure surfaces as the rightmost non-zero exit instead of
        // being masked by `head` / `tee` / `cat`. zsh honours pipefail
        // identically to bash.
        let prefixedCommand = "set -o pipefail; \(command)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", prefixedCommand]
        process.currentDirectoryURL = rootPath

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Live streaming wiring: incrementally read from both pipes,
        // appending to a per-stream buffer (for the model's final
        // result) AND broadcasting to a LiveExecSink (for the chat UI).
        // `lastActivity` powers the optional idle-timeout watchdog.
        let collector = ShellRunOutputCollector()
        let sink = LiveExecSink()

        installPipeReader(
            pipe: stdoutPipe,
            collector: collector,
            isStderr: false,
            sink: sink
        )
        installPipeReader(
            pipe: stderrPipe,
            collector: collector,
            isStderr: true,
            sink: sink
        )

        // Register the live entry BEFORE starting the process so the
        // chat card can mount its viewer immediately.
        let toolCallId = ChatExecutionContext.currentToolCallId ?? UUID().uuidString
        let processBox = ShellRunProcessBox(process: process)
        let terminate: @Sendable (Int) async -> Void = { graceSeconds in
            sink.requestTerminate()
            await processBox.terminateWithGrace(graceSeconds: graceSeconds)
        }

        await LiveExecRegistry.shared.register(
            LiveExecRegistry.Entry(
                toolCallId: toolCallId,
                pid: "",
                command: command,
                startedAt: Date(),
                outputPublisher: sink.outputPublisher,
                statusPublisher: sink.statusPublisher,
                currentStatus: { sink.currentStatus },
                seed: { await sink.bufferedSnapshot() },
                terminate: terminate
            )
        )

        // Idle-timeout watchdog. Only runs when `idleTimeout` is set;
        // resets implicitly on every chunk via `collector.lastActivity`.
        // A watchdog kill is flagged on the collector so the result
        // envelope can say WHY output stopped (`killed_by: idle_timeout`)
        // instead of looking like a spontaneous non-zero exit.
        let idleWatcher: Task<Void, Never>?
        if let idleTimeout {
            idleWatcher = Task.detached { @Sendable in
                let pollNanos: UInt64 = 1_000_000_000
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: pollNanos)
                    if Task.isCancelled { return }
                    let last = collector.lastActivity
                    if Date().timeIntervalSince(last) >= idleTimeout {
                        collector.markIdleKilled()
                        await processBox.terminate()
                        return
                    }
                }
            }
        } else {
            idleWatcher = nil
        }

        defer {
            idleWatcher?.cancel()
        }

        do {
            try await FolderToolHelpers.runProcessAsync(process)
        } catch {
            sink.markExited(code: -1)
            await LiveExecRegistry.shared.unregister(toolCallId: toolCallId)
            throw FolderToolError.operationFailed("Failed to execute command: \(error)")
        }

        // Drain anything buffered in the pipes after exit (the
        // readabilityHandlers stop firing once the process closes its
        // end). `availableData` returns the residual bytes.
        collector.appendDrain(
            stdoutData: stdoutPipe.fileHandleForReading.availableData,
            stderrData: stderrPipe.fileHandleForReading.availableData,
            sink: sink
        )

        // Stop the readabilityHandlers — Foundation leaves them wired
        // even after the process exits, which keeps the FileHandle
        // alive.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let exitCode = process.terminationStatus
        sink.markExited(code: exitCode)
        await LiveExecRegistry.shared.unregister(toolCallId: toolCallId)

        let (stdoutText, stderrText) = collector.snapshot()
        let trimmedStdout = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)

        var payload: [String: Any] = [
            "stdout": truncateOutput(trimmedStdout),
            "stderr": truncateOutput(trimmedStderr),
            "exit_code": Int(exitCode),
        ]
        if sink.terminationReason == .user {
            payload["killed_by"] = "user"
        } else if collector.wasIdleKilled, let idleTimeout {
            payload["killed_by"] = "idle_timeout"
            payload["idle_timeout_seconds"] = Int(idleTimeout)
        }
        var warnings = diagnosticWarnings(
            command: command,
            exitCode: exitCode,
            stdout: trimmedStdout,
            stderr: trimmedStderr
        )
        if payload["killed_by"] as? String == "idle_timeout", let idleTimeout {
            warnings.append(
                "Process was killed by the idle-timeout watchdog: no output for \(Int(idleTimeout))s. "
                    + "The command did not finish on its own — the output above is incomplete."
            )
        }

        // Undo-log bookkeeping for the mutation plan computed pre-exec.
        if exitCode == 0 {
            switch mutationPlan {
            case .none:
                break
            case .mutations(let planned):
                if let sessionId = ChatExecutionContext.currentSessionId, !sessionId.isEmpty {
                    var operationIds: [String] = []
                    for op in planned {
                        let operation = FileOperation(
                            type: op.type,
                            path: op.path,
                            destinationPath: op.destinationPath,
                            previousContent: op.previousContent,
                            sessionId: sessionId,
                            batchId: ChatExecutionContext.currentBatchId
                        )
                        await FileOperationLog.shared.log(operation)
                        operationIds.append(operation.id.uuidString)
                    }
                    payload["operation_ids"] = operationIds
                }
            case .unloggable:
                warnings.append(
                    "This command's filesystem changes were NOT captured in the undo log — `file_undo` cannot revert them."
                )
            }
        }

        return ToolEnvelope.success(
            tool: name,
            result: payload,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }

    /// Clamp the model-supplied idle timeout to 1...3600 seconds. `nil`,
    /// zero, and negative all mean "omitted" — zero/negative would
    /// otherwise arm a watchdog that kills the process before it can emit
    /// a single byte.
    static func clampIdleTimeout(_ raw: Int?) -> TimeInterval? {
        guard let raw, raw > 0 else { return nil }
        return TimeInterval(min(raw, 3600))
    }

    /// Install a `readabilityHandler` that streams every chunk into
    /// the collector AND the sink. Closes both sides cleanly on EOF
    /// so the FileHandle isn't leaked.
    ///
    /// Both sinks here are non-blocking and synchronous: `sink.write`
    /// just hits a PassthroughSubject; `collector.append` is a single
    /// lock-guarded Data append. We deliberately AVOID `Task { … }`
    /// per chunk — on a chatty pipe that fires the handler thousands
    /// of times a second the per-Task overhead dominates the actual
    /// work, swamping the cooperative thread pool and starving the
    /// process drain that actually frees the pipe.
    private func installPipeReader(
        pipe: Pipe,
        collector: ShellRunOutputCollector,
        isStderr: Bool,
        sink: LiveExecSink
    ) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            try? sink.write(chunk)
            collector.append(chunk, isStderr: isStderr)
        }
    }

    /// Tail-biased like `sandbox_exec`: for build/test output the failure
    /// summary the model needs lives at the end.
    private func truncateOutput(_ output: String) -> String {
        HeadTailTruncation.apply(
            output,
            cap: ToolOutputCaps.shellOutput,
            headFraction: 0.4,
            hint: "pipe through `grep`/`tail` or redirect to a file and use file_read to see the rest"
        )
    }
}

/// Per-call output collector for `ShellRunTool`. Splits the streaming
/// chunks back into stdout / stderr (the underlying `Pipe`s feed two
/// separate `readabilityHandler`s on Foundation's IO queue).
///
/// Was an `actor` originally, which serialised updates cleanly but
/// forced every `installPipeReader` callback to spawn a `Task` per
/// chunk. On a chatty pipe (think `cargo build` or `npm install`)
/// that's hundreds of Tasks per second — enough to swamp the
/// cooperative thread pool and starve the process drain. A plain
/// `NSLock` guards the same data with no scheduling overhead, and
/// every callsite is already short and non-blocking.
final class ShellRunOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuf = Data()
    private var stderrBuf = Data()
    private var _lastActivity = Date()
    private var _idleKilled = false

    var lastActivity: Date {
        lock.withLock { _lastActivity }
    }

    /// True when the idle-timeout watchdog terminated the process. Set by
    /// the watchdog task BEFORE it sends the terminate, read after exit to
    /// stamp `killed_by: "idle_timeout"` on the result envelope.
    var wasIdleKilled: Bool {
        lock.withLock { _idleKilled }
    }

    func markIdleKilled() {
        lock.withLock { _idleKilled = true }
    }

    func append(_ chunk: Data, isStderr: Bool) {
        lock.withLock {
            if isStderr {
                stderrBuf.append(chunk)
            } else {
                stdoutBuf.append(chunk)
            }
            _lastActivity = Date()
        }
    }

    /// Append the residual bytes drained from the pipes after process
    /// exit, also pushing them through the live sink so the chat card
    /// sees the final flush. `availableData` may return empty data on
    /// each pipe; we no-op in that case.
    func appendDrain(stdoutData: Data, stderrData: Data, sink: LiveExecSink) {
        lock.withLock {
            if !stdoutData.isEmpty {
                stdoutBuf.append(stdoutData)
                try? sink.write(stdoutData)
            }
            if !stderrData.isEmpty {
                stderrBuf.append(stderrData)
                try? sink.write(stderrData)
            }
        }
    }

    func snapshot() -> (stdout: String, stderr: String) {
        lock.withLock {
            (
                String(data: stdoutBuf, encoding: .utf8) ?? "",
                String(data: stderrBuf, encoding: .utf8) ?? ""
            )
        }
    }
}

/// Lightweight Sendable wrapper around the host `Process` so the
/// terminate closure (which crosses task boundaries) can signal it
/// without tripping strict-concurrency on `Process` itself.
private actor ShellRunProcessBox {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    /// Send SIGTERM only — used by the idle-timeout watchdog where the
    /// "graceful then kill" escalation is overkill.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()  // SIGTERM
    }

    /// SIGTERM → grace → SIGKILL. Mirrors `ProcessHandleBox` for
    /// `sandbox_exec` so terminate-from-the-chat-card behaves the
    /// same across both tools.
    func terminateWithGrace(graceSeconds: Int) async {
        guard process.isRunning else { return }
        process.terminate()  // SIGTERM
        if graceSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(graceSeconds) * 1_000_000_000)
        }
        guard process.isRunning else { return }
        // Foundation has no SIGKILL helper; fall back to the POSIX
        // syscall via the process identifier.
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}

// MARK: - Git Tools

// MARK: Git Status Tool

struct GitStatusTool: OsaurusTool {
    let name = "git_status"
    let description = "Show the current git status including branch name and uncommitted changes."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
        "required": .array([]),
    ])

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let (output, exitCode) = try await FolderToolHelpers.runGitCommand(
            arguments: ["status"],
            in: rootPath
        )

        if exitCode != 0 {
            throw FolderToolError.operationFailed("git status failed: \(output)")
        }

        return ToolEnvelope.success(
            tool: name,
            text: output.isEmpty ? "No changes" : output
        )
    }
}

// MARK: Git Diff Tool

struct GitDiffTool: OsaurusTool {
    let name = "git_diff"
    let description =
        "Show git diff for files. Can show staged changes, unstaged changes, or diff between commits."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Optional file path to diff (default: all files)"),
            ]),
            "staged": .object([
                "type": .string("boolean"),
                "description": .string("Show staged changes only (default: false)"),
            ]),
            "commit": .object([
                "type": .string("string"),
                "description": .string("Optional commit hash or range to diff against"),
            ]),
        ]),
        "required": .array([]),
    ])

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        // All three are optional; the preflight already drops empty-string
        // fillers (`path: ""`, `commit: ""`) so a plain `as? String` cleanly
        // yields nil when the model didn't intend to specify them.
        let filePath = args["path"] as? String
        let staged = coerceBool(args["staged"]) ?? false
        let commit = args["commit"] as? String

        // Validate `path` through the same resolver every other folder
        // tool uses. Previously the path went straight to `git diff --`,
        // which silently accepted absolute paths and `..`-style traversal.
        // The resolver throws `FolderToolError.invalidArguments` /
        // `pathOutsideRoot` so the model gets the standard message on a
        // bad path.
        if let filePath {
            _ = try FolderToolHelpers.resolvePath(filePath, rootPath: rootPath)
        }

        var arguments = ["diff"]
        if staged { arguments.append("--cached") }
        if let commit = commit { arguments.append(commit) }
        if let filePath = filePath { arguments.append(contentsOf: ["--", filePath]) }

        let (output, exitCode) = try await FolderToolHelpers.runGitCommand(
            arguments: arguments,
            in: rootPath
        )

        if exitCode != 0 {
            throw FolderToolError.operationFailed("git diff failed: \(output)")
        }

        // Head-biased: diffs are ordered by file, so the front carries
        // whole files while a prefix-only cut would silently drop the
        // trailing ones — keep both ends and say how to recover the middle.
        let truncated = HeadTailTruncation.apply(
            output,
            cap: ToolOutputCaps.gitDiff,
            headFraction: 0.6,
            hint: "re-run git_diff with `file_path` scoped to one file to see its full diff"
        )
        let text = truncated.isEmpty ? "No differences" : truncated
        return ToolEnvelope.success(tool: name, text: text)
    }
}

// MARK: Git Commit Tool

struct GitCommitTool: OsaurusTool, PermissionedTool {
    let name = "git_commit"
    let description =
        "Stage and commit changes to git. This action requires approval. Optionally specify files to stage, otherwise runs `git add -A` to stage all tracked and untracked changes."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "message": .object([
                "type": .string("string"),
                "description": .string("Commit message"),
            ]),
            "files": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("string")
                ]),
                "description": .string(
                    "Optional array of file paths to stage (default: all changes)"
                ),
            ]),
        ]),
        "required": .array([.string("message")]),
    ])

    var requirements: [String] { ["permission:git"] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let messageReq = requireString(
            args,
            "message",
            expected: "non-empty commit message",
            tool: name
        )
        guard case .value(let message) = messageReq else {
            return messageReq.failureEnvelope ?? ""
        }

        let files = coerceStringArray(args["files"])

        // Validate every staged path through the resolver — same security
        // boundary as the rest of the folder tools. `git add` would
        // otherwise silently accept absolutes / traversal.
        if let files {
            for file in files {
                _ = try FolderToolHelpers.resolvePath(file, rootPath: rootPath)
            }
        }

        // Stage files
        let stageArgs = (files != nil && !files!.isEmpty) ? ["add"] + files! : ["add", "-A"]
        let (stageOutput, stageExitCode) = try await FolderToolHelpers.runGitCommand(
            arguments: stageArgs,
            in: rootPath
        )

        if stageExitCode != 0 {
            throw FolderToolError.operationFailed("git add failed: \(stageOutput)")
        }

        // Commit
        let (commitOutput, commitExitCode) = try await FolderToolHelpers.runGitCommand(
            arguments: ["commit", "-m", message],
            in: rootPath
        )

        if commitExitCode != 0 {
            if commitOutput.contains("nothing to commit") {
                return ToolEnvelope.success(tool: name, text: "Nothing to commit")
            }
            throw FolderToolError.operationFailed("git commit failed: \(commitOutput)")
        }

        return ToolEnvelope.success(
            tool: name,
            text: "Committed successfully:\n\(commitOutput)"
        )
    }
}

// MARK: - Tool Factory

/// Factory for creating folder tool instances
enum FolderToolFactory {
    /// Build all core file tools. `share_artifact` is NOT here — it's a
    /// global built-in (registered in `ToolRegistry.registerBuiltInTools`)
    /// so it works in plain chat / folder / sandbox alike.
    ///
    /// Lean by design: filesystem mutations (`mv`, `cp`, `rm`, `mkdir`)
    /// go through `shell_run` rather than discrete `file_move` /
    /// `file_copy` / `file_delete` / `dir_create` tools so the model
    /// picks "shell command" once instead of differentiating four
    /// near-identical tool names. `shell_run` is loaded on every folder
    /// mount (not gated on a detected project type) so the prompt's
    /// "use `shell_run` for `mv`/`cp`/`rm`/`mkdir`" advice always
    /// matches the schema. Multi-step orchestration goes through
    /// `shell_run` chains or — when the chat is sandbox-mode —
    /// `sandbox_write_file` + `sandbox_exec`.
    static func buildCoreTools(rootPath: URL) -> [OsaurusTool] {
        // `file_tree` is intentionally absent: `file_read` now lists a
        // directory when the path is one (the path carries the decision),
        // so a separate listing tool is just a redundant name the model
        // can mis-select. `FileTreeTool` remains as an internal lister
        // reused by `file_read`.
        return [
            FileReadTool(rootPath: rootPath),
            FileWriteTool(rootPath: rootPath),
            FileEditTool(rootPath: rootPath),
            FileOperationHistoryTool(rootPath: rootPath),
            FileUndoTool(rootPath: rootPath),
            FileSearchTool(rootPath: rootPath),
            ShellRunTool(rootPath: rootPath),
        ]
    }

    /// Build git tools. Installed when the working folder is a git repo.
    static func buildGitTools(rootPath: URL) -> [OsaurusTool] {
        return [
            GitStatusTool(rootPath: rootPath),
            GitDiffTool(rootPath: rootPath),
            GitCommitTool(rootPath: rootPath),
        ]
    }
    // Note: no `allToolNames` helper — the live tool list is the source of
    // truth (via `FolderToolManager.folderToolNames`). A hand-maintained
    // mirror would silently go stale every time a tool is added, renamed,
    // or moved between Core/Git groups.
}

// MARK: - String Extension

extension String {
    func ranges(of searchString: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = self.startIndex
        while start < self.endIndex, let range = self.range(of: searchString, range: start ..< self.endIndex) {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }
}
