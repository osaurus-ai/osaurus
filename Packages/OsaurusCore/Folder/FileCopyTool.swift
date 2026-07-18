//
//  FileCopyTool.swift
//  osaurus
//
//  Combined-mode bridge tool: copies file BYTES between the user's host
//  workspace folder and the Linux sandbox's VirtioFS-backed storage
//  (`/workspace/...`), host-side via FileManager. This is the only way a
//  binary file (PDF, image, archive) crosses the boundary — `file_read`
//  extracts text and `file_write` carries text through tokens, so neither
//  can deliver raw bytes. Registered with the folder tools but visible
//  ONLY in combined sandbox + host-read mode.
//

import Foundation

struct FileCopyTool: OsaurusTool, PermissionedTool {
    let name = "file_copy"
    let description =
        "Copy a file between the user's workspace folder and the sandbox — the only way to move "
        + "binary files (PDFs, images, archives) between them. Bytes are copied directly; nothing "
        + "passes through the conversation. Each path routes like the other file tools: a relative "
        + "path is the workspace, an absolute `/workspace/...` path is the sandbox. To process a "
        + "workspace file with sandbox commands, copy it to a path under your sandbox home first. "
        + "Pass `overwrite: true` to replace an existing destination. "
        + "Example: {\"source\": \"data/report.pdf\", \"destination\": \"/workspace/agents/NAME/report.pdf\"} "
        + "(where `/workspace/agents/NAME` is your sandbox home)"
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "source": .object([
                "type": .string("string"),
                "description": .string(
                    "File to copy: relative path = workspace, `/workspace/...` = sandbox"
                ),
            ]),
            "destination": .object([
                "type": .string("string"),
                "description": .string(
                    "Where to copy it (including the filename): relative path = workspace, "
                        + "`/workspace/...` = sandbox"
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
    /// A host-bound copy mutates the selected folder; the registry's dual
    /// checkpoint (host + sandbox in combined mode) makes every copy land
    /// in the Changes sheet and stay undoable, whichever side it touched.
    var mutatesHostFolder: Bool { true }

    /// Same 512 MB precedent as `SandboxManager.maxArtifactDownloadBytes`:
    /// far above any realistic document, but stops a runaway copy of a
    /// disk image / model checkpoint from filling the sandbox share.
    static let defaultMaxCopyBytes = 512 * 1024 * 1024

    private let rootPath: URL
    private let maxCopyBytes: Int

    init(rootPath: URL, maxCopyBytes: Int = FileCopyTool.defaultMaxCopyBytes) {
        self.rootPath = rootPath
        self.maxCopyBytes = maxCopyBytes
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let sourceReq = requireString(
            args,
            "source",
            expected: "relative workspace path or absolute `/workspace/...` sandbox path",
            tool: name
        )
        guard case .value(let source) = sourceReq else {
            return sourceReq.failureEnvelope ?? ""
        }
        let destinationReq = requireString(
            args,
            "destination",
            expected: "relative workspace path or absolute `/workspace/...` sandbox path",
            tool: name
        )
        guard case .value(let destination) = destinationReq else {
            return destinationReq.failureEnvelope ?? ""
        }
        let overwrite = coerceBool(args["overwrite"]) ?? false

        // Combined-mode-only surface: without the sandbox identity there is
        // no second filesystem to bridge to, so refuse instead of guessing
        // (plain folder mode has shell `cp`; plain sandbox mode has no
        // workspace).
        guard ChatExecutionContext.sandboxReadBridge != nil else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "`file_copy` is only available in combined sandbox + workspace mode. "
                    + "Use `shell_run` (`cp`) in folder mode, or `sandbox_exec` (`cp`) in sandbox mode.",
                tool: name,
                retryable: false
            )
        }

        let sourceRoute = combinedFileRoute(path: source)
        let destinationRoute = combinedFileRoute(path: destination)

        // Host-bound destinations are writes to the user's folder — gated
        // on the same per-agent opt-in as `file_write` / `file_edit`.
        if destinationRoute == .host, !ChatExecutionContext.allowHostFolderWrites {
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
            sourceURL = try FolderToolHelpers.resolvePath(source, rootPath: rootPath)
            // Copying a secret INTO the sandbox is exactly the exfiltration
            // path the combined-mode read denylist exists to block.
            if FolderToolHelpers.shouldRefuseSecret(fileURL: sourceURL) {
                return FolderToolHelpers.secretRefusalEnvelope(relativePath: source, tool: name)
            }
        case .sandbox:
            sourceURL = try Self.resolveSandboxURL(source)
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
                    + "Copy files individually (sandbox-to-sandbox directory copies can use "
                    + "`sandbox_exec` with `cp -r`).",
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
        switch destinationRoute {
        case .host:
            destinationURL = try FolderToolHelpers.resolvePath(destination, rootPath: rootPath)
            // Same tamper gate as `file_write`: a sandbox-driven agent must
            // not create or overwrite secret-shaped files in the workspace.
            if FolderToolHelpers.shouldRefuseSecret(fileURL: destinationURL) {
                return FolderToolHelpers.secretWriteRefusalEnvelope(
                    relativePath: destination,
                    tool: name
                )
            }
        case .sandbox:
            destinationURL = try Self.resolveSandboxURL(destination)
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

        return ToolEnvelope.success(
            tool: name,
            result: [
                "source": source,
                "destination": destination,
                "source_area": Self.areaLabel(sourceRoute),
                "destination_area": Self.areaLabel(destinationRoute),
                "bytes": sourceBytes,
                "overwrote": destinationExists,
            ]
        )
    }

    /// Map an absolute `/workspace/...` path to its host-side URL inside
    /// the VirtioFS share (`OsaurusPaths.containerWorkspace()` is mounted
    /// as `/workspace` in the VM). Reuses `resolvePath` for the
    /// symlink-safe containment check, so `..` traversal and in-share
    /// symlinks cannot escape the container workspace.
    private static func resolveSandboxURL(_ path: String) throws -> URL {
        var relative = String(path.dropFirst("/workspace".count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        guard !relative.isEmpty else {
            throw FolderToolError.invalidArguments(
                "'/workspace' itself is a directory — pass a file path under it "
                    + "(e.g. under your sandbox home)."
            )
        }
        return try FolderToolHelpers.resolvePath(
            relative,
            rootPath: OsaurusPaths.containerWorkspace()
        )
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
