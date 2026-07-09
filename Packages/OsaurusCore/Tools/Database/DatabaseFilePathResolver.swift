//
//  DatabaseFilePathResolver.swift
//  osaurus
//
//  Dual-root path resolution for Agent DB file tools (`db_import`,
//  `db_export`, `db_execute` path mode). Reads and writes may target
//  files under the Linux sandbox agent dir (host-visible at
//  `OsaurusPaths.containerAgentDir`) or the bound host working folder.
//

import Foundation

enum DatabaseFilePathResolver {
    enum Scope: String, Sendable {
        case sandbox
        case hostFolder
    }

    struct Resolved: Sendable {
        let url: URL
        let scope: Scope
    }

    enum Outcome: Sendable {
        case resolved(Resolved)
        case failed(envelope: String)
    }

    /// Resolve a path for reading an existing file (import / SQL script).
    static func resolveForRead(path: String, tool: String) async -> Outcome {
        var rootsChecked: [String] = []
        var candidates: [(URL, Scope)] = []

        if let agentName = await currentSandboxAgentName() {
            rootsChecked.append("sandbox workspace for agent `\(agentName)`")
            candidates.append(contentsOf: sandboxCandidates(path: path, agentName: agentName))
        }

        if let root = await hostWorkingFolderRoot() {
            rootsChecked.append("host working folder `\(root.path)`")
            if let url = try? FolderToolHelpers.resolvePath(path, rootPath: root) {
                candidates.append((url, .hostFolder))
            }
        }

        guard !rootsChecked.isEmpty else {
            return .failed(
                envelope: ToolEnvelope.failure(
                    kind: .unavailable,
                    message:
                        "`\(tool)` reads files from your sandbox workspace or host "
                        + "working folder, but neither is available in this session. "
                        + "Run in sandbox mode or ask the user to pick a working folder, "
                        + "then retry. Fallback for tabular data: one `db_insert` with "
                        + "a `rows` array instead of row-by-row inserts.",
                    tool: tool,
                    retryable: false
                )
            )
        }

        for (url, scope) in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return .resolved(Resolved(url: url, scope: scope))
            }
        }

        let tried = candidates.map(\.0.path).joined(separator: ", ")
        return .failed(
            envelope: ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "No file at `\(path)`. Checked: \(rootsChecked.joined(separator: "; "))."
                    + (tried.isEmpty ? "" : " Candidate paths: \(tried)."),
                field: "path",
                tool: tool,
                retryable: false
            )
        )
    }

    /// Resolve a destination path for writing (export). Creates parent
    /// directories when `createParents` is true.
    static func resolveForWrite(
        path: String,
        tool: String,
        overwrite: Bool,
        createParents: Bool = true
    ) async -> Outcome {
        var rootsChecked: [String] = []
        var candidates: [(URL, Scope)] = []

        if let agentName = await currentSandboxAgentName() {
            rootsChecked.append("sandbox workspace for agent `\(agentName)`")
            if let url = primarySandboxCandidate(path: path, agentName: agentName) {
                candidates.append((url, .sandbox))
            }
        }

        if let root = await hostWorkingFolderRoot() {
            rootsChecked.append("host working folder `\(root.path)`")
            if let url = try? FolderToolHelpers.resolvePath(path, rootPath: root) {
                candidates.append((url, .hostFolder))
            }
        }

        guard !rootsChecked.isEmpty else {
            return .failed(
                envelope: ToolEnvelope.failure(
                    kind: .unavailable,
                    message:
                        "`\(tool)` writes files to your sandbox workspace or host "
                        + "working folder, but neither is available in this session. "
                        + "Run in sandbox mode or ask the user to pick a working folder, "
                        + "then retry.",
                    tool: tool,
                    retryable: false
                )
            )
        }

        guard let (url, scope) = candidates.first else {
            return .failed(
                envelope: ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Path `\(path)` is outside every checked root "
                        + "(\(rootsChecked.joined(separator: "; "))).",
                    field: "path",
                    tool: tool,
                    retryable: false
                )
            )
        }

        if FileManager.default.fileExists(atPath: url.path), !overwrite {
            return .failed(
                envelope: ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "File already exists at `\(path)`. Pass `overwrite: true` "
                        + "to replace it, or choose a different path.",
                    field: "overwrite",
                    tool: tool,
                    retryable: false
                )
            )
        }

        if createParents {
            let parent = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                return .failed(
                    envelope: ToolEnvelope.failure(
                        kind: .executionError,
                        message: "Could not create directory `\(parent.path)`: \(error.localizedDescription)",
                        tool: tool
                    )
                )
            }
        }

        return .resolved(Resolved(url: url, scope: scope))
    }

    /// Read file bytes with the shared 64 MiB cap used by import paths.
    enum ReadTextOutcome: Sendable {
        case text(String)
        case failed(envelope: String)
    }

    static func readTextFile(at url: URL, tool: String) -> ReadTextOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return .failed(
                envelope: ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No file at `\(url.path)`.",
                    field: "path",
                    tool: tool,
                    retryable: false
                )
            )
        }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > DatabaseImport.maxBytes {
            return .failed(
                envelope: ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "File is \(size) bytes; limit is \(DatabaseImport.maxBytes). "
                        + "Split the file or run smaller chunks.",
                    field: "path",
                    tool: tool,
                    retryable: false
                )
            )
        }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                return .failed(
                    envelope: ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "File is not valid UTF-8 text.",
                        field: "path",
                        tool: tool,
                        retryable: false
                    )
                )
            }
            return .text(text)
        } catch {
            return .failed(
                envelope: ToolEnvelope.failure(
                    kind: .executionError,
                    message: "Could not read `\(url.path)`: \(error.localizedDescription)",
                    tool: tool
                )
            )
        }
    }

    /// Resolve `path` and read a UTF-8 text script (SQL, CSV, etc.).
    static func loadTextScript(path: String, tool: String) async -> ReadTextOutcome {
        switch await resolveForRead(path: path, tool: tool) {
        case .failed(let envelope):
            return .failed(envelope: envelope)
        case .resolved(let resolved):
            return readTextFile(at: resolved.url, tool: tool)
        }
    }

    // MARK: - Sandbox identity

    static func currentSandboxAgentName() async -> String? {
        if let bridge = ChatExecutionContext.sandboxReadBridge {
            return bridge.agentName
        }
        if let name = ChatExecutionContext.sandboxAgentName {
            return name
        }
        let captured: String? = await MainActor.run {
            ToolRegistry.shared.activeSandboxAgentContext?.agentName
        }
        if let captured { return captured }
        // Last-resort fallback for entry points that bypass the registry
        // TaskLocal binding. Only trust it when the agent actually has a
        // provisioned sandbox dir — deriving a name from a bare agent id
        // in host-folder mode would fabricate a sandbox root and hijack
        // writes away from the working folder.
        if let agentId = ChatExecutionContext.currentAgentId {
            let name = await MainActor.run {
                SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
            }
            let agentDir = OsaurusPaths.containerAgentDir(name)
            if FileManager.default.fileExists(atPath: agentDir.path) {
                return name
            }
        }
        return nil
    }

    private static func hostWorkingFolderRoot() async -> URL? {
        await MainActor.run {
            FolderToolManager.shared.registeredContext?.rootPath
        }
    }

    // MARK: - Path mapping (mirrors SharedArtifact sandbox resolution)

    private static func sandboxCandidates(path: String, agentName: String) -> [(URL, Scope)] {
        var out: [(URL, Scope)] = []
        if let primary = primarySandboxCandidate(path: path, agentName: agentName) {
            out.append((primary, .sandbox))
        }
        if let basename = extractPathComponent(path) {
            let agentDir = OsaurusPaths.containerAgentDir(agentName)
            for sub in ["output", "out", "build", "dist"] {
                if let attempt = resolveContainedPath("\(sub)/\(basename)", within: agentDir) {
                    out.append((attempt, .sandbox))
                }
            }
        }
        return out
    }

    private static func primarySandboxCandidate(path: String, agentName: String) -> URL? {
        let agentDir = OsaurusPaths.containerAgentDir(agentName)
        let containerHome = OsaurusPaths.inContainerAgentHome(agentName)

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
        guard !relativePath.hasPrefix("/") else { return nil }
        return resolveContainedPath(relativePath, within: agentDir)
    }

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
}
