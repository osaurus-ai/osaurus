//
//  ShareArtifactTool.swift
//  osaurus
//
//  Global built-in for surfacing files / inline content to the chat thread.
//  This is the only sanctioned path that creates an artifact card —
//  `file_write` / `sandbox_write_file` writes never appear in chat.
//
//  Result shape: `ToolEnvelope.success` whose `result.text` carries the
//  legacy marker-delimited blob (`---SHARED_ARTIFACT_START` / `END`)
//  that `SharedArtifact.processToolResult` parses downstream. Migrating
//  the payload itself off markers is tracked separately.
//

import Foundation

/// Unified tool for sharing files or inline content with the user.
public struct ShareArtifactTool: OsaurusTool {
    public let name = "share_artifact"
    public let description =
        "Surface an artifact to the user in the chat thread. The chat does NOT show files you wrote to disk or "
        + "to the sandbox unless you also call this tool — it is the only path that creates an artifact card the "
        + "user can click. Use for generated images, charts, websites, reports, code blobs, and any deliverable. "
        + "**The file must already exist before this call — `share_artifact` does NOT create files.** "
        + "Pass `path` to share an existing file (under your working folder, or under your sandbox home / "
        + "`/workspace/...`), or `content` + `filename` to share inline text/markdown without writing to disk first. "
        + "If unsure where you wrote a file, list it first with `sandbox_search_files(target=\"files\", pattern=\"<name>\")` "
        + "(sandbox) or `file_tree`/`file_search` (folder mode). Required: at least one of `path` or `content`."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Path to an existing file or directory. In sandbox mode: relative to the agent home "
                        + "(e.g. `report.pdf`, `output/chart.svg`) or `/workspace/...` absolute. In folder mode: "
                        + "relative to the working folder. The file MUST exist — this tool does not create files."
                ),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string(
                    "Inline text or markdown content to share directly. Use this when you want to share "
                        + "generated text without writing to a file first. Omit entirely when using `path` — do "
                        + "NOT pass an empty string."
                ),
            ]),
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "Filename for the artifact. Required when using `content`. Optional with `path` (defaults "
                        + "to the file/directory basename). Omit entirely when not used — do NOT pass an empty string."
                ),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("Brief human-readable description of what this artifact is."),
            ]),
        ]),
        "required": .array([]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let json) = argsReq else { return argsReq.failureEnvelope ?? "" }

        // Empty-string filler bug: many models pass `content: ""` and
        // `filename: ""` as placeholders for unused optional fields when
        // they only mean to share a path. Treat empty / whitespace-only
        // strings as absent so the path-mode validator doesn't trip.
        func nonEmpty(_ value: Any?) -> String? {
            guard let s = value as? String else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : s
        }

        let path = nonEmpty(json["path"])
        let rawContent = nonEmpty(json["content"])
        let filename = nonEmpty(json["filename"])
        let description = nonEmpty(json["description"])

        guard path != nil || rawContent != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "At least one of `path` or `content` must be provided (and non-empty). "
                    + "Pass `path` to share an existing file, or `content` + `filename` for inline text.",
                tool: name
            )
        }

        if rawContent != nil {
            guard filename != nil else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`filename` is required when using `content` mode.",
                    field: "filename",
                    expected: "non-empty filename string",
                    tool: name
                )
            }
        }

        // Reject content containing either marker token — there's no
        // escape mechanism, so an embedded marker would silently truncate
        // the artifact at parse time. Match the bare token (no surrounding
        // newline) so adversarial inputs like `---SHARED_ARTIFACT_START---X`
        // are still caught.
        let startToken = "---SHARED_ARTIFACT_START---"
        let endToken = "---SHARED_ARTIFACT_END---"
        if let rawContent,
            rawContent.contains(startToken) || rawContent.contains(endToken)
        {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`content` contains a reserved artifact marker "
                    + "(`\(startToken)` or `\(endToken)`) which would corrupt parsing. "
                    + "Strip the marker or share the content as a file.",
                field: "content",
                expected: "string without artifact marker substrings",
                tool: name
            )
        }

        let content = rawContent?
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")

        let resolvedFilename: String
        if let filename, !filename.isEmpty {
            resolvedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let path {
            resolvedFilename = (path as NSString).lastPathComponent
        } else {
            resolvedFilename = "artifact.txt"
        }

        let mimeType = SharedArtifact.mimeType(from: resolvedFilename)

        var metadataDict: [String: Any] = [
            "filename": resolvedFilename,
            "mime_type": mimeType,
        ]
        if let path { metadataDict["path"] = path }
        if content != nil { metadataDict["has_content"] = true }
        if let description { metadataDict["description"] = description }

        let metadataJSON: String
        if let jsonData = try? JSONSerialization.data(withJSONObject: metadataDict),
            let jsonStr = String(data: jsonData, encoding: .utf8)
        {
            metadataJSON = jsonStr
        } else {
            metadataJSON = "{}"
        }

        var marker = """
            Artifact shared:
            - Filename: \(resolvedFilename)
            - Type: \(mimeType)
            """
        if let description {
            marker += "\n- Description: \(description)"
        }

        marker += "\n\n\(SharedArtifact.startMarker)"
        marker += metadataJSON + "\n"
        if let content {
            marker += content + "\n"
        }
        marker += SharedArtifact.endMarker

        // The marker substring is parsed by `SharedArtifact.processToolResult`
        // post-execute, so we ride it in the envelope's `text` field.
        // `ChatView.processShareArtifactResult` rewrites the result into a
        // failure envelope if path-mode resolve/copy then fails.
        return ToolEnvelope.success(tool: name, text: marker)
    }
}
