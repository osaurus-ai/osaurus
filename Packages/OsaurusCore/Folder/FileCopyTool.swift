//
//  FileCopyTool.swift
//  osaurus
//
//  Binary-safe file duplicate. In folder mode it copies BYTES between two
//  paths in the user's workspace (version-before-edit, duplicate a
//  template, stage a PDF next to its summary) — `file_read` extracts text
//  and `file_write` carries text through tokens, so neither can deliver
//  raw bytes. When a sandbox bridge is bound, an absolute `/workspace/...`
//  path is the Linux sandbox's VirtioFS share and the copy crosses the
//  boundary host-side via FileManager. Host-side writes are logged as
//  `FileOperation.copy` (previous destination bytes captured, any
//  encoding) so `file_undo` reverts an overwrite exactly.
//

import Foundation

struct FileCopyTool: OsaurusTool, PermissionedTool {
    let name = "file_copy"
    let description =
        "Copy one file to a new path as a raw byte copy — binary-safe (PDFs, images, archives, "
        + "generated .docx/.xlsx), nothing passes through the conversation. Use it to duplicate or "
        + "version a file before editing it. Paths are relative to the working folder and route like "
        + "the other file tools. Pass `overwrite: true` to replace an existing destination (the "
        + "previous bytes stay undoable with `file_undo`). "
        + "Example: {\"source\": \"reports/q3.docx\", \"destination\": \"reports/q3-draft.docx\"}"
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "source": .object([
                "type": .string("string"),
                "description": .string("File to copy, relative to the working folder"),
            ]),
            "destination": .object([
                "type": .string("string"),
                "description": .string(
                    "Where to copy it (including the filename), relative to the working folder"
                ),
            ]),
            "overwrite": .object([
                "type": .string("boolean"),
                "description": .string(
                    "Replace the destination if it already exists (default: false)"
                ),
            ]),
        ]),
        "required": .array([.string("source"), .string("destination")]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }
    /// A host-bound copy mutates the selected folder; the registry's
    /// checkpoint makes every copy land in the Changes sheet and stay
    /// undoable.
    var mutatesHostFolder: Bool { true }

    /// Same 512 MB precedent as `SandboxManager.maxArtifactDownloadBytes`:
    /// far above any realistic document, but stops a runaway copy of a
    /// disk image / model checkpoint from filling the disk.
    static let defaultMaxCopyBytes = 512 * 1024 * 1024

    /// Overwritten destination bytes above this are not captured for undo
    /// (the operation is still logged; undo reports it cannot restore).
    static let maxUndoCaptureBytes = 64 * 1024 * 1024

    private let fixedRootPath: URL?
    private let maxCopyBytes: Int

    init(rootPath: URL? = nil, maxCopyBytes: Int = FileCopyTool.defaultMaxCopyBytes) {
        self.fixedRootPath = rootPath
        self.maxCopyBytes = maxCopyBytes
    }

    /// The executing chat's folder root (TaskLocal scope), or the fixed
    /// root when this instance was built for a known folder. Only needed
    /// for host-side routes; sandbox-to-sandbox copies never touch it.
    private var rootPath: URL? { FolderToolHelpers.resolveRoot(fixed: fixedRootPath) }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let sourceReq = requireString(
            args,
            "source",
            expected: "relative working-folder path or absolute `/workspace/...` sandbox path",
            tool: name
        )
        guard case .value(let source) = sourceReq else {
            return sourceReq.failureEnvelope ?? ""
        }
        let destinationReq = requireString(
            args,
            "destination",
            expected: "relative working-folder path or absolute `/workspace/...` sandbox path",
            tool: name
        )
        guard case .value(let destination) = destinationReq else {
            return destinationReq.failureEnvelope ?? ""
        }
        let overwrite = coerceBool(args["overwrite"]) ?? false

        let bridge = ChatExecutionContext.sandboxReadBridge
        let sourceRoute: CombinedFileRoute = bridge == nil ? .host : combinedFileRoute(path: source)
        let destinationRoute: CombinedFileRoute =
            bridge == nil ? .host : combinedFileRoute(path: destination)

        // Host-bound destinations are writes to the user's folder — when a
        // sandbox is attached they are gated on the same per-agent opt-in
        // as `file_write` / `file_edit`.
        if bridge != nil, destinationRoute == .host, !ChatExecutionContext.allowHostFolderWrites {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "Refused to copy to '\(destination)': the workspace is read-only in sandbox "
                    + "mode, so `file_copy` can only copy INTO the sandbox (a `/workspace/...` "
                    + "destination). The user can enable folder writes in the agent's sandbox "
                    + "settings; meanwhile, deliver files to the user with `share_artifact`.",
                tool: name,
                retryable: false
            )
        }

        let sourceURL: URL
        switch sourceRoute {
        case .host:
            guard let rootPath else {
                return FolderToolHelpers.noActiveFolderEnvelope(tool: name)
            }
            sourceURL = try FolderToolHelpers.resolvePath(source, rootPath: rootPath)
            // Copying a secret INTO the sandbox is exactly the exfiltration
            // path the read denylist exists to block.
            if FolderToolHelpers.shouldRefuseSecret(fileURL: sourceURL) {
                return FolderToolHelpers.secretRefusalEnvelope(relativePath: source, tool: name)
            }
        case .sandbox:
            sourceURL = try Self.resolveSandboxURL(source, home: bridge?.home)
        }

        var sourceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory)
        else {
            throw FolderToolError.fileNotFound(source)
        }
        if sourceIsDirectory.boolValue {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`source` '\(source)' is a directory — `file_copy` copies a single file. "
                    + "Copy files individually, or use `shell_run` with `cp -r` for a directory tree.",
                field: "source",
                expected: "path to a single file",
                tool: name,
                retryable: false
            )
        }

        let sourceBytes =
            (try? FileManager.default.attributesOfItem(atPath: sourceURL.path))?[.size]
            as? Int64 ?? 0
        if sourceBytes > Int64(maxCopyBytes) {
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "'\(source)' is \(Self.formatBytes(sourceBytes)), which exceeds the "
                    + "\(Self.formatBytes(Int64(maxCopyBytes))) copy limit. This is not retryable.",
                tool: name,
                retryable: false
            )
        }

        let destinationURL: URL
        var logRoot: URL? = nil
        switch destinationRoute {
        case .host:
            guard let rootPath else {
                return FolderToolHelpers.noActiveFolderEnvelope(tool: name)
            }
            destinationURL = try FolderToolHelpers.resolvePath(destination, rootPath: rootPath)
            // Same tamper gate as `file_write`: an agent must not create or
            // overwrite secret-shaped files in the workspace.
            if FolderToolHelpers.shouldRefuseSecret(fileURL: destinationURL) {
                return FolderToolHelpers.secretWriteRefusalEnvelope(
                    relativePath: destination,
                    tool: name
                )
            }
            logRoot = rootPath
        case .sandbox:
            destinationURL = try Self.resolveSandboxURL(destination, home: bridge?.home)
        }

        if destinationURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`source` and `destination` resolve to the same file.",
                field: "destination",
                expected: "a path different from `source`",
                tool: name,
                retryable: false
            )
        }

        var destinationIsDirectory: ObjCBool = false
        let destinationExists = FileManager.default.fileExists(
            atPath: destinationURL.path,
            isDirectory: &destinationIsDirectory
        )
        if destinationExists, destinationIsDirectory.boolValue {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`destination` '\(destination)' is an existing directory — include the "
                    + "target filename in the path.",
                field: "destination",
                expected: "a file path including the filename",
                tool: name,
                retryable: false
            )
        }
        if destinationExists, !overwrite {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Destination '\(destination)' already exists. Pass `overwrite: true` to "
                    + "replace it, or choose a different destination.",
                field: "overwrite",
                expected: "`true` to replace the existing file",
                tool: name,
                retryable: false
            )
        }

        // Capture the overwritten bytes (any encoding) before replacing
        // them so the copy is undoable byte-for-byte.
        var previousBytes: Data? = nil
        var previousCaptured = true
        if destinationExists, logRoot != nil {
            let existingSize =
                (try? FileManager.default.attributesOfItem(atPath: destinationURL.path))?[.size]
                as? Int64 ?? 0
            if existingSize <= Int64(Self.maxUndoCaptureBytes) {
                previousBytes = try? Data(contentsOf: destinationURL)
            } else {
                previousCaptured = false
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if destinationExists {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw FolderToolError.operationFailed(
                "Copy failed: \(error.localizedDescription)"
            )
        }

        var result: [String: Any] = [
            "kind": "file_copy_result",
            "source": source,
            "destination": destination,
            "source_area": Self.areaLabel(sourceRoute),
            "destination_area": Self.areaLabel(destinationRoute),
            "bytes": sourceBytes,
            "overwrote": destinationExists,
            "file_reference": [
                "kind": destinationRoute == .host ? "workspace_file" : "sandbox_file",
                "path": destination,
                "exportable": true,
            ],
        ]
        var warnings: [String] = []
        if let logRoot, let sessionId = ChatExecutionContext.currentSessionId {
            let encoded = FileOperation.encodePreviousContent(previousBytes)
            let operation = FileOperation(
                type: .copy,
                path: source,
                destinationPath: destination,
                previousContent: encoded.content,
                previousContentEncoding: encoded.encoding,
                sessionId: sessionId,
                batchId: ChatExecutionContext.currentBatchId,
                rootPath: logRoot.standardizedFileURL.path
            )
            await FileOperationLog.shared.log(operation)
            result["operation_id"] = operation.id.uuidString
            if destinationExists, !previousCaptured {
                warnings.append(
                    "The overwritten destination was larger than \(Self.formatBytes(Int64(Self.maxUndoCaptureBytes))); "
                        + "`file_undo` will remove the copy but cannot restore the previous bytes."
                )
            }
        }
        return ToolEnvelope.success(
            tool: name,
            result: result,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }

    /// Map a sandbox path (relative to the agent home, or absolute
    /// `/workspace/...`) to its host-side URL inside the VirtioFS share
    /// (`OsaurusPaths.containerWorkspace()` is mounted as `/workspace` in
    /// the VM); see `WorkspaceShareRoute`.
    private static func resolveSandboxURL(_ path: String, home: String?) throws -> URL {
        if let home, let absolute = WorkspaceShareRoute.absoluteSandboxPath(path, home: home) {
            return try WorkspaceShareRoute.hostURL(forSandboxPath: absolute)
        }
        return try WorkspaceShareRoute.hostURL(forSandboxPath: path)
    }

    private static func areaLabel(_ route: CombinedFileRoute) -> String {
        switch route {
        case .host: return "workspace"
        case .sandbox: return "sandbox"
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
