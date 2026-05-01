//
//  FolderTools.swift
//  osaurus
//
//  Folder-context tools for file operations, code editing, and git
//  integration. Registered by FolderToolManager whenever a working folder
//  is selected; agents use them to operate directly on the host folder.
//

import Foundation

// MARK: - Tool Errors

enum FolderToolError: LocalizedError {
    case invalidArguments(String)
    case pathOutsideRoot(String)
    case fileNotFound(String)
    case directoryNotFound(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): return "Invalid arguments: \(msg)"
        case .pathOutsideRoot(let path): return "Path is outside working directory: \(path)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .directoryNotFound(let path): return "Directory not found: \(path)"
        case .operationFailed(let msg): return "Operation failed: \(msg)"
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
}

// MARK: - Core Tools

// MARK: File Tree Tool

struct FileTreeTool: OsaurusTool {
    let name = "file_tree"
    let description =
        "List the directory structure of the working directory or a subdirectory. **Use this instead "
        + "of `ls` / `tree` in `shell_run`.** Returns a tree view of files and folders. Skips hidden "
        + "files and truncates at 300 files."
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
        let args = try FolderToolHelpers.parseArguments(argumentsJSON)
        let relativePath = args["path"] as? String ?? "."
        let maxDepth = coerceInt(args["max_depth"]) ?? 3

        let targetURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw FolderToolError.directoryNotFound(relativePath)
        }

        return ToolEnvelope.success(tool: name, text: buildTree(targetURL, maxDepth: maxDepth))
    }

    private func buildTree(_ url: URL, maxDepth: Int) -> String {
        var result = "./\n"
        var fileCount = 0
        let maxFiles = 300
        let ignorePatterns = FolderToolHelpers.detectProjectType(rootPath).ignorePatterns

        func traverse(_ currentURL: URL, depth: Int, prefix: String) {
            guard depth <= maxDepth, fileCount < maxFiles else { return }

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

            for (index, item) in sorted.enumerated() {
                guard fileCount < maxFiles else {
                    result += "\(prefix)... (truncated)\n"
                    return
                }

                let name = item.lastPathComponent
                if FolderToolHelpers.shouldIgnore(name, patterns: ignorePatterns) { continue }

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
                    result += "\(prefix)\(connector)\(name)\n"
                    fileCount += 1
                }
            }
        }

        traverse(url, depth: 1, prefix: "")
        return result
    }
}

// MARK: File Read Tool

