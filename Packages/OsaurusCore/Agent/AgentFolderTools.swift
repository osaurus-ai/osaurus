//
//  AgentFolderTools.swift
//  osaurus
//
//  Agent folder tools for file operations, code editing, and git integration.
//  These tools are internal to the agent and do NOT appear in CapabilitiesSelectorView.
//

import Foundation

// MARK: - Tool Errors

enum AgentFolderToolError: LocalizedError {
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
enum AgentFolderToolHelpers {
    /// Resolve and validate a relative path, ensuring it's within rootPath
    static func resolvePath(_ relativePath: String, rootPath: URL) throws -> URL {
        let cleanPath = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        let resolvedURL = rootPath.appendingPathComponent(cleanPath).standardized
        let rootPathString = rootPath.standardized.path

        guard resolvedURL.path.hasPrefix(rootPathString) else {
            throw AgentFolderToolError.pathOutsideRoot(relativePath)
        }
        return resolvedURL
    }

    /// Parse JSON arguments to dictionary
    static func parseArguments(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AgentFolderToolError.invalidArguments("Failed to parse JSON")
        }
        return dict
    }

    /// Detect project type from root path
    static func detectProjectType(_ url: URL) -> AgentProjectType {
        let fm = FileManager.default
        for projectType in AgentProjectType.allCases where projectType != .unknown {
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
}

// MARK: - Core Tools

// MARK: File Tree Tool

struct AgentFileTreeTool: OsaurusTool {
    let name = "file_tree"
    let description =
        "List the directory structure of the working directory or a subdirectory. Returns a tree view of files and folders."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
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
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)
        let relativePath = args["path"] as? String ?? "."
        let maxDepth = args["max_depth"] as? Int ?? 3

        let targetURL = try AgentFolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw AgentFolderToolError.directoryNotFound(relativePath)
        }

        return buildTree(targetURL, maxDepth: maxDepth)
    }

    private func buildTree(_ url: URL, maxDepth: Int) -> String {
        var result = "\(url.lastPathComponent)/\n"
        var fileCount = 0
        let maxFiles = 300
        let ignorePatterns = AgentFolderToolHelpers.detectProjectType(rootPath).ignorePatterns

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
                if AgentFolderToolHelpers.shouldIgnore(name, patterns: ignorePatterns) { continue }

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

struct AgentFileReadTool: OsaurusTool {
    let name = "file_read"
    let description =
        "Read the contents of a file. Optionally specify start_line and end_line for partial reads. Line numbers are 1-indexed."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
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

    func execute(argumentsJSON: String) async throws -> String {
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        guard let relativePath = args["path"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: path")
        }

        let fileURL = try AgentFolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentFolderToolError.fileNotFound(relativePath)
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        let startLine = (args["start_line"] as? Int) ?? 1
        let endLine = (args["end_line"] as? Int) ?? lines.count
        let validStart = max(1, min(startLine, lines.count))
        let validEnd = max(validStart, min(endLine, lines.count))

        var output = ""
        for i in (validStart - 1) ..< validEnd {
            output += String(format: "%6d| %@\n", i + 1, lines[i])
        }

        if output.isEmpty { return "(empty file)" }

        if validStart > 1 || validEnd < lines.count {
            return "Lines \(validStart)-\(validEnd) of \(lines.count):\n" + output
        }
        return output
    }
}

// MARK: File Write Tool

struct AgentFileWriteTool: OsaurusTool, PermissionedTool {
    let name = "file_write"
    let description =
        "Create a new file or overwrite an existing file with the provided content. Parent directories will be created if they don't exist."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path for the file"),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("Content to write to the file"),
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
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        guard let relativePath = args["path"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: path")
        }
        guard let content = args["content"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: content")
        }

        let fileURL = try AgentFolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        // Capture previous state for undo
        let existed = FileManager.default.fileExists(atPath: fileURL.path)
        let previousContent = existed ? try? String(contentsOf: fileURL, encoding: .utf8) : nil

        // Log operation before executing
        if let issueId = AgentExecutionContext.currentIssueId {
            await AgentFileOperationLog.shared.log(
                AgentFileOperation(
                    type: existed ? .write : .create,
                    path: relativePath,
                    previousContent: previousContent,
                    issueId: issueId
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
        return "\(action) \(relativePath) (\(lineCount) lines, \(content.count) characters)"
    }
}

// MARK: File Move Tool

struct AgentFileMoveTool: OsaurusTool, PermissionedTool {
    let name = "file_move"
    let description = "Move or rename a file or directory."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "source": .object([
                "type": .string("string"),
                "description": .string("Relative path of the source file or directory"),
            ]),
            "destination": .object([
                "type": .string("string"),
                "description": .string("Relative path of the destination"),
            ]),
        ]),
        "required": .array([.string("source"), .string("destination")]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        guard let sourcePath = args["source"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: source")
        }
        guard let destPath = args["destination"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: destination")
        }

        let sourceURL = try AgentFolderToolHelpers.resolvePath(sourcePath, rootPath: rootPath)
        let destURL = try AgentFolderToolHelpers.resolvePath(destPath, rootPath: rootPath)

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw AgentFolderToolError.fileNotFound(sourcePath)
        }

        // Log operation before executing
        if let issueId = AgentExecutionContext.currentIssueId {
            await AgentFileOperationLog.shared.log(
                AgentFileOperation(
                    type: .move,
                    path: sourcePath,
                    destinationPath: destPath,
                    issueId: issueId
                )
            )
        }

        // Create parent directories if needed
        let parentDir = destURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        try FileManager.default.moveItem(at: sourceURL, to: destURL)

        return "Moved \(sourcePath) to \(destPath)"
    }
}

