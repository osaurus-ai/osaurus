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
            for manifestFile in projectType.manifestFiles {
                if fm.fileExists(atPath: url.appendingPathComponent(manifestFile).path) {
                    return projectType
                }
            }
        }
        return .unknown
    }

    /// Check if pattern matches filename
    static func matchesPattern(_ name: String, pattern: String) -> Bool {
        if pattern.contains("*") {
            let regex = pattern.replacingOccurrences(of: ".", with: "\\.")
                .replacingOccurrences(of: "*", with: ".*")
            return name.range(of: "^\(regex)$", options: .regularExpression) != nil
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

    /// File-count ceiling — caps how many leaf files the tree enumerates.
    private static let maxFiles = 300
    /// Character ceiling for the rendered tree. A wide/deep layout (many
    /// directories, which don't count toward `maxFiles`) can still bloat the
    /// retained context across every later request, so cap the raw output too.
    private static let maxOutputChars = 8000
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
        "Read a file's contents, or list a directory's contents. Pass any path — files return text, "
        + "directories return a listing. Use this rather than a shell `cat` / `head` / `tail` / `ls` / "
        + "`tree`. For files: text and text-extractable documents (PDF, Word, PowerPoint, RTF, HTML) and "
        + "a bounded XLSX workbook preview are supported (images and other binaries are not); bound large "
        + "reads with start_line/end_line, tail_lines, or max_chars. For directories: bound the depth with "
        + "max_depth."
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
    /// Consistent with truncation limits on shell_run (10k) and git_diff (20k).
    private static let maxOutputChars = 15_000

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
            let listing = FileTreeTool(rootPath: rootPath).treeText(for: fileURL, maxDepth: maxDepth)
            return ToolEnvelope.success(tool: name, text: listing)
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
        for i in (validStart - 1) ..< validEnd {
            let line = String(format: "%6d| %@\n", i + 1, lines[i])
            if output.count + line.count > charCap {
                let remaining = charCap - output.count
                if remaining > 0 {
                    output += String(line.prefix(remaining))
                    lastLineIncluded = i + 1
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
            output +=
                "\n... (truncated at \(lastLineIncluded) of \(Self.lineCountLabel(lines.count, rawRead: content.rawRead)) lines — use start_line/end_line for specific ranges)"
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
            text = "Lines \(validStart)-\(lastLineIncluded) of \(totalLines):\n" + output
        } else {
            text = output
        }
        var result: [String: Any] = [
            "text": text,
            "path": relativePath,
            "start_line": validStart,
            "end_line": lastLineIncluded,
            "total_lines": lines.count,
            "total_lines_exact": content.rawRead?.truncatedByByteLimit != true,
            "truncated": outputTruncated || lastLineIncluded < validEnd
                || content.rawRead?.truncatedByByteLimit == true,
        ]
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
        "Create a new file or overwrite an existing file with the provided content. **Use this "
        + "instead of `echo` / `cat` heredoc in `shell_run`.** Parent directories will be created "
        + "if they don't exist. You MUST provide the file contents in the `content` parameter."
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

        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        // Capture previous state for undo
        let existed = FileManager.default.fileExists(atPath: fileURL.path)
        let previousContent = existed ? try? String(contentsOf: fileURL, encoding: .utf8) : nil

        // Log operation before executing
        if let sessionId = ChatExecutionContext.currentSessionId {
            await FileOperationLog.shared.log(
                FileOperation(
                    type: existed ? .write : .create,
                    path: relativePath,
                    previousContent: previousContent,
                    sessionId: sessionId,
                    batchId: ChatExecutionContext.currentBatchId
                )
            )
        }

        // Create parent directories if needed
        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Write content
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let lineCount = content.components(separatedBy: .newlines).count
        let action = existed ? "Updated" : "Created"
        return ToolEnvelope.success(
            tool: name,
            text: "\(action) \(relativePath) (\(lineCount) lines, \(content.count) characters)"
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
        "Edit a file by replacing specific text. **Use this instead of `sed` / `awk` in "
        + "`shell_run`.** `old_string` must uniquely match exactly one location in the file — "
        + "include surrounding context lines if needed to ensure uniqueness. Fails if `old_string` "
        + "is not found or matches multiple locations. You MUST provide the strings in the parameters."
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

        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FolderToolError.fileNotFound(relativePath)
        }

        // Capture pre-edit contents for the operation log (undo support).
        let originalContent = try String(contentsOf: fileURL, encoding: .utf8)
        var content = originalContent

        guard let range = content.range(of: oldString) else {
            throw FolderToolError.operationFailed(
                "Could not find the specified text in the file. Make sure old_string exactly matches the file content."
            )
        }

        let matches = content.ranges(of: oldString)
        if matches.count > 1 {
            throw FolderToolError.operationFailed(
                "Found \(matches.count) matches for old_string — include more context to uniquely identify the location."
            )
        }

        content.replaceSubrange(range, with: newString)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Log for undo parity with `file_write`. Skipped when no session.
        if let sid = ChatExecutionContext.currentSessionId {
            await FileOperationLog.shared.log(
                FileOperation(
                    type: .fileEdit,
                    path: relativePath,
                    previousContent: originalContent,
                    sessionId: sid,
                    batchId: ChatExecutionContext.currentBatchId
                )
            )
        }

        let beforeLines = oldString.components(separatedBy: .newlines).count
        let afterLines = newString.components(separatedBy: .newlines).count

        return ToolEnvelope.success(
            tool: name,
            text: "Edited \(relativePath): replaced \(beforeLines) line(s) with \(afterLines) line(s)"
        )
    }
}

// MARK: File Search Tool

struct FileSearchTool: OsaurusTool {
    let name = "file_search"
    let description =
        "Search files in the working directory. With `target=\"content\"` (default) it finds text by "
        + "case-insensitive substring match, returning matching lines with file paths and line numbers. "
        + "With `target=\"files\"` it finds files by name glob (e.g. `*.swift`). Use this rather than a "
        + "shell `grep` / `rg` / `find`."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "pattern": .object([
                "type": .string("string"),
                "description": .string(
                    "When `target=\"content\"`: text to find (case-insensitive substring). "
                        + "When `target=\"files\"`: filename glob (e.g. `*.swift`, `test_*`)."
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

    init(rootPath: URL) {
        self.rootPath = rootPath
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
        let maxResults = coerceInt(args["max_results"]) ?? 50
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

        // `target="files"`: filename-glob find (no content read). Mirrors
        // `sandbox_search_files(target:"files")` so the unified family can
        // locate files by name on either filesystem.
        if target == "files" {
            return findFilesByName(root: searchURL, glob: pattern, maxResults: maxResults)
        }

        var results: [String] = []
        var totalMatches = 0

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

        if isDirectory.boolValue {
            // Search directory recursively
            let enumerator = FileManager.default.enumerator(
                at: searchURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                guard totalMatches < maxResults else { break }

                // Check if regular file
                guard
                    let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                    resourceValues.isRegularFile == true
                else { continue }

                // Combined-mode secret denylist: never return contents of
                // a non-hidden secret (`server.pem`, `id_rsa`, …). `.env`
                // and other dotfiles are already excluded by
                // `.skipsHiddenFiles`; this catches the rest.
                if FolderToolHelpers.shouldRefuseSecret(fileURL: fileURL) {
                    continue
                }

                // Check file pattern
                if let pattern = filePattern {
                    let regex = pattern.replacingOccurrences(of: ".", with: "\\.")
                        .replacingOccurrences(of: "*", with: ".*")
                    if fileURL.lastPathComponent.range(of: "^\(regex)$", options: .regularExpression)
                        == nil
                    {
                        continue
                    }
                }

                // Search file
                if let matches = searchFile(fileURL, pattern: pattern, maxResults: maxResults - totalMatches) {
                    results.append(contentsOf: matches)
                    totalMatches += matches.count
                }
            }
        } else {
            // Search single file
            if let matches = searchFile(searchURL, pattern: pattern, maxResults: maxResults) {
                results.append(contentsOf: matches)
                totalMatches = matches.count
            }
        }

        if results.isEmpty {
            return ToolEnvelope.success(
                tool: name,
                text: "No matches found for '\(pattern)'"
            )
        }

        var output = "Found \(totalMatches) match(es):\n\n"
        output += results.joined(separator: "\n")

        if totalMatches >= maxResults {
            output += "\n\n(results truncated at \(maxResults))"
        }

        return ToolEnvelope.success(tool: name, text: output)
    }

    /// Filename-glob find under `root` (recursive, hidden + secret files
    /// skipped), returning matching relative paths as a host-style text
    /// envelope. The glob supports `*` and `.`; matching is anchored to the
    /// full basename. Mirrors the sandbox `find … -name` behaviour.
    private func findFilesByName(root: URL, glob: String, maxResults: Int) -> String {
        let regex =
            "^"
            + NSRegularExpression.escapedPattern(for: glob)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
            + "$"

        var matches: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            guard matches.count < maxResults else { break }
            guard
                let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                resourceValues.isRegularFile == true
            else { continue }
            if FolderToolHelpers.shouldRefuseSecret(fileURL: fileURL) { continue }
            let name = fileURL.lastPathComponent
            guard name.range(of: regex, options: .regularExpression) != nil else { continue }
            let relativePath =
                fileURL.path.hasPrefix(rootPath.path)
                ? String(fileURL.path.dropFirst(rootPath.path.count + 1))
                : name
            matches.append(relativePath)
        }

        if matches.isEmpty {
            return ToolEnvelope.success(tool: name, text: "No files found matching '\(glob)'")
        }
        var output = "Found \(matches.count) file(s):\n\n" + matches.joined(separator: "\n")
        if matches.count >= maxResults {
            output += "\n\n(results truncated at \(maxResults))"
        }
        return ToolEnvelope.success(tool: name, text: output)
    }

    private func searchFile(_ url: URL, pattern: String, maxResults: Int) -> [String]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        let relativePath =
            url.path.hasPrefix(rootPath.path)
            ? String(url.path.dropFirst(rootPath.path.count + 1))
            : url.lastPathComponent

        let lines = content.components(separatedBy: .newlines)
        var matches: [String] = []

        for (index, line) in lines.enumerated() {
            guard matches.count < maxResults else { break }

            if line.localizedCaseInsensitiveContains(pattern) {
                let lineNum = index + 1
                matches.append("\(relativePath):\(lineNum): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        return matches.isEmpty ? nil : matches
    }
}

// MARK: Shell Run Tool

struct ShellRunTool: OsaurusTool, PermissionedTool {
    let name = "shell_run"
    let description =
        "Run a shell command in the working directory. **Reserve this for builds, tests, "
        + "git, processes, network calls, and filesystem mutations (`mv`/`cp`/`rm`/`mkdir`).** "
        + "For file IO, search, edit, write, and directory listing, prefer the dedicated "
        + "`file_*` tools — each one's description notes the shell pattern it "
        + "replaces. This action requires approval. Long-running commands stream their "
        + "output live to the chat — the user sees it as it happens and can press [Terminate] "
        + "at any time. Final stdout truncated to 10,000 characters. No built-in timeout: "
        + "pass `timeout: <seconds>` ONLY if you want a hard idle ceiling (kill the process "
        + "if no output for N seconds). Avoid `2>/dev/null` in pipelines — pipefail is on "
        + "and suppressing stderr will trigger an empty-output warning."
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
        let idleTimeout: TimeInterval? = coerceInt(args["timeout"]).map(TimeInterval.init)

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
        let idleWatcher: Task<Void, Never>?
        if let idleTimeout {
            idleWatcher = Task.detached { @Sendable in
                let pollNanos: UInt64 = 1_000_000_000
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: pollNanos)
                    if Task.isCancelled { return }
                    let last = collector.lastActivity
                    if Date().timeIntervalSince(last) >= idleTimeout {
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
        }
        let warnings = diagnosticWarnings(
            command: command,
            exitCode: exitCode,
            stdout: trimmedStdout,
            stderr: trimmedStderr
        )
        return ToolEnvelope.success(
            tool: name,
            result: payload,
            warnings: warnings.isEmpty ? nil : warnings
        )
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

    private func truncateOutput(_ output: String, maxLength: Int = 10000) -> String {
        if output.count > maxLength {
            return String(output.prefix(maxLength)) + "\n... (truncated)"
        }
        return output
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

    var lastActivity: Date {
        lock.withLock { _lastActivity }
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

        // Truncate if too long
        let text: String
        if output.count > 20000 {
            text = String(output.prefix(20000)) + "\n... (diff truncated)"
        } else {
            text = output.isEmpty ? "No differences" : output
        }
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
    /// `sandbox_execute_code`.
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
