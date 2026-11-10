//
//  WorkflowArtifacts.swift
//  osaurus
//
//  The files a run hands the person. A step's `share_artifact` is copied
//  into the run's own files (there is no chat to attach it to); the
//  output's `format: "file"` fields are shown where they are. Both must
//  name a file inside the run's folders. When an agent or the
//  Orchestrator called the workflow from a chat, the files are copied into
//  that chat's artifacts and attached to the turn that made the call.
//

import Foundation

/// Where a run's files may live, and how a step's path names one.
struct WorkflowFileScope: Sendable {
    var folderRoot: URL
    var workspace: URL
    var granted: [URL]
    var sandbox: WorkflowSandboxContext?

    init(folderRoot: URL, workspace: URL, granted: [URL], sandbox: WorkflowSandboxContext? = nil) {
        self.folderRoot = folderRoot
        self.workspace = workspace
        self.granted = granted
        self.sandbox = sandbox
    }

    /// The node's folders, including any the person allowed during this
    /// attempt, and the files this workflow's runs made (a media step's
    /// images, which a later step edits or replies with).
    init(context: WorkflowNodeContext) {
        self.init(
            folderRoot: context.folderRoot, workspace: context.workspace,
            granted: (ChatExecutionContext.workflowGrantedPaths ?? context.grantedPaths)
                + [Self.artifactsRoot(workflowID: context.workflowID)],
            sandbox: context.sandbox)
    }

    /// Every run's files for one workflow.
    static func artifactsRoot(workflowID: UUID) -> URL {
        OsaurusPaths.workflowRunArtifacts(workflowID: workflowID, runID: UUID()).deletingLastPathComponent()
    }

    enum Failure: Error, Equatable {
        case notFound(String)
        case outside(String)
    }

    /// An existing file or folder inside the scope. A relative path is
    /// tried in the working folder, then the workspace; a path in the
    /// sandbox's run workspace maps to the host workspace it shares.
    func resolve(_ raw: String) -> Result<URL, Failure> {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let inVM = sandbox?.inVMWorkingDirectory, path == inVM || path.hasPrefix(inVM + "/") {
            path = workspace.path + path.dropFirst(inVM.count)
        }
        if path == "~" || path.hasPrefix("~/") { path = NSString(string: path).expandingTildeInPath }
        let candidates =
            path.hasPrefix("/")
            ? [URL(fileURLWithPath: path)]
            : [folderRoot, workspace].map { $0.appendingPathComponent(path) }
        let roots = ([folderRoot, workspace] + granted).map(SharedArtifact.canonicalizedURL)
        var inside: URL?
        for candidate in candidates {
            let url = SharedArtifact.canonicalizedURL(candidate)
            guard roots.contains(where: { SharedArtifact.isContained(url, in: $0) }) else { continue }
            if FileManager.default.fileExists(atPath: url.path) { return .success(url) }
            if inside == nil { inside = url }
        }
        if let inside { return .failure(.notFound(inside.path)) }
        return .failure(.outside(candidates.first?.standardized.path ?? path))
    }
}

enum WorkflowArtifactCollector {
    static let shareToolName = "share_artifact"

    struct Shared {
        /// What the step's model or record sees instead of the marker blob.
        var modelResult: String
        var artifact: WorkflowArtifact?
    }

    /// A step's `share_artifact` result: the file (or inline content) is
    /// copied into `directory` and the marker is replaced with a short
    /// confirmation. A result without a marker passes through.
    static func share(_ rawResult: String, nodeID: String, scope: WorkflowFileScope, into directory: URL) -> Shared {
        guard let payload = ToolEnvelope.successPayload(rawResult) as? [String: Any],
            let text = payload["text"] as? String,
            let parsed = SharedArtifact.parseMarkers(from: text)
        else { return Shared(modelResult: rawResult, artifact: nil) }

        func failure(_ message: String, field: String? = nil) -> Shared {
            Shared(
                modelResult: ToolEnvelope.failure(
                    kind: .invalidArgs, message: "share_artifact failed: \(message)", field: field,
                    tool: shareToolName, retryable: true),
                artifact: nil)
        }

        let fm = FileManager.default
        let description = parsed.metadata["description"] as? String
        let destination = uniqueDestination(SharedArtifact.sanitizeArtifactFilename(parsed.filename), in: directory)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let artifact: WorkflowArtifact
        if parsed.metadata["has_content"] as? Bool == true {
            let content = parsed.contentLines.joined(separator: "\n")
            do {
                try content.write(to: destination, atomically: true, encoding: .utf8)
            } catch {
                return failure("could not save `\(destination.lastPathComponent)`: \(error.localizedDescription)")
            }
            artifact = WorkflowArtifact(
                source: .shared, nodeID: nodeID, filename: destination.lastPathComponent,
                mimeType: parsed.metadata["mime_type"] as? String, path: destination.path,
                fileSize: content.utf8.count, description: description)
        } else if let path = parsed.metadata["path"] as? String {
            let source: URL
            switch scope.resolve(path) {
            case .success(let url): source = url
            case .failure(.notFound(let resolved)):
                return failure(
                    "no file at `\(resolved)`. Write it first (relative paths are in the run's workspace), "
                        + "or pass `content` and `filename`.", field: "path")
            case .failure(.outside(let resolved)):
                return failure(
                    "`\(resolved)` is outside the folders this workflow may use. Share a file from the run's "
                        + "workspace or a declared folder, or pass `content` and `filename`.", field: "path")
            }
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
            do {
                try fm.copyItem(at: source, to: destination)
            } catch {
                return failure("could not copy `\(source.path)`: \(error.localizedDescription)")
            }
            let size =
                isDirectory.boolValue
                ? OsaurusPaths.directorySize(at: destination)
                : (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
            artifact = WorkflowArtifact(
                source: .shared, nodeID: nodeID, filename: destination.lastPathComponent,
                mimeType: isDirectory.boolValue ? nil : parsed.metadata["mime_type"] as? String,
                path: destination.path, fileSize: size, isDirectory: isDirectory.boolValue, description: description)
        } else {
            return failure("pass `path` to an existing file, or `content` and `filename`.")
        }

        let confirmation =
            "'\(artifact.filename)' is in this run's files; the person sees it with the result. "
            + "Refer to it by name; do not share it again."
        return Shared(modelResult: ToolEnvelope.success(tool: shareToolName, text: confirmation), artifact: artifact)
    }

    /// `name`, or `name 2`, `name 3`… when a file by that name is already there.
    static func uniqueDestination(_ name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            index += 1
        }
        return candidate
    }