// MARK: File Copy Tool

struct AgentFileCopyTool: OsaurusTool, PermissionedTool {
    let name = "file_copy"
    let description = "Copy a file or directory to a new location."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "source": .object([
                "type": .string("string"),
                "description": .string("Relative path of the source file or directory"),
            ]),
            "destination": .object([
                "type": .string("string"),
                "description": .string("Relative path of the destination"),
            ]),
        ]),
        "required": .array([.string("source"), .string("destination")]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        guard let sourcePath = args["source"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: source")
        }
        guard let destPath = args["destination"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: destination")
        }

        let sourceURL = try AgentFolderToolHelpers.resolvePath(sourcePath, rootPath: rootPath)
        let destURL = try AgentFolderToolHelpers.resolvePath(destPath, rootPath: rootPath)

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw AgentFolderToolError.fileNotFound(sourcePath)
        }

        // Log operation before executing
        if let issueId = AgentExecutionContext.currentIssueId {
            await AgentFileOperationLog.shared.log(
                AgentFileOperation(
                    type: .copy,
                    path: sourcePath,
                    destinationPath: destPath,
                    issueId: issueId
                )
            )
        }

        // Create parent directories if needed
        let parentDir = destURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        return "Copied \(sourcePath) to \(destPath)"
    }
}

// MARK: File Delete Tool

struct AgentFileDeleteTool: OsaurusTool, PermissionedTool {
    let name = "file_delete"
    let description = "Delete a file or directory. This action requires approval."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path of the file or directory to delete"),
            ])
        ]),
        "required": .array([.string("path")]),
    ])

    var requirements: [String] { ["permission:folder_delete"] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        guard let relativePath = args["path"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: path")
        }

        let fileURL = try AgentFolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentFolderToolError.fileNotFound(relativePath)
        }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)

        // Capture previous content for undo (text files only)
        var previousContent: String?
        if !isDirectory.boolValue {
            previousContent = try? String(contentsOf: fileURL, encoding: .utf8)
        }

        // Log operation before executing
        if let issueId = AgentExecutionContext.currentIssueId {
            await AgentFileOperationLog.shared.log(
                AgentFileOperation(
                    type: .delete,
                    path: relativePath,
                    previousContent: previousContent,
                    issueId: issueId
                )
            )
        }

        try FileManager.default.removeItem(at: fileURL)

        let itemType = isDirectory.boolValue ? "directory" : "file"
        return "Deleted \(itemType): \(relativePath)"
    }
}

// MARK: Directory Create Tool

struct AgentDirCreateTool: OsaurusTool, PermissionedTool {
    let name = "dir_create"
    let description =
        "Create a new directory. Parent directories will be created if they don't exist."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path of the directory to create"),
            ])
        ]),
        "required": .array([.string("path")]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        guard let relativePath = args["path"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: path")
        }

        let dirURL = try AgentFolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        if FileManager.default.fileExists(atPath: dirURL.path) {
            return "Directory already exists: \(relativePath)"
        }

        // Log operation before executing
        if let issueId = AgentExecutionContext.currentIssueId {
            await AgentFileOperationLog.shared.log(
                AgentFileOperation(
                    type: .dirCreate,
                    path: relativePath,
                    issueId: issueId
                )
            )
        }

        try FileManager.default.createDirectory(
            at: dirURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        return "Created directory: \(relativePath)"
    }
}

// MARK: File Metadata Tool

