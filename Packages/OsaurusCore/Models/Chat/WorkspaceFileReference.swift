//
//  WorkspaceFileReference.swift
//  OsaurusCore
//

import Foundation

/// Typed handoff emitted by workspace write/edit tools. The model receives the
/// compact reference while chat presentation adds a mode-appropriate action
/// hint without requiring a second artifact-sharing turn.
struct WorkspaceFileReference: Sendable, Equatable {
    let path: String
    let exportable: Bool

    static func parse(toolResult: String) -> WorkspaceFileReference? {
        guard let payload = ToolEnvelope.successPayload(toolResult) as? [String: Any],
            let reference = payload["file_reference"] as? [String: Any],
            reference["kind"] as? String == "workspace_file",
            let path = reference["path"] as? String,
            !path.isEmpty,
            let exportable = reference["exportable"] as? Bool
        else { return nil }
        return WorkspaceFileReference(path: path, exportable: exportable)
    }

    /// Presentation-only result used by the tool card. The original compact
    /// result remains in model history.
    static func cardResult(toolResult: String, toolName: String) -> String? {
        guard let reference = parse(toolResult: toolResult),
            var payload = ToolEnvelope.successPayload(toolResult) as? [String: Any]
        else { return nil }
        payload["delivery"] = [
            "surface": "file_changes",
            "action": reference.exportable ? "export" : "open_or_reveal",
            "message":
                reference.exportable
                ? "Available in File Changes. Choose Export to save it to the Mac."
                : "Available in the selected working folder and File Changes.",
        ]
        return ToolEnvelope.success(tool: toolName, result: payload)
    }
}