    /// Top-level output properties marked `"format": "file"`: a string, or
    /// an array whose items are.
    static func fileFields(of schema: JSONValue) -> [String] {
        guard let root = schema.objectValue, let properties = root["properties"]?.objectValue else { return [] }
        func isFile(_ value: JSONValue?) -> Bool { value?.objectValue?["format"]?.stringValue == "file" }
        let marked = properties.filter { _, property in
            isFile(property) || isFile(property.objectValue?["items"])
        }.map(\.key)
        var required: [String] = []
        if case .array(let list)? = root["required"] {
            required = list.compactMap(\.stringValue).filter(marked.contains)
        }
        return required + marked.filter { !required.contains($0) }.sorted()
    }

    /// The output's file fields as files. A path that is missing or
    /// outside the run's folders is kept with its `problem`.
    static func outputFiles(_ output: JSONValue, schema: JSONValue, scope: WorkflowFileScope) -> [WorkflowArtifact] {
        guard let values = output.objectValue else { return [] }
        var files: [WorkflowArtifact] = []
        for key in fileFields(of: schema) {
            let paths: [String]
            switch values[key] {
            case .string(let path)?: paths = [path]
            case .array(let items)?: paths = items.compactMap(\.stringValue)
            default: paths = []
            }
            for (index, raw) in paths.enumerated() {
                let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { continue }
                let id = paths.count > 1 ? "output:\(key):\(index)" : "output:\(key)"
                let name = (path as NSString).lastPathComponent
                switch scope.resolve(path) {
                case .success(let url):
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    let size =
                        isDirectory.boolValue
                        ? OsaurusPaths.directorySize(at: url)
                        : (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    files.append(
                        WorkflowArtifact(
                            id: id, source: .output, field: key, filename: url.lastPathComponent, path: url.path,
                            fileSize: size, isDirectory: isDirectory.boolValue))
                case .failure(.notFound(let resolved)):
                    files.append(
                        WorkflowArtifact(
                            id: id, source: .output, field: key, filename: name, path: "",
                            problem: L("No file at \(resolved).")))
                case .failure(.outside(let resolved)):
                    files.append(
                        WorkflowArtifact(
                            id: id, source: .output, field: key, filename: name, path: "",
                            problem: L("\(resolved) is outside the folders this workflow may use.")))
                }
            }
        }
        return files
    }
}

enum WorkflowArtifactForwarder {
    /// A chat in this app called the workflow: an agent's workflow tool or
    /// the Orchestrator's `run_workflow`.
    static func forwards(_ caller: WorkflowCaller) -> Bool {
        (caller.kind == .agent || caller.kind == .orchestrator) && !(caller.sessionID ?? "").isEmpty
            && !caller.isExternalSurface
    }

    /// The files a finished run attaches to its calling chat.
    static func forwardable(_ run: WorkflowRun) -> [WorkflowArtifact] {
        guard run.status.isTerminal, forwards(run.caller) else { return [] }
        return run.artifacts.filter { $0.isAvailable && !$0.isDirectory }
    }

    /// Copies the files into the calling chat's artifacts and leaves them
    /// for the chat to attach once the workflow call returns.
    static func forward(_ run: WorkflowRun) {
        guard let sessionID = run.caller.sessionID else { return }
        for file in forwardable(run) {
            let outcome = SharedArtifact.processTrustedLocalFileResult(
                fileURL: URL(fileURLWithPath: file.path), filename: file.filename, mimeType: file.mimeType,
                description: file.description ?? run.workflowName, contextId: sessionID, contextType: .chat)
            if case .success(let processed) = outcome {
                SpawnArtifactCollector.deposit(processed.artifact, sessionId: sessionID)
            }
        }
    }
}
