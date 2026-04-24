//
//  SharedArtifact.swift
//  osaurus
//
//  An artifact (file, directory, or inline content) handed off by the agent
//  to the user. Used by the chat-side `share_artifact` tool path.
//

import Foundation

// MARK: - Artifact Context Type

public enum ArtifactContextType: String, Codable, Sendable {
    /// Retained only so previously-encoded artifacts decode cleanly. New
    /// artifacts are always `.chat`.
    case work
    case chat
}

// MARK: - SharedArtifact

/// A shared artifact handed off by the agent to the user.
/// Supports files (images, HTML, audio, etc.), directories, and inline text content.
public struct SharedArtifact: Identifiable, Codable, Sendable, Equatable {
    /// Unique ID for this artifact
    public let id: String
    /// The owning context — a chat session ID
    public let contextId: String
    /// Whether this artifact belongs to a work task or chat session
    public let contextType: ArtifactContextType
    /// Display filename (e.g. "result.png", "my-website")
    public let filename: String
    /// MIME type (e.g. "image/png", "text/html", "inode/directory")
    public let mimeType: String
    /// Total size in bytes (sum of all files if directory)
    public let fileSize: Int
    /// Absolute path on the host filesystem (~/.osaurus/artifacts/{contextId}/{filename})
    public let hostPath: String
    /// Whether this artifact is a directory
    public let isDirectory: Bool
    /// Inline text content (stored in DB). Nil for binary files and directories.
    public let content: String?
    /// Human-readable description provided by the agent
    public let description: String?
    /// Whether this is the final result artifact from the agent's `complete` call
    public let isFinalResult: Bool
    /// When the artifact was created
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        contextId: String,
        contextType: ArtifactContextType,
        filename: String,
        mimeType: String,
        fileSize: Int,
        hostPath: String,
        isDirectory: Bool = false,
        content: String? = nil,
        description: String? = nil,
        isFinalResult: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.contextId = contextId
        self.contextType = contextType
        self.filename = filename
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.hostPath = hostPath
        self.isDirectory = isDirectory
        self.content = content
        self.description = description
        self.isFinalResult = isFinalResult
        self.createdAt = createdAt
    }

    /// Detects MIME type from a filename extension.
    public static func mimeType(from filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "md", "markdown": return "text/markdown"
        case "txt": return "text/plain"
        case "csv": return "text/csv"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "tar": return "application/x-tar"
        case "gz": return "application/gzip"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "ogg": return "audio/ogg"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "py": return "text/x-python"
        case "swift": return "text/x-swift"
        case "rs": return "text/x-rust"
        case "go": return "text/x-go"
        case "java": return "text/x-java"
        case "c", "h": return "text/x-c"
        case "cpp", "hpp", "cc": return "text/x-c++"
        case "ts": return "text/typescript"
        case "xml": return "application/xml"
        case "yaml", "yml": return "application/x-yaml"
        default: return "application/octet-stream"
        }
    }

    /// Whether this artifact's MIME type indicates an image.
    public var isImage: Bool { mimeType.hasPrefix("image/") }

    /// Whether this artifact's MIME type indicates audio.
    public var isAudio: Bool { mimeType.hasPrefix("audio/") }

    /// Whether this artifact's MIME type indicates a text-based format.
    public var isText: Bool {
        mimeType.hasPrefix("text/") || mimeType == "application/json" || mimeType == "application/xml"
            || mimeType == "application/x-yaml"
    }

    /// Whether this artifact is an HTML file or directory containing index.html.
    public var isHTML: Bool { mimeType == "text/html" }

    /// Whether this artifact's MIME type indicates video.
    public var isVideo: Bool { mimeType.hasPrefix("video/") }

    /// Whether this artifact is a PDF document.
    public var isPDF: Bool { mimeType == "application/pdf" }

    /// Human-readable content category label.
    public var categoryLabel: String {
        if isDirectory { return "Directory" }
        if isImage { return "Image" }
        if isPDF { return "PDF" }
        if isAudio { return "Audio" }
        if isVideo { return "Video" }
        if isHTML { return "Web Page" }
        if mimeType == "text/markdown" { return "Markdown" }
        if isText { return "Text" }
        return "File"
    }
}

// MARK: - Tool Result Processing

extension SharedArtifact {

    static let startMarker = "---SHARED_ARTIFACT_START---\n"
    static let endMarker = "\n---SHARED_ARTIFACT_END---"

