//
//  WorkspaceShareRoute.swift
//  osaurus
//
//  `/workspace` inside the Linux sandbox is a VirtioFS share of
//  `OsaurusPaths.containerWorkspace()` on the host. Text flows through the
//  sandbox bridge (`sandboxBridgeRead` / `sandboxBridgeWrite`), but a
//  document or image has no useful raw-text form in the VM — the host side
//  owns the extractors (PDFKit, RichDocumentAdapter, XLSX, Vision OCR) and
//  the writers (`FileWriteDocumentRouting`). This helper resolves a sandbox
//  path to its host-side URL, containment-checked against the calling
//  agent's home and `/workspace/shared` (never another agent's home), so `file_read` /
//  `file_write` and the `sandbox_*` twins serve those formats from the share
//  instead of failing on raw bytes.
//

import Foundation

enum WorkspaceShareRoute {
    /// Mount point of the container workspace inside the VM.
    static let mountPoint = "/workspace"

    /// Whether a read of this extension is served host-side (document
    /// extraction, workbook preview, image attach/OCR) rather than through
    /// the raw-text bridge. Unsupported document variants (`.xls`, `.pages`,
    /// …) are included so the model gets the honest format envelope instead
    /// of a garbage byte read.
    static func servesRead(extension ext: String) -> Bool {
        switch WorkspaceFileFormatPolicy.readSupport(for: ext) {
        case .extractedText, .workbook, .image, .unsupportedDocument:
            return true
        case .rawText:
            return false
        }
    }

    /// Whether a write of this extension is a generated document
    /// (`.xlsx` / `.docx` / `.pdf`) that must run through the host writers.
    static func servesWrite(extension ext: String) -> Bool {
        FileWriteDocumentRouting.target(forExtension: ext) != nil
    }

    /// Absolute sandbox path for a model-supplied path (relative to the
    /// agent home or absolute under the allowed roots). `nil` when the
    /// sanitizer rejects it — the caller falls back to the bridge, whose
    /// envelope carries the specific rejection reason.
    static func absoluteSandboxPath(_ path: String, home: String) -> String? {
        SandboxPathSanitizer.sanitize(path, agentHome: home)
    }

    /// Path relative to the share root for an absolute `/workspace/...`
    /// path, or `nil` when the path is not under the mount point.
    static func shareRelativePath(forSandboxPath path: String) -> String? {
        guard path == mountPoint || path.hasPrefix(mountPoint + "/") else { return nil }
        var relative = String(path.dropFirst(mountPoint.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    /// Map an absolute `/workspace/...` path to its host-side URL inside
    /// the VirtioFS share, scoped to the calling agent's home and
    /// `/workspace/shared` (`SandboxAgentPathScope`). Symlink-safe, so `..`
    /// traversal and in-share symlinks cannot reach another agent's home
    /// or escape the share.
    static func hostURL(forSandboxPath path: String, home: String) throws -> URL {
        guard let scope = SandboxAgentPathScope(agentHome: home) else {
            throw FolderToolError.invalidArguments("'\(home)' is not a sandbox agent home.")
        }
        guard shareRelativePath(forSandboxPath: path)?.isEmpty == false else {
            throw FolderToolError.invalidArguments(
                "'\(path)' is not a file under `\(mountPoint)` — pass a file path "
                    + "under your sandbox home or `\(SandboxAgentPathScope.sharedMountPath)`."
            )
        }
        return try scope.hostURL(forSandboxPath: path)
    }

    /// Host-side root of the share.
    static var shareRoot: URL { OsaurusPaths.containerWorkspace() }

    /// Resolved host-side location of a sandbox file the host should serve.
    struct Resolved {
        /// Absolute sandbox path (`/workspace/agents/NAME/report.pdf`) —
        /// what the model sees in `path`.
        let sandboxPath: String
        /// Share-relative path (`agents/NAME/report.pdf`) for operation logs.
        let shareRelativePath: String
        /// Host URL inside the VirtioFS share.
        let hostURL: URL
        let fileExtension: String
    }

    /// Resolve a model path for host-side serving when its extension
    /// qualifies. Returns `nil` when the extension is plain text (bridge
    /// path), the path is rejected, or it is not under the share.
    static func resolveForRead(path: String, home: String) -> Resolved? {
        resolve(path: path, home: home, qualifies: servesRead(extension:))
    }

    static func resolveForWrite(path: String, home: String) -> Resolved? {
        // The share is created lazily by the sandbox runtime; a document
        // written before the VM has ever started still belongs there, and
        // containment resolution needs the scope roots on disk so firmlinked
        // temp roots resolve symmetrically.
        SandboxAgentPathScope(agentHome: home)?.ensureRootsExist()
        return resolve(path: path, home: home, qualifies: servesWrite(extension:))
    }

    private static func resolve(
        path: String,
        home: String,
        qualifies: (String) -> Bool
    ) -> Resolved? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !ext.isEmpty, qualifies(ext) else { return nil }
        guard let absolute = absoluteSandboxPath(path, home: home),
            let relative = shareRelativePath(forSandboxPath: absolute),
            !relative.isEmpty,
            let hostURL = try? Self.hostURL(forSandboxPath: absolute, home: home)
        else { return nil }
        return Resolved(
            sandboxPath: absolute,
            shareRelativePath: relative,
            hostURL: hostURL,
            fileExtension: ext
        )
    }
}