struct AgentFileMetadataTool: OsaurusTool {
    let name = "file_metadata"
    let description = "Get metadata about a file or directory (size, dates, type)."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path of the file or directory"),
            ])
        ]),
        "required": .array([.string("path")]),
    ])

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        guard let relativePath = args["path"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: path")
        }

        let fileURL = try AgentFolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentFolderToolError.fileNotFound(relativePath)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)

        let fileType = isDirectory.boolValue ? "directory" : "file"
        let size = attributes[.size] as? Int64 ?? 0
        let created = attributes[.creationDate] as? Date
        let modified = attributes[.modificationDate] as? Date

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        var result = """
            Path: \(relativePath)
            Type: \(fileType)
            Size: \(formatBytes(size))
            """

        if let created = created {
            result += "\nCreated: \(formatter.string(from: created))"
        }
        if let modified = modified {
            result += "\nModified: \(formatter.string(from: modified))"
        }

        // For files, also show line count
        if !isDirectory.boolValue {
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                let lineCount = content.components(separatedBy: .newlines).count
                result += "\nLines: \(lineCount)"
            }
        }

        return result
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Coding Tools

// MARK: File Edit Tool

struct AgentFileEditTool: OsaurusTool, PermissionedTool {
    let name = "file_edit"
    let description =
        "Edit a file by replacing specific text. Use old_string to identify the text to replace and new_string for the replacement. For surgical edits, include enough context in old_string to uniquely identify the location."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path to the file"),
            ]),
            "old_string": .object([
                "type": .string("string"),
                "description": .string(
                    "The exact text to find and replace (include enough context to be unique)"
                ),
            ]),
            "new_string": .object([
                "type": .string("string"),
                "description": .string("The text to replace it with"),
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
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        guard let relativePath = args["path"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: path")
        }
        guard let oldString = args["old_string"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: old_string")
        }
        guard let newString = args["new_string"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: new_string")
        }

        let fileURL = try AgentFolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentFolderToolError.fileNotFound(relativePath)
        }

        var content = try String(contentsOf: fileURL, encoding: .utf8)

        // Find the old string
        guard let range = content.range(of: oldString) else {
            throw AgentFolderToolError.operationFailed(
                "Could not find the specified text in the file. Make sure old_string exactly matches the file content."
            )
        }

        // Check for multiple matches
        let matches = content.ranges(of: oldString)
        if matches.count > 1 {
            throw AgentFolderToolError.operationFailed(
                "Found \(matches.count) matches for old_string. Include more context to uniquely identify the location."
            )
        }

        // Replace
        content.replaceSubrange(range, with: newString)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Calculate affected lines
        let beforeLines = oldString.components(separatedBy: .newlines).count
        let afterLines = newString.components(separatedBy: .newlines).count

        return "Edited \(relativePath): replaced \(beforeLines) line(s) with \(afterLines) line(s)"
    }
}

// MARK: File Search Tool

struct AgentFileSearchTool: OsaurusTool {
    let name = "file_search"
    let description =
        "Search for text in files. Returns matching lines with file paths and line numbers."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "pattern": .object([
                "type": .string("string"),
                "description": .string("Text or regex pattern to search for"),
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
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        guard let pattern = args["pattern"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: pattern")
        }

        let searchPath = args["path"] as? String ?? "."
        let filePattern = args["file_pattern"] as? String
        let maxResults = args["max_results"] as? Int ?? 50

        let searchURL = try AgentFolderToolHelpers.resolvePath(searchPath, rootPath: rootPath)

        var results: [String] = []
        var totalMatches = 0

        // Determine if searching a file or directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchURL.path, isDirectory: &isDirectory)
        else {
            throw AgentFolderToolError.fileNotFound(searchPath)
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
            return "No matches found for '\(pattern)'"
        }

        var output = "Found \(totalMatches) match(es):\n\n"
        output += results.joined(separator: "\n")

        if totalMatches >= maxResults {
            output += "\n\n(results truncated at \(maxResults))"
        }

        return output
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

struct AgentShellRunTool: OsaurusTool, PermissionedTool {
    let name = "shell_run"
    let description =
        "Run a shell command in the working directory. This action requires approval. Use for builds, tests, or other commands."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
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
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        guard let command = args["command"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: command")
        }

        let timeout = min(args["timeout"] as? Int ?? 30, 300)

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
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AgentFolderToolError.operationFailed("Failed to execute command: \(error)")
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

        var result = "Exit code: \(exitCode)\n"

        if !stdout.isEmpty {
            result += "\n--- stdout ---\n\(truncateOutput(stdout))"
        }
        if !stderr.isEmpty {
            result += "\n\n--- stderr ---\n\(truncateOutput(stderr))"
        }

        if stdout.isEmpty && stderr.isEmpty {
            result += "\n(no output)"
        }

        return result
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

struct AgentGitStatusTool: OsaurusTool {
    let name = "git_status"
    let description = "Show the current git status including branch name and uncommitted changes."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "required": .array([]),
    ])

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status"]
        process.currentDirectoryURL = rootPath

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AgentFolderToolError.operationFailed("Failed to run git status: \(error)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output =
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            throw AgentFolderToolError.operationFailed("git status failed: \(output)")
        }

        return output.isEmpty ? "No changes" : output
    }
}

// MARK: Git Diff Tool

struct AgentGitDiffTool: OsaurusTool {
    let name = "git_diff"
    let description =
        "Show git diff for files. Can show staged changes, unstaged changes, or diff between commits."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
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
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        let filePath = args["path"] as? String
        let staged = args["staged"] as? Bool ?? false
        let commit = args["commit"] as? String