    /// Raw parsed content extracted from the marker-delimited region.
    struct ParsedMarkers {
        var metadata: [String: Any]
        var filename: String
        let contentLines: [String]
        let startRange: Range<String.Index>
        let endRange: Range<String.Index>
    }

    /// Result of fully processing a share_artifact tool result.
    struct ProcessingResult {
        let artifact: SharedArtifact
        let enrichedToolResult: String
    }

    /// Extracts marker-delimited metadata and content lines from a tool result string.
    static func parseMarkers(from toolResult: String) -> ParsedMarkers? {
        guard let startRange = toolResult.range(of: startMarker),
            let endRange = toolResult.range(of: endMarker)
        else { return nil }

        let inner = String(toolResult[startRange.upperBound ..< endRange.lowerBound])
        let lines = inner.components(separatedBy: "\n")
        guard let metadataLine = lines.first,
            let data = metadataLine.data(using: .utf8),
            let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let filename = metadata["filename"] as? String
        else { return nil }

        return ParsedMarkers(
            metadata: metadata,
            filename: filename,
            contentLines: Array(lines.dropFirst()),
            startRange: startRange,
            endRange: endRange
        )
    }

    /// Full processing pipeline: parse markers, resolve files, copy to
    /// artifacts dir, and return both the artifact and an enriched tool
    /// result string. Artifacts live on disk under
    /// `~/.osaurus/artifacts/{contextId}/` and are referenced by the
    /// enriched tool-result string carried in chat transcripts — no
    /// database persistence.
    static func processToolResult(
        _ toolResult: String,
        contextId: String,
        contextType: ArtifactContextType,
        executionMode: ExecutionMode,
        sandboxAgentName: String? = nil
    ) -> ProcessingResult? {
        guard var parsed = parseMarkers(from: toolResult) else {
            NSLog("[SharedArtifact] parseMarkers failed – markers not found in tool result")
            return nil
        }

        let mimeType = parsed.metadata["mime_type"] as? String ?? "application/octet-stream"
        let description = parsed.metadata["description"] as? String
        let hasContent = parsed.metadata["has_content"] as? Bool ?? false
        let path = parsed.metadata["path"] as? String

        // Strip any path segments the agent may have smuggled into the filename
        // (e.g. `../quarterly.md`) before we resolve it against the context dir.
        let sanitizedFilename = sanitizeArtifactFilename(parsed.filename)
        if sanitizedFilename != parsed.filename {
            NSLog(
                "[SharedArtifact] Sanitized artifact filename '%@' → '%@'",
                parsed.filename,
                sanitizedFilename
            )
        }
        parsed.filename = sanitizedFilename
        parsed.metadata["filename"] = sanitizedFilename

        let contextDir = OsaurusPaths.contextArtifactsDir(contextId: contextId)
        OsaurusPaths.ensureExistsSilent(contextDir)
        guard let destPath = resolveDestinationPath(filename: parsed.filename, contextDir: contextDir) else {
            NSLog("[SharedArtifact] Refused destination path for filename '%@'", parsed.filename)
            return nil
        }

        let artifact: SharedArtifact
        let contentLines: [String]

        if hasContent {
            let textContent = parsed.contentLines.joined(separator: "\n")
            try? textContent.write(to: destPath, atomically: true, encoding: .utf8)

            artifact = SharedArtifact(
                contextId: contextId,
                contextType: contextType,
                filename: parsed.filename,
                mimeType: mimeType,
                fileSize: textContent.utf8.count,
                hostPath: destPath.path,
                content: textContent,
                description: description,
                isFinalResult: false
            )
            contentLines = parsed.contentLines

        } else if let path {
            guard
                let source = resolveSourcePath(
                    path,
                    executionMode: executionMode,
                    sandboxAgentName: sandboxAgentName
                )
            else {
                NSLog(
                    "[SharedArtifact] Could not resolve '%@' (mode=%@, agent=%@)",
                    path,
                    String(describing: executionMode),
                    sandboxAgentName ?? "nil"
                )
                return nil
            }

            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
                NSLog("[SharedArtifact] File not found: %@", source.path)
                return nil
            }
            let isDirectory = isDir.boolValue

            if fm.fileExists(atPath: destPath.path) { try? fm.removeItem(at: destPath) }
            do { try fm.copyItem(at: source, to: destPath) } catch {
                NSLog(
                    "[SharedArtifact] Copy failed %@ → %@: %@",
                    source.path,
                    destPath.path,
                    error.localizedDescription
                )
                return nil
            }

            let fileSize =
                isDirectory
                ? OsaurusPaths.directorySize(at: destPath)
                : (try? fm.attributesOfItem(atPath: destPath.path)[.size] as? Int) ?? 0
            let resolvedMime = isDirectory ? "inode/directory" : mimeType

            artifact = SharedArtifact(
                contextId: contextId,
                contextType: contextType,
                filename: parsed.filename,
                mimeType: resolvedMime,
                fileSize: fileSize,
                hostPath: destPath.path,
                isDirectory: isDirectory,
                description: description,
                isFinalResult: false
            )
            if isDirectory { parsed.metadata["is_directory"] = true; parsed.metadata["mime_type"] = resolvedMime }
            contentLines = []

        } else {
            NSLog("[SharedArtifact] No content and no path in metadata for '\(parsed.filename)'")
            return nil
        }