struct FileReadTool: OsaurusTool {
    let name = "file_read"
    let description =
        "Read the contents of a text file. **Use this instead of `cat` / `head` / `tail` in "
        + "`shell_run`.** Cannot read binary files (PDFs, images, etc.). Optionally specify start_line "
        + "and end_line for partial reads. Line numbers are 1-indexed."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path to the file from the working directory"),
            ]),
            "start_line": .object([
                "type": .string("integer"),
                "description": .string("Optional start line number (1-indexed, inclusive)"),
            ]),
            "end_line": .object([
                "type": .string("integer"),
                "description": .string("Optional end line number (1-indexed, inclusive)"),
            ]),
        ]),
        "required": .array([.string("path")]),
    ])

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    /// Maximum characters for file_read output to prevent context window exhaustion.
    /// Consistent with truncation limits on shell_run (10k) and git_diff (20k).
    private static let maxOutputChars = 15_000

    func execute(argumentsJSON: String) async throws -> String {
        let args = try FolderToolHelpers.parseArguments(argumentsJSON)

        guard let relativePath = args["path"] as? String else {
            throw FolderToolError.invalidArguments("Missing required parameter: path")
        }

        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FolderToolError.fileNotFound(relativePath)
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        let startLine = coerceInt(args["start_line"]) ?? 1
        let endLine = coerceInt(args["end_line"]) ?? lines.count
        let validStart = max(1, min(startLine, lines.count))
        let validEnd = max(validStart, min(endLine, lines.count))

        var output = ""
        var lastLineIncluded = validStart - 1
        for i in (validStart - 1) ..< validEnd {
            let line = String(format: "%6d| %@\n", i + 1, lines[i])
            if output.count + line.count > Self.maxOutputChars {
                break
            }
            output += line
            lastLineIncluded = i + 1
        }

        if output.isEmpty { return "(empty file)" }

        // If truncated, inform the model and suggest using line ranges
        if lastLineIncluded < validEnd {
            output +=
                "\n... (truncated at \(lastLineIncluded) of \(lines.count) lines — use start_line/end_line for specific ranges)"
        }

        let text: String
        if validStart > 1 || validEnd < lines.count {
            text = "Lines \(validStart)-\(validEnd) of \(lines.count):\n" + output
        } else {
            text = output
        }
        return ToolEnvelope.success(tool: name, text: text)
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
        let args = try FolderToolHelpers.parseArguments(argumentsJSON)

        guard let relativePath = args["path"] as? String else {
            throw FolderToolError.invalidArguments("Missing required parameter: path")
        }
        guard let content = args["content"] as? String else {
            throw FolderToolError.invalidArguments("Missing required parameter: content")
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
        let args = try FolderToolHelpers.parseArguments(argumentsJSON)

        guard let relativePath = args["path"] as? String else {
            throw FolderToolError.invalidArguments("Missing required parameter: path")
        }
        guard let oldString = args["old_string"] as? String else {
            throw FolderToolError.invalidArguments("Missing required parameter: old_string")
        }
        // Empty `old_string` is ambiguous — reject explicitly (matches
        // `sandbox_edit_file`).
        guard !oldString.isEmpty else {
            throw FolderToolError.invalidArguments(
                "old_string must not be empty. Pass the exact text you want to replace."
            )
        }
        guard let newString = args["new_string"] as? String else {
            throw FolderToolError.invalidArguments("Missing required parameter: new_string")
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
        "Search for text in files using case-insensitive substring matching. **Use this instead of "
        + "`grep` / `rg` / `find` in `shell_run`.** Returns matching lines with file paths and line numbers."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "pattern": .object([
                "type": .string("string"),
                "description": .string("Text to search for (case-insensitive substring match)"),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional directory or file path to search in (default: entire working directory)"
                ),
            ]),
            "file_pattern": .object([
                "type": .string("string"),
                "description": .string("Optional file name pattern (e.g., '*.swift', '*.ts')"),
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
        let args = try FolderToolHelpers.parseArguments(argumentsJSON)

        guard let pattern = args["pattern"] as? String else {
            throw FolderToolError.invalidArguments("Missing required parameter: pattern")
        }

        let searchPath = args["path"] as? String ?? "."
        let filePattern = args["file_pattern"] as? String
        let maxResults = coerceInt(args["max_results"]) ?? 50

        let searchURL = try FolderToolHelpers.resolvePath(searchPath, rootPath: rootPath)

        var results: [String] = []
        var totalMatches = 0

        // Determine if searching a file or directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchURL.path, isDirectory: &isDirectory)
        else {
            throw FolderToolError.fileNotFound(searchPath)
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
        "Run a shell command in the working directory. This action requires approval. Output is truncated to 10,000 characters. Use for builds, tests, or other commands."
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
                "description": .string("Timeout in seconds (default: 30, max: 300)"),
            ]),
        ]),
        "required": .array([.string("command")]),
    ])

    var requirements: [String] { ["permission:shell"] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = try FolderToolHelpers.parseArguments(argumentsJSON)

        guard let command = args["command"] as? String else {
            throw FolderToolError.invalidArguments("Missing required parameter: command")
        }

        let timeout = min(coerceInt(args["timeout"]) ?? 30, 300)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = rootPath

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set up timeout
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            if process.isRunning {
                process.terminate()
            }
        }

        defer {
            timeoutTask.cancel()
        }

        do {
            try await FolderToolHelpers.runProcessAsync(process)
        } catch {
            throw FolderToolError.operationFailed("Failed to execute command: \(error)")
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout =
            String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let stderr =
            String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        let exitCode = process.terminationStatus

        return ToolEnvelope.success(
            tool: name,
            result: [
                "stdout": truncateOutput(stdout),
                "stderr": truncateOutput(stderr),
                "exit_code": Int(exitCode),
            ]
        )
    }

    private func truncateOutput(_ output: String, maxLength: Int = 10000) -> String {
        if output.count > maxLength {
            return String(output.prefix(maxLength)) + "\n... (truncated)"
        }
        return output
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
        let args = try FolderToolHelpers.parseArguments(argumentsJSON)

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
        let args = try FolderToolHelpers.parseArguments(argumentsJSON)

        guard let message = args["message"] as? String else {
            throw FolderToolError.invalidArguments("Missing required parameter: message")
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
    /// near-identical tool names. Multi-step orchestration goes through
    /// `shell_run` chains or — when the chat is sandbox-mode —
    /// `sandbox_execute_code`.
    static func buildCoreTools(rootPath: URL) -> [OsaurusTool] {
        return [
            FileTreeTool(rootPath: rootPath),
            FileReadTool(rootPath: rootPath),
            FileWriteTool(rootPath: rootPath),
            FileEditTool(rootPath: rootPath),
            FileSearchTool(rootPath: rootPath),
        ]
    }

    /// Build project-aware coding tools. Installed when the working folder
    /// has a detected project type (swift/node/python/rust/go).
    static func buildCodingTools(rootPath: URL) -> [OsaurusTool] {
        return [
            ShellRunTool(rootPath: rootPath)
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
    // or moved between Core/Coding/Git groups.
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