        var arguments = ["diff"]

        if staged {
            arguments.append("--cached")
        }

        if let commit = commit {
            arguments.append(commit)
        }

        if let filePath = filePath {
            arguments.append("--")
            arguments.append(filePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = rootPath

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AgentFolderToolError.operationFailed("Failed to run git diff: \(error)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        var output =
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            throw AgentFolderToolError.operationFailed("git diff failed: \(output)")
        }

        // Truncate if too long
        if output.count > 20000 {
            output = String(output.prefix(20000)) + "\n... (diff truncated)"
        }

        return output.isEmpty ? "No differences" : output
    }
}

// MARK: Git Commit Tool

struct AgentGitCommitTool: OsaurusTool, PermissionedTool {
    let name = "git_commit"
    let description =
        "Stage and commit changes to git. This action requires approval. Optionally specify files to stage, otherwise stages all changes."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
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
        let args = try AgentFolderToolHelpers.parseArguments(argumentsJSON)

        guard let message = args["message"] as? String else {
            throw AgentFolderToolError.invalidArguments("Missing required parameter: message")
        }

        let files = args["files"] as? [String]

        // Stage files
        let stageProcess = Process()
        stageProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        stageProcess.currentDirectoryURL = rootPath

        if let files = files, !files.isEmpty {
            stageProcess.arguments = ["add"] + files
        } else {
            stageProcess.arguments = ["add", "-A"]
        }

        let stagePipe = Pipe()
        stageProcess.standardOutput = stagePipe
        stageProcess.standardError = stagePipe

        try stageProcess.run()
        stageProcess.waitUntilExit()

        if stageProcess.terminationStatus != 0 {
            let stageOutput =
                String(
                    data: stagePipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
            throw AgentFolderToolError.operationFailed("git add failed: \(stageOutput)")
        }

        // Commit
        let commitProcess = Process()
        commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commitProcess.arguments = ["commit", "-m", message]
        commitProcess.currentDirectoryURL = rootPath

        let commitPipe = Pipe()
        commitProcess.standardOutput = commitPipe
        commitProcess.standardError = commitPipe

        try commitProcess.run()
        commitProcess.waitUntilExit()

        let commitOutput =
            String(data: commitPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""

        if commitProcess.terminationStatus != 0 {
            if commitOutput.contains("nothing to commit") {
                return "Nothing to commit"
            }
            throw AgentFolderToolError.operationFailed("git commit failed: \(commitOutput)")
        }

        return "Committed successfully:\n\(commitOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

// MARK: - Tool Factory

/// Factory for creating folder tool instances
enum AgentFolderToolFactory {
    /// Build all core file tools
    static func buildCoreTools(rootPath: URL) -> [OsaurusTool] {
        return [
            AgentFileTreeTool(rootPath: rootPath),
            AgentFileReadTool(rootPath: rootPath),
            AgentFileWriteTool(rootPath: rootPath),
            AgentFileMoveTool(rootPath: rootPath),
            AgentFileCopyTool(rootPath: rootPath),
            AgentFileDeleteTool(rootPath: rootPath),
            AgentDirCreateTool(rootPath: rootPath),
            AgentFileMetadataTool(rootPath: rootPath),
        ]
    }

    /// Build coding tools
    static func buildCodingTools(rootPath: URL) -> [OsaurusTool] {
        return [
            AgentFileEditTool(rootPath: rootPath),
            AgentFileSearchTool(rootPath: rootPath),
            AgentShellRunTool(rootPath: rootPath),
        ]
    }

    /// Build git tools
    static func buildGitTools(rootPath: URL) -> [OsaurusTool] {
        return [
            AgentGitStatusTool(rootPath: rootPath),
            AgentGitDiffTool(rootPath: rootPath),
            AgentGitCommitTool(rootPath: rootPath),
        ]
    }

    /// Get all tool names (for filtering)
    static var allToolNames: [String] {
        return [
            // Core
            "file_tree", "file_read", "file_write", "file_move",
            "file_copy", "file_delete", "dir_create", "file_metadata",
            // Coding
            "file_edit", "file_search", "shell_run",
            // Git
            "git_status", "git_diff", "git_commit",
        ]
    }
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