        parsed.metadata["host_path"] = artifact.hostPath
        parsed.metadata["context_id"] = contextId
        parsed.metadata["context_type"] = contextType.rawValue
        parsed.metadata["file_size"] = artifact.fileSize
        let enriched = rebuildToolResult(toolResult, parsed: parsed, contentLines: contentLines)
        return ProcessingResult(artifact: artifact, enrichedToolResult: enriched)
    }

    /// Reconstructs a SharedArtifact from an enriched tool result string (for display).
    /// Only succeeds when the result has been enriched with host_path, context_id, etc.
    ///
    /// Accepts both shapes:
    ///   - the legacy raw marker-delimited string (used by mock data and any
    ///     plugin author still emitting markers directly), and
    ///   - the new `ToolEnvelope.success` envelope whose `result.text`
    ///     carries the marker block — extracted before parsing.
    static func fromEnrichedToolResult(_ result: String) -> SharedArtifact? {
        let markerSource: String
        if let payload = ToolEnvelope.successPayload(result) as? [String: Any],
            let text = payload["text"] as? String
        {
            markerSource = text
        } else {
            markerSource = result
        }
        guard let parsed = parseMarkers(from: markerSource) else { return nil }

        let filename = parsed.filename
        let mimeType = parsed.metadata["mime_type"] as? String ?? "application/octet-stream"
        let description = parsed.metadata["description"] as? String
        let hostPath = parsed.metadata["host_path"] as? String ?? ""
        let contextId = parsed.metadata["context_id"] as? String ?? ""
        let contextTypeRaw = parsed.metadata["context_type"] as? String
        let contextType = contextTypeRaw.flatMap(ArtifactContextType.init(rawValue:)) ?? .chat
        let fileSize = parsed.metadata["file_size"] as? Int ?? 0
        let isDirectory = parsed.metadata["is_directory"] as? Bool ?? false
        let hasContent = parsed.metadata["has_content"] as? Bool ?? false
        let textContent = hasContent ? parsed.contentLines.joined(separator: "\n") : nil

        return SharedArtifact(
            contextId: contextId,
            contextType: contextType,
            filename: filename,
            mimeType: mimeType,
            fileSize: fileSize > 0 ? fileSize : (textContent?.utf8.count ?? 0),
            hostPath: hostPath,
            isDirectory: isDirectory,
            content: textContent,
            description: description
        )
    }

    /// Best-effort artifact construction from a raw (non-enriched) tool result.
    /// Used as a fallback when `processToolResult` fails (e.g. file can't be copied
    /// from sandbox), so artifact handler plugins still receive metadata.
    static func fromToolResultFallback(
        _ toolResult: String,
        contextId: String,
        contextType: ArtifactContextType
    ) -> SharedArtifact? {
        guard let parsed = parseMarkers(from: toolResult) else { return nil }

        let mimeType = parsed.metadata["mime_type"] as? String ?? "application/octet-stream"
        let description = parsed.metadata["description"] as? String
        let hasContent = parsed.metadata["has_content"] as? Bool ?? false
        let textContent = hasContent ? parsed.contentLines.joined(separator: "\n") : nil

        return SharedArtifact(
            contextId: contextId,
            contextType: contextType,
            filename: parsed.filename,
            mimeType: mimeType,
            fileSize: textContent?.utf8.count ?? 0,
            hostPath: "",
            content: textContent,
            description: description
        )
    }

    // MARK: - Private Helpers

    /// Maps an agent-provided path to the host-side URL, normalizing absolute
    /// in-container paths, `./` prefixes, and falling back to a basename search.
    /// Every returned URL is canonicalized and verified to live inside the
    /// caller's trusted root — a crafted `../` path cannot escape the sandbox
    /// agent dir, the container workspace, or the user-picked host folder.
    private static func resolveSourcePath(
        _ path: String,
        executionMode: ExecutionMode,
        sandboxAgentName: String?
    ) -> URL? {
        switch executionMode {
        case .sandbox:
            let agent = sandboxAgentName ?? "default"
            let agentDir = OsaurusPaths.containerAgentDir(agent)
            let containerHome = OsaurusPaths.inContainerAgentHome(agent)

            var relativePath = path
            if relativePath.hasPrefix(containerHome + "/") {
                relativePath = String(relativePath.dropFirst(containerHome.count + 1))
            } else if relativePath.hasPrefix("/workspace/") {
                let stripped = String(relativePath.dropFirst("/workspace/".count))
                return resolveContainedPath(stripped, within: OsaurusPaths.containerWorkspace())
            }
            if relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }
            // After the container-absolute prefixes above are stripped, any
            // remaining leading `/` means the agent handed us an unrelated
            // absolute path — refuse rather than let basename-fallback guess.
            guard !relativePath.hasPrefix("/") else { return nil }

            if let primary = resolveContainedPath(relativePath, within: agentDir) {
                return primary
            }

            // Basename fallback in common output subdirectories, still contained.
            guard let basename = extractPathComponent(path) else { return nil }
            for sub in ["output", "out", "build", "dist"] {
                if let attempt = resolveContainedPath("\(sub)/\(basename)", within: agentDir) {
                    return attempt
                }
            }
            return nil

        case .hostFolder(let ctx):
            return resolveContainedPath(path, within: ctx.rootPath)

        case .none:
            return nil
        }
    }

    /// Resolves an artifact destination under `contextDir`, refusing anything
    /// that would escape the context directory via `..`, symlinks, or an
    /// absolute path smuggled in through the filename.
    private static func resolveDestinationPath(filename: String, contextDir: URL) -> URL? {
        let contextRoot = canonicalizedURL(contextDir)
        let destination = contextRoot.appendingPathComponent(filename).standardizedFileURL
        guard isContained(destination, in: contextRoot) else { return nil }
        return destination
    }

    /// Resolves a caller-supplied relative or absolute path against `root`,
    /// canonicalizes it, and returns it only if it still lives inside `root`.
    /// Does not require the target to exist — callers do their own existence check.
    private static func resolveContainedPath(_ rawPath: String, within root: URL) -> URL? {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        let rootURL = canonicalizedURL(root)
        let candidate =
            trimmedPath.hasPrefix("/")
            ? URL(fileURLWithPath: trimmedPath)
            : rootURL.appendingPathComponent(trimmedPath)
        let resolved = canonicalizedURL(candidate)

        guard isContained(resolved, in: rootURL) else { return nil }
        return resolved
    }

    private static func sanitizeArtifactFilename(_ rawFilename: String) -> String {
        extractPathComponent(rawFilename) ?? "artifact"
    }

    /// Returns a safe single-segment basename, or nil if nothing usable remains.
    /// Normalizes both POSIX and Windows-style separators because agents have
    /// been observed to hand us either.
    private static func extractPathComponent(_ rawPath: String) -> String? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        let basename = (normalized as NSString).lastPathComponent
        let sanitized = basename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(sanitized)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
        return cleaned
    }

    private static func canonicalizedURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func rebuildToolResult(
        _ original: String,
        parsed: ParsedMarkers,
        contentLines: [String]
    ) -> String {
        let prefix = String(original[..<parsed.startRange.upperBound])
        let suffix = String(original[parsed.endRange.lowerBound...])

        var inner = ""
        if let jsonData = try? JSONSerialization.data(withJSONObject: parsed.metadata),
            let jsonStr = String(data: jsonData, encoding: .utf8)
        {
            inner = jsonStr
        }
        if !contentLines.isEmpty {
            inner += "\n" + contentLines.joined(separator: "\n")
        }

        return prefix + inner + suffix
    }
}
